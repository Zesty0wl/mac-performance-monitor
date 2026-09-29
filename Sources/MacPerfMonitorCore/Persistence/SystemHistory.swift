import Foundation
import GRDB

/// One point on the dashboard's historical timelines. Carries the pressure
/// index, the taxonomy category bytes and swap so the hero timeline, the swap
/// trend, and an optional taxonomy-over-time area can all be drawn from one
/// query. `totalRAM`/`free` are not stored in the aggregates, so they are not
/// part of this point; the live stacked bar (which must sum to total RAM) uses
/// the current `SystemSample` instead.
public struct SystemHistoryPoint: Sendable, Identifiable, Equatable {
    /// The highest raw value inside the bucket this point summarises. Set for
    /// points read from the minute and hour tiers, whose value is a mean; nil
    /// for a raw sample, whose peak is itself. The charts draw the mean as the
    /// line and the peak as the top of the band behind it, so a long range still
    /// shows what the spikes reached rather than a flat average. Extrema added
    /// in v17 stay nil for older buckets that did not record them.
    public var peaks: SystemHistoryPeaks?
    /// Number of raw system samples represented by the point, not a duration.
    public var sampleCount: Int = 1
    /// Width of the source aggregate bucket in seconds; zero for a raw sample.
    public var bucketDuration: TimeInterval = 0
    /// Lowest recorded values in the bucket. Nil means the full range is
    /// unknown, not that its minimum equals its mean. Raw samples need no
    /// separate extrema because both ends of their range equal the value.
    public var minima: SystemHistoryPeaks? = nil

    public var date: Date
    public var pressurePercent: Double
    public var appMemory: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cachedFiles: UInt64
    public var swapUsed: UInt64
    /// Total system CPU as a fraction of capacity, 0...1. Defaulted so call
    /// sites that predate CPU history (and the analysis tests) still build.
    public var cpuLoad: Double
    /// The kernel's load averages: run-queue length over the last 1, 5 and
    /// 15 minutes. Zero for rows written before they were recorded.
    public var loadAverage1: Double
    public var loadAverage5: Double
    public var loadAverage15: Double
    // Battery timeline scalars (the charge-line slope shows charge vs discharge,
    // so no separate charging flag is carried here). Defaulted, like cpuLoad.
    public var batteryCharge: Double
    public var batteryPowerWatts: Double
    public var batteryHealthPercent: Double
    public var batteryTemperatureCelsius: Double
    // Network throughput timeline scalars (bytes/second), defaulted like the
    // battery scalars so call sites that predate network history still build.
    public var networkInBytesPerSec: Double
    public var networkOutBytesPerSec: Double
    public var diskReadBytesPerSec: Double
    public var diskWriteBytesPerSec: Double
    public var diskReadOperationsPerSec: Double
    public var diskWriteOperationsPerSec: Double
    // Disk detail (v12). Optional, unlike the scalars above: nil marks "no IO
    // in this interval" (latency/utilization) or "not recorded yet" (boot
    // volume capacity), and charts must gap rather than draw zero.
    public var diskReadLatencyMs: Double?
    public var diskWriteLatencyMs: Double?
    /// GPU device figures (v13); nil on ticks that did not read the GPU.
    public var gpuUtilization: Double?
    public var gpuPowerWatts: Double?
    public var gpuMemoryBytes: Double?
    public var gpuMemorySampleCount: Int?
    public var gpuActiveResidency: Double?
    public var gpuActiveSampleCount: Int?
    public var gpuReadBandwidthGBps: Double?
    public var gpuReadBandwidthSampleCount: Int?
    public var gpuWriteBandwidthGBps: Double?
    public var gpuWriteBandwidthSampleCount: Int?
    public var gpuTotalBandwidthGBps: Double?
    public var gpuTotalBandwidthSampleCount: Int?
    public var anePowerWatts: Double?
    public var anePowerSampleCount: Int?
    public var aneTimeMillisecondsPerSecond: Double?
    public var aneSampleIsPartial: Bool?
    public var aneSampleCount: Int?
    public var diskUtilizationPercent: Double?
    public var bootFreeBytes: UInt64?
    public var bootTotalBytes: UInt64?
    // Thermal figures (v14); nil on ticks that did not read the SMC. On
    // aggregate ranges these carry the bucket MAX, not the average: "how hot
    // did it get" is the question thermal history answers, and averaging
    // erases exactly the spikes users go looking for.
    public var cpuDieC: Double?
    public var gpuDieC: Double?
    /// Means of the recorded die readings, separate from the peaks above.
    /// Legacy aggregates retain their stored means but have unknown weights.
    public var cpuDieAverageC: Double? = nil
    public var gpuDieAverageC: Double? = nil
    /// Valid sensor readings contributing to the corresponding mean. Zero
    /// means no reading; nil means the count was not recorded, so the mean
    /// cannot be treated as an exactly weighted aggregate of raw readings.
    public var cpuDieSampleCount: Int? = nil
    public var gpuDieSampleCount: Int? = nil
    public var ssdTemperatureC: Double?
    public var fanRPM: Double?
    /// Worst thermal pressure in the interval.
    public var thermalPressure: ThermalPressureState?
    // Per-domain hottest readings (v15), the recorded series behind the
    // Hardware tab's sensor charts.
    public var cpuPCoreDieC: Double?
    public var cpuECoreDieC: Double?
    public var airflowC: Double?
    public var skinC: Double?
    public var wirelessC: Double?
    public var voltageRailC: Double?
    public var otherSensorC: Double?

