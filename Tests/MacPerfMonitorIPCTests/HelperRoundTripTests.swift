import Darwin
import Foundation
import MacPerfMonitorCore
import XCTest

@testable import MacPerfMonitorIPC

/// Exercises the real XPC serialization path end to end, in process, with no
/// root and no launchd: an anonymous `NSXPCListener` backed by `HelperService`
/// on one side and a `HelperConnection` on the other. This proves the `@objc`
/// bridge, the JSON `[RawProcessRead]` payload, and the synchronous client
/// wrapper all work together.
final class HelperRoundTripTests: XCTestCase {
    func testANEPowerFailedLaunchBacksOff() async {
        let factory = PowerProcessFixture(
            frame: Data(), executable: "/nonexistent-macperf-tool/powermetrics")
        let sampler = ANEPowerSampler(canSample: { true }, makeProcess: { factory.make() })
        defer { sampler.shutdown() }
        let client = UUID()
        let first = await power(sampler, client: client)
        let second = await power(sampler, client: client)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(factory.processes.count, 1)
        XCTAssertFalse(factory.processes.first?.isRunning ?? true)
    }

    func testANEPowerBadOutputAndEarlyExitBackOffWithoutLeavingAChild() async throws {
        for (frame, exitCode, ignoreTermination) in [
            (Data("not a plist\0".utf8), Optional<Int>.none, true),
            (Data(), Optional(0), false),
            (Data(), Optional(17), false),
        ] {
            let exited = expectation(description: "Invalid power child exits")
            let factory = PowerProcessFixture(
                frame: frame, exitCode: exitCode, ignoreTermination: ignoreTermination)
            let sampler = ANEPowerSampler(
                canSample: { true }, makeProcess: { factory.make() },
                onExit: { _ in exited.fulfill() })
            defer { sampler.shutdown() }
            let client = UUID()
            _ = await power(sampler, client: client)
            await fulfillment(of: [exited], timeout: 5)
            XCTAssertFalse(try XCTUnwrap(factory.processes.first).isRunning)
            let reply = await power(sampler, client: client)
            XCTAssertNil(reply)
            XCTAssertEqual(factory.processes.count, 1)
        }
    }

