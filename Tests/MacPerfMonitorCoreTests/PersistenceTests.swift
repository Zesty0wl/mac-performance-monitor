import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class PersistenceTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-test-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        // WAL sidecar files.
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private func insertTick(
        _ timestamp: Date, footprint: UInt64, pid: Int32 = 1000,
        startTime: Date = Date(timeIntervalSince1970: 1_000_000)
    ) throws {
        let snapshot = Sampler.Snapshot(
            system: Make.system(timestamp: timestamp, pressurePercent: 10),
            processes: [
                Make.process(
                    timestamp: timestamp, pid: pid, startTime: startTime, footprint: footprint)
            ],
            unreadableProcessCount: 3
        )
        try store.insert(snapshot)
    }

    private func count(_ table: String) throws -> Int {
        try store.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    func testInsertAndReadBack() throws {
        let now = Date()
        try insertTick(now, footprint: 250 * 1024 * 1024)

        let system = try store.latestSystemSample()
        XCTAssertNotNil(system)
        XCTAssertEqual(system!.pressurePercent, 10, accuracy: 0.001)

        let processes = try store.latestProcessSamples()
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.physFootprint, 250 * 1024 * 1024)
        XCTAssertEqual(processes.first?.name, "TestProc")
    }

    func testPerformanceIndexesIncludeNetworkDiskAndProcessAge() throws {
        let indexes = try store.databasePool.read { db -> [String: [String]] in
            var result: [String: [String]] = [:]
            for name in ["idx_process_samples_consumer", "idx_processes_last_seen"] {
                result[name] = try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))")
                    .map { $0["name"] as String }
            }
            return result
        }
        XCTAssertEqual(
            indexes["idx_process_samples_consumer"],
            [
                "process_id", "timestamp", "footprint_readable", "phys_footprint",
                "cpu_percent", "energy_impact", "net_total", "disk_read", "disk_written",
            ])
        XCTAssertEqual(indexes["idx_processes_last_seen"], ["last_seen"])
    }

    func testFootprintSeriesRoundTrips() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = ProcessIdentity(pid: 1000, startTime: Date(timeIntervalSince1970: 1_000_000))
        try insertTick(base, footprint: 100 * 1024 * 1024)
        try insertTick(base.addingTimeInterval(2), footprint: 150 * 1024 * 1024)
        try insertTick(base.addingTimeInterval(4), footprint: 200 * 1024 * 1024)

        let series = try store.footprintSeries(for: identity, since: base.addingTimeInterval(-10))
        XCTAssertEqual(series.count, 3)
        let expected: [UInt64] = [100 * 1024 * 1024, 150 * 1024 * 1024, 200 * 1024 * 1024]
        XCTAssertEqual(series.map { $0.1 }, expected)
        // Ascending by time.
        let times = series.map { $0.0 }
        XCTAssertEqual(times, times.sorted())
    }

    func testProcessHistorySliceBoundsAndTier() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = ProcessIdentity(pid: 1000, startTime: Date(timeIntervalSince1970: 1_000_000))
        for i in 0..<10 {
            try insertTick(base.addingTimeInterval(Double(i) * 2), footprint: 100)
        }

        // Raw slice: inclusive on both ends, only the requested interval.
        let slice = try store.processHistories(
            for: [identity], granularity: .raw,
            from: base.addingTimeInterval(4), to: base.addingTimeInterval(10))
        XCTAssertEqual(slice[identity]?.map { $0.date.timeIntervalSince(base) }, [4, 6, 8, 10])

        // An interval with no rows yields no entry (absent, not []).
        let empty = try store.processHistories(
            for: [identity], granularity: .raw,
            from: base.addingTimeInterval(100), to: base.addingTimeInterval(200))
        XCTAssertNil(empty[identity])

        // Roll the raw rows into the minute tier, then slice that tier: the
        // bucketed points land on minute boundaries within the interval.
        try Retention.run(
            store.databasePool, now: base.addingTimeInterval(3 * 3600),
            policy: RetentionPolicy(rawWindow: 3600, minuteWindow: 86_400, hourWindow: 90 * 86_400))
        let minuteSlice = try store.processHistories(
            for: [identity], granularity: .minute,
            from: base.addingTimeInterval(-60), to: base.addingTimeInterval(60))
        XCTAssertFalse(minuteSlice.isEmpty)
        for point in minuteSlice[identity] ?? [] {
            XCTAssertEqual(point.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0)
        }
    }

    func testTouchLastSeenAdvancesCachedProcessRows() throws {
        // Two ticks: the second resolves the process id from the in-memory
        // cache, skipping the upsert — so last_seen stays at the FIRST tick.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = ProcessIdentity(pid: 1000, startTime: Date(timeIntervalSince1970: 1_000_000))
        try insertTick(t0, footprint: 100 * 1024 * 1024)
        try insertTick(t0.addingTimeInterval(600), footprint: 100 * 1024 * 1024)

        func lastSeen() throws -> Double {
            try store.databasePool.read { db in
                try Double.fetchOne(db, sql: "SELECT last_seen FROM processes WHERE pid = 1000")!
            }
        }
        XCTAssertEqual(try lastSeen(), t0.timeIntervalSince1970, accuracy: 0.001)

        // touchLastSeen is what keeps group membership (filtered on last_seen)
        // alive for continuously-cached processes.
        let t2 = t0.addingTimeInterval(7200)
        store.touchLastSeen(keeping: [identity], now: t2)
        XCTAssertEqual(try lastSeen(), t2.timeIntervalSince1970, accuracy: 0.001)

        // An identity that is not cached is left alone.
        let stranger = ProcessIdentity(pid: 4242, startTime: t0)
        store.touchLastSeen(keeping: [stranger], now: t2.addingTimeInterval(600))
        XCTAssertEqual(try lastSeen(), t2.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRetentionRollsRawIntoMinuteAndTrims() throws {
        let now = Date()
        // Three samples in one minute bucket, three hours ago (older than 2h raw window).
        let oldMinute =
            (now.addingTimeInterval(-3 * 3600).timeIntervalSince1970 / 60).rounded(.down) * 60
        let oldBase = Date(timeIntervalSince1970: oldMinute)
        try insertTick(oldBase.addingTimeInterval(0), footprint: 100 * 1024 * 1024)
        try insertTick(oldBase.addingTimeInterval(20), footprint: 200 * 1024 * 1024)
        try insertTick(oldBase.addingTimeInterval(40), footprint: 300 * 1024 * 1024)

        XCTAssertEqual(try count("process_samples"), 3)

        try Retention.run(store.databasePool, now: now)

        // Raw rolled away (older than 2h) and a minute aggregate created.
        XCTAssertEqual(try count("process_samples"), 0)
        XCTAssertEqual(try count("process_minute"), 1)

        let row = try store.databasePool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM process_minute LIMIT 1")
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(SQLInt.read(row!["footprint_min"]), 100 * 1024 * 1024)
        XCTAssertEqual(SQLInt.read(row!["footprint_avg"]), 200 * 1024 * 1024)
        XCTAssertEqual(SQLInt.read(row!["footprint_max"]), 300 * 1024 * 1024)
        // `samples` is the bucket's covered duration in seconds (the time-weight),
        // not a raw-row count: three evenly-spaced rows each hold their value for
        // 20 s across the 60 s bucket → 60. (At 1 s logging duration ≈ row count.)
        XCTAssertEqual(row!["samples"] as Int, 60)

        // System rolled too.
        XCTAssertEqual(try count("system_minute"), 1)
    }

    func testRetentionIsIdempotent() throws {
        let now = Date()
        let oldMinute =
            (now.addingTimeInterval(-3 * 3600).timeIntervalSince1970 / 60).rounded(.down) * 60
        let oldBase = Date(timeIntervalSince1970: oldMinute)
        try insertTick(oldBase, footprint: 100 * 1024 * 1024)
        try insertTick(oldBase.addingTimeInterval(20), footprint: 300 * 1024 * 1024)

        try Retention.run(store.databasePool, now: now)
        let firstAvg = try store.databasePool.read { db in
            try Int64.fetchOne(db, sql: "SELECT footprint_avg FROM process_minute LIMIT 1")
        }
        try Retention.run(store.databasePool, now: now)
        let secondAvg = try store.databasePool.read { db in
            try Int64.fetchOne(db, sql: "SELECT footprint_avg FROM process_minute LIMIT 1")
        }
        XCTAssertEqual(firstAvg, secondAvg)
        XCTAssertEqual(try count("process_minute"), 1)
    }

    func testRetentionRollsWithConfiguredStandardBucket() throws {
        let now = Date()
        // A 300s-aligned bucket three hours ago (older than the 2h raw window).
        let oldBucket =
            (now.addingTimeInterval(-3 * 3600).timeIntervalSince1970 / 300).rounded(.down) * 300
        let base = Date(timeIntervalSince1970: oldBucket)
        // Five samples spread across ~4 minutes: at the default 60s bucket these
        // would land in several buckets, but a 300s standard bucket collapses
        // them into one aggregate row.
        for i in 0..<5 {
            try insertTick(
                base.addingTimeInterval(Double(i) * 50),
                footprint: UInt64((i + 1) * 100) * 1024 * 1024, pid: 1000)
        }

        let policy = RetentionPolicy(standardResBucket: 300)
        try Retention.run(store.databasePool, now: now, policy: policy)

        XCTAssertEqual(try count("process_minute"), 1, "300s bucket should collapse to one row")
        let row = try store.databasePool.read { db in
            try Row.fetchOne(db, sql: "SELECT bucket, samples FROM process_minute LIMIT 1")
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(Int64(row!["bucket"] as Int64) % 300, 0, "bucket key aligns to 300s")
        // `samples` is covered duration (seconds): the five rows' held durations
        // sum to the full 300 s bucket (the last row holds to the bucket end).
        XCTAssertEqual(row!["samples"] as Int, 300, "held durations cover the full 300s bucket")
    }

    func testStandardBucketChangeRealignsWatermarkWithoutCollision() throws {
        // Simulate a mature DB rolled at 60s: a watermark that is a multiple of
        // 60 but NOT of 300. Switching to a 300s bucket must advance the
        // watermark to the next 300 boundary so a new coarse bucket key can
        // never collide with (and overwrite) an existing 60s bucket row.
        try store.databasePool.write { db in
            try Retention.setMeta(db, "minute_watermark", 1_000_060)
            try Retention.setMeta(db, "minute_bucket_seconds", 60)
            try Retention.realignMinuteBucketIfNeeded(db, bucket: 300)
        }
        let (watermark, width) = try store.databasePool.read { db in
            (
                try Retention.meta(db, "minute_watermark"),
                try Retention.meta(db, "minute_bucket_seconds")
            )
        }
        XCTAssertEqual(width, 300)
        XCTAssertNotNil(watermark)
        XCTAssertEqual(watermark!.truncatingRemainder(dividingBy: 300), 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(watermark!, 1_000_060)
    }

    func testRecentRawSurvivesRetention() throws {
        let now = Date()
        try insertTick(now, footprint: 123 * 1024 * 1024)
        try Retention.run(store.databasePool, now: now)
        // Within the 2h window, raw is retained.
        XCTAssertEqual(try count("process_samples"), 1)
    }

    func testSizeCapLeavesDataWhenUnderBudget() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<10 {
            try insertTick(
                base.addingTimeInterval(Double(i)), footprint: 100 * 1024 * 1024,
                pid: Int32(1000 + i))
        }
        let before = try count("process_samples")
        XCTAssertGreaterThan(before, 0)
        try store.databasePool.write { db in
            try Retention.enforceSizeLimit(db, maxBytes: 100 * 1024 * 1024)  // far over
        }
        XCTAssertEqual(
            try count("process_samples"), before, "Nothing should be trimmed under the cap")
    }

    func testSizeCapTrimsOldestSamples() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<40 {
            try insertTick(
                base.addingTimeInterval(Double(i)), footprint: 100 * 1024 * 1024,
                pid: Int32(1000 + i))
        }
        XCTAssertGreaterThan(try count("process_samples"), 0)
        // A 1-byte cap can never be met (the schema pages alone exceed it), so the
        // sample tiers are emptied entirely — proving the trim path runs and that
        // `incremental_vacuum` is valid inside the retention transaction.
        try store.databasePool.write { db in
            try Retention.enforceSizeLimit(db, maxBytes: 1)
        }
        XCTAssertEqual(try count("process_samples"), 0)
        XCTAssertEqual(try count("system_samples"), 0)
    }
}
