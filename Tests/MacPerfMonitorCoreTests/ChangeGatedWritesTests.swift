import GRDB
import XCTest

@testable import MacPerfMonitorCore

/// Covers the change-gated raw write path (`SampleStore.insertChanged`) and the
/// read/roll-up correctness that depends on the resulting SPARSE process rows:
/// time-weighted aggregation, group carry-forward, pressure dominant-process
/// carry-forward (with a staleness bound), and the current-snapshot read.
final class ChangeGatedWritesTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!
    private let mb: UInt64 = 1024 * 1024
    /// A 60-second-aligned instant, so bucket maths is exact in the tests.
    private let base = Date(timeIntervalSince1970: 1_700_000_400)

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-gated-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private func count(_ table: String) throws -> Int {
        try store.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    /// Insert a single-process tick through the change-gated path; returns rows written.
    @discardableResult
    private func gatedTick(
        _ dt: TimeInterval, pid: Int32 = 1000, cpu: Double = 0, fp: UInt64 = 100 * 1024 * 1024,
        pressure: PressureLevel = .normal, bucket: Double = 60
    ) throws -> Int {
        let ts = base.addingTimeInterval(dt)
        return try store.insertChanged(
            Make.system(timestamp: ts, pressure: pressure),
            processes: [Make.process(timestamp: ts, pid: pid, footprint: fp, cpu: cpu)],
            bucket: bucket)
    }

    // MARK: - Gate behaviour

    func testGateSkipsUnchangedButWritesOnChangeAndHeartbeat() throws {
        XCTAssertEqual(try gatedTick(0, cpu: 0, fp: 100 * mb), 1, "first sighting writes")
        XCTAssertEqual(
            try gatedTick(1, cpu: 0, fp: 100 * mb), 0, "unchanged, same bucket → skipped")
        XCTAssertEqual(try gatedTick(2, cpu: 50, fp: 100 * mb), 1, "CPU change writes")
        XCTAssertEqual(try gatedTick(3, cpu: 50, fp: 100 * mb), 0, "still unchanged → skipped")
        XCTAssertEqual(
            try gatedTick(4, cpu: 50, fp: 102 * mb), 1, "footprint change (>512 KB) writes")
        XCTAssertEqual(
            try gatedTick(60, cpu: 50, fp: 102 * mb), 1,
            "new bucket → heartbeat writes even though nothing changed")

        // Four process rows written (ticks 0, 2, 4, 60); the system row is never
        // gated, so all six ticks recorded one.
        XCTAssertEqual(try count("process_samples"), 4)
        XCTAssertEqual(try count("system_samples"), 6)
    }

    func testGateWritesOnFileDescriptorAndDiskChange() throws {
        // Baseline row.
        _ = try store.insertChanged(
            Make.system(timestamp: base),
            processes: [Make.process(timestamp: base, pid: 1000, fdTotal: 10, diskBytesRead: 0)],
            bucket: 60)
        // Only the FD count changed.
        let fdWrite = try store.insertChanged(
            Make.system(timestamp: base.addingTimeInterval(1)),
            processes: [
                Make.process(
                    timestamp: base.addingTimeInterval(1), pid: 1000, fdTotal: 11, diskBytesRead: 0)
            ], bucket: 60)
        XCTAssertEqual(fdWrite, 1, "a change in FD count is material")
        // Only disk I/O advanced.
        let diskWrite = try store.insertChanged(
            Make.system(timestamp: base.addingTimeInterval(2)),
            processes: [
                Make.process(
                    timestamp: base.addingTimeInterval(2), pid: 1000, fdTotal: 11,
                    diskBytesRead: 4096)
            ], bucket: 60)
        XCTAssertEqual(diskWrite, 1, "any disk I/O since the last row is material")
    }

    func testFailedTransactionDoesNotPoisonWriteCaches() throws {
        let system = Make.system(timestamp: base)
        let first = Make.process(timestamp: base, pid: 1000, footprint: 100 * mb)
        let second = Make.process(timestamp: base, pid: 2000, footprint: 200 * mb)

        try store.databasePool.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER abort_second_process
                    BEFORE INSERT ON process_samples
                    WHEN (SELECT pid FROM processes WHERE id = NEW.process_id) = 2000
                    BEGIN
                      SELECT RAISE(ABORT, 'forced rollback');
                    END
                    """)
        }

        XCTAssertThrowsError(
            try store.insertChanged(system, processes: [first, second], bucket: 60))
        XCTAssertEqual(try count("system_samples"), 0)
        XCTAssertEqual(try count("processes"), 0)
        XCTAssertEqual(try count("process_samples"), 0)

        try store.databasePool.write { db in
            try db.execute(sql: "DROP TRIGGER abort_second_process")
        }
        XCTAssertEqual(
            try store.insertChanged(system, processes: [first, second], bucket: 60), 2,
            "the exact retry must not be skipped or reuse rolled-back process IDs")
        XCTAssertEqual(try count("processes"), 2)
        XCTAssertEqual(try count("process_samples"), 2)
    }

    // MARK: - Time-weighted roll-up

    /// The heart of the correctness argument: sparse rows must roll up to a
    /// TIME-weighted mean, not a per-row sample-mean. A value held 50 s then 10 s
    /// inside one 60 s bucket must average by duration, not by row count.
    func testWeightedRollupIsTimeWeightedNotSampleMean() throws {
        // Two rows in bucket [base, base+60): (cpu 10, 100 MB) held for 50 s, then
        // (cpu 50, 200 MB) held for the final 10 s (to the bucket end).
        try store.insert(
            Sampler.Snapshot(
                system: Make.system(timestamp: base),
                processes: [Make.process(timestamp: base, pid: 1000, footprint: 100 * mb, cpu: 10)],
                unreadableProcessCount: 0))
        try store.insert(
            Sampler.Snapshot(
                system: Make.system(timestamp: base.addingTimeInterval(50)),
                processes: [
                    Make.process(
                        timestamp: base.addingTimeInterval(50), pid: 1000, footprint: 200 * mb,
                        cpu: 50)
                ], unreadableProcessCount: 0))

        // now two minutes on, so the bucket is complete and rolls.
        try Retention.run(store.databasePool, now: base.addingTimeInterval(120))

        let row = try store.databasePool.read { db in
            try Row.fetchOne(
                db, sql: "SELECT cpu_avg, footprint_avg, samples FROM process_minute LIMIT 1")
        }
        let cpuAvg: Double = try XCTUnwrap(row)["cpu_avg"]
        // Time-weighted: (10·50 + 50·10) / 60 = 16.67, NOT the sample-mean 30.
        XCTAssertEqual(cpuAvg, 1000.0 / 60.0, accuracy: 0.01)
        // (100·50 + 200·10) MB / 60 s, integer-truncated like the SQL CAST.
        XCTAssertEqual(SQLInt.read(row!["footprint_avg"]), (100 * mb * 50 + 200 * mb * 10) / 60)
        // `samples` is covered duration in seconds — the full bucket.
        XCTAssertEqual(row!["samples"] as Int, 60)
    }

    // MARK: - Group raw carry-forward

    func testGroupRawSeriesCarriesForwardSparseMembers() throws {
        // t0: A=100 MB, B=50 MB (both first-seen → written).
        _ = try store.insertChanged(
            Make.system(timestamp: base),
            processes: [
                Make.process(timestamp: base, pid: 1000, footprint: 100 * mb),
                Make.process(timestamp: base, pid: 2000, footprint: 50 * mb),
            ], bucket: 60)
        // t1: A grows to 200 MB (written); B unchanged (gated → no row at t1).
        _ = try store.insertChanged(
            Make.system(timestamp: base.addingTimeInterval(1)),
            processes: [
                Make.process(timestamp: base.addingTimeInterval(1), pid: 1000, footprint: 200 * mb),
                Make.process(timestamp: base.addingTimeInterval(1), pid: 2000, footprint: 50 * mb),
            ], bucket: 60)

        XCTAssertEqual(try count("process_samples"), 3, "A×2 + B×1 (B's unchanged tick was gated)")

        let ids = try store.databasePool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM processes ORDER BY pid")
        }
        let series = try store.groupSeries(
            processIDs: ids, window: .oneHour, now: base.addingTimeInterval(2))
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].footprint, 150 * mb, "t0 = A(100) + B(50)")
        // The crux: at t1 only A wrote, but B's 50 MB is carried forward, so the
        // group total is 250 — a GROUP BY timestamp would have dropped B and shown 200.
        XCTAssertEqual(series[1].footprint, 250 * mb, "t1 = A(200 written) + B(50 carried forward)")
    }

    // MARK: - Pressure dominant carry-forward

    func testPressureDominantCarriesForwardWithinBucket() throws {
        // Pressure steps normal→warning at t1. The 500 MB process wrote at t0 but
        // is gated at t1 (unchanged), so it has no row at the exact step tick.
        _ = try store.insertChanged(
            Make.system(timestamp: base.addingTimeInterval(10), pressure: .normal),
            processes: [
                Make.process(timestamp: base.addingTimeInterval(10), pid: 1000, footprint: 500 * mb)
            ],
            bucket: 60)
        _ = try store.insertChanged(
            Make.system(timestamp: base.addingTimeInterval(12), pressure: .warning),
            processes: [
                Make.process(timestamp: base.addingTimeInterval(12), pid: 1000, footprint: 500 * mb)
            ],
            bucket: 60)

        let events = try store.pressureEvents(bucket: 60, now: base.addingTimeInterval(60))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(
            events.first?.dominantIdentity?.pid, 1000,
            "dominant is carried forward from t0 despite no process row at the step tick")
        XCTAssertEqual(events.first?.dominantFootprint, 500 * mb)
    }

    func testPressureDominantIgnoresStaleDeadProcess() throws {
        // Small bucket so staleness is easy to cross. Q (800 MB) writes once, then
        // dies; P (500 MB) is alive at the step. With bucket=5, Q's last row is
        // older than one bucket at the step, so it must NOT be crowned dominant.
        _ = try store.insertChanged(
            Make.system(timestamp: base, pressure: .normal),
            processes: [Make.process(timestamp: base, pid: 900, footprint: 800 * mb)],
            bucket: 5)
        // Step 8 s later; only P is present now (Q got no further row).
        _ = try store.insertChanged(
            Make.system(timestamp: base.addingTimeInterval(8), pressure: .warning),
            processes: [
                Make.process(timestamp: base.addingTimeInterval(8), pid: 1000, footprint: 500 * mb)
            ],
            bucket: 5)

        let events = try store.pressureEvents(bucket: 5, now: base.addingTimeInterval(30))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(
            events.first?.dominantIdentity?.pid, 1000,
            "the live 500 MB process wins; the 800 MB one died > 1 bucket ago and is stale")
        XCTAssertEqual(events.first?.dominantFootprint, 500 * mb)
    }

    // MARK: - Current snapshot

    func testLatestProcessSamplesReturnsEachLiveProcess() throws {
        _ = try store.insertChanged(
            Make.system(timestamp: base),
            processes: [
                Make.process(timestamp: base, pid: 1000, footprint: 100 * mb),
                Make.process(timestamp: base, pid: 2000, footprint: 50 * mb),
            ], bucket: 60)
        // Only A changes; B is gated and writes no row at t1.
        _ = try store.insertChanged(
            Make.system(timestamp: base.addingTimeInterval(1)),
            processes: [
                Make.process(timestamp: base.addingTimeInterval(1), pid: 1000, footprint: 200 * mb),
                Make.process(timestamp: base.addingTimeInterval(1), pid: 2000, footprint: 50 * mb),
            ], bucket: 60)

        let latest = try store.latestProcessSamples()
        // Both processes are returned (each its latest row), not just the one that
        // wrote on the final tick.
        XCTAssertEqual(Set(latest.map(\.pid)), [1000, 2000])
        XCTAssertEqual(latest.first(where: { $0.pid == 1000 })?.physFootprint, 200 * mb)
        XCTAssertEqual(latest.first(where: { $0.pid == 2000 })?.physFootprint, 50 * mb)
    }
}