    public var id: Date { date }

    public init(
        date: Date,
        pressurePercent: Double,
        appMemory: UInt64,
        wired: UInt64,
        compressed: UInt64,
        cachedFiles: UInt64,
        swapUsed: UInt64,
        cpuLoad: Double = 0,
        loadAverage1: Double = 0,
        loadAverage5: Double = 0,
        loadAverage15: Double = 0,
        batteryCharge: Double = 0,
        batteryPowerWatts: Double = 0,
        batteryHealthPercent: Double = 0,
        batteryTemperatureCelsius: Double = 0,
        networkInBytesPerSec: Double = 0,
        networkOutBytesPerSec: Double = 0,
        diskReadBytesPerSec: Double = 0,
        diskWriteBytesPerSec: Double = 0,
        diskReadOperationsPerSec: Double = 0,
        diskWriteOperationsPerSec: Double = 0,
        diskReadLatencyMs: Double? = nil,
        diskWriteLatencyMs: Double? = nil,
        diskUtilizationPercent: Double? = nil,
        bootFreeBytes: UInt64? = nil,
        bootTotalBytes: UInt64? = nil,
        gpuUtilization: Double? = nil,
        gpuPowerWatts: Double? = nil,
        gpuMemoryBytes: Double? = nil,
        gpuMemorySampleCount: Int? = nil,
        gpuActiveResidency: Double? = nil,
        gpuActiveSampleCount: Int? = nil,
        gpuReadBandwidthGBps: Double? = nil,
        gpuReadBandwidthSampleCount: Int? = nil,
        gpuWriteBandwidthGBps: Double? = nil,
        gpuWriteBandwidthSampleCount: Int? = nil,
        gpuTotalBandwidthGBps: Double? = nil,
        gpuTotalBandwidthSampleCount: Int? = nil,
        anePowerWatts: Double? = nil,
        anePowerSampleCount: Int? = nil,
        aneTimeMillisecondsPerSecond: Double? = nil,
        aneSampleIsPartial: Bool? = nil,
        aneSampleCount: Int? = nil,
        cpuDieC: Double? = nil,
        gpuDieC: Double? = nil,
        ssdTemperatureC: Double? = nil,
        fanRPM: Double? = nil,
        thermalPressure: ThermalPressureState? = nil,
        cpuPCoreDieC: Double? = nil,
        cpuECoreDieC: Double? = nil,
        airflowC: Double? = nil,
        skinC: Double? = nil,
        wirelessC: Double? = nil,
        voltageRailC: Double? = nil,
        otherSensorC: Double? = nil,
        sampleCount: Int = 1,
        bucketDuration: TimeInterval = 0,
        minima: SystemHistoryPeaks? = nil,
        cpuDieAverageC: Double? = nil,
        gpuDieAverageC: Double? = nil,
        cpuDieSampleCount: Int? = nil,
        gpuDieSampleCount: Int? = nil
    ) {
        self.sampleCount = sampleCount
        self.bucketDuration = bucketDuration
        self.minima = minima
        self.date = date
        self.pressurePercent = pressurePercent
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.swapUsed = swapUsed
        self.cpuLoad = cpuLoad
        self.loadAverage1 = loadAverage1
        self.loadAverage5 = loadAverage5
        self.loadAverage15 = loadAverage15
        self.batteryCharge = batteryCharge
        self.batteryPowerWatts = batteryPowerWatts
        self.batteryHealthPercent = batteryHealthPercent
        self.batteryTemperatureCelsius = batteryTemperatureCelsius
        self.networkInBytesPerSec = networkInBytesPerSec
        self.networkOutBytesPerSec = networkOutBytesPerSec
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.diskReadOperationsPerSec = diskReadOperationsPerSec
        self.diskWriteOperationsPerSec = diskWriteOperationsPerSec
        self.diskReadLatencyMs = diskReadLatencyMs
        self.diskWriteLatencyMs = diskWriteLatencyMs
        self.diskUtilizationPercent = diskUtilizationPercent
        self.bootFreeBytes = bootFreeBytes
        self.bootTotalBytes = bootTotalBytes
        self.gpuUtilization = gpuUtilization
        self.gpuPowerWatts = gpuPowerWatts
        self.gpuMemoryBytes = gpuMemoryBytes
        self.gpuMemorySampleCount = gpuMemorySampleCount
        self.gpuActiveResidency = gpuActiveResidency
        self.gpuActiveSampleCount = gpuActiveSampleCount
        self.gpuReadBandwidthGBps = gpuReadBandwidthGBps
        self.gpuReadBandwidthSampleCount = gpuReadBandwidthSampleCount
        self.gpuWriteBandwidthGBps = gpuWriteBandwidthGBps
        self.gpuWriteBandwidthSampleCount = gpuWriteBandwidthSampleCount
        self.gpuTotalBandwidthGBps = gpuTotalBandwidthGBps
        self.gpuTotalBandwidthSampleCount = gpuTotalBandwidthSampleCount
        self.anePowerWatts = anePowerWatts
        self.anePowerSampleCount = anePowerSampleCount
        self.aneTimeMillisecondsPerSecond = aneTimeMillisecondsPerSecond
        self.aneSampleIsPartial = aneSampleIsPartial
        self.aneSampleCount = aneSampleCount
        self.cpuDieC = cpuDieC
        self.gpuDieC = gpuDieC
        self.cpuDieAverageC = cpuDieAverageC
        self.gpuDieAverageC = gpuDieAverageC
        self.cpuDieSampleCount = cpuDieSampleCount
        self.gpuDieSampleCount = gpuDieSampleCount
        self.ssdTemperatureC = ssdTemperatureC
        self.fanRPM = fanRPM
        self.thermalPressure = thermalPressure
        self.cpuPCoreDieC = cpuPCoreDieC
        self.cpuECoreDieC = cpuECoreDieC
        self.airflowC = airflowC
        self.skinC = skinC
        self.wirelessC = wirelessC
        self.voltageRailC = voltageRailC
        self.otherSensorC = otherSensorC
    }
}

