import Darwin
import Foundation
import MacPerfMonitorCore
import os.log

/// Client side of the helper XPC link, adapting the root daemon to the
/// `PrivilegedReader` the `Sampler` consumes. Lives in `MacPerfMonitorIPC` (not the
/// app) so it can be exercised by tests against an in-process anonymous
/// listener, with no root and no launchd.
///
/// `readProcesses` is synchronous because the sampler calls it from its serial
/// queue: it issues the async XPC call and blocks on a semaphore with a hard
/// timeout, so a wedged or slow daemon can never stall sampling indefinitely.
public final class HelperConnection: PrivilegedReader, @unchecked Sendable {
    private enum Target {
        case machService(String)
        case endpoint(NSXPCListenerEndpoint)
    }

    private let target: Target
    private let serverRequirement: String?
    private let timeout: TimeInterval
    /// A longer ceiling for `runMemoryTool`, whose `heap`/`leaks` subprocess can
    /// legitimately run for several seconds on a large target (the tool itself is
    /// capped at ~30s server-side).
    private let toolTimeout: TimeInterval = 40
    private let log = Logger(subsystem: "uk.co.bzwrd.macperfmonitor", category: "helper-client")

    private let lock = NSLock()
    private var cached: NSXPCConnection?

    /// Connect to the real root daemon by Mach service name, pinning its code
    /// signature so the app only ever talks to the genuine helper.
    public convenience init(
        machServiceName: String = HelperConstants.machServiceName,
        requirement: String? = HelperConstants.peerRequirement(
            forIdentifier: HelperConstants.machServiceName),
        timeout: TimeInterval = 2.0
    ) {
        self.init(target: .machService(machServiceName), requirement: requirement, timeout: timeout)
    }

    /// Connect to an explicit listener endpoint. Used by tests with an
    /// anonymous in-process listener.
    public convenience init(
        endpoint: NSXPCListenerEndpoint, requirement: String? = nil, timeout: TimeInterval = 2.0
    ) {
        self.init(target: .endpoint(endpoint), requirement: requirement, timeout: timeout)
    }

    private init(target: Target, requirement: String?, timeout: TimeInterval) {
        self.target = target
        self.serverRequirement = requirement
        self.timeout = timeout
    }

    /// Tear down the cached connection. Safe to call repeatedly.
    public func invalidate() {
        lock.lock()
        let connection = cached
        cached = nil
        lock.unlock()
        connection?.invalidate()
    }

