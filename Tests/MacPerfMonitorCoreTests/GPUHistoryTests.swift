import GRDB
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

    func testBandwidthSamplesKeepSeparateRatesAndUnknownGaps() throws {
        let now = Date()
        let labels = ["1GB/s", "5GB/s", "32GB/s"]
        let read = try XCTUnwrap(GPUBandwidthHistogram(labels: labels, counts: [3, 1, 0]))
        let write = try XCTUnwrap(GPUBandwidthHistogram(labels: labels, counts: [1, 3, 0]))
        let total = try XCTUnwrap(GPUBandwidthHistogram(labels: labels, counts: [0, 1, 0]))
        let bandwidth = try XCTUnwrap(
            GPUBandwidthSample(
                timestamp: now, interval: 1, read: read, write: write, combined: total))
        let rates = bandwidth.estimatedRates(at: now)
        XCTAssertEqual(rates.read, 2)
        XCTAssertEqual(rates.write, 4)
        XCTAssertEqual(rates.total, 5)
        var sample = Make.system(timestamp: now, pressurePercent: 10)
        let legacy = try JSONEncoder().encode(sample)
        sample.gpuReadBandwidthGBps = rates.read
        sample.gpuWriteBandwidthGBps = rates.write
        sample.gpuTotalBandwidthGBps = rates.total
        let decoded = try JSONDecoder().decode(
            SystemSample.self, from: JSONEncoder().encode(sample))
        XCTAssertEqual(decoded.gpuReadBandwidthGBps, 2)
        XCTAssertEqual(decoded.gpuWriteBandwidthGBps, 4)
        XCTAssertEqual(decoded.gpuTotalBandwidthGBps, 5)
        let old = try JSONDecoder().decode(SystemSample.self, from: legacy)
        XCTAssertNil(old.gpuReadBandwidthGBps)
        XCTAssertNil(old.gpuWriteBandwidthGBps)
        XCTAssertNil(old.gpuTotalBandwidthGBps)
        let stale = bandwidth.estimatedRates(at: now.addingTimeInterval(6))
        XCTAssertNil(stale.read)
        XCTAssertNil(stale.write)
        XCTAssertNil(stale.total)
        let low = try XCTUnwrap(GPUBandwidthHistogram(labels: labels, counts: [10, 0, 0]))
        let unresolved = try XCTUnwrap(GPUBandwidthSample(timestamp: now, interval: 1, read: low))
        XCTAssertNil(unresolved.estimatedRates(at: now).read)
        XCTAssertNil(unresolved.estimatedRates(at: now).total)
    }

    func testBandwidthRawHistoryRetainsChannelsAndRejectsInvalidRates() throws {
        let now = Date()
        for (offset, rate) in [(0.0, 0.0), (1, 3.5), (2, -1), (3, .infinity), (4, .nan)] {
            var sample = Make.system(timestamp: now.addingTimeInterval(offset), pressurePercent: 5)
            sample.gpuReadBandwidthGBps = rate
            sample.gpuWriteBandwidthGBps = 2
            sample.gpuTotalBandwidthGBps = 8
            try store.insert(systemSample: sample)
        }
        let history = try store.systemHistory(.fiveMinutes, now: now.addingTimeInterval(5))
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history[0].gpuReadBandwidthGBps, 0)
        XCTAssertEqual(history[1].gpuReadBandwidthGBps, 3.5)
        XCTAssertEqual(history[1].gpuReadBandwidthSampleCount, 1)
        XCTAssertEqual(history[1].gpuWriteBandwidthGBps, 2)
        XCTAssertEqual(history[1].gpuTotalBandwidthGBps, 8)
        for point in history.dropFirst(2) {
            XCTAssertNil(point.gpuReadBandwidthGBps)
            XCTAssertEqual(point.gpuReadBandwidthSampleCount, 0)
            XCTAssertEqual(point.gpuWriteBandwidthSampleCount, 1)
            XCTAssertEqual(point.gpuTotalBandwidthSampleCount, 1)
        }
        let latest = try XCTUnwrap(store.latestSystemSample())
        XCTAssertNil(latest.gpuReadBandwidthGBps)
        XCTAssertEqual(latest.gpuWriteBandwidthGBps, 2)
        XCTAssertEqual(latest.gpuTotalBandwidthGBps, 8)
        store = nil
        store = try SampleStore(url: tempURL)
        let reopened = try store.systemHistory(.fiveMinutes, now: now.addingTimeInterval(5))
        XCTAssertEqual(reopened, history)
    }

    func testBandwidthRollupsKeepPerChannelWeightsBoundsAndGaps() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let readings: [(TimeInterval, Double?, Double?, Double?)] = [
            (1, 1, 2, 8), (2, 3, nil, 12), (3, nil, 6, 16),
            (61, 9, 10, 24), (62, nil, nil, nil), (121, nil, nil, nil),
        ]
        for (offset, read, write, total) in readings {
            var sample = Make.system(
                timestamp: start.addingTimeInterval(offset), pressurePercent: 5)
            sample.gpuReadBandwidthGBps = read
            sample.gpuWriteBandwidthGBps = write
            sample.gpuTotalBandwidthGBps = total
            try store.insert(systemSample: sample)
        }
        try Retention.run(store.databasePool, now: start.addingTimeInterval(3700))
        let minutes = try store.systemHistory(
            from: start, to: start.addingTimeInterval(3599), granularity: .minute)
        XCTAssertEqual(minutes.count, 3)
        XCTAssertEqual(minutes[0].gpuReadBandwidthGBps, 2)
        XCTAssertEqual(minutes[0].gpuWriteBandwidthGBps, 4)
        XCTAssertEqual(minutes[0].gpuTotalBandwidthGBps, 12)
        XCTAssertEqual(minutes[0].gpuReadBandwidthSampleCount, 2)
        XCTAssertEqual(minutes[0].gpuWriteBandwidthSampleCount, 2)
        XCTAssertEqual(minutes[0].gpuTotalBandwidthSampleCount, 3)
        XCTAssertNil(minutes[2].gpuReadBandwidthGBps)
        XCTAssertNil(minutes[2].gpuWriteBandwidthGBps)
        XCTAssertNil(minutes[2].gpuTotalBandwidthGBps)
        XCTAssertEqual(minutes[2].gpuReadBandwidthSampleCount, 0)
        let hour = try XCTUnwrap(
            store.systemHistory(from: start, to: start.addingTimeInterval(3599), granularity: .hour)
                .first)
        XCTAssertEqual(try XCTUnwrap(hour.gpuReadBandwidthGBps), 13.0 / 3, accuracy: 0.000_001)
        XCTAssertEqual(hour.gpuWriteBandwidthGBps, 6)
        XCTAssertEqual(hour.gpuTotalBandwidthGBps, 15)
        XCTAssertEqual(hour.gpuReadBandwidthSampleCount, 3)
        XCTAssertEqual(hour.gpuWriteBandwidthSampleCount, 3)
        XCTAssertEqual(hour.gpuTotalBandwidthSampleCount, 4)
        XCTAssertEqual(hour.minima?.gpuReadBandwidthGBps, 1)
        XCTAssertEqual(hour.minima?.gpuWriteBandwidthGBps, 2)
        XCTAssertEqual(hour.minima?.gpuTotalBandwidthGBps, 8)
        XCTAssertEqual(hour.effectivePeaks.gpuReadBandwidthGBps, 9)
        XCTAssertEqual(hour.effectivePeaks.gpuWriteBandwidthGBps, 10)
        XCTAssertEqual(hour.effectivePeaks.gpuTotalBandwidthGBps, 24)
        let reduced = try XCTUnwrap(minutes.chartDownsampled(span: 3600, to: 1).first)
        XCTAssertEqual(reduced.gpuReadBandwidthGBps, hour.gpuReadBandwidthGBps)
        XCTAssertEqual(reduced.gpuWriteBandwidthGBps, hour.gpuWriteBandwidthGBps)
        XCTAssertEqual(reduced.gpuTotalBandwidthGBps, hour.gpuTotalBandwidthGBps)
        XCTAssertEqual(reduced.gpuReadBandwidthSampleCount, 3)
        XCTAssertEqual(reduced.gpuWriteBandwidthSampleCount, 3)
        XCTAssertEqual(reduced.gpuTotalBandwidthSampleCount, 4)
        XCTAssertEqual(reduced.minima?.gpuReadBandwidthGBps, 1)
        XCTAssertEqual(reduced.minima?.gpuWriteBandwidthGBps, 2)
        XCTAssertEqual(reduced.minima?.gpuTotalBandwidthGBps, 8)
        XCTAssertEqual(reduced.effectivePeaks.gpuReadBandwidthGBps, 9)
        XCTAssertEqual(reduced.effectivePeaks.gpuWriteBandwidthGBps, 10)
        XCTAssertEqual(reduced.effectivePeaks.gpuTotalBandwidthGBps, 24)
        var window = SystemHistoryWindow(span: 3600)
        window.replace(minutes)
        XCTAssertEqual(Array(window.values(.gpuReadBandwidthSampleCount)), [2, 1, 0])
        XCTAssertEqual(Array(window.values(.gpuWriteBandwidthSampleCount)), [2, 1, 0])
        XCTAssertEqual(Array(window.values(.gpuTotalBandwidthSampleCount)), [3, 1, 0])
        XCTAssertEqual(window.values(.gpuReadBandwidthMinimum).first, 1)
        XCTAssertEqual(window.values(.gpuWriteBandwidthPeak).first, 6)
        XCTAssertEqual(window.values(.gpuTotalBandwidthPeak).first, 16)
        XCTAssertTrue(try XCTUnwrap(window.values(.gpuTotalBandwidthGBps).last).isNaN)
    }

    func testBandwidthLiveColumnsKeepGapsAndZeroDistinct() throws {
        var sample = Make.system(timestamp: Date(), pressurePercent: 5)
        var window = SystemHistoryWindow(span: 60)
        window.append(SystemHistoryPoint(sample: sample))
        sample.timestamp.addTimeInterval(1)
        sample.gpuReadBandwidthGBps = 0
        sample.gpuWriteBandwidthGBps = 2.5
        sample.gpuTotalBandwidthGBps = 5
        window.append(SystemHistoryPoint(sample: sample))
        XCTAssertTrue(try XCTUnwrap(window.values(.gpuReadBandwidthGBps).first).isNaN)
        XCTAssertEqual(window.values(.gpuReadBandwidthGBps).last, 0)
        XCTAssertEqual(window.values(.gpuWriteBandwidthGBps).last, 2.5)
        XCTAssertEqual(window.values(.gpuTotalBandwidthGBps).last, 5)
        XCTAssertEqual(Array(window.values(.gpuTotalBandwidthSampleCount)), [0, 1])
        XCTAssertEqual(window.values(.gpuReadBandwidthMinimum).last, 0)
        XCTAssertEqual(window.values(.gpuTotalBandwidthPeak).last, 5)
        XCTAssertEqual(window.points().last?.gpuWriteBandwidthGBps, 2.5)
    }

    func testGPUMemorySampleKeepsMissingAndZeroReadingsDistinct() throws {
        var sample = Make.system(timestamp: Date(), pressurePercent: 10)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertNil(
            try decoder.decode(SystemSample.self, from: encoder.encode(sample)).gpuMemoryBytes)
        for bytes: UInt64 in [0, 2_200_000_000] {
            sample.gpuMemoryBytes = bytes
            XCTAssertEqual(
                try decoder.decode(SystemSample.self, from: encoder.encode(sample)).gpuMemoryBytes,
                bytes)
        }
    }

    func testGPUAwakeHistoryStaysDistinctFromUtilizationAndUnknownData() throws {
        let now = Date()
        for (offset, awake) in [(0.0, 100.0), (1, 0), (2, -1), (3, 101), (4, .infinity)] {
            var sample = Make.system(timestamp: now.addingTimeInterval(offset), pressurePercent: 10)
            sample.gpuUtilization = 5
            sample.gpuActiveResidency = awake
            try store.insert(systemSample: sample)
            XCTAssertEqual(
                try store.latestSystemSample()?.gpuActiveResidency,
                (0...100).contains(awake) ? awake : nil)
        }
        let history = try store.systemHistory(.fiveMinutes, now: now.addingTimeInterval(4))
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history[0].gpuActiveResidency, 100)
        XCTAssertEqual(history[0].gpuUtilization, 5)
        XCTAssertEqual(history[0].gpuActiveSampleCount, 1)
        XCTAssertEqual(history[1].gpuActiveResidency, 0)
        for point in history.dropFirst(2) {
            XCTAssertNil(point.gpuActiveResidency)
            XCTAssertEqual(point.gpuActiveSampleCount, 0)
        }
        let older = Make.system(timestamp: now, pressurePercent: 10)
        XCTAssertNil(
            try JSONDecoder().decode(SystemSample.self, from: JSONEncoder().encode(older))
                .gpuActiveResidency)
    }

    func testPublished21UpgradePreservesHistoryWithoutBackfillingGPUValues() throws {
        let directory = tempURL.appendingPathExtension("upgrade")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("history.sqlite")
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let pool = try DatabasePool(path: legacyURL.path)
            try MacPerfMonitorDatabase.migrator.migrate(pool, upTo: "v20-energy-history")
            try pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO system_samples
                        (timestamp, total_ram, free, active, inactive, wired, speculative, compressed,
                         app_memory, cached_files, swap_total, swap_used, pressure_level, pressure_percent,
                         page_ins, page_outs, compressions, decompressions,
                         page_ins_delta, page_outs_delta, compressions_delta, decompressions_delta, cpu_load,
                         gpu_util, battery_present, battery_charge, battery_cycles)
                        VALUES (?,0,0,0,0,0,0,0,0,0,0,0,0,10,0,0,0,0,0,0,0,0,0.35,42,1,73,160)
                        """, arguments: [timestamp.timeIntervalSince1970])
            }
        }
        let migrated = try SampleStore(url: legacyURL)
        let old = try XCTUnwrap(migrated.systemHistory(.fiveMinutes, now: timestamp).first)
        XCTAssertEqual(old.gpuUtilization, 42)
        XCTAssertEqual(old.cpuLoad, 0.35)
        XCTAssertEqual(old.batteryCharge, 73)
        XCTAssertNil(old.aneTimeMillisecondsPerSecond)
        XCTAssertNil(old.anePowerWatts)
        XCTAssertEqual(try migrated.latestSystemSample()?.batteryCycleCount, 160)
        XCTAssertNil(old.gpuMemoryBytes)
        XCTAssertEqual(old.gpuMemorySampleCount, 0)
        XCTAssertNil(old.gpuActiveResidency)
        XCTAssertEqual(old.gpuActiveSampleCount, 0)
        XCTAssertNil(old.gpuReadBandwidthGBps)
        XCTAssertNil(old.gpuWriteBandwidthGBps)
        XCTAssertNil(old.gpuTotalBandwidthGBps)
        XCTAssertEqual(old.gpuReadBandwidthSampleCount, 0)
        XCTAssertEqual(old.gpuWriteBandwidthSampleCount, 0)
        XCTAssertEqual(old.gpuTotalBandwidthSampleCount, 0)
        XCTAssertNil(try migrated.latestSystemSample()?.gpuMemoryBytes)
        var new = Make.system(timestamp: timestamp.addingTimeInterval(1), pressurePercent: 10)
        new.gpuMemoryBytes = 2_200_000_000
        try migrated.insert(systemSample: new)
        let history = try migrated.systemHistory(.fiveMinutes, now: new.timestamp)
        XCTAssertEqual(history.count, 2)
        XCTAssertNil(history[0].gpuMemoryBytes)
        XCTAssertEqual(history[1].gpuMemoryBytes, 2_200_000_000)
    }

    func testSystemGPUFiguresRoundTrip() throws {
        let now = Date()
        var sampled = Make.system(timestamp: now.addingTimeInterval(-2), pressurePercent: 10)
        sampled.gpuUtilization = 83
        sampled.gpuPowerWatts = 3.56
        sampled.gpuMemoryBytes = 2_200_000_000
        sampled.anePowerWatts = 0.5
        sampled.anePowerSampledAt = sampled.timestamp
        sampled.anePowerSampleInterval = 1
        sampled.aneTimeMillisecondsPerSecond = 650
        sampled.aneSampleIsPartial = true
        let unsampled = Make.system(timestamp: now, pressurePercent: 10)
        try store.insert(systemSample: sampled)
        XCTAssertEqual(try store.latestSystemSample()?.gpuMemoryBytes, 2_200_000_000)
        try store.insert(systemSample: unsampled)

        let history = try store.systemHistory(.fiveMinutes, now: now)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].gpuUtilization ?? -1, 83, accuracy: 0.001)
        XCTAssertEqual(history[0].gpuPowerWatts ?? -1, 3.56, accuracy: 0.001)
        XCTAssertEqual(history[0].gpuMemoryBytes, 2_200_000_000)
        XCTAssertEqual(history[0].gpuMemorySampleCount, 1)
        XCTAssertEqual(history[0].anePowerWatts ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(history[0].anePowerSampleCount, 1)
        XCTAssertEqual(history[0].aneTimeMillisecondsPerSecond, 650)
        XCTAssertEqual(history[0].aneSampleIsPartial, true)
        XCTAssertEqual(history[0].aneSampleCount, 1)
        // A tick that did not read the GPU stays distinct from a measured 0.
        XCTAssertNil(history[1].gpuUtilization)
        XCTAssertNil(history[1].gpuPowerWatts)
        XCTAssertNil(history[1].gpuMemoryBytes)
        XCTAssertEqual(history[1].gpuMemorySampleCount, 0)
        XCTAssertNil(history[1].aneTimeMillisecondsPerSecond)
        XCTAssertNil(history[1].aneSampleIsPartial)

        let latest = try store.latestSystemSample()
        XCTAssertNil(latest?.gpuUtilization)
        XCTAssertNil(latest?.gpuMemoryBytes)
        XCTAssertNil(latest?.aneTimeMillisecondsPerSecond)
    }

    func testANEPowerHistoryKeepsSourceAndValidReadingWeights() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (offset, watts) in [
            (1.0, 1.0), (2.0, 3.0), (3.0, Double.nan), (61.0, 9.0), (121.0, Double.nan),
        ] {
            var sample = Make.system(
                timestamp: start.addingTimeInterval(offset), pressurePercent: 5)
            sample.anePowerWatts = watts.isFinite ? watts : nil
            sample.anePowerSampledAt = watts.isFinite ? sample.timestamp : nil
            sample.anePowerSampleInterval = watts.isFinite ? 1.02 : nil
            try store.insert(systemSample: sample)
        }
        let raw = try store.systemHistory(
            from: start, to: start.addingTimeInterval(3599), granularity: .raw)
        XCTAssertEqual(raw[0].anePowerWatts, 1)
        XCTAssertNil(raw[2].anePowerWatts)
        XCTAssertEqual(raw[2].anePowerSampleCount, 0)
        try Retention.run(store.databasePool, now: start.addingTimeInterval(3700))
        let minutes = try store.systemHistory(
            from: start, to: start.addingTimeInterval(3599), granularity: .minute)
        XCTAssertEqual(minutes[0].anePowerWatts, 2)
        XCTAssertEqual(minutes[0].anePowerSampleCount, 2)
        XCTAssertEqual(minutes[0].minima?.anePowerWatts, 1)
        XCTAssertEqual(minutes[0].effectivePeaks.anePowerWatts, 3)
        let hour = try XCTUnwrap(
            store.systemHistory(from: start, to: start.addingTimeInterval(3599), granularity: .hour)
                .first)
        XCTAssertEqual(try XCTUnwrap(hour.anePowerWatts), 13.0 / 3, accuracy: 0.00001)
        XCTAssertEqual(hour.anePowerSampleCount, 3)
        XCTAssertEqual(hour.effectivePeaks.anePowerWatts, 9)
        let reduced = try XCTUnwrap(minutes.chartDownsampled(span: 3600, to: 1).first)
        XCTAssertEqual(try XCTUnwrap(reduced.anePowerWatts), 13.0 / 3, accuracy: 0.00001)
        XCTAssertEqual(reduced.minima?.anePowerWatts, 1)
        XCTAssertEqual(reduced.effectivePeaks.anePowerWatts, 9)
        let energy = try store.readAskData(
            AskToolCall(name: .systemHistory, metric: .energy), at: start.addingTimeInterval(300)
        ).result
        let fact = try XCTUnwrap(energy.facts.first { $0.id == "ane-power-mean" })
        XCTAssertTrue(fact.value.hasSuffix(" W"))
        XCTAssertFalse(fact.value.contains("%"))
        XCTAssertTrue(fact.meaning.contains("estimate"))
    }

    func testGPUMemoryHistoryKeepsValidReadingWeightsAndBounds() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let readings: [(TimeInterval, UInt64?)] = [
            (1, 1_000_000_000), (2, 3_000_000_000), (3, nil),
            (61, 9_000_000_000), (62, nil), (121, nil),
        ]
        for (offset, bytes) in readings {
            var sample = Make.system(
                timestamp: start.addingTimeInterval(offset), pressurePercent: 5)
            sample.gpuMemoryBytes = bytes
            try store.insert(systemSample: sample)
        }
        try Retention.run(store.databasePool, now: start.addingTimeInterval(3700))
        let minutes = try store.systemHistory(
            from: start, to: start.addingTimeInterval(3599), granularity: .minute)
        XCTAssertEqual(minutes.count, 3)
        XCTAssertEqual(minutes[0].gpuMemoryBytes, 2_000_000_000)
        XCTAssertEqual(minutes[0].gpuMemorySampleCount, 2)
        XCTAssertEqual(minutes[0].minima?.gpuMemoryBytes, 1_000_000_000)
        XCTAssertEqual(minutes[0].effectivePeaks.gpuMemoryBytes, 3_000_000_000)
        XCTAssertNil(minutes[2].gpuMemoryBytes)
        XCTAssertEqual(minutes[2].gpuMemorySampleCount, 0)
        let hour = try XCTUnwrap(
            store.systemHistory(from: start, to: start.addingTimeInterval(3599), granularity: .hour)
                .first)
        let reduced = try XCTUnwrap(minutes.chartDownsampled(span: 3600, to: 1).first)
        for point in [hour, reduced] {
            XCTAssertEqual(
                try XCTUnwrap(point.gpuMemoryBytes), 13_000_000_000.0 / 3, accuracy: 0.001)
            XCTAssertEqual(point.gpuMemorySampleCount, 3)
            XCTAssertEqual(point.minima?.gpuMemoryBytes, 1_000_000_000)
            XCTAssertEqual(point.effectivePeaks.gpuMemoryBytes, 9_000_000_000)
        }
    }

    func testGPUMemoryChartColumnsDistinguishGapsFromZero() throws {
        var sample = Make.system(timestamp: Date(), pressurePercent: 5)
        var window = SystemHistoryWindow(span: 60)
        window.append(SystemHistoryPoint(sample: sample))
        sample.timestamp.addTimeInterval(1)
        sample.gpuMemoryBytes = 0
        window.append(SystemHistoryPoint(sample: sample))
        sample.timestamp.addTimeInterval(1)
        sample.gpuMemoryBytes = 2_200_000_000
        window.append(SystemHistoryPoint(sample: sample))
        XCTAssertTrue(try XCTUnwrap(window.values(.gpuMemoryBytes).first).isNaN)
        XCTAssertEqual(Array(window.values(.gpuMemoryBytes).dropFirst()), [0, 2_200_000_000])
        XCTAssertEqual(Array(window.values(.gpuMemorySampleCount)), [0, 1, 1])
        XCTAssertTrue(try XCTUnwrap(window.values(.gpuMemoryMinimum).first).isNaN)
        XCTAssertEqual(window.values(.gpuMemoryPeak).last, 2_200_000_000)
    }

    func testGPUAwakeRollupsAndChartColumnsKeepWeightsBoundsAndGaps() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let readings: [(TimeInterval, Double?)] = [
            (1, 0), (2, 60), (3, nil), (61, 90), (62, nil), (121, nil),
        ]
        var raw = SystemHistoryWindow(span: 3600)
        for (offset, awake) in readings {
            var sample = Make.system(
                timestamp: start.addingTimeInterval(offset), pressurePercent: 5)
            sample.gpuActiveResidency = awake
            try store.insert(systemSample: sample)
            raw.append(SystemHistoryPoint(sample: sample))
        }
        XCTAssertEqual(raw.values(.gpuActiveResidency).first, 0)
        XCTAssertEqual(raw.values(.gpuActivePeak)[1], 60)
        XCTAssertTrue(raw.values(.gpuActiveResidency)[2].isNaN)
        XCTAssertEqual(Array(raw.values(.gpuActiveSampleCount)), [1, 1, 0, 1, 0, 0])
        try Retention.run(store.databasePool, now: start.addingTimeInterval(3700))
        let minutes = try store.systemHistory(
            from: start, to: start.addingTimeInterval(3599), granularity: .minute)
        XCTAssertEqual(minutes[0].gpuActiveResidency, 30)
        XCTAssertEqual(minutes[0].gpuActiveSampleCount, 2)
        XCTAssertEqual(minutes[0].minima?.gpuActiveResidency, 0)
        XCTAssertEqual(minutes[0].effectivePeaks.gpuActiveResidency, 60)
        XCTAssertNil(minutes[2].gpuActiveResidency)
        let hour = try XCTUnwrap(
            store.systemHistory(from: start, to: start.addingTimeInterval(3599), granularity: .hour)
                .first)
        let reduced = try XCTUnwrap(minutes.chartDownsampled(span: 3600, to: 1).first)
        for point in [hour, reduced] {
            XCTAssertEqual(point.gpuActiveResidency, 50)
            XCTAssertEqual(point.gpuActiveSampleCount, 3)
            XCTAssertEqual(point.minima?.gpuActiveResidency, 0)
            XCTAssertEqual(point.effectivePeaks.gpuActiveResidency, 90)
        }
    }

    func testANEPowerWithoutHelperSourceDoesNotBecomeReportedPower() throws {
        let now = Date()
        var sample = Make.system(timestamp: now, pressurePercent: 5)
        sample.anePowerWatts = 8
        XCTAssertNil(sample.reportedANEPowerWatts)
        try store.insert(systemSample: sample)
        let raw = try XCTUnwrap(store.systemHistory(.fiveMinutes, now: now).first)
        XCTAssertNil(raw.anePowerWatts)
        sample.anePowerSampledAt = now.addingTimeInterval(-10)
        sample.anePowerSampleInterval = 1
        XCTAssertNil(sample.reportedANEPowerWatts)
        sample.anePowerSampledAt = now
        XCTAssertEqual(sample.reportedANEPowerWatts, 8)
    }

    func testANEHistoryRollupsWeightValidReadingsAndPreserveMissingData() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let values: [(TimeInterval, Double?, Bool?)] = [
            (1, 100, false), (2, 300, true), (3, nil, nil),
            (61, 900, false), (62, nil, nil), (121, nil, nil),
        ]
        for (offset, rate, partial) in values {
            var sample = Make.system(
                timestamp: start.addingTimeInterval(offset), pressurePercent: 5)
            sample.aneTimeMillisecondsPerSecond = rate
            sample.aneSampleIsPartial = partial
            try store.insert(systemSample: sample)
        }
        try Retention.run(store.databasePool, now: start.addingTimeInterval(3700))
        let minutes = try store.systemHistory(
            from: start, to: start.addingTimeInterval(3599), granularity: .minute)
        XCTAssertEqual(minutes.count, 3)
        XCTAssertEqual(minutes[0].aneTimeMillisecondsPerSecond, 200)
        XCTAssertEqual(minutes[0].aneSampleCount, 2)
        XCTAssertEqual(minutes[0].aneSampleIsPartial, true)
        XCTAssertEqual(minutes[1].aneTimeMillisecondsPerSecond, 900)
        XCTAssertNil(minutes[2].aneTimeMillisecondsPerSecond)
        XCTAssertNil(minutes[2].aneSampleIsPartial)
        let hours = try store.systemHistory(
            from: start, to: start.addingTimeInterval(3599), granularity: .hour)
        let hour = try XCTUnwrap(hours.first)
        XCTAssertEqual(hours.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(hour.aneTimeMillisecondsPerSecond), 1300.0 / 3, accuracy: 0.001)
        XCTAssertEqual(hour.aneSampleCount, 3)
        XCTAssertEqual(hour.aneSampleIsPartial, true)
        XCTAssertEqual(hour.effectivePeaks.aneTimeMillisecondsPerSecond, 900)
        XCTAssertEqual(hour.minima?.aneTimeMillisecondsPerSecond, 100)
        let reduced = try XCTUnwrap(minutes.chartDownsampled(span: 3600, to: 1).first)
        XCTAssertEqual(
            try XCTUnwrap(reduced.aneTimeMillisecondsPerSecond), 1300.0 / 3, accuracy: 0.001)
        XCTAssertEqual(reduced.aneSampleCount, 3)
        XCTAssertEqual(reduced.effectivePeaks.aneTimeMillisecondsPerSecond, 900)
        XCTAssertEqual(reduced.minima?.aneTimeMillisecondsPerSecond, 100)
    }

    func testANEChartColumnsKeepMissingReadingsAsGaps() throws {
        var sample = Make.system(timestamp: Date(), pressurePercent: 5)
        var window = SystemHistoryWindow(span: 60)
        window.append(SystemHistoryPoint(sample: sample))
        sample.timestamp.addTimeInterval(1)
        sample.aneTimeMillisecondsPerSecond = 720
        sample.aneSampleIsPartial = false
        window.append(SystemHistoryPoint(sample: sample))
        let values = Array(window.values(.aneTimeMillisecondsPerSecond))
        XCTAssertTrue(values[0].isNaN)
        XCTAssertEqual(values[1], 720)
        XCTAssertEqual(Array(window.values(.aneTimeSampleCount)), [0, 1])
        XCTAssertTrue(try XCTUnwrap(window.values(.aneTimeMinimum).first).isNaN)
        XCTAssertEqual(window.values(.aneTimePeak).last, 720)
        XCTAssertEqual(window.points().last?.aneSampleIsPartial, false)
    }

    func testAskUsesANETimeInsteadOfZeroPowerAndKeepsCoverageLimits() throws {
        let now = Date()
        for offset in [-4.0, -2.0, 0.0] {
            var sample = Make.system(timestamp: now.addingTimeInterval(offset), pressurePercent: 5)
            sample.aneTimeMillisecondsPerSecond = offset == -4 ? nil : 750
            sample.aneSampleIsPartial = offset == -4 ? nil : true
            sample.anePowerWatts = 0
            try store.insert(systemSample: sample)
        }
        let result = try store.readAskData(AskToolCall(name: .systemHistory, metric: .gpu), at: now)
            .result
        let fact = try XCTUnwrap(result.facts.first { $0.id == "ane-time-mean" })
        XCTAssertTrue(fact.value.hasSuffix(" ms/s"))
        XCTAssertFalse(fact.value.contains("%"))
        XCTAssertTrue(fact.meaning.contains("not percent"))
        XCTAssertTrue(result.limits.contains { $0.contains("partial") })
        let energy = try store.readAskData(
            AskToolCall(name: .systemHistory, metric: .energy), at: now
        ).result
        XCTAssertFalse(energy.facts.contains { $0.id.hasPrefix("ane-power") })
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