/// Per-bucket extrema stored alongside the means in the minute and hour
/// tiers. Used for both `peaks` and `minima`; optional fields distinguish an
/// unrecorded extremum from a measured zero.
public struct SystemHistoryPeaks: Sendable, Equatable {
    public var pressurePercent: Double
    public var cpuLoad: Double
    public var networkInBytesPerSec: Double
    public var networkOutBytesPerSec: Double
    public var diskReadBytesPerSec: Double
    public var diskWriteBytesPerSec: Double
    public var gpuUtilization: Double?
    /// The 1 minute load average's extremum. Nil for tier rows written before it
    /// was recorded.
    public var loadAverage1: Double?
    public var appMemory: Double? = nil
    public var wired: Double? = nil
    public var compressed: Double? = nil
    public var cachedFiles: Double? = nil
    public var swapUsed: Double? = nil
    public var cpuDieC: Double? = nil
    public var gpuDieC: Double? = nil
    public var aneTimeMillisecondsPerSecond: Double? = nil
    public var anePowerWatts: Double? = nil
    public var gpuMemoryBytes: Double? = nil
    public var gpuActiveResidency: Double? = nil
    public var gpuReadBandwidthGBps: Double? = nil
    public var gpuWriteBandwidthGBps: Double? = nil
    public var gpuTotalBandwidthGBps: Double? = nil