    public func readANEPower(reply: @escaping @Sendable (ANEPowerReading?) -> Void) {
        guard let connection = currentConnection() else {
            reply(nil)
            return
        }
        let response = PowerReply(reply)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            response.finish(nil)
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in response.finish(nil) }
        guard let helper = proxy as? MacPerfMonitorHelperProtocol else {
            response.finish(nil)
            return
        }
        helper.readANEPower { data in
            guard let data, data.count <= 4096,
                let reading = try? JSONDecoder().decode(ANEPowerReading.self, from: data),
                reading.isFresh(at: Date())
            else {
                response.finish(nil)
                return
            }
            response.finish(reading)
        }
    }

    public func stopANEPower() {
        let connection = lock.withLock { cached }
        guard let connection else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
        (proxy as? MacPerfMonitorHelperProtocol)?.stopANEPower(reply: {})
    }

    private final class PowerReply: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: (@Sendable (ANEPowerReading?) -> Void)?

        init(_ reply: @escaping @Sendable (ANEPowerReading?) -> Void) { self.reply = reply }

        func finish(_ reading: ANEPowerReading?) {
            let callback = lock.withLock {
                let callback = reply
                reply = nil
                return callback
            }
            callback?(reading)
        }
    }

    public func readProcesses(pids: [Int32]) -> [Int32: RawProcessRead] {
        guard !pids.isEmpty, let connection = currentConnection() else { return [:] }

        let resultLock = NSLock()
        var result: [Int32: RawProcessRead] = [:]
        let done = DispatchSemaphore(value: 0)

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, log] error in
            log.error("helper unreachable: \(error.localizedDescription, privacy: .public)")
            // Drop the cached connection so the next tick rebuilds it. Without
            // this a connection wedged after a reboot or update would keep
            // failing until the user toggled coverage off and on by hand.
            self?.clearConnection()
            done.signal()
        }
        guard let helper = proxy as? MacPerfMonitorHelperProtocol else {
            log.error("helper proxy did not conform to the expected interface")
            return [:]
        }

        helper.readProcesses(pids.map { NSNumber(value: $0) }) { data in
            if let data,
                let decoded = try? JSONDecoder().decode([RawProcessRead].self, from: data)
            {
                resultLock.lock()
                for read in decoded { result[read.pid] = read }
                resultLock.unlock()
            }
            done.signal()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            log.error("helper read timed out after \(self.timeout, privacy: .public)s")
            // A wedged daemon: rebuild the connection next time rather than
            // reusing a stuck one indefinitely.
            clearConnection()
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        return result
    }

    /// Ask the root daemon to exit, used just before an app update installs so the
    /// new binary replaces a stopped one and is demand-launched fresh. Best-effort
    /// with a short timeout; our side is invalidated afterwards since the daemon
    /// is on its way out.
    public func terminateHelper() {
        guard let connection = currentConnection() else { return }
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { [log] error in
            log.error(
                "helper terminate unreachable: \(error.localizedDescription, privacy: .public)")
            done.signal()
        }
        if let helper = proxy as? MacPerfMonitorHelperProtocol {
            helper.terminateForUpdate { done.signal() }
            _ = done.wait(timeout: .now() + timeout)
        }
        invalidate()
    }

    /// The build (`CFBundleVersion`) the running daemon was launched from, read via
    /// a short `ping`. Returns nil when the daemon is unreachable. The app compares
    /// this with its own build to detect a STALE helper — an old-binary process
    /// left running after an in-place app update swapped the bundle — so it can be
    /// restarted to pick up the new binary. Synchronous with the standard timeout.
    public func helperBuild() -> String? {
        guard let connection = currentConnection() else { return nil }
        let lock = NSLock()
        var build: String?
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { [log] error in
            log.error("helper ping unreachable: \(error.localizedDescription, privacy: .public)")
            done.signal()
        }
        if let helper = proxy as? MacPerfMonitorHelperProtocol {
            helper.ping { reply in
                lock.lock()
                build = reply
                lock.unlock()
                done.signal()
            }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                log.error("helper ping timed out after \(self.timeout, privacy: .public)s")
                clearConnection()
            }
        }
        lock.lock()
        defer { lock.unlock() }
        return build
    }

    /// List a process's open file descriptors via the root daemon. Returns nil
    /// when the daemon is unreachable or the reply cannot be decoded (so callers
    /// can fall back to a user-level read); an empty array means the process
    /// genuinely has no descriptors. Synchronous with the same hard timeout as
    /// `readProcesses`, so a wedged daemon can never stall the caller.
    public func listFileDescriptors(pid: Int32) -> [OpenFileDescriptor]? {
        guard let connection = currentConnection() else { return nil }

        let resultLock = NSLock()
        var result: [OpenFileDescriptor]?
        let done = DispatchSemaphore(value: 0)

        let proxy = connection.remoteObjectProxyWithErrorHandler { [log] error in
            log.error("helper unreachable: \(error.localizedDescription, privacy: .public)")
            done.signal()
        }
        guard let helper = proxy as? MacPerfMonitorHelperProtocol else {
            log.error("helper proxy did not conform to the expected interface")
            return nil
        }

        helper.listFileDescriptors(NSNumber(value: pid)) { data in
            if let data,
                let decoded = try? JSONDecoder().decode([OpenFileDescriptor].self, from: data)
            {
                resultLock.lock()
                result = decoded
                resultLock.unlock()
            }
            done.signal()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            log.error("helper fd list timed out after \(self.timeout, privacy: .public)s")
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        return result
    }

    /// Force-terminate a process via the root daemon. Returns 0 on success or a
    /// POSIX errno from the daemon (for example `ESRCH` if the process had
    /// already exited, `EPERM` if even root was refused). Returns `EHOSTDOWN`
    /// when the daemon is unreachable or the call times out, so the caller can
    /// tell a transport failure apart from the OS refusing the signal.
    public func terminateProcess(pid: Int32, signal: Int32) -> Int32 {
        guard let connection = currentConnection() else { return EHOSTDOWN }

        let resultLock = NSLock()
        var code: Int32 = EHOSTDOWN
        let done = DispatchSemaphore(value: 0)

        let proxy = connection.remoteObjectProxyWithErrorHandler { [log] error in
            log.error("helper unreachable: \(error.localizedDescription, privacy: .public)")
            done.signal()
        }
        guard let helper = proxy as? MacPerfMonitorHelperProtocol else {
            log.error("helper proxy did not conform to the expected interface")
            return EHOSTDOWN
        }

        helper.terminateProcess(NSNumber(value: pid), signal: NSNumber(value: signal)) { result in
            resultLock.lock()
            code = result
            resultLock.unlock()
            done.signal()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            log.error("helper terminate timed out after \(self.timeout, privacy: .public)s")
            return EHOSTDOWN
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        return code
    }

    /// Run an allow-listed Apple memory tool (`footprint`/`heap`/`leaks`) against
    /// a process via the root daemon, returning its combined stdout/stderr text,
    /// or nil when the daemon is unreachable or the tool failed. Unlike the other
    /// calls this uses a much longer timeout, because `heap`/`leaks` briefly
    /// suspend and walk the whole target and can legitimately take many seconds
    /// on a large process. Synchronous, run off the main thread by the caller.
    public func runMemoryTool(_ tool: MemoryInspection.Tool, pid: Int32) -> String? {
        guard let connection = currentConnection() else { return nil }

        let resultLock = NSLock()
        var result: String?
        let done = DispatchSemaphore(value: 0)

        let proxy = connection.remoteObjectProxyWithErrorHandler { [log] error in
            log.error("helper unreachable: \(error.localizedDescription, privacy: .public)")
            done.signal()
        }
        guard let helper = proxy as? MacPerfMonitorHelperProtocol else {
            log.error("helper proxy did not conform to the expected interface")
            return nil
        }

        helper.runMemoryTool(NSNumber(value: tool.rawValue), pid: NSNumber(value: pid)) { data in
            if let data { result = String(decoding: data, as: UTF8.self) }
            done.signal()
        }

        // The tool itself is capped at ~30s server-side; allow a little longer
        // here so the daemon has time to finish and reply before we give up.
        if done.wait(timeout: .now() + toolTimeout) == .timedOut {
            log.error("helper memory tool timed out after \(self.toolTimeout, privacy: .public)s")
            return nil
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        return result
    }

    private func currentConnection() -> NSXPCConnection? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let connection: NSXPCConnection
        switch target {
        case .machService(let name):
            connection = NSXPCConnection(machServiceName: name, options: .privileged)
        case .endpoint(let endpoint):
            connection = NSXPCConnection(listenerEndpoint: endpoint)
        }
        connection.remoteObjectInterface = NSXPCInterface(with: MacPerfMonitorHelperProtocol.self)
        if let serverRequirement {
            connection.setCodeSigningRequirement(serverRequirement)
        }
        connection.invalidationHandler = { [weak self] in self?.clearConnection() }
        connection.interruptionHandler = { [weak self] in self?.clearConnection() }
        connection.resume()
        cached = connection
        return connection
    }

    private func clearConnection() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
