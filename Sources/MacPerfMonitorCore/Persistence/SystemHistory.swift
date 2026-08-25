import Foundation
import GRDB

/// One point on the dashboard's historical timelines. Carries the pressure
/// index, the taxonomy category bytes and swap so the hero timeline, the swap
/// trend, and an optional taxonomy-over-time area can all be drawn from one
/// query. `totalRAM`/`free` are not stored in the aggregates, so they are not
/// part of this point; the live stacked bar (which must sum to total RAM) uses
/// the current `SystemSample` instead.
public struct SystemHistoryPoint: Sendable, Identifiable, Equatable {
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
    public var anePowerWatts: Double?
    public var diskUtilizationPercent: Double?
    public var bootFreeBytes: UInt64?
    public var bootTotalBytes: UInt64?
    // Thermal figures (v14); nil on ticks that did not read the SMC. On
    // aggregate ranges these carry the bucket MAX, not the average: "how hot
    // did it get" is the question thermal history answers, and averaging
    // erases exactly the spikes users go looking for.
    public var cpuDieC: Double?
    public var gpuDieC: Double?
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
        anePowerWatts: Double? = nil,
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
        otherSensorC: Double? = nil
    ) {
        self.date = date
        self.pressurePercent = pressurePercent
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.swapUsed = swapUsed
        self.cpuLoad = cpuLoad
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
        self.anePowerWatts = anePowerWatts
        self.cpuDieC = cpuDieC
        self.gpuDieC = gpuDieC
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

extension SampleStore {
    /// System history for a dashboard window, oldest first. Reads from the raw,
    /// minute, or hour table according to `window.granularity`. The whole app
    /// shares one `HistoryWindow` (5m / 30m / 1h / 6h / 24h / 7d) so every page's
    /// history picker offers the same timeframes.
    public func systemHistory(
        _ window: HistoryWindow, now: Date = Date()
    ) throws -> [SystemHistoryPoint] {
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        switch window.granularity {
        case .raw:
            return try rawHistory(since: since)
        case .minute:
            return try aggregateHistory(table: "system_minute", since: since)
        case .hour:
            return try aggregateHistory(table: "system_hour", since: since)
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
        try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT timestamp, pressure_percent, app_memory, wired, compressed, cached_files, swap_used, cpu_load,
                           battery_charge, battery_power, battery_health, battery_temp, net_in, net_out,
                           disk_read, disk_write, disk_read_iops, disk_write_iops,
                           disk_read_latency, disk_write_latency, disk_util, boot_free, boot_total,
                           gpu_util, gpu_power, ane_power,
                           cpu_die, gpu_die, ssd_temp, fan_rpm, thermal_state,
                           cpu_p_die, cpu_e_die, airflow_temp, skin_temp, wireless_temp,
                           vrail_temp, other_temp
                    FROM system_samples
                    WHERE timestamp >= ?
                    ORDER BY timestamp ASC
                    """, arguments: [since]
            ).map(Self.decodeHistoryPoint)
        }
    }

    private func aggregateHistory(table: String, since: Double) throws -> [SystemHistoryPoint] {
        try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT bucket, pressure_avg, app_avg, wired_avg, compressed_avg, cached_avg, swap_used_avg, cpu_avg,
                           battery_charge_avg, battery_power_avg, battery_health_avg, battery_temp_avg,
                           net_in_avg, net_out_avg,
                           disk_read_avg, disk_write_avg, disk_read_iops_avg, disk_write_iops_avg,
                           disk_read_latency_avg, disk_write_latency_avg, disk_util_avg,
                           boot_free_min, boot_total,
                           gpu_util_avg, gpu_power_avg, ane_power_avg,
                           cpu_die_max, gpu_die_max, ssd_temp_max, fan_rpm_max, thermal_state_max,
                           cpu_p_die_max, cpu_e_die_max, airflow_temp_max, skin_temp_max,
                           wireless_temp_max, vrail_temp_max, other_temp_max
                    FROM \(table)
                    WHERE bucket >= ?
                    ORDER BY bucket ASC
                    """, arguments: [since]
            ).map(Self.decodeHistoryPoint)
        }
    }

    /// Positional decode shared by the raw and aggregate queries, which list the
    /// same 23 columns in the same order. Reading by index (`row[0]`) rather than
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
            anePowerWatts: row[25],
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
