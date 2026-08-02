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

    // MARK: - Exited processes

    /// Insert a tick and advance `last_seen` for the processes in it, the way the
    /// retention pass does in the running app (`touchLastSeen`). The dimension
    /// upsert is short-circuited by the process-id cache, so without this a
    /// process's `last_seen` would never move off its first sighting.
    private func insertLiveTick(
        _ timestamp: Date, _ processes: [(pid: Int32, footprint: UInt64, cpu: Double)]
    ) throws {
        try insertTick(timestamp, processes)
        store.touchLastSeen(
            keeping: Set(processes.map { ProcessIdentity(pid: $0.pid, startTime: startTime) }),
            now: timestamp)
    }

    /// The picker roster lists processes that have since exited, most recently
    /// seen first. That is the whole point of it: their series is recorded and
    /// chartable but a live-process list can never name them.
    func testExitedProcessesListsThemNewestFirst() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        // P1000 and P3000 stop after the first tick; P2000 keeps reporting.
        try insertLiveTick(base, [(1000, 100 * mb, 0), (2000, 50 * mb, 0), (3000, 20 * mb, 0)])
        try insertLiveTick(base.addingTimeInterval(10), [(2000, 55 * mb, 0), (3000, 25 * mb, 0)])
        try insertLiveTick(base.addingTimeInterval(300), [(2000, 60 * mb, 0)])

        let exited = try store.exitedProcesses(
            since: base.addingTimeInterval(-60), liveWithin: 60)
        XCTAssertEqual(exited.map(\.identity.pid), [3000, 1000], "newest first, running excluded")

        let gone = try XCTUnwrap(exited.first { $0.identity.pid == 1000 })
        XCTAssertEqual(gone.name, "P1000")
        XCTAssertEqual(gone.lastSeen, base)
        XCTAssertEqual(gone.identity.startTime, startTime)
        // The identity is the one the history queries take, so it charts directly.
        XCTAssertFalse(
            try store.processHistory(
                for: gone.identity, window: .oneHour, now: base.addingTimeInterval(300)
            ).isEmpty)
    }

    /// A cap applied before the still-running processes are dropped would be spent
    /// entirely on them: a Mac runs hundreds at once, all sharing the newest
    /// `last_seen`. Excluding them in the query is what makes the cap buy real
    /// coverage of what has exited.
    func testExitedProcessesCapIsNotSpentOnRunningProcesses() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let running: [(pid: Int32, footprint: UInt64, cpu: Double)] =
            (1...20).map { (Int32(5000 + $0), 10 * mb, 0) }
        try insertLiveTick(base, running + [(1000, 100 * mb, 0)])
        try insertLiveTick(base.addingTimeInterval(300), running)

        let exited = try store.exitedProcesses(
            since: base.addingTimeInterval(-60), liveWithin: 60, limit: 5)
        XCTAssertEqual(exited.map(\.identity.pid), [1000])
    }

    /// Search runs in SQL, so a process that exited long ago is reachable even
    /// though the most recent page never reaches back that far.
    func testExitedProcessesSearchesBeyondTheCap() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let needle = Make.process(
            timestamp: base, pid: 42, startTime: startTime, name: "Needle", footprint: 90 * mb)
        try store.insert(Make.system(timestamp: base), processes: [needle])
        store.touchLastSeen(
            keeping: [ProcessIdentity(pid: 42, startTime: startTime)], now: base)
        // Plenty of later churn, then a survivor that keeps the clock moving.
        for i in 0..<10 {
            let ts = base.addingTimeInterval(100 + Double(i))
            try insertLiveTick(ts, [(Int32(7000 + i), 10 * mb, 0), (9999, 5 * mb, 0)])
        }
        try insertLiveTick(base.addingTimeInterval(400), [(9999, 5 * mb, 0)])

        let since = base.addingTimeInterval(-60)
        let page = try store.exitedProcesses(since: since, liveWithin: 60, limit: 3)
        XCTAssertFalse(
            page.contains { $0.name == "Needle" }, "too far back to be on the first page")

        let found = try store.exitedProcesses(
            since: since, matching: "needl", liveWithin: 60, limit: 3)
        XCTAssertEqual(found.map(\.name), ["Needle"])
    }

    /// LIKE wildcards in what the user typed must match literally, not act as
    /// patterns.
    func testExitedProcessesSearchEscapesWildcards() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let odd = Make.process(
            timestamp: base, pid: 42, startTime: startTime, name: "we%rd", footprint: 90 * mb)
        try store.insert(Make.system(timestamp: base), processes: [odd])
        store.touchLastSeen(
            keeping: [ProcessIdentity(pid: 42, startTime: startTime)], now: base)
        try insertLiveTick(base.addingTimeInterval(300), [(9999, 5 * mb, 0)])

        let since = base.addingTimeInterval(-60)
        XCTAssertEqual(
            try store.exitedProcesses(since: since, matching: "we%rd", liveWithin: 60)
                .map(\.name), ["we%rd"])
        XCTAssertTrue(
            try store.exitedProcesses(since: since, matching: "w%d", liveWithin: 60).isEmpty,
            "the % the user typed is a literal, not a wildcard")
    }

    /// Processes last seen before the window are out of scope: the picker offers
    /// what the span being charted can actually draw.
    func testExitedProcessesHonoursWindow() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        try insertLiveTick(base, [(1000, 100 * mb, 0)])
        try insertLiveTick(base.addingTimeInterval(600), [(2000, 50 * mb, 0)])
        try insertLiveTick(base.addingTimeInterval(1200), [(3000, 50 * mb, 0)])

        let recent = try store.exitedProcesses(
            since: base.addingTimeInterval(300), liveWithin: 60)
        XCTAssertEqual(recent.map(\.identity.pid), [2000], "P1000 is older than the window")
    }
}
