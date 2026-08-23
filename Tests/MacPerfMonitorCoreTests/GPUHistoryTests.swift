import XCTest

@testable import MacPerfMonitorCore

/// The v13 GPU columns round-trip through the store: device figures on the
/// system rows (nullable), GPU share on the process rows, and both through
/// the minute rollup.
final class GPUHistoryTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-gpu-test-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    func testSystemGPUFiguresRoundTrip() throws {
        let now = Date()
        var sampled = Make.system(timestamp: now.addingTimeInterval(-2), pressurePercent: 10)
        sampled.gpuUtilization = 83
        sampled.gpuPowerWatts = 3.56
        sampled.anePowerWatts = 0.5
        let unsampled = Make.system(timestamp: now, pressurePercent: 10)
        try store.insert(systemSample: sampled)
        try store.insert(systemSample: unsampled)

        let history = try store.systemHistory(.fiveMinutes, now: now)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].gpuUtilization ?? -1, 83, accuracy: 0.001)
        XCTAssertEqual(history[0].gpuPowerWatts ?? -1, 3.56, accuracy: 0.001)
        XCTAssertEqual(history[0].anePowerWatts ?? -1, 0.5, accuracy: 0.001)
        // A tick that did not read the GPU stays distinct from a measured 0.
        XCTAssertNil(history[1].gpuUtilization)
        XCTAssertNil(history[1].gpuPowerWatts)

        let latest = try store.latestSystemSample()
        XCTAssertNil(latest?.gpuUtilization)
    }

    func testProcessGPUShareRoundTrip() throws {
        let now = Date()
        var process = Make.process(timestamp: now, pid: 4242, name: "ollama", footprint: 1 << 30)
        process.gpuTimeNanos = 5_000_000_000
        process.gpuPercent = 42.5
        process.gpuLastActive = now
        let snapshot = Sampler.Snapshot(
            system: Make.system(timestamp: now, pressurePercent: 10),
            processes: [process], unreadableProcessCount: 0)
        try store.insert(snapshot)

        let samples = try store.latestProcessSamples()
        XCTAssertEqual(samples.count, 1)
        let points = try store.processHistory(for: process.id, since: now.addingTimeInterval(-60))
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].gpuPercent, 42.5, accuracy: 0.001)
    }

    func testGPUShareChangeTripsTheWriteGate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ offset: TimeInterval, gpu: Double) -> ProcessSample {
            var p = Make.process(timestamp: start.addingTimeInterval(offset), pid: 99, name: "mlx")
            p.gpuPercent = gpu
            return p
        }
        let system = { (offset: TimeInterval) in
            Make.system(timestamp: start.addingTimeInterval(offset), pressurePercent: 5)
        }
        // Same bucket, nothing but GPU share changing: the first row always
        // lands, a flat GPU share is gated out, a jump is written.
        XCTAssertEqual(
            try store.insertChanged(system(0), processes: [sample(0, gpu: 10)], bucket: 3600), 1)
        XCTAssertEqual(
            try store.insertChanged(system(1), processes: [sample(1, gpu: 10.2)], bucket: 3600), 0)
        XCTAssertEqual(
            try store.insertChanged(system(2), processes: [sample(2, gpu: 35)], bucket: 3600), 1)
    }
}
