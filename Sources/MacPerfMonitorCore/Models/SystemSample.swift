import Foundation

/// A single system-wide measurement captured once per sampling tick.
public struct SystemSample: Sendable, Codable {
    public var timestamp: Date

    public var totalRAM: UInt64

    // Raw VM categories (bytes), derived from vm_statistics64.
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var speculative: UInt64
    public var compressed: UInt64

    // Derived taxonomy categories (bytes). See docs/memory-taxonomy.md.
    public var appMemory: UInt64
    public var cachedFiles: UInt64

    public var swapTotal: UInt64
    public var swapUsed: UInt64

    public var pressureLevel: PressureLevel
    /// Continuous 0...100 index for smooth charting. See docs/pressure-index.md.
    public var pressurePercent: Double

    // Cumulative kernel counters.
    public var pageIns: UInt64
    public var pageOuts: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64

    // Deltas since the previous tick (0 on the first tick), stored alongside the
    // cumulative counters so reads never have to recompute them.
    public var pageInsDelta: UInt64
    public var pageOutsDelta: UInt64
    public var compressionsDelta: UInt64
    public var decompressionsDelta: UInt64

    /// System-wide CPU load as a fraction (0...1 per core averaged), best-effort.
    public var cpuLoad: Double
    /// The kernel's load averages (run-queue length over 1, 5 and 15 minutes,
    /// the figures `uptime` reports), persisted so the load card has history.
    public var loadAverage1: Double
    public var loadAverage5: Double
    public var loadAverage15: Double

    // Battery state, persisted so the dashboard battery timelines work over the
    // long ranges. Only the chartable scalars live here; the richer live-only
    // detail (adapter, serial, voltage, time-remaining) rides on `BatterySample`
    // in the live snapshot. `batteryPresent` distinguishes a genuine reading
    // from a Mac with no battery (a desktop), so history never shows a fake 0%.
    public var batteryPresent: Bool
    /// Charge level, 0...100. The user-facing figure (IOKit current/max).
    public var batteryCharge: Double
    /// Instantaneous power flow in watts (always >= 0; see `batteryIsCharging`).
    public var batteryPowerWatts: Double
    /// Whole-machine power draw in watts (SMC `SystemLoad`), reported on laptops
    /// and desktops alike — the source for the energy menubar's power-draw chart.
    public var batterySystemPowerWatts: Double
    public var batteryIsCharging: Bool
    /// Maximum capacity as a fraction of design capacity, 0...100.
    public var batteryHealthPercent: Double
    public var batteryCycleCount: Int
    /// Battery temperature in degrees Celsius.
    public var batteryTemperatureCelsius: Double

    // System-wide network throughput for this tick, in bytes per second, summed
    // across the physical interfaces. Instantaneous rates (like `cpuLoad`), not
    // cumulative counters: the sampler differences the interfaces' cumulative
    // byte counters between ticks and stores the per-second result here, so the
    // menubar, dashboard, and insights all read a rate without recomputing it.
    /// Download (received) throughput, bytes/second.
    public var networkInBytesPerSec: Double
    /// Upload (sent) throughput, bytes/second.
    public var networkOutBytesPerSec: Double

    /// Physical block-device throughput summed across real internal and external
    /// disks. Virtual disk images are excluded by `DiskReader`.
    public var diskReadBytesPerSec: Double
    public var diskWriteBytesPerSec: Double
    public var diskReadOperationsPerSec: Double
    public var diskWriteOperationsPerSec: Double