    public init(
        pressurePercent: Double, cpuLoad: Double, networkInBytesPerSec: Double,
        networkOutBytesPerSec: Double, diskReadBytesPerSec: Double,
        diskWriteBytesPerSec: Double, gpuUtilization: Double? = nil,
        loadAverage1: Double? = nil,
        appMemory: Double? = nil, wired: Double? = nil, compressed: Double? = nil,
        cachedFiles: Double? = nil, swapUsed: Double? = nil,
        cpuDieC: Double? = nil, gpuDieC: Double? = nil,
        aneTimeMillisecondsPerSecond: Double? = nil, anePowerWatts: Double? = nil,
        gpuMemoryBytes: Double? = nil, gpuActiveResidency: Double? = nil,
        gpuReadBandwidthGBps: Double? = nil, gpuWriteBandwidthGBps: Double? = nil,
        gpuTotalBandwidthGBps: Double? = nil
    ) {
        self.pressurePercent = pressurePercent
        self.cpuLoad = cpuLoad
        self.networkInBytesPerSec = networkInBytesPerSec
        self.networkOutBytesPerSec = networkOutBytesPerSec
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.gpuUtilization = gpuUtilization
        self.loadAverage1 = loadAverage1
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.swapUsed = swapUsed
        self.cpuDieC = cpuDieC
        self.gpuDieC = gpuDieC
        self.aneTimeMillisecondsPerSecond = aneTimeMillisecondsPerSecond
        self.anePowerWatts = anePowerWatts
        self.gpuMemoryBytes = gpuMemoryBytes
        self.gpuActiveResidency = gpuActiveResidency
        self.gpuReadBandwidthGBps = gpuReadBandwidthGBps
        self.gpuWriteBandwidthGBps = gpuWriteBandwidthGBps
        self.gpuTotalBandwidthGBps = gpuTotalBandwidthGBps
    }

    /// The peaks of a single raw sample: the sample itself.
    public init(_ point: SystemHistoryPoint) {
        self.init(
            pressurePercent: point.pressurePercent, cpuLoad: point.cpuLoad,
            networkInBytesPerSec: point.networkInBytesPerSec,
            networkOutBytesPerSec: point.networkOutBytesPerSec,
            diskReadBytesPerSec: point.diskReadBytesPerSec,
            diskWriteBytesPerSec: point.diskWriteBytesPerSec,
            gpuUtilization: point.gpuUtilization, loadAverage1: point.loadAverage1,
            appMemory: Double(point.appMemory), wired: Double(point.wired),
            compressed: Double(point.compressed), cachedFiles: Double(point.cachedFiles),
            swapUsed: Double(point.swapUsed), cpuDieC: point.cpuDieC, gpuDieC: point.gpuDieC,
            aneTimeMillisecondsPerSecond: point.aneTimeMillisecondsPerSecond,
            anePowerWatts: point.anePowerWatts, gpuMemoryBytes: point.gpuMemoryBytes,
            gpuActiveResidency: point.gpuActiveResidency,
            gpuReadBandwidthGBps: point.gpuReadBandwidthGBps,
            gpuWriteBandwidthGBps: point.gpuWriteBandwidthGBps,
            gpuTotalBandwidthGBps: point.gpuTotalBandwidthGBps)
    }

