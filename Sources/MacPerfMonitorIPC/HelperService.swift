import Darwin
import Foundation
import MacPerfMonitorCore
import os.log

/// Server-side implementation of the helper XPC interface. Runs inside the root
/// daemon. Each call reads the requested PIDs via `ProcessReader` (which, as
/// root, can see system and other-user processes) and returns the results as a
/// JSON-encoded `[RawProcessRead]`.
///
/// Reusable and testable: the same object backs both the real LaunchDaemon and
/// the in-process anonymous-listener used by tests.
public final class HelperService: NSObject, MacPerfMonitorHelperProtocol {
    private let reader = ProcessReader()
    private let log = Logger(subsystem: "uk.co.bzwrd.macperfmonitor", category: "helper")
    private let version: String
    private let power: any ANEPowerProviding
    private let powerClient = UUID()

    public convenience init(version: String = "1") {
        self.init(version: version, power: ANEPowerSampler())
    }

    init(version: String, power: any ANEPowerProviding) {
        self.version = version
        self.power = power
        super.init()
    }

    deinit { power.stop(for: powerClient) }

    func disconnected() { power.stop(for: powerClient) }

    public func readANEPower(reply: @escaping @Sendable (Data?) -> Void) {
        power.read(for: powerClient) { reading in
            reply(reading.flatMap { try? JSONEncoder().encode($0) })
        }
    }

    public func stopANEPower(reply: @escaping () -> Void) {
        power.stop(for: powerClient)
        reply()
    }

    public func readProcesses(_ pids: [NSNumber], reply: @escaping (Data?) -> Void) {
        // Cap the batch defensively so a malformed request cannot ask the daemon
        // to do unbounded work. The system never has anywhere near this many.
        let capped = pids.prefix(8192)
        let reads = capped.map { reader.rawRead($0.int32Value) }
        do {
            let data = try JSONEncoder().encode(Array(reads))
            reply(data)
        } catch {
            log.error("encode failed: \(error.localizedDescription, privacy: .public)")
            reply(nil)
        }
    }

    public func listFileDescriptors(_ pid: NSNumber, reply: @escaping (Data?) -> Void) {
        let fds = reader.openFileDescriptors(pid.int32Value) ?? []
        do {
            let data = try JSONEncoder().encode(fds)
            reply(data)
        } catch {
            log.error("fd encode failed: \(error.localizedDescription, privacy: .public)")
            reply(nil)
        }
    }

    public func terminateProcess(
        _ pid: NSNumber, signal: NSNumber, reply: @escaping (Int32) -> Void
    ) {
        let target = pid.int32Value
        let sig = signal.int32Value
        // Guard rails on a root-privileged signal sender: never touch pid 0/1
        // (the kernel and launchd) and never signal a process group (a negative
        // pid), and only ever deliver the two termination signals the app uses.
        guard target > 1 else {
            log.error("terminate refused: invalid pid \(target, privacy: .public)")
            reply(EINVAL)
            return
        }
        guard sig == SIGTERM || sig == SIGKILL else {
            log.error("terminate refused: disallowed signal \(sig, privacy: .public)")
            reply(EINVAL)
            return
        }
        if kill(target, sig) == 0 {
            log.notice(
                "terminated pid \(target, privacy: .public) with signal \(sig, privacy: .public)")
            reply(0)
        } else {
            let code = errno
            log.error(
                "terminate pid \(target, privacy: .public) failed: errno \(code, privacy: .public)")
            reply(code)
        }
    }

    public func runMemoryTool(_ tool: NSNumber, pid: NSNumber, reply: @escaping (Data?) -> Void) {
        // Map the wire code back to an allow-listed tool. Anything outside the
        // enum is rejected, so a caller can never name an arbitrary executable.
        guard let resolved = MemoryInspection.Tool(rawValue: tool.intValue) else {
            log.error("runMemoryTool refused: unknown tool code \(tool.intValue, privacy: .public)")
            reply(nil)
            return
        }
        let target = pid.int32Value
        guard target > 1 else {
            log.error("runMemoryTool refused: invalid pid \(target, privacy: .public)")
            reply(nil)
            return
        }
        switch MemoryToolRunner.run(resolved, pid: target) {
        case .success(let text):
            log.notice(
                "ran \(resolved.label, privacy: .public) on pid \(target, privacy: .public) (\(text.utf8.count, privacy: .public) bytes)"
            )
            reply(Data(text.utf8))
        case .failure(let error):
            log.error(
                "runMemoryTool \(resolved.label, privacy: .public) pid \(target, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            reply(nil)
        }
    }

    public func ping(reply: @escaping (String) -> Void) {
        reply(version)
    }

    public func terminateForUpdate(reply: @escaping () -> Void) {
        log.notice("terminateForUpdate: exiting so an app update can replace the helper binary")
        power.shutdown()
        reply()
        // Give the reply a moment to flush over XPC, then exit so launchd
        // demand-launches the fresh binary on the next connection. No KeepAlive,
        // so it will not respawn until the app reconnects.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }
}

/// `NSXPCListenerDelegate` that wires each accepted connection to a fresh
/// `HelperService`, optionally pinning the client's code signature first so only
/// the genuine MacPerfMonitor app can call the root daemon.
public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let clientRequirement: String?
    private let version: String
    private let power: any ANEPowerProviding

    /// - Parameter clientRequirement: a code-signing requirement string the
    ///   connecting client must satisfy, or `nil` to accept any client (used by
    ///   the in-process tests, never by the real root daemon).
    public convenience init(clientRequirement: String?, version: String = "1") {
        self.init(clientRequirement: clientRequirement, version: version, power: ANEPowerSampler())
    }

    init(clientRequirement: String?, version: String = "1", power: any ANEPowerProviding) {
        self.clientRequirement = clientRequirement
        self.version = version
        self.power = power
        super.init()
    }

    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Pin the caller's code signature. If the peer does not satisfy the
        // requirement the connection is invalidated by the system, so a rogue
        // process cannot drive the root daemon.
        if let clientRequirement {
            connection.setCodeSigningRequirement(clientRequirement)
        }
        connection.exportedInterface = NSXPCInterface(with: MacPerfMonitorHelperProtocol.self)
        let service = HelperService(version: version, power: power)
        connection.exportedObject = service
        connection.invalidationHandler = { service.disconnected() }
        connection.interruptionHandler = { service.disconnected() }
        connection.resume()
        return true
    }
}
