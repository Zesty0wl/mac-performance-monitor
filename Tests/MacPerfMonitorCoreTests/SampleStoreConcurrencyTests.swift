import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class SampleStoreConcurrencyTests: XCTestCase {
    private var directory: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "macperfmonitor-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testPruningWaitsForTheDatabaseWriter() throws {
        try assertMaintenanceWaitsForWriter { store, identity in
            store.pruneProcessIDCache(keeping: [identity])
        }
    }

    func testClearingWaitsForTheDatabaseWriter() throws {
        try assertMaintenanceWaitsForWriter { store, _ in
            store.clearProcessIDCache()
        }
    }

    func testLastSeenLookupWaitsEvenWhenTheCacheIsCurrentlyEmpty() throws {
        try assertMaintenanceWaitsForWriter(seedCache: false) { store, identity in
            store.touchLastSeen(keeping: [identity])
        }
    }

    func testPruningPreservesLiveChangeGatesAndEvictsDeadEntries() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_400)
        let live = Make.process(timestamp: timestamp, pid: 1000, footprint: 100 * 1024 * 1024)
        let dead = Make.process(timestamp: timestamp, pid: 2000, footprint: 100 * 1024 * 1024)
        XCTAssertEqual(
            try store.insertChanged(
                Make.system(timestamp: timestamp), processes: [live, dead], bucket: 60), 2)
        store.pruneProcessIDCache(keeping: [live.id])

        let next = timestamp.addingTimeInterval(1)
        let samples = [live, dead].map { original in
            var updated = original
            updated.timestamp = next
            return updated
        }
        XCTAssertEqual(
            try store.insertChanged(Make.system(timestamp: next), processes: samples, bucket: 60), 1
        )
        let rows = try store.databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT processes.pid, COUNT(*) AS count
                    FROM process_samples JOIN processes ON processes.id = process_samples.process_id
                    GROUP BY processes.pid ORDER BY processes.pid
                    """)
        }
        XCTAssertEqual(rows.map { $0["count"] as Int }, [1, 2])
    }

    func testClearingResolvesDeletedIDsAndResetsChangeGates() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_400)
        let sample = Make.process(timestamp: timestamp, pid: 1000, footprint: 100 * 1024 * 1024)
        XCTAssertEqual(
            try store.insertChanged(
                Make.system(timestamp: timestamp), processes: [sample], bucket: 60), 1)
        try store.databasePool.write { db in
            try db.execute(sql: "DELETE FROM processes")
        }
        store.clearProcessIDCache()
        XCTAssertEqual(
            try store.insertChanged(
                Make.system(timestamp: timestamp), processes: [sample], bucket: 60), 1)
        XCTAssertEqual(
            try store.databasePool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM process_samples")
            }, 1)
    }

    func testCommitFailureClearsBothCachesBeforeAnExactRetry() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_400)
        let system = Make.system(timestamp: timestamp)
        let samples = [1000, 2000].map { pid in
            Make.process(timestamp: timestamp, pid: Int32(pid), footprint: 100 * 1024 * 1024)
        }
        try store.databasePool.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE commit_guard (
                        process_id INTEGER REFERENCES processes(id) DEFERRABLE INITIALLY DEFERRED
                    );
                    CREATE TRIGGER fail_process_commit AFTER INSERT ON process_samples
                    WHEN (SELECT pid FROM processes WHERE id = NEW.process_id) = 2000
                    BEGIN
                        INSERT INTO commit_guard (process_id) VALUES (-1);
                    END;
                    """)
        }
        XCTAssertThrowsError(try store.insertChanged(system, processes: samples, bucket: 60)) {
            error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
        }
        try store.databasePool.read { db in
            for table in ["processes", "process_samples", "system_samples", "commit_guard"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0)
            }
        }
        try store.databasePool.write { db in
            try db.execute(sql: "DROP TRIGGER fail_process_commit")
        }
        XCTAssertEqual(try store.insertChanged(system, processes: samples, bucket: 60), 2)
        XCTAssertEqual(try store.insertChanged(system, processes: samples, bucket: 60), 0)
        try store.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processes"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM process_samples"), 2)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testConcurrentWritersAndCacheMaintenanceKeepDatabaseConsistent() throws {
        let store = try XCTUnwrap(store)
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let ticks = 120
        let processesPerWriter = 16
        let live = Set(
            (0..<(2 * processesPerWriter)).map { index in
                Make.process(timestamp: base, pid: Int32(1000 + index)).id
            })
        DispatchQueue.concurrentPerform(iterations: 3) { worker in
            for tick in 0..<ticks {
                if worker == 2 {
                    store.pruneProcessIDCache(keeping: tick.isMultiple(of: 2) ? live : [])
                    store.touchLastSeen(keeping: live, now: base.addingTimeInterval(Double(tick)))
                    if tick.isMultiple(of: 3) { store.clearProcessIDCache() }
                } else {
                    let timestamp = base.addingTimeInterval(Double(tick * 2 + worker))
                    let samples = (0..<processesPerWriter).map { index in
                        Make.process(
                            timestamp: timestamp,
                            pid: Int32(1000 + worker * processesPerWriter + index),
                            footprint: UInt64(100 + tick) * 1024 * 1024)
                    }
                    do {
                        let written = try store.insertChanged(
                            Make.system(timestamp: timestamp), processes: samples, bucket: 60)
                        XCTAssertEqual(written, processesPerWriter)
                    } catch {
                        XCTFail("Concurrent insert failed: \(error)")
                    }
                }
            }
        }
        try store.databasePool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processes"), 2 * processesPerWriter)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM process_samples"),
                2 * processesPerWriter * ticks)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM system_samples"), 2 * ticks)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
        }
        let timestamp = base.addingTimeInterval(300)
        let samples = (0..<(2 * processesPerWriter)).map { index in
            Make.process(timestamp: timestamp, pid: Int32(1000 + index))
        }
        try store.insert(Make.system(timestamp: timestamp), processes: samples)
        let lastSeen = timestamp.addingTimeInterval(60)
        store.touchLastSeen(keeping: live, now: lastSeen)
        XCTAssertEqual(
            try store.databasePool.read { db in
                try Double.fetchAll(db, sql: "SELECT DISTINCT last_seen FROM processes")
            }, [lastSeen.timeIntervalSince1970])
    }

    func testRollbackRecoveryAndConcurrentWritesKeepCachesConsistent() throws {
        let store = try XCTUnwrap(store)
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let ticks = 120
        try store.databasePool.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER reject_process BEFORE INSERT ON process_samples
                    WHEN (SELECT pid FROM processes WHERE id = NEW.process_id) = 9000
                    BEGIN
                        SELECT RAISE(ABORT, 'forced concurrent rollback');
                    END;
                    """)
        }
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            for tick in 0..<ticks {
                let timestamp = base.addingTimeInterval(Double(tick * 2 + worker))
                let system = Make.system(timestamp: timestamp)
                if worker == 0 {
                    let samples = [3000 + tick, 9000].map { pid in
                        Make.process(timestamp: timestamp, pid: Int32(pid))
                    }
                    do {
                        _ = try store.insertChanged(system, processes: samples, bucket: 60)
                        XCTFail("The failing transaction unexpectedly committed")
                    } catch {
                        XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
                    }
                } else {
                    let sample = Make.process(
                        timestamp: timestamp, pid: 1000, footprint: UInt64(100 + tick) * 1024 * 1024
                    )
                    do {
                        let written = try store.insertChanged(
                            system, processes: [sample], bucket: 60)
                        XCTAssertEqual(written, 1)
                    } catch {
                        XCTFail("Successful writer failed during rollback recovery: \(error)")
                    }
                }
            }
        }
        try store.databasePool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processes"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM process_samples"), ticks)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM system_samples"), ticks)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        try store.databasePool.write { db in
            try db.execute(sql: "DROP TRIGGER reject_process")
        }
        let timestamp = base.addingTimeInterval(300)
        let samples = [3000, 9000].map { pid in
            Make.process(timestamp: timestamp, pid: Int32(pid))
        }
        XCTAssertEqual(
            try store.insertChanged(
                Make.system(timestamp: timestamp), processes: samples, bucket: 60), 2)
    }

    private func assertMaintenanceWaitsForWriter(
        seedCache: Bool = true, operation: @escaping (SampleStore, ProcessIdentity) -> Void
    ) throws {
        let store = try XCTUnwrap(store)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = Make.process(timestamp: timestamp, footprint: 100 * 1024 * 1024)
        if seedCache {
            try store.insert(
                Make.system(timestamp: timestamp, pressurePercent: 10), processes: [sample])
        }

        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerFinished = DispatchGroup()
        let maintenanceFinished = DispatchGroup()
        writerFinished.enter()
        DispatchQueue(label: "test.cache.writer").async {
            defer { writerFinished.leave() }
            store.databasePool.writeWithoutTransaction { _ in
                writerEntered.signal()
                XCTAssertEqual(releaseWriter.wait(timeout: .now() + 5), .success)
            }
        }
        defer {
            releaseWriter.signal()
            XCTAssertEqual(writerFinished.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(maintenanceFinished.wait(timeout: .now() + 5), .success)
        }
        guard writerEntered.wait(timeout: .now() + 5) == .success else {
            XCTFail("The writer did not start")
            return
        }

        let maintenanceStarted = DispatchSemaphore(value: 0)
        maintenanceFinished.enter()
        DispatchQueue(label: "test.cache.maintenance").async {
            maintenanceStarted.signal()
            operation(store, sample.id)
            maintenanceFinished.leave()
        }
        XCTAssertEqual(maintenanceStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(
            maintenanceFinished.wait(timeout: .now() + 0.1), .timedOut,
            "Cache maintenance must not run while the database writer is occupied")
    }
}