    // Disk detail added alongside the throughput scalars. All optional (and
    // decoded as such) so samples recorded before these fields existed keep
    // decoding, and "no IO this tick" stays distinct from a measured zero.
    /// Ops-weighted average device service time this tick, milliseconds.
    public var diskReadLatencyMs: Double?
    public var diskWriteLatencyMs: Double?
    /// Busiest device's busy share of the tick, 0 to 100.
    public var diskUtilizationPercent: Double?
    /// Root filesystem capacity, refreshed at most once a minute by
    /// `BootVolumeReader`. On APFS the free figure is the container's shared
    /// free pool, the number that matters when the disk fills up.
    public var bootVolumeTotalBytes: UInt64?
    public var bootVolumeFreeBytes: UInt64?
    // GPU device figures, present only on ticks that read the GPU (while a
    // GPU surface is showing or history is being recorded). Optional so
    // older samples decode and "not sampled" stays distinct from 0.
    public var gpuUtilization: Double?
    public var gpuPowerWatts: Double?
    public var anePowerWatts: Double?
    // Thermal figures (v14), read from the SMC on the same ticks as the GPU
    // figures. Optional for the same reason: "not sampled" stays distinct
    // from 0. cpuDieC and gpuDieC are the hottest sensor of their domain;
    // fanRPM is the fastest fan.
    public var cpuDieC: Double?
    public var gpuDieC: Double?
    public var ssdTemperatureC: Double?
    public var fanRPM: Double?
    // Per-domain hottest readings (v15), so the Hardware tab's sensor charts
    // read their trend back from the log instead of starting empty on every
    // launch. The die, GPU, SSD, battery and fan figures above already cover
    // their own domains; these are the rest of the sensor groups.
    public var cpuPCoreDieC: Double?
    public var cpuECoreDieC: Double?
    public var airflowC: Double?
    public var skinC: Double?
    public var wirelessC: Double?
    public var voltageRailC: Double?
    public var otherSensorC: Double?
    /// macOS's own thermal pressure verdict, read every tick (public API, no
    /// SMC involved), so throttling history survives even without sensors.
    public var thermalPressure: ThermalPressureState?

    public init(
        timestamp: Date,
        totalRAM: UInt64,
        free: UInt64,
        active: UInt64,
        inactive: UInt64,
        wired: UInt64,
        speculative: UInt64,
        compressed: UInt64,
        appMemory: UInt64,
        cachedFiles: UInt64,
        swapTotal: UInt64,
        swapUsed: UInt64,
        pressureLevel: PressureLevel,
        pressurePercent: Double,
        pageIns: UInt64,
        pageOuts: UInt64,
        compressions: UInt64,
        decompressions: UInt64,
        pageInsDelta: UInt64 = 0,
        pageOutsDelta: UInt64 = 0,
        compressionsDelta: UInt64 = 0,
        decompressionsDelta: UInt64 = 0,
        cpuLoad: Double = 0,
        loadAverage1: Double = 0,
        loadAverage5: Double = 0,
        loadAverage15: Double = 0,
        batteryPresent: Bool = false,
        batteryCharge: Double = 0,
        batteryPowerWatts: Double = 0,
        batterySystemPowerWatts: Double = 0,
        batteryIsCharging: Bool = false,
        batteryHealthPercent: Double = 0,
        batteryCycleCount: Int = 0,
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
        bootVolumeTotalBytes: UInt64? = nil,
        bootVolumeFreeBytes: UInt64? = nil,
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
        self.timestamp = timestamp
        self.totalRAM = totalRAM
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.speculative = speculative
        self.compressed = compressed
        self.appMemory = appMemory
        self.cachedFiles = cachedFiles
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
        self.pressureLevel = pressureLevel
        self.pressurePercent = pressurePercent
        self.pageIns = pageIns
        self.pageOuts = pageOuts
        self.compressions = compressions
        self.decompressions = decompressions
        self.pageInsDelta = pageInsDelta
        self.pageOutsDelta = pageOutsDelta
        self.compressionsDelta = compressionsDelta
        self.decompressionsDelta = decompressionsDelta
        self.cpuLoad = cpuLoad
        self.loadAverage1 = loadAverage1
        self.loadAverage5 = loadAverage5
        self.loadAverage15 = loadAverage15
        self.batteryPresent = batteryPresent
        self.batteryCharge = batteryCharge
        self.batteryPowerWatts = batteryPowerWatts
        self.batterySystemPowerWatts = batterySystemPowerWatts
        self.batteryIsCharging = batteryIsCharging
        self.batteryHealthPercent = batteryHealthPercent
        self.batteryCycleCount = batteryCycleCount
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
        self.bootVolumeTotalBytes = bootVolumeTotalBytes
        self.bootVolumeFreeBytes = bootVolumeFreeBytes
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
