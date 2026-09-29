import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class SystemHistoryStatisticsTests: XCTestCase {
    private var directory: URL!
    private var store: SampleStore!
    // An exact hour boundary, also aligned to every supported minute width.
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    private let minimumColumns = [
        "pressure_min", "cpu_min", "net_in_min", "net_out_min", "disk_read_min",
        "disk_write_min", "gpu_util_min", "load_1_min", "app_min", "wired_min",
        "compressed_min", "cached_min", "swap_used_min", "cpu_die_min", "gpu_die_min",
    ]
    private let memoryMaximumColumns = [
        "app_max", "wired_max", "compressed_max", "cached_max", "swap_used_max",
    ]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-history-statistics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func sample(
        _ offset: TimeInterval, value: Int, cpu: Double? = nil, gpu: Double? = nil
    ) -> SystemSample {
        var sample = Make.system(
            timestamp: anchor.addingTimeInterval(offset),
            compressed: UInt64(value * 300), swapUsed: UInt64(value * 500),
            pressurePercent: Double(value), appMemory: UInt64(value * 100),
            wired: UInt64(value * 200), cachedFiles: UInt64(value * 400))
        sample.cpuLoad = Double(value) / 100
        sample.networkInBytesPerSec = Double(value * 10)
        sample.networkOutBytesPerSec = Double(value * 20)
        sample.diskReadBytesPerSec = Double(value * 30)
        sample.diskWriteBytesPerSec = Double(value * 40)
        sample.gpuUtilization = Double(value)
        sample.loadAverage1 = Double(value) / 10
        sample.loadAverage5 = Double(value) / 20
        sample.loadAverage15 = Double(value) / 40
        sample.cpuDieC = cpu
        sample.gpuDieC = gpu
        return sample
    }

    private func insertUnequalBuckets() throws {
        let readings: [(TimeInterval, Int, Double?, Double?)] = [
            (1, 10, 50, 40), (61, 30, 60, 30), (67, 50, nil, 70), (73, 70, 100, nil),
        ]
        for (offset, value, cpu, gpu) in readings {
            try store.insert(systemSample: sample(offset, value: value, cpu: cpu, gpu: gpu))
        }
    }

    private func assertStatistics(
        _ point: SystemHistoryPoint, mean: Double, minimum: Double, maximum: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let minima = try XCTUnwrap(point.minima, file: file, line: line)
        let peaks = try XCTUnwrap(point.peaks, file: file, line: line)
        let scalars: [(Double, Double, Double, Double)] = [
            (point.pressurePercent, minima.pressurePercent, peaks.pressurePercent, 1),
            (point.cpuLoad, minima.cpuLoad, peaks.cpuLoad, 0.01),
            (
                point.networkInBytesPerSec, minima.networkInBytesPerSec,
                peaks.networkInBytesPerSec, 10
            ),
            (
                point.networkOutBytesPerSec, minima.networkOutBytesPerSec,
                peaks.networkOutBytesPerSec, 20
            ),
            (point.diskReadBytesPerSec, minima.diskReadBytesPerSec, peaks.diskReadBytesPerSec, 30),
            (
                point.diskWriteBytesPerSec, minima.diskWriteBytesPerSec,
                peaks.diskWriteBytesPerSec, 40
            ),
        ]
        for (value, low, high, scale) in scalars {
            XCTAssertEqual(value, mean * scale, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(low, minimum * scale, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(high, maximum * scale, accuracy: 1e-9, file: file, line: line)
        }
        let memory: [(UInt64, Double?, Double?, Double)] = [
            (point.appMemory, minima.appMemory, peaks.appMemory, 100),
            (point.wired, minima.wired, peaks.wired, 200),
            (point.compressed, minima.compressed, peaks.compressed, 300),
            (point.cachedFiles, minima.cachedFiles, peaks.cachedFiles, 400),
            (point.swapUsed, minima.swapUsed, peaks.swapUsed, 500),
        ]
        for (value, low, high, scale) in memory {
            XCTAssertEqual(Double(value), mean * scale, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(
                try XCTUnwrap(low), minimum * scale, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(
                try XCTUnwrap(high), maximum * scale, accuracy: 1e-9, file: file, line: line)
        }
        XCTAssertEqual(
            try XCTUnwrap(point.gpuUtilization), mean, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(minima.gpuUtilization, minimum, file: file, line: line)
        XCTAssertEqual(peaks.gpuUtilization, maximum, file: file, line: line)
        XCTAssertEqual(point.loadAverage1, mean / 10, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(point.loadAverage5, mean / 20, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(point.loadAverage15, mean / 40, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(minima.loadAverage1, minimum / 10, file: file, line: line)
        XCTAssertEqual(peaks.loadAverage1, maximum / 10, file: file, line: line)
    }

    func testRawPointsDefaultToUnitWeightsAndDecodeValidThermalCounts() throws {
        let constructed = SystemHistoryPoint(
            date: anchor, pressurePercent: 20, appMemory: 100, wired: 200, compressed: 300,
            cachedFiles: 400, swapUsed: 500, cpuDieC: 53, gpuDieC: 47)
        XCTAssertEqual(constructed.sampleCount, 1)
        XCTAssertEqual(constructed.bucketDuration, 0)
        XCTAssertNil(constructed.minima)
        XCTAssertNil(constructed.cpuDieAverageC)
        XCTAssertNil(constructed.gpuDieAverageC)
        XCTAssertNil(constructed.cpuDieSampleCount)
        XCTAssertNil(constructed.gpuDieSampleCount)
        let extrema = SystemHistoryPeaks(constructed)
        XCTAssertEqual(extrema.appMemory, 100)
        XCTAssertEqual(extrema.wired, 200)
        XCTAssertEqual(extrema.compressed, 300)
        XCTAssertEqual(extrema.cachedFiles, 400)
        XCTAssertEqual(extrema.swapUsed, 500)
        XCTAssertEqual(extrema.cpuDieC, 53)
        XCTAssertEqual(extrema.gpuDieC, 47)

        try store.insert(systemSample: sample(1, value: 20, cpu: 53, gpu: 47))
        try store.insert(systemSample: sample(7, value: 30))
        let raw = try store.systemHistory(.fiveMinutes, now: anchor.addingTimeInterval(60))
        XCTAssertEqual(raw.map(\.sampleCount), [1, 1])
        XCTAssertEqual(raw.map(\.bucketDuration), [0, 0])
        XCTAssertTrue(raw.allSatisfy { $0.peaks == nil && $0.minima == nil })
        XCTAssertEqual(raw.map(\.cpuDieAverageC), [53, nil])
        XCTAssertEqual(raw.map(\.gpuDieAverageC), [47, nil])
        XCTAssertEqual(raw.map(\.cpuDieSampleCount), [1, 0])
        XCTAssertEqual(raw.map(\.gpuDieSampleCount), [1, 0])
    }

    func testUnequalSampleCountsAndTrueExtremaSurviveMinuteAndHourLoads() throws {
        try insertUnequalBuckets()
        let minuteNow = anchor.addingTimeInterval(120)
        let raw = try store.systemHistory(.oneHour, now: minuteNow)
        XCTAssertEqual(raw.map(\.sampleCount), [1, 1, 1, 1])
        try Retention.run(store.databasePool, now: minuteNow)

        let minutes = try store.systemHistory(.oneDay, now: minuteNow)
        XCTAssertEqual(minutes.count, 2)
        guard minutes.count == 2 else { return }
        XCTAssertEqual(minutes.map(\.sampleCount), [1, 3])
        XCTAssertEqual(minutes.map(\.bucketDuration), [60, 60])
        try assertStatistics(minutes[0], mean: 10, minimum: 10, maximum: 10)
        try assertStatistics(minutes[1], mean: 50, minimum: 30, maximum: 70)
        let weight = minutes.reduce(0) { $0 + $1.sampleCount }
        let weightedMean =
            minutes.reduce(0.0) {
                $0 + $1.pressurePercent * Double($1.sampleCount)
            } / Double(weight)
        XCTAssertEqual(weightedMean, 40, accuracy: 1e-9, "not the unweighted mean of 30")
        XCTAssertEqual(minutes.map(\.cpuDieAverageC), [50, 80])
        XCTAssertEqual(minutes.map(\.gpuDieAverageC), [40, 50])
        XCTAssertEqual(minutes.map(\.cpuDieSampleCount), [1, 2])
        XCTAssertEqual(minutes.map(\.gpuDieSampleCount), [1, 2])
        XCTAssertEqual(minutes[1].minima?.cpuDieC, 60)
        XCTAssertEqual(minutes[1].minima?.gpuDieC, 30)
        XCTAssertEqual(minutes[1].peaks?.cpuDieC, 100)
        XCTAssertEqual(minutes[1].peaks?.gpuDieC, 70)

        let hourNow = anchor.addingTimeInterval(3600)
        try Retention.run(store.databasePool, now: hourNow)
        let hours = try store.systemHistory(.sevenDays, now: hourNow)
        XCTAssertEqual(hours.count, 1)
        let hour = try XCTUnwrap(hours.first)
        XCTAssertEqual(hour.sampleCount, 4)
        XCTAssertEqual(hour.bucketDuration, 3600)
        try assertStatistics(hour, mean: 40, minimum: 10, maximum: 70)
        XCTAssertEqual(hour.cpuDieC, 100, "existing thermal histories still receive the maximum")
        XCTAssertEqual(hour.gpuDieC, 70)
        XCTAssertEqual(hour.peaks?.cpuDieC, 100)
        XCTAssertEqual(hour.peaks?.gpuDieC, 70)
        XCTAssertEqual(hour.minima?.cpuDieC, 50)
        XCTAssertEqual(hour.minima?.gpuDieC, 30)
        XCTAssertEqual(try XCTUnwrap(hour.cpuDieAverageC), 70, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hour.gpuDieAverageC), 140.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(hour.cpuDieSampleCount, 3)
        XCTAssertEqual(hour.gpuDieSampleCount, 3)
    }

    func testEmptySensorBucketsKeepZeroValidCountsWithoutDilutingMeans() throws {
        try store.insert(systemSample: sample(1, value: 10))
        try store.insert(systemSample: sample(7, value: 20))
        try store.insert(systemSample: sample(61, value: 30, cpu: 65))
        try store.insert(systemSample: sample(67, value: 40))
        let now = anchor.addingTimeInterval(3600)
        try Retention.run(store.databasePool, now: now)

        let minutes = try store.systemHistory(.oneDay, now: now)
        XCTAssertEqual(minutes.map(\.cpuDieSampleCount), [0, 1])
        XCTAssertEqual(minutes.map(\.gpuDieSampleCount), [0, 0])
        let hour = try XCTUnwrap(try store.systemHistory(.sevenDays, now: now).first)
        XCTAssertEqual(hour.sampleCount, 4)
        XCTAssertEqual(hour.cpuDieAverageC, 65)
        XCTAssertEqual(hour.cpuDieSampleCount, 1)
        XCTAssertEqual(hour.cpuDieC, 65)
        XCTAssertNil(hour.gpuDieAverageC)
        XCTAssertEqual(hour.gpuDieSampleCount, 0)
        XCTAssertNil(hour.gpuDieC)
        // The conservative full-range rule also applies to an empty bucket.
        XCTAssertNil(hour.minima?.cpuDieC)
        XCTAssertNil(hour.minima?.gpuDieC)
    }

    func testConfiguredBucketWidthsSurvivePolicyChangesAndMixedTierLoads() throws {
        for offset in [1.0, 7] {
            try store.insert(systemSample: sample(offset, value: 10))
        }
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(60))
        for offset in [301.0, 307] {
            try store.insert(systemSample: sample(offset, value: 30))
        }
        let coarse = RetentionPolicy(standardResBucket: 300)
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600), policy: coarse)
        let minutes = try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600))
        XCTAssertEqual(minutes.map(\.bucketDuration), [60, 300])
        XCTAssertEqual(minutes.map(\.sampleCount), [2, 2])
        XCTAssertEqual(minutes.map { $0.date.timeIntervalSince(anchor) }, [0, 300])

        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(3600), policy: coarse)
        for offset in [3601.0, 3607] {
            try store.insert(systemSample: sample(offset, value: 50))
        }
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(3900), policy: coarse)
        try store.insert(systemSample: sample(3910, value: 70))
        let mixed = try store.systemHistory(.sevenDays, now: anchor.addingTimeInterval(3910))
        XCTAssertEqual(mixed.map(\.bucketDuration), [3600, 300, 0])
        XCTAssertEqual(mixed.map(\.sampleCount), [4, 2, 1])
        XCTAssertEqual(mixed.map { $0.date.timeIntervalSince(anchor) }, [0, 3600, 3910])
        XCTAssertEqual(mixed.map(\.pressurePercent), [20, 50, 70])
    }

    private func insertLegacyAggregate(_ db: Database, table: String) throws {
        try db.execute(
            sql: """
                INSERT INTO \(table) (bucket, pressure_avg, pressure_max,
                    app_avg, wired_avg, compressed_avg, cached_avg, swap_used_avg,
                    cpu_avg, cpu_max, samples, net_in_avg, net_in_max,
                    cpu_die_avg, cpu_die_max, gpu_die_avg, gpu_die_max,
                    gpu_util_avg, gpu_util_max, load_1_avg, load_1_max)
                VALUES (?, 40, 90, 4000, 8000, 12000, 16000, 20000,
                    0.4, 0.9, 3, 400, 900, 50, 95, 40, 60, 40, 90, 4, 9)
                """, arguments: [anchor.timeIntervalSince1970])
    }

    func testV17MigrationLeavesLegacyExtremaCountsAndWidthsNull() throws {
        let pool = try DatabasePool(path: directory.appendingPathComponent("legacy.sqlite").path)
        try MacPerfMonitorDatabase.migrator.migrate(pool, upTo: "v16-load-averages")
        try pool.write { db in
            try insertLegacyAggregate(db, table: "system_minute")
            try insertLegacyAggregate(db, table: "system_hour")
            try Retention.setMeta(db, "minute_bucket_seconds", 120)
            try Retention.setMeta(db, "minute_watermark", anchor.timeIntervalSince1970 + 3600)
            try Retention.setMeta(db, "hour_watermark", anchor.timeIntervalSince1970 + 3600)
        }
        try MacPerfMonitorDatabase.migrator.migrate(pool)
        try MacPerfMonitorDatabase.migrator.migrate(pool)

        let addedColumns =
            minimumColumns + memoryMaximumColumns
            + ["cpu_die_samples", "gpu_die_samples", "bucket_seconds"]
        try pool.read { db in
            for table in ["system_minute", "system_hour"] {
                let schema = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM \(table)"))
                for column in addedColumns {
                    let definition = try XCTUnwrap(
                        schema.first { ($0["name"] as String) == column })
                    XCTAssertEqual(definition["notnull"] as Int, 0, column)
                    XCTAssertNil(definition["dflt_value"] as String?, column)
                    XCTAssertNil(row[column] as Double?, column)
                }
                XCTAssertEqual(row["samples"] as Int, 3)
                XCTAssertEqual(row["pressure_avg"] as Double, 40)
                XCTAssertEqual(row["pressure_max"] as Double, 90)
                XCTAssertEqual(row["cpu_die_avg"] as Double, 50)
                XCTAssertEqual(row["cpu_die_max"] as Double, 95)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 1)
            }
            XCTAssertEqual(try Retention.meta(db, "minute_bucket_seconds"), 120)
            XCTAssertEqual(
                try Retention.meta(db, "minute_watermark"), anchor.timeIntervalSince1970 + 3600)
            XCTAssertEqual(
                try Retention.meta(db, "hour_watermark"), anchor.timeIntervalSince1970 + 3600)
        }

        let migrated = SampleStore(pool: pool)
        let now = anchor.addingTimeInterval(3600)
        let minute = try XCTUnwrap(try migrated.systemHistory(.oneDay, now: now).first)
        let hour = try XCTUnwrap(try migrated.systemHistory(.sevenDays, now: now).first)
        XCTAssertEqual(minute.bucketDuration, 120, "legacy minute widths use the stored policy")
        XCTAssertEqual(hour.bucketDuration, 3600)
        for point in [minute, hour] {
            XCTAssertEqual(point.sampleCount, 3)
            XCTAssertNil(point.minima)
            XCTAssertNil(point.peaks?.appMemory)
            XCTAssertNil(point.peaks?.wired)
            XCTAssertNil(point.peaks?.compressed)
            XCTAssertNil(point.peaks?.cachedFiles)
            XCTAssertNil(point.peaks?.swapUsed)
            XCTAssertEqual(point.cpuDieC, 95)
            XCTAssertEqual(point.cpuDieAverageC, 50)
            XCTAssertEqual(point.gpuDieAverageC, 40)
            XCTAssertNil(point.cpuDieSampleCount)
            XCTAssertNil(point.gpuDieSampleCount)
        }
    }

    func testLegacyMinuteWidthDefaultsToSixtyWithoutMetadata() throws {
        try store.databasePool.write { db in
            try insertLegacyAggregate(db, table: "system_minute")
        }
        let minute = try XCTUnwrap(
            try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(120)).first)
        XCTAssertEqual(minute.bucketDuration, 60)
        XCTAssertNil(minute.minima)
        XCTAssertNil(minute.cpuDieSampleCount)
    }

    func testMixedLegacyHourKeepsUnknownExtremaAndThermalWeights() throws {
        try store.databasePool.write { db in
            try insertLegacyAggregate(db, table: "system_minute")
            try Retention.setMeta(db, "minute_watermark", anchor.timeIntervalSince1970 + 60)
            try Retention.setMeta(db, "minute_bucket_seconds", 60)
        }
        try store.insert(systemSample: sample(61, value: 60, cpu: 100, gpu: 70))
        let now = anchor.addingTimeInterval(3600)
        try Retention.run(store.databasePool, now: now)
        let hour = try XCTUnwrap(try store.systemHistory(.sevenDays, now: now).first)
        XCTAssertEqual(hour.sampleCount, 4)
        XCTAssertEqual(hour.pressurePercent, 45)
        XCTAssertEqual(hour.peaks?.pressurePercent, 90)
        XCTAssertEqual(hour.peaks?.networkInBytesPerSec, 900)
        XCTAssertNil(hour.minima)
        XCTAssertNil(hour.peaks?.appMemory)
        XCTAssertEqual(hour.cpuDieC, 100)
        XCTAssertEqual(hour.gpuDieC, 70)
        // Preserve the legacy approximate mean, but never claim known weights.
        XCTAssertEqual(hour.cpuDieAverageC, 62.5)
        XCTAssertEqual(hour.gpuDieAverageC, 47.5)
        XCTAssertNil(hour.cpuDieSampleCount)
        XCTAssertNil(hour.gpuDieSampleCount)
        try store.databasePool.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM system_hour"))
            for column in minimumColumns + memoryMaximumColumns {
                XCTAssertNil(row[column] as Double?, column)
            }
        }
    }

    func testMissingExtremaPropagateIndependentlyAcrossHourRollup() throws {
        try insertUnequalBuckets()
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(120))
        try store.databasePool.write { db in
            try db.execute(
                sql: """
                    UPDATE system_minute SET app_min = NULL, wired_max = NULL,
                        gpu_util_min = NULL, load_1_min = NULL, cpu_die_min = NULL
                    WHERE bucket = ?
                    """, arguments: [anchor.timeIntervalSince1970])
        }
        let now = anchor.addingTimeInterval(3600)
        try Retention.run(store.databasePool, now: now)
        let hour = try XCTUnwrap(try store.systemHistory(.sevenDays, now: now).first)
        let minima = try XCTUnwrap(hour.minima)
        XCTAssertEqual(minima.pressurePercent, 10)
        XCTAssertEqual(minima.cpuLoad, 0.1)
        XCTAssertNil(minima.appMemory)
        XCTAssertNil(minima.gpuUtilization)
        XCTAssertNil(minima.loadAverage1)
        XCTAssertNil(minima.cpuDieC)
        XCTAssertEqual(minima.gpuDieC, 30)
        XCTAssertEqual(minima.wired, 2000)
        XCTAssertNil(hour.peaks?.wired)
        XCTAssertEqual(hour.peaks?.appMemory, 7000)
        XCTAssertEqual(hour.peaks?.compressed, 21000)
        XCTAssertEqual(hour.cpuDieAverageC, 70)
        XCTAssertEqual(hour.cpuDieSampleCount, 3)
    }

    func testUnknownSensorCountsPropagateIndependentlyWithoutDenseCountSubstitution() throws {
        try insertUnequalBuckets()
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(120))
        try store.databasePool.write { db in
            try db.execute(
                sql: "UPDATE system_minute SET cpu_die_samples = NULL WHERE bucket = ?",
                arguments: [anchor.timeIntervalSince1970])
        }
        let now = anchor.addingTimeInterval(3600)
        try Retention.run(store.databasePool, now: now)
        let hour = try XCTUnwrap(try store.systemHistory(.sevenDays, now: now).first)
        XCTAssertEqual(hour.sampleCount, 4)
        XCTAssertNil(hour.cpuDieSampleCount)
        XCTAssertEqual(hour.cpuDieAverageC, 72.5, "the legacy fallback remains marked approximate")
        XCTAssertEqual(hour.gpuDieSampleCount, 3)
        XCTAssertEqual(try XCTUnwrap(hour.gpuDieAverageC), 140.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(hour.cpuDieC, 100)
        XCTAssertEqual(hour.gpuDieC, 70)
    }

    func testMissingRequiredMinimumOmitsAggregateMinimaRatherThanUsingMean() throws {
        try store.insert(systemSample: sample(1, value: 10))
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(60))
        try store.databasePool.write { db in
            try db.execute(sql: "UPDATE system_minute SET pressure_min = NULL")
        }
        let minute = try XCTUnwrap(
            try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(60)).first)
        XCTAssertNil(minute.minima)
        XCTAssertEqual(minute.peaks?.appMemory, 1000)
        XCTAssertEqual(minute.sampleCount, 1)
        XCTAssertEqual(minute.bucketDuration, 60, "a one-sample aggregate is not a raw point")
    }

    func testMergingMemoryPeaksDoesNotReplaceLegacyUnknownsWithPartialMaxima() {
        let raw = SystemHistoryPoint(
            date: anchor, pressurePercent: 20, appMemory: 100, wired: 200, compressed: 300,
            cachedFiles: 400, swapUsed: 500, cpuDieC: 80, gpuDieC: 60)
        let known = SystemHistoryPeaks(raw)
        let legacy = SystemHistoryPeaks(
            pressurePercent: 90, cpuLoad: 0.9, networkInBytesPerSec: 20,
            networkOutBytesPerSec: 30, diskReadBytesPerSec: 40, diskWriteBytesPerSec: 50)
        for merged in [known.merged(with: legacy), legacy.merged(with: known)] {
            XCTAssertNil(merged.appMemory)
            XCTAssertNil(merged.wired)
            XCTAssertNil(merged.compressed)
            XCTAssertNil(merged.cachedFiles)
            XCTAssertNil(merged.swapUsed)
            XCTAssertEqual(merged.pressurePercent, 90)
            XCTAssertEqual(merged.cpuDieC, 80)
            XCTAssertEqual(merged.gpuDieC, 60)
        }
    }
}