    /// The element-wise larger of two peaks.
    public func merged(with other: SystemHistoryPeaks) -> SystemHistoryPeaks {
        // Memory is present on every raw sample. If either bucket omitted its
        // peak, the other bucket's peak cannot describe the full combined range.
        func completeMaximum(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return nil }
            return max(a, b)
        }
        return SystemHistoryPeaks(
            pressurePercent: max(pressurePercent, other.pressurePercent),
            cpuLoad: max(cpuLoad, other.cpuLoad),
            networkInBytesPerSec: max(networkInBytesPerSec, other.networkInBytesPerSec),
            networkOutBytesPerSec: max(networkOutBytesPerSec, other.networkOutBytesPerSec),
            diskReadBytesPerSec: max(diskReadBytesPerSec, other.diskReadBytesPerSec),
            diskWriteBytesPerSec: max(diskWriteBytesPerSec, other.diskWriteBytesPerSec),
            gpuUtilization: [gpuUtilization, other.gpuUtilization].compactMap { $0 }.max(),
            loadAverage1: [loadAverage1, other.loadAverage1].compactMap { $0 }.max(),
            appMemory: completeMaximum(appMemory, other.appMemory),
            wired: completeMaximum(wired, other.wired),
            compressed: completeMaximum(compressed, other.compressed),
            cachedFiles: completeMaximum(cachedFiles, other.cachedFiles),
            swapUsed: completeMaximum(swapUsed, other.swapUsed),
            cpuDieC: [cpuDieC, other.cpuDieC].compactMap { $0 }.max(),
            gpuDieC: [gpuDieC, other.gpuDieC].compactMap { $0 }.max(),
            aneTimeMillisecondsPerSecond: [
                aneTimeMillisecondsPerSecond, other.aneTimeMillisecondsPerSecond,
            ]
            .compactMap { $0 }.max(),
            anePowerWatts: [anePowerWatts, other.anePowerWatts].compactMap { $0 }.max(),
            gpuMemoryBytes: [gpuMemoryBytes, other.gpuMemoryBytes].compactMap { $0 }.max(),
            gpuActiveResidency: [gpuActiveResidency, other.gpuActiveResidency].compactMap { $0 }
                .max(),
            gpuReadBandwidthGBps: [gpuReadBandwidthGBps, other.gpuReadBandwidthGBps].compactMap {
                $0
            }.max(),
            gpuWriteBandwidthGBps: [gpuWriteBandwidthGBps, other.gpuWriteBandwidthGBps].compactMap {
                $0
            }.max(),
            gpuTotalBandwidthGBps: [gpuTotalBandwidthGBps, other.gpuTotalBandwidthGBps].compactMap {
                $0
            }.max())
    }
}

extension SystemHistoryPoint {
    /// The peaks this point stands for: its stored bucket peaks, or itself.
    public var effectivePeaks: SystemHistoryPeaks { peaks ?? SystemHistoryPeaks(self) }
}

extension SampleStore {
    /// System history for a dashboard window, oldest first. Reads from the raw,
    /// minute, or hour table according to `window.granularity`. The whole app
    /// shares one `HistoryWindow` (5m / 30m / 1h / 6h / 24h / 7d) so every page's
    /// history picker offers the same timeframes.
    ///
    /// A tier only holds buckets that were complete when retention last ran, so
    /// on its own it ends up to a minute (or an hour) before now. The result is
    /// topped up from the finer tiers past each tier's watermark, down to the
    /// raw rows, so every range runs right up to the last recorded sample and
    /// the live samples the caller appends join on without a hole.
    public func systemHistory(
        _ window: HistoryWindow, now: Date = Date()
    ) throws -> [SystemHistoryPoint] {
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        switch window.granularity {
        case .raw:
            return try rawHistory(since: since)
        case .minute:
            return try tieredHistory(since: since, hours: false)
        case .hour:
            return try tieredHistory(since: since, hours: true)
        }
    }

    public func systemHistory(
        from: Date, to: Date, granularity: HistoryWindow.Granularity
    ) throws -> [SystemHistoryPoint] {
        guard from <= to else { return [] }
        let since = from.timeIntervalSince1970
        let until = to.timeIntervalSince1970
        switch granularity {
        case .raw:
            return try databasePool.read { db in
                try Self.rawHistory(db, since: since, until: until)
            }
        case .minute:
            let paddedStart = try databasePool.read { db in
                try Double.fetchOne(
                    db, sql: "SELECT MAX(bucket) FROM system_minute WHERE bucket < ?",
                    arguments: [since]) ?? since
            }
            return try tieredHistory(since: paddedStart, until: until, hours: false)
                .filter {
                    $0.date >= from
                        || ($0.bucketDuration > 0
                            && $0.date.addingTimeInterval($0.bucketDuration) > from)
                }
        case .hour:
            return try tieredHistory(since: since - 3600, until: until, hours: true)
                .filter {
                    $0.date >= from
                        || ($0.bucketDuration > 0
                            && $0.date.addingTimeInterval($0.bucketDuration) > from)
                }
        }
    }

    private func tieredHistory(
        since: Double, until: Double = .greatestFiniteMagnitude, hours: Bool
    ) throws -> [SystemHistoryPoint] {
        try databasePool.read { db in
            var points: [SystemHistoryPoint] = []
            var coveredThrough = since
            if hours {
                points = try Self.aggregateHistory(
                    db, table: "system_hour", since: since, until: until)
                let watermark = try Retention.meta(db, "hour_watermark") ?? 0
                coveredThrough = max(coveredThrough, watermark)
            }
            points += try Self.aggregateHistory(
                db, table: "system_minute", since: coveredThrough, until: until)
            let watermark = try Retention.meta(db, "minute_watermark") ?? 0
            coveredThrough = max(coveredThrough, watermark)
            points += try Self.rawHistory(db, since: coveredThrough, until: until)
            return points
        }
    }

