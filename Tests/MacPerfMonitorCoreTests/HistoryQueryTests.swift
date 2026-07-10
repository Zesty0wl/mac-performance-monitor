import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class HistoryQueryTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    private let startTime = Date(timeIntervalSince1970: 1_000_000)
    private let mb: UInt64 = 1024 * 1024

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-hquery-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    /// Insert one tick carrying the given (pid, footprint) processes.
    private func insertTick(
        _ timestamp: Date, _ processes: [(pid: Int32, footprint: UInt64, cpu: Double)]
    ) throws {
        let samples = processes.map {
            Make.process(
                timestamp: timestamp, pid: $0.pid, startTime: startTime,
                name: "P\($0.pid)", footprint: $0.footprint, cpu: $0.cpu)
        }
        try store.insert(
            Sampler.Snapshot(
                system: Make.system(timestamp: timestamp),
                processes: samples,
                unreadableProcessCount: 0))
    }

    func testTopConsumersAggregatesRawWindow() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        // P1 footprints 100/150/200 MB (avg 150, peak 200); P2 flat 50 MB. Rows
        // are 1 s apart — the real logging cadence — so each raw row's held
        // duration is one interval and the time-weighted mean equals the simple
        // mean of the three readings.
        try insertTick(base, [(1000, 100 * mb, 10), (2000, 50 * mb, 1)])
        try insertTick(base.addingTimeInterval(1), [(1000, 150 * mb, 20), (2000, 50 * mb, 1)])
        try insertTick(base.addingTimeInterval(2), [(1000, 200 * mb, 30), (2000, 50 * mb, 1)])

        let top = try store.topConsumers(
            window: .oneHour, metric: .averageFootprint,
            limit: 10, now: base.addingTimeInterval(2))

        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top.first?.identity.pid, 1000)
        XCTAssertEqual(top.first?.averageFootprint, 150 * mb)
        XCTAssertEqual(top.first?.peakFootprint, 200 * mb)
        XCTAssertEqual(top.first?.sampleCount, 3)
        XCTAssertEqual(top.first?.averageCPU ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(top.last?.identity.pid, 2000)
        XCTAssertEqual(top.last?.averageFootprint, 50 * mb)
    }

    func testTopConsumersMetricChangesOrdering() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        // P1: 100/100/400 MB -> avg 200, peak 400. P2: flat 250 -> avg 250, peak 250.
        try insertTick(base, [(1000, 100 * mb, 0), (2000, 250 * mb, 0)])
        try insertTick(base.addingTimeInterval(2), [(1000, 100 * mb, 0), (2000, 250 * mb, 0)])
        try insertTick(base.addingTimeInterval(4), [(1000, 400 * mb, 0), (2000, 250 * mb, 0)])

        let byAverage = try store.topConsumers(
            window: .oneHour, metric: .averageFootprint,
            now: base.addingTimeInterval(4))
        XCTAssertEqual(byAverage.first?.identity.pid, 2000, "P2 has the higher average")

        let byPeak = try store.topConsumers(
            window: .oneHour, metric: .peakFootprint,
            now: base.addingTimeInterval(4))
        XCTAssertEqual(byPeak.first?.identity.pid, 1000, "P1 has the higher peak")
    }

    func testTopConsumersReadsMinuteAggregatesForLongerWindow() throws {
        // Two complete minutes of samples, then roll into the minute tier and
        // query a 24-hour window (which is minute-backed).
        let base = Date(timeIntervalSince1970: 1_700_000_400)  // minute-aligned
        // Minute m0: P1 = 100 MB, P2 = 50 MB (x3 samples each).
        for offset in [0.0, 20.0, 40.0] {
            try insertTick(
                base.addingTimeInterval(offset), [(1000, 100 * mb, 10), (2000, 50 * mb, 5)])
        }
        // Minute m1: P1 = 200 MB, P2 = 60 MB (x3 samples each).
        for offset in [60.0, 80.0, 100.0] {
            try insertTick(
                base.addingTimeInterval(offset), [(1000, 200 * mb, 30), (2000, 60 * mb, 5)])
        }

        let now = base.addingTimeInterval(180)  // both minutes complete
        try Retention.run(store.databasePool, now: now)

        let top = try store.topConsumers(
            window: .oneDay, metric: .averageFootprint,
            limit: 10, now: now)

        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top.first?.identity.pid, 1000)
        // Time-weighted average across both minutes: (100*3 + 200*3) / 6 = 150 MB.
        XCTAssertEqual(top.first?.averageFootprint, 150 * mb)
        XCTAssertEqual(top.first?.peakFootprint, 200 * mb)
        // `sampleCount` on a minute-backed window is the summed coverage duration
        // (seconds), not a raw-row count — two full minutes = 120 s. Under change-
        // gating the raw-row count varies with activity, so duration is the honest
        // time-weight the aggregate averages are computed against.
        XCTAssertEqual(top.first?.sampleCount, 120)
        XCTAssertEqual(top.first?.averageCPU ?? 0, 20, accuracy: 0.001)
    }

    func testTopConsumersEmptyWhenNoData() throws {
        let top = try store.topConsumers(
            window: .oneHour, now: Date(timeIntervalSince1970: 1_700_000_400))
        XCTAssertTrue(top.isEmpty)
    }

    func testTopConsumersRankByAverageDiskThroughput() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        var busy = Make.process(
            timestamp: base, pid: 1000, startTime: startTime, name: "Busy",
            diskBytesRead: 1_000, diskBytesWritten: 2_000)
        var quiet = Make.process(
            timestamp: base, pid: 2000, startTime: startTime, name: "Quiet",
            diskBytesRead: 1_000, diskBytesWritten: 2_000)
        try store.insert(Make.system(timestamp: base), processes: [busy, quiet])

        busy.timestamp = base.addingTimeInterval(10)
        busy.diskBytesRead = 81_000
        busy.diskBytesWritten = 22_000
        quiet.timestamp = base.addingTimeInterval(10)
        quiet.diskBytesRead = 11_000
        quiet.diskBytesWritten = 2_000
        try store.insert(
            Make.system(timestamp: base.addingTimeInterval(10)), processes: [busy, quiet])

        let ranked = try store.topConsumers(
            window: .oneHour, metric: .averageDisk, limit: 10,
            now: base.addingTimeInterval(11))
        XCTAssertEqual(ranked.map(\.name), ["Busy", "Quiet"])
        XCTAssertEqual(ranked[0].averageDisk, 10_000, accuracy: 0.001)
        XCTAssertEqual(ranked[1].averageDisk, 1_000, accuracy: 0.001)
    }
}