    func testRealASITopCaptureWhenExplicitlyProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MACPERF_TEST_ANE_CAPTURE"] else {
            throw XCTSkip("A recorded powermetrics plist is required.")
        }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var decoder = ANEPowerFrameDecoder()
        var count = 0
        var active = 0
        var peak = 0.0
        while let data = try file.read(upToCount: 65536), !data.isEmpty {
            for reading in try decoder.append(data) {
                let reading = try XCTUnwrap(reading)
                XCTAssertTrue(reading.isFresh(at: reading.timestamp))
                count += 1
                if reading.watts > 0 { active += 1 }
                peak = max(peak, reading.watts)
            }
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertGreaterThan(active, 0)
        print(
            "ANE PLIST REPLAY: \(count) samples, \(active) nonzero, peak \(peak) W; other data omitted."
        )
    }

    func testANEPowerRoundTripsAndDisconnectReleasesLease() async throws {
        let released = expectation(description: "XPC disconnect releases its power lease")
        let reading = ANEPowerReading(timestamp: Date(), interval: 1.04, watts: 3.25)
        let provider = PowerProviderFixture(reading: reading, released: { released.fulfill() })
        let delegate = HelperListenerDelegate(clientRequirement: nil, power: provider)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let client = HelperConnection(endpoint: listener.endpoint, timeout: 2)
        defer {
            client.invalidate()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }
        let received = await withCheckedContinuation { continuation in
            client.readANEPower { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(received, reading)
        client.invalidate()
        await fulfillment(of: [released], timeout: 3)
    }

    func testANEPowerXPCRejectsStaleReadingsAndExplicitStopReleasesLease() async throws {
        let released = expectation(description: "Explicit stop releases the lease")
        let provider = PowerProviderFixture(
            reading: ANEPowerReading(
                timestamp: Date().addingTimeInterval(-30), interval: 1, watts: 8),
            released: { released.fulfill() })
        let delegate = HelperListenerDelegate(clientRequirement: nil, power: provider)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let client = HelperConnection(endpoint: listener.endpoint, timeout: 2)
        defer {
            client.invalidate()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }
        let received = await withCheckedContinuation { continuation in
            client.readANEPower { continuation.resume(returning: $0) }
        }
        XCTAssertNil(received)
        client.stopANEPower()
        await fulfillment(of: [released], timeout: 3)
    }

    private final class PowerProviderFixture: ANEPowerProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var clients = Set<UUID>()
        private let reading: ANEPowerReading
        private let released: @Sendable () -> Void

        init(reading: ANEPowerReading, released: @escaping @Sendable () -> Void) {
            self.reading = reading
            self.released = released
        }

        func read(for client: UUID, reply: @escaping @Sendable (ANEPowerReading?) -> Void) {
            _ = lock.withLock { clients.insert(client) }
            reply(reading)
        }

        func stop(for client: UUID) {
            if lock.withLock({ clients.remove(client) != nil }) { released() }
        }

        func shutdown() { lock.withLock { clients.removeAll() } }
    }

    func testANEPowerSamplerSharesAChildAndStopsWhenLastClientLeaves() async throws {
        let frame = try powerFixtureFrame()
        let observed = expectation(description: "A native power frame is decoded")
        let stopped = expectation(description: "Last-client stop reaps the child")
        let factory = PowerProcessFixture(frame: frame)
        let sampler = ANEPowerSampler(
            canSample: { true }, makeProcess: { factory.make() },
            onSample: { reading in
                XCTAssertEqual(reading?.watts, 2.5)
                observed.fulfill()
            }, onExit: { _ in stopped.fulfill() })
        defer { sampler.shutdown() }
        let first = UUID()
        let second = UUID()
        _ = await power(sampler, client: first)
        await fulfillment(of: [observed], timeout: 5)
        let reading = await power(sampler, client: second)
        XCTAssertEqual(reading?.watts, 2.5)
        XCTAssertEqual(factory.processes.count, 1)
        sampler.stop(for: first)
        let sharedReading = await power(sampler, client: second)
        XCTAssertEqual(sharedReading?.watts, 2.5)
        let process = try XCTUnwrap(factory.processes.first)
        sampler.stop(for: second)
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertFalse(process.isRunning)
    }

    func testANEPowerSamplerLeaseExpiresAndUnprivilegedCallsDoNotLaunch() async throws {
        let deniedFactory = PowerProcessFixture(frame: try powerFixtureFrame())
        let denied = ANEPowerSampler(canSample: { false }, makeProcess: { deniedFactory.make() })
        let unavailable = await power(denied, client: UUID())
        XCTAssertNil(unavailable)
        XCTAssertTrue(deniedFactory.processes.isEmpty)
        let received = expectation(description: "Lease fixture emits a frame")
        let expired = expectation(description: "An unrenewed power lease stops the child")
        let factory = PowerProcessFixture(frame: try powerFixtureFrame())
        let sampler = ANEPowerSampler(
            canSample: { true }, makeProcess: { factory.make() },
            leaseInterval: 0.5, maintenanceInterval: 0.05, onSample: { _ in received.fulfill() },
            onExit: { _ in expired.fulfill() })
        defer { sampler.shutdown() }
        _ = await power(sampler, client: UUID())
        await fulfillment(of: [received], timeout: 5)
        let process = try XCTUnwrap(factory.processes.first)
        await fulfillment(of: [expired], timeout: 5)
        XCTAssertFalse(process.isRunning)
    }

    private func power(_ sampler: ANEPowerSampler, client: UUID) async -> ANEPowerReading? {
        await withCheckedContinuation { continuation in
            sampler.read(for: client) { continuation.resume(returning: $0) }
        }
    }

    private func powerFixtureFrame() throws -> Data {
        var frame = try PropertyListSerialization.data(
            fromPropertyList: [
                "timestamp": Date(), "elapsed_ns": 1_000_000_000, "processor": ["ane_energy": 2500],
            ], format: .xml, options: 0)
        frame.append(0)
        return frame
    }

    private final class PowerProcessFixture: @unchecked Sendable {
        private let lock = NSLock()
        private let frame: Data
        private let exitCode: Int?
        private let ignoreTermination: Bool
        private let executable: String
        private var children: [Process] = []
        var processes: [Process] { lock.withLock { children } }

        init(
            frame: Data, exitCode: Int? = nil, ignoreTermination: Bool = false,
            executable: String = "/usr/bin/python3"
        ) {
            self.frame = frame
            self.exitCode = exitCode
            self.ignoreTermination = ignoreTermination
            self.executable = executable
        }

        func make() -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            let setup = ignoreTermination ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n" : ""
            let finish = exitCode.map { "sys.exit(\($0))" } ?? "signal.pause()"
            process.arguments = [
                "-u", "-c",
                "import base64, signal, sys\n\(setup)sys.stdout.buffer.write(base64.b64decode('\(frame.base64EncodedString())'))\nsys.stdout.buffer.flush()\n\(finish)",
            ]
            lock.withLock { children.append(process) }
            return process
        }
    }

    func testANEPowerUsesActualIntervalAndSeparatesMissingFromZero() throws {
        let timestamp = Date()
        let report: [String: Any] = [
            "timestamp": timestamp, "elapsed_ns": 1_016_000_000,
            "processor": ["ane_energy": 3048, "ane_power": 9999],
        ]
        let reading = try XCTUnwrap(ANEPowerFrameDecoder.reading(from: report))
        XCTAssertEqual(reading.watts, 3, accuracy: 0.000001)
        XCTAssertEqual(reading.interval, 1.016, accuracy: 0.000001)
        XCTAssertTrue(reading.isFresh(at: timestamp.addingTimeInterval(4)))
        XCTAssertFalse(reading.isFresh(at: timestamp.addingTimeInterval(6)))
        var changed = report
        changed["processor"] = ["ane_energy": 0]
        XCTAssertEqual(ANEPowerFrameDecoder.reading(from: changed)?.watts, 0)
        changed["processor"] = [:] as [String: Any]
        XCTAssertNil(ANEPowerFrameDecoder.reading(from: changed))
        changed["processor"] = ["ane_power": 1500]
        XCTAssertEqual(ANEPowerFrameDecoder.reading(from: changed)?.watts, 1.5)
    }

    func testANEPowerRejectsInvalidNumbersAndFutureReadings() {
        let timestamp = Date()
        for value in [true, -1, Double.nan, Double.infinity, "500"] as [Any] {
            XCTAssertNil(
                ANEPowerFrameDecoder.reading(from: [
                    "timestamp": timestamp, "elapsed_ns": 1_000_000_000,
                    "processor": ["ane_energy": value],
                ]))
        }
        XCTAssertNil(
            ANEPowerFrameDecoder.reading(from: [
                "timestamp": timestamp, "elapsed_ns": 0, "processor": ["ane_energy": 5],
            ]))
        XCTAssertFalse(
            ANEPowerReading(timestamp: timestamp.addingTimeInterval(10), interval: 1, watts: 2)
                .isFresh(at: timestamp))
    }

    func testANEPowerFramesHandleSplitReadsAndEnforceBounds() throws {
        let report: [String: Any] = [
            "timestamp": Date(), "elapsed_ns": 1_000_000_000, "processor": ["ane_energy": 2500],
        ]
        var frame = try PropertyListSerialization.data(
            fromPropertyList: report, format: .xml, options: 0)
        frame.append(0)
        var decoder = ANEPowerFrameDecoder()
        XCTAssertTrue(try decoder.append(frame.prefix(31)).isEmpty)
        XCTAssertEqual(try decoder.append(frame.dropFirst(31)).first??.watts, 2.5)
        XCTAssertEqual(try decoder.append(frame + frame).count, 2)
        XCTAssertThrowsError(
            try decoder.append(
                Data(repeating: 65, count: ANEPowerFrameDecoder.maximumFrameBytes + 1)))
        var malformed = ANEPowerFrameDecoder()
        XCTAssertThrowsError(try malformed.append(Data("invalid\0".utf8)))
    }

    private var listener: NSXPCListener!
    private var delegate: HelperListenerDelegate!
    private var connection: HelperConnection!

    override func setUp() {
        super.setUp()
        // No client requirement: the in-process peer is the test runner, not the
        // signed app, so signature pinning is intentionally skipped here.
        delegate = HelperListenerDelegate(clientRequirement: nil)
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        connection = HelperConnection(endpoint: listener.endpoint, requirement: nil, timeout: 5.0)
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        connection = nil
        listener = nil
        delegate = nil
        super.tearDown()
    }

    func testReadsOwnProcessOverXPC() {
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let reads = connection.readProcesses(pids: [myPID])

        let mine = reads[myPID]
        XCTAssertNotNil(mine, "Expected a read for the test process over XPC")
        XCTAssertEqual(mine?.pid, myPID)
        XCTAssertNotNil(mine?.task, "Own process task info should be readable")
        XCTAssertNotNil(mine?.rusage, "Own process footprint should be readable")
        XCTAssertGreaterThan(mine?.rusage?.physFootprint ?? 0, 0)
    }

    func testEmptyRequestReturnsEmpty() {
        XCTAssertTrue(connection.readProcesses(pids: []).isEmpty)
    }

    func testMultiplePIDsRoundTrip() {
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        // PID 1 (launchd) exists but is not readable at user level; the call
        // must still succeed and return our own process.
        let reads = connection.readProcesses(pids: [myPID, 1])
        XCTAssertNotNil(reads[myPID]?.task)
    }

    // MARK: File descriptors

    func testListsOwnDescriptorsOverXPC() {
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let fds = connection.listFileDescriptors(pid: myPID)
        XCTAssertNotNil(fds, "Expected a descriptor list for the test process")
        // The test runner always has at least a few descriptors open.
        XCTAssertFalse(fds?.isEmpty ?? true, "Own process should report open descriptors")
    }

    // MARK: Termination

    func testTerminatesOwnedChildOverXPC() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["100"]
        try task.run()
        let pid = task.processIdentifier
        XCTAssertGreaterThan(pid, 1)

        let code = connection.terminateProcess(pid: pid, signal: SIGKILL)
        XCTAssertEqual(code, 0, "Killing an owned child process should succeed")

        task.waitUntilExit()
        XCTAssertFalse(task.isRunning, "The child should be gone after SIGKILL")
    }

    func testTerminateRejectsInvalidPID() {
        // pid 0 and negative pids (which would signal a process group) are
        // refused by the daemon's guard rails before any kill(2) is attempted.
        XCTAssertEqual(connection.terminateProcess(pid: 0, signal: SIGKILL), EINVAL)
        XCTAssertEqual(connection.terminateProcess(pid: -1, signal: SIGKILL), EINVAL)
    }

    func testTerminateRejectsDisallowedSignal() {
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        // A non-termination signal is rejected before any kill(2) call, so the
        // test runner is never actually signalled by this assertion.
        XCTAssertEqual(connection.terminateProcess(pid: myPID, signal: SIGHUP), EINVAL)
    }
}