    /// Raw system history for the last `seconds` (default two hours, which is the
    /// raw retention window), oldest first. The Processes-tab header trend
    /// sparklines always want the full raw window at 2-second resolution,
    /// independent of the dashboard's range picker, so this bypasses
    /// `HistoryWindow` rather than adding a case that would also appear there.
    public func recentSystemHistory(
        seconds: TimeInterval = 2 * 3600, now: Date = Date()
    ) throws -> [SystemHistoryPoint] {
        let since = now.addingTimeInterval(-seconds).timeIntervalSince1970
        return try rawHistory(since: since)
    }

    private func rawHistory(since: Double) throws -> [SystemHistoryPoint] {
        try databasePool.read { db in try Self.rawHistory(db, since: since) }
    }

    private static func rawHistory(
        _ db: Database, since: Double, until: Double = .greatestFiniteMagnitude
    ) throws -> [SystemHistoryPoint] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT timestamp, pressure_percent, app_memory, wired, compressed, cached_files, swap_used, cpu_load,
                       battery_charge, battery_power, battery_health, battery_temp, net_in, net_out,
                       disk_read, disk_write, disk_read_iops, disk_write_iops,
                       disk_read_latency, disk_write_latency, disk_util, boot_free, boot_total,
                       gpu_util, gpu_power,
                       CASE WHEN ane_power_observed_at IS NOT NULL THEN ane_power END AS ane_power,
                       cpu_die, gpu_die, ssd_temp, fan_rpm, thermal_state,
                       cpu_p_die, cpu_e_die, airflow_temp, skin_temp, wireless_temp,
                       vrail_temp, other_temp,
                      load_1, load_5, load_15,
                      ane_time, ane_partial,
                      CASE WHEN ane_time IS NULL THEN 0 ELSE 1 END AS ane_time_samples,
                      CASE WHEN ane_power_observed_at IS NOT NULL AND ane_power IS NOT NULL THEN 1 ELSE 0 END AS ane_power_samples,
                      gpu_memory, CASE WHEN gpu_memory IS NULL THEN 0 ELSE 1 END AS gpu_memory_samples,
                      gpu_active, CASE WHEN gpu_active IS NULL THEN 0 ELSE 1 END AS gpu_active_samples,
                      gpu_bw_read, CASE WHEN gpu_bw_read IS NULL THEN 0 ELSE 1 END AS gpu_bw_read_samples,
                      gpu_bw_write, CASE WHEN gpu_bw_write IS NULL THEN 0 ELSE 1 END AS gpu_bw_write_samples,
                      gpu_bw_total, CASE WHEN gpu_bw_total IS NULL THEN 0 ELSE 1 END AS gpu_bw_total_samples
                FROM system_samples
                WHERE timestamp >= ? AND timestamp <= ?
                ORDER BY timestamp ASC
                """, arguments: [since, until]
        ).map { row in
            var point = decodeHistoryPoint(row)
            point.cpuDieAverageC = point.cpuDieC
            point.gpuDieAverageC = point.gpuDieC
            point.cpuDieSampleCount = point.cpuDieC == nil ? 0 : 1
            point.gpuDieSampleCount = point.gpuDieC == nil ? 0 : 1
            return point
        }
    }

    private static func aggregateHistory(
        _ db: Database, table: String, since: Double, until: Double = .greatestFiniteMagnitude
    ) throws -> [SystemHistoryPoint] {
        let legacyBucketDuration: TimeInterval
        if table == "system_hour" {
            legacyBucketDuration = 3600
        } else {
            legacyBucketDuration = try Retention.meta(db, "minute_bucket_seconds") ?? 60
        }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT bucket, pressure_avg, app_avg, wired_avg, compressed_avg, cached_avg, swap_used_avg, cpu_avg,
                       battery_charge_avg, battery_power_avg, battery_health_avg, battery_temp_avg,
                       net_in_avg, net_out_avg,
                       disk_read_avg, disk_write_avg, disk_read_iops_avg, disk_write_iops_avg,
                       disk_read_latency_avg, disk_write_latency_avg, disk_util_avg,
                       boot_free_min, boot_total,
                       gpu_util_avg, gpu_power_avg,
                       CASE WHEN ane_power_samples > 0 THEN ane_power_avg END AS ane_power_avg,
                       cpu_die_max, gpu_die_max, ssd_temp_max, fan_rpm_max, thermal_state_max,
                       cpu_p_die_max, cpu_e_die_max, airflow_temp_max, skin_temp_max,
                       wireless_temp_max, vrail_temp_max, other_temp_max,
                       load_1_avg, load_5_avg, load_15_avg,
                       pressure_max, cpu_max, net_in_max, net_out_max,
                       disk_read_max, disk_write_max, gpu_util_max, load_1_max,
                       samples, COALESCE(bucket_seconds, ?) AS bucket_seconds,
                       pressure_min, cpu_min, net_in_min, net_out_min,
                       disk_read_min, disk_write_min, gpu_util_min, load_1_min,
                       app_min, wired_min, compressed_min, cached_min, swap_used_min,
                       cpu_die_min, gpu_die_min,
                       app_max, wired_max, compressed_max, cached_max, swap_used_max,
                      cpu_die_avg, gpu_die_avg, cpu_die_samples, gpu_die_samples,
                       ane_time_avg AS ane_time, ane_partial, ane_time_max, ane_time_samples, ane_time_min,
                       ane_power_samples, ane_power_min,
                       CASE WHEN ane_power_samples > 0 THEN ane_power_max END AS ane_power_max,
                       gpu_memory_avg AS gpu_memory, gpu_memory_min, gpu_memory_max, gpu_memory_samples,
                       gpu_active_avg AS gpu_active, gpu_active_min, gpu_active_max, gpu_active_samples,
                       gpu_bw_read_avg AS gpu_bw_read, gpu_bw_read_min, gpu_bw_read_max, gpu_bw_read_samples,
                       gpu_bw_write_avg AS gpu_bw_write, gpu_bw_write_min, gpu_bw_write_max, gpu_bw_write_samples,
                       gpu_bw_total_avg AS gpu_bw_total, gpu_bw_total_min, gpu_bw_total_max, gpu_bw_total_samples
                FROM \(table)
                WHERE bucket >= ? AND bucket <= ?
                ORDER BY bucket ASC
                """, arguments: [legacyBucketDuration, since, until]
        ).map(Self.decodeAggregatePoint)
    }

    /// The shared decode plus the aggregate statistics (columns 41 through 74).
    private static func decodeAggregatePoint(_ row: Row) -> SystemHistoryPoint {
        var point = decodeHistoryPoint(row)
        point.peaks = SystemHistoryPeaks(
            pressurePercent: row[41], cpuLoad: row[42],
            networkInBytesPerSec: row[43], networkOutBytesPerSec: row[44],
            diskReadBytesPerSec: row[45], diskWriteBytesPerSec: row[46],
            gpuUtilization: row[47], loadAverage1: row[48],
            appMemory: row[66], wired: row[67], compressed: row[68],
            cachedFiles: row[69], swapUsed: row[70],
            cpuDieC: point.cpuDieC, gpuDieC: point.gpuDieC,
            aneTimeMillisecondsPerSecond: row["ane_time_max"], anePowerWatts: row["ane_power_max"],
            gpuMemoryBytes: row["gpu_memory_max"], gpuActiveResidency: row["gpu_active_max"],
            gpuReadBandwidthGBps: row["gpu_bw_read_max"],
            gpuWriteBandwidthGBps: row["gpu_bw_write_max"],
            gpuTotalBandwidthGBps: row["gpu_bw_total_max"])
        point.sampleCount = row[49]
        point.bucketDuration = row[50]
        // Required scalar minima are non-optional inside SystemHistoryPeaks.
        // If even one is missing, omit the range rather than invent its floor.
        if let pressure = row[51] as Double?, let cpu = row[52] as Double?,
            let networkIn = row[53] as Double?, let networkOut = row[54] as Double?,
            let diskRead = row[55] as Double?, let diskWrite = row[56] as Double?
        {
            point.minima = SystemHistoryPeaks(
                pressurePercent: pressure, cpuLoad: cpu,
                networkInBytesPerSec: networkIn, networkOutBytesPerSec: networkOut,
                diskReadBytesPerSec: diskRead, diskWriteBytesPerSec: diskWrite,
                gpuUtilization: row[57], loadAverage1: row[58],
                appMemory: row[59], wired: row[60], compressed: row[61],
                cachedFiles: row[62], swapUsed: row[63],
                cpuDieC: row[64], gpuDieC: row[65])
        }
        point.cpuDieAverageC = row[71]
        point.minima?.aneTimeMillisecondsPerSecond = row["ane_time_min"]
        point.minima?.anePowerWatts = row["ane_power_min"]
        point.minima?.gpuMemoryBytes = row["gpu_memory_min"]
        point.minima?.gpuActiveResidency = row["gpu_active_min"]
        point.minima?.gpuReadBandwidthGBps = row["gpu_bw_read_min"]
        point.minima?.gpuWriteBandwidthGBps = row["gpu_bw_write_min"]
        point.minima?.gpuTotalBandwidthGBps = row["gpu_bw_total_min"]
        point.gpuDieAverageC = row[72]
        point.cpuDieSampleCount = row[73]
        point.gpuDieSampleCount = row[74]
        return point
    }

    /// Positional decode shared by the raw and aggregate queries, which list the
    /// same 41 columns in the same order (the load columns, 38 to 40, are null
    /// on rows written before v16). Reading by index (`row[0]`) rather than
    /// by name (`row["..."]`) avoids a column-name→index lookup per field per row,
    /// which over a few hundred points × 14 columns was a measurable read cost.
    private static func decodeHistoryPoint(_ row: Row) -> SystemHistoryPoint {
        let ts: Double = row[0]
        return SystemHistoryPoint(
            date: Date(timeIntervalSince1970: ts),
            pressurePercent: row[1],
            appMemory: SQLInt.read(row[2]),
            wired: SQLInt.read(row[3]),
            compressed: SQLInt.read(row[4]),
            cachedFiles: SQLInt.read(row[5]),
            swapUsed: SQLInt.read(row[6]),
            cpuLoad: row[7],
            loadAverage1: (row[38] as Double?) ?? 0,
            loadAverage5: (row[39] as Double?) ?? 0,
            loadAverage15: (row[40] as Double?) ?? 0,
            batteryCharge: row[8],
            batteryPowerWatts: row[9],
            batteryHealthPercent: row[10],
            batteryTemperatureCelsius: row[11],
            networkInBytesPerSec: row[12],
            networkOutBytesPerSec: row[13],
            diskReadBytesPerSec: row[14],
            diskWriteBytesPerSec: row[15],
            diskReadOperationsPerSec: row[16],
            diskWriteOperationsPerSec: row[17],
            diskReadLatencyMs: row[18],
            diskWriteLatencyMs: row[19],
            diskUtilizationPercent: row[20],
            bootFreeBytes: (row[21] as Int64?).map(SQLInt.read),
            bootTotalBytes: (row[22] as Int64?).map(SQLInt.read),
            gpuUtilization: row[23],
            gpuPowerWatts: row[24],
            gpuMemoryBytes: row["gpu_memory"],
            gpuMemorySampleCount: row["gpu_memory_samples"],
            gpuActiveResidency: row["gpu_active"],
            gpuActiveSampleCount: row["gpu_active_samples"],
            gpuReadBandwidthGBps: row["gpu_bw_read"],
            gpuReadBandwidthSampleCount: row["gpu_bw_read_samples"],
            gpuWriteBandwidthGBps: row["gpu_bw_write"],
            gpuWriteBandwidthSampleCount: row["gpu_bw_write_samples"],
            gpuTotalBandwidthGBps: row["gpu_bw_total"],
            gpuTotalBandwidthSampleCount: row["gpu_bw_total_samples"],
            anePowerWatts: row[25],
            anePowerSampleCount: row["ane_power_samples"],
            aneTimeMillisecondsPerSecond: row["ane_time"],
            aneSampleIsPartial: row["ane_partial"],
            aneSampleCount: row["ane_time_samples"],
            cpuDieC: row[26],
            gpuDieC: row[27],
            ssdTemperatureC: row[28],
            fanRPM: row[29],
            thermalPressure: (row[30] as Int?).flatMap { ThermalPressureState(rawValue: $0) },
            cpuPCoreDieC: row[31],
            cpuECoreDieC: row[32],
            airflowC: row[33],
            skinC: row[34],
            wirelessC: row[35],
            voltageRailC: row[36],
            otherSensorC: row[37]
        )
    }
}
