import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class DiskPersistenceTests: XCTestCase {
    private var store: SampleStore!

    override func setUpWithError() throws {
        store = try SampleStore()
    }

    func testDiskFieldsRoundTripThroughRawSystemHistory() throws {
        let now = Date()
        var system = Make.system(timestamp: now)
        system.diskReadBytesPerSec = 8_000_000
        system.diskWriteBytesPerSec = 2_000_000
        system.diskReadOperationsPerSec = 120
        system.diskWriteOperationsPerSec = 30

        try store.insert(systemSample: system)

        let latest = try XCTUnwrap(try store.latestSystemSample())
        XCTAssertEqual(latest.diskReadBytesPerSec, 8_000_000)
        XCTAssertEqual(latest.diskWriteBytesPerSec, 2_000_000)
        XCTAssertEqual(latest.diskReadOperationsPerSec, 120)
        XCTAssertEqual(latest.diskWriteOperationsPerSec, 30)

        let point = try XCTUnwrap(
            try store.systemHistory(.oneHour, now: now.addingTimeInterval(1)).last)
        XCTAssertEqual(point.diskReadBytesPerSec, 8_000_000)
        XCTAssertEqual(point.diskWriteBytesPerSec, 2_000_000)
        XCTAssertEqual(point.diskReadOperationsPerSec, 120)
        XCTAssertEqual(point.diskWriteOperationsPerSec, 30)
    }

    func testDiskFieldsRollThroughMinuteAndHourHistory() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_040)
        for index in 0..<20 {
            var system = Make.system(timestamp: anchor.addingTimeInterval(Double(index) * 6))
            system.diskReadBytesPerSec = 6_000_000
            system.diskWriteBytesPerSec = 2_000_000
            system.diskReadOperationsPerSec = 60
            system.diskWriteOperationsPerSec = 20
            try store.insert(systemSample: system)
        }

        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))
        let minute = try XCTUnwrap(
            try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600)).first)
        XCTAssertEqual(minute.diskReadBytesPerSec, 6_000_000, accuracy: 0.001)
        XCTAssertEqual(minute.diskWriteBytesPerSec, 2_000_000, accuracy: 0.001)

        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(7200))
        let hour = try XCTUnwrap(
            try store.systemHistory(.sevenDays, now: anchor.addingTimeInterval(7200)).first)
        XCTAssertEqual(hour.diskReadBytesPerSec, 6_000_000, accuracy: 0.001)
        XCTAssertEqual(hour.diskWriteBytesPerSec, 2_000_000, accuracy: 0.001)
    }

    func testDiskDetailFieldsRoundTripIncludingNil() throws {
        let now = Date()
        var withValues = Make.system(timestamp: now)
        withValues.diskReadLatencyMs = 0.42
        withValues.diskWriteLatencyMs = 1.5
        withValues.diskUtilizationPercent = 37.5
        withValues.bootVolumeTotalBytes = 500_000_000_000
        withValues.bootVolumeFreeBytes = 38_000_000_000
        try store.insert(systemSample: withValues)

        let decoded = try XCTUnwrap(try store.latestSystemSample())
        XCTAssertEqual(decoded.diskReadLatencyMs, 0.42)
        XCTAssertEqual(decoded.diskWriteLatencyMs, 1.5)
        XCTAssertEqual(decoded.diskUtilizationPercent, 37.5)
        XCTAssertEqual(decoded.bootVolumeTotalBytes, 500_000_000_000)
        XCTAssertEqual(decoded.bootVolumeFreeBytes, 38_000_000_000)

        // Nil must survive as nil, not as zero: a quiet tick has no latency.
        let idle = Make.system(timestamp: now.addingTimeInterval(1))
        try store.insert(systemSample: idle)
        let decodedIdle = try XCTUnwrap(try store.latestSystemSample())
        XCTAssertNil(decodedIdle.diskReadLatencyMs)
        XCTAssertNil(decodedIdle.diskUtilizationPercent)
        XCTAssertNil(decodedIdle.bootVolumeFreeBytes)

        let points = try store.systemHistory(.oneHour, now: now.addingTimeInterval(2))
        XCTAssertEqual(points.first?.diskReadLatencyMs, 0.42)
        XCTAssertEqual(points.first?.bootFreeBytes, 38_000_000_000)
        XCTAssertNil(points.last?.diskReadLatencyMs)
    }

    func testDiskDetailRollupExcludesNilAndKeepsFreeSpaceLowWaterMark() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_040)
        // Same minute bucket: two busy ticks (latency 1 ms and 3 ms) and two
        // quiet ticks (nil). The minute average must be 2 ms, not 1 ms.
        for index in 0..<4 {
            var system = Make.system(timestamp: anchor.addingTimeInterval(Double(index) * 6))
            if index.isMultiple(of: 2) {
                system.diskReadLatencyMs = index == 0 ? 1.0 : 3.0
                system.diskUtilizationPercent = 50
            }
            system.bootVolumeTotalBytes = 1_000_000
            system.bootVolumeFreeBytes = UInt64(100_000 - index * 10_000)
            try store.insert(systemSample: system)
        }

        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))
        let minute = try XCTUnwrap(
            try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600)).first)
        XCTAssertEqual(minute.diskReadLatencyMs ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(minute.diskUtilizationPercent ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(minute.bootFreeBytes, 70_000, "tier point carries the low water mark")
        XCTAssertEqual(minute.bootTotalBytes, 1_000_000)

        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(7200))
        let hour = try XCTUnwrap(
            try store.systemHistory(.sevenDays, now: anchor.addingTimeInterval(7200)).first)
        XCTAssertEqual(hour.diskReadLatencyMs ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(hour.bootFreeBytes, 70_000)
    }

    func testAllNilDetailRollsUpAsNilNotZero() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_040)
        for index in 0..<3 {
            try store.insert(
                systemSample: Make.system(timestamp: anchor.addingTimeInterval(Double(index) * 6)))
        }
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))
        let minute = try XCTUnwrap(
            try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600)).first)
        XCTAssertNil(minute.diskReadLatencyMs)
        XCTAssertNil(minute.diskUtilizationPercent)
        XCTAssertNil(minute.bootFreeBytes)
    }

    func testV11DatabaseMigratesWithNilDiskDetailDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperf-v11-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }
        let pool = try DatabasePool(path: url.path)
        try MacPerfMonitorDatabase.migrator.migrate(pool, upTo: "v11-system-disk-activity")
        let now = Date()
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO system_samples
                    (timestamp, total_ram, free, active, inactive, wired, speculative, compressed,
                     app_memory, cached_files, swap_total, swap_used, pressure_level,
                     pressure_percent, page_ins, page_outs, compressions, decompressions,
                     page_ins_delta, page_outs_delta, compressions_delta, decompressions_delta,
                     cpu_load, battery_present, battery_charge, battery_power, battery_charging,
                     battery_health, battery_cycles, battery_temp, net_in, net_out,
                     disk_read, disk_write, disk_read_iops, disk_write_iops)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    now.timeIntervalSince1970, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, false, 0, 0, false, 0, 0, 0, 0, 0, 5, 6, 7, 8,
                ])
        }

        try MacPerfMonitorDatabase.migrator.migrate(pool)
        let migrated = SampleStore(pool: pool)
        let old = try XCTUnwrap(try migrated.latestSystemSample())
        XCTAssertEqual(old.diskReadBytesPerSec, 5)
        XCTAssertNil(old.diskReadLatencyMs, "pre-v12 rows must decode the new columns as nil")
        XCTAssertNil(old.bootVolumeFreeBytes)

        var new = Make.system(timestamp: now.addingTimeInterval(1))
        new.diskReadLatencyMs = 0.9
        new.bootVolumeFreeBytes = 42
        new.bootVolumeTotalBytes = 100
        try migrated.insert(systemSample: new)
        let latest = try XCTUnwrap(try migrated.latestSystemSample())
        XCTAssertEqual(latest.diskReadLatencyMs, 0.9)
        XCTAssertEqual(latest.bootVolumeFreeBytes, 42)
    }

    func testV10DatabaseMigratesWithZeroDiskDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperf-v10-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }
        let pool = try DatabasePool(path: url.path)
        try MacPerfMonitorDatabase.migrator.migrate(
            pool, upTo: "v10-raw-network-and-process-age-indexes")
        let now = Date()
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO system_samples
                    (timestamp, total_ram, free, active, inactive, wired, speculative, compressed,
                     app_memory, cached_files, swap_total, swap_used, pressure_level,
                     pressure_percent, page_ins, page_outs, compressions, decompressions,
                     page_ins_delta, page_outs_delta, compressions_delta, decompressions_delta,
                     cpu_load, battery_present, battery_charge, battery_power, battery_charging,
                     battery_health, battery_cycles, battery_temp, net_in, net_out)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    now.timeIntervalSince1970, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, false, 0, 0, false, 0, 0, 0, 0, 0,
                ])
        }

        try MacPerfMonitorDatabase.migrator.migrate(pool)
        let migrated = SampleStore(pool: pool)
        let old = try XCTUnwrap(try migrated.latestSystemSample())
        XCTAssertEqual(old.diskReadBytesPerSec, 0)
        XCTAssertEqual(old.diskWriteBytesPerSec, 0)

        var new = Make.system(timestamp: now.addingTimeInterval(1))
        new.diskReadBytesPerSec = 1234
        new.diskWriteBytesPerSec = 5678
        try migrated.insert(systemSample: new)
        let latest = try XCTUnwrap(try migrated.latestSystemSample())
        XCTAssertEqual(latest.diskReadBytesPerSec, 1234)
        XCTAssertEqual(latest.diskWriteBytesPerSec, 5678)
    }
}
