import Foundation

/// One battery measurement captured on a sampling tick. Carries the live state
/// (charge, charging, time estimates), the instantaneous electrical figures
/// (power, voltage, amperage, temperature), the hardware health figures (cycle
/// count, design/max capacity, condition), and the live-only context (serial,
/// power adapter, Low Power Mode).
///
/// Only the chartable scalars are persisted (via `SystemSample`); the rest is
/// read live and shown from the latest snapshot. `nil` from `BatteryReader.read`
/// means this Mac has no internal battery (a desktop) — callers must treat that
/// as "no battery" rather than fabricating zeros.
public struct BatterySample: Sendable, Codable, Equatable {
    public var timestamp: Date

    /// Whether an internal battery is present and was readable.
    public var isPresent: Bool

    // MARK: Live state
    /// Charge level as a percentage, 0...100 (IOKit current/max capacity).
    public var chargePercent: Double
    public var isCharging: Bool
    /// True when running on the wall adapter (AC), false when on battery.
    public var isOnAC: Bool
    public var isLowPowerMode: Bool
    /// Minutes until empty, or nil when on AC / still being calculated.
    public var timeToEmptyMinutes: Int?
    /// Minutes until fully charged, or nil when discharging / still calculating.
    public var timeToFullMinutes: Int?
    public var runtimeEstimate: BatteryRuntimeEstimate?

    // MARK: Instantaneous electrical
    /// Power flow magnitude in watts (always >= 0; `isCharging` gives direction).
    public var powerWatts: Double
    /// The Mac's total system power draw in watts, measured by the SMC
    /// (`AppleSmartBattery` → `PowerTelemetryData.SystemLoad`). Unlike `powerWatts`
    /// (the battery's charge/discharge), this is the whole-machine consumption and
    /// is reported on AC and on battery, on laptops AND desktops — desktops expose
    /// the `AppleSmartBattery` entry for telemetry even with no cell installed. 0
    /// when the telemetry is unavailable.
    public var systemPowerWatts: Double
    /// Instantaneous current in milliamps, signed (negative = discharging).
    public var amperageMilliAmps: Int
    public var voltageMilliVolts: Int
    public var temperatureCelsius: Double?

    // MARK: Health / hardware
    public var cycleCount: Int?
    public var designCapacitymAh: Int?
    /// Current full-charge capacity in mAh (NominalChargeCapacity, falling back to
    /// AppleRawMaxCapacity / Intel's mAh MaxCapacity).
    public var maxCapacitymAh: Int?
    /// Current charge in mAh (AppleRawCurrentCapacity / Intel's mAh CurrentCapacity).
    public var currentCapacitymAh: Int?
    /// Max capacity as a fraction of design capacity, 0...100. nil if unknown.
    public var healthPercent: Double?
    /// PermanentFailureStatus: 0 == normal, non-zero == service recommended.
    public var conditionRaw: Int

    // MARK: Live-only detail (never persisted)
    public var serialNumber: String?
    public var adapterWatts: Int?
    public var adapterName: String?
    /// The cell's manufacture date, decoded from `AppleSmartBattery`. nil when the
    /// firmware doesn't expose it (some Apple-silicon Macs omit it).
    public var manufactureDate: Date?
    /// The battery pack assembler, e.g. "Huizhou Desay Battery Company", resolved
    /// from the serial's vendor prefix. nil when the prefix isn't a known vendor.
    public var manufacturer: String?
    /// Per-cell voltages in millivolts, one entry per series cell (a 3-cell pack
    /// reports three). nil when the firmware doesn't break voltage out per cell.
    public var cellVoltagesMilliVolts: [Int]?
    /// The connected power adapter's output voltage in millivolts (e.g. 20000 = 20 V),
    /// or nil when on battery / not reported.
    public var adapterVoltageMilliVolts: Int?
    /// The connected power adapter's output current in milliamps (e.g. 4800 = 4.8 A),
    /// or nil when on battery / not reported.
    public var adapterAmperageMilliAmps: Int?
    /// The charge controller's present charging current in milliamps — the live
    /// rate the cell is being charged at (0 when full / not charging), or nil.
    public var chargingCurrentMilliAmps: Int?
    /// The battery's gas-gauge controller chip, e.g. "bq40z651". nil when absent.
    public var gasGaugeChip: String?

    public init(
        timestamp: Date,
        isPresent: Bool = false,
        chargePercent: Double = 0,
        isCharging: Bool = false,
        isOnAC: Bool = false,
        isLowPowerMode: Bool = false,
        timeToEmptyMinutes: Int? = nil,
        timeToFullMinutes: Int? = nil,
        runtimeEstimate: BatteryRuntimeEstimate? = nil,
        powerWatts: Double = 0,
        systemPowerWatts: Double = 0,
        amperageMilliAmps: Int = 0,
        voltageMilliVolts: Int = 0,
        temperatureCelsius: Double? = nil,
        cycleCount: Int? = nil,
        designCapacitymAh: Int? = nil,
        maxCapacitymAh: Int? = nil,
        currentCapacitymAh: Int? = nil,
        healthPercent: Double? = nil,
        conditionRaw: Int = 0,
        serialNumber: String? = nil,
        adapterWatts: Int? = nil,
        adapterName: String? = nil,
        manufactureDate: Date? = nil,
        manufacturer: String? = nil,
        cellVoltagesMilliVolts: [Int]? = nil,
        adapterVoltageMilliVolts: Int? = nil,
        adapterAmperageMilliAmps: Int? = nil,
        chargingCurrentMilliAmps: Int? = nil,
        gasGaugeChip: String? = nil
    ) {
        self.timestamp = timestamp
        self.isPresent = isPresent
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isOnAC = isOnAC
        self.isLowPowerMode = isLowPowerMode
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
        self.runtimeEstimate = runtimeEstimate
        self.powerWatts = powerWatts
        self.systemPowerWatts = systemPowerWatts
        self.amperageMilliAmps = amperageMilliAmps
        self.voltageMilliVolts = voltageMilliVolts
        self.temperatureCelsius = temperatureCelsius
        self.cycleCount = cycleCount
        self.designCapacitymAh = designCapacitymAh
        self.maxCapacitymAh = maxCapacitymAh
        self.currentCapacitymAh = currentCapacitymAh
        self.healthPercent = healthPercent
        self.conditionRaw = conditionRaw
        self.serialNumber = serialNumber
        self.adapterWatts = adapterWatts
        self.adapterName = adapterName
        self.manufactureDate = manufactureDate
        self.manufacturer = manufacturer
        self.cellVoltagesMilliVolts = cellVoltagesMilliVolts
        self.adapterVoltageMilliVolts = adapterVoltageMilliVolts
        self.adapterAmperageMilliAmps = adapterAmperageMilliAmps
        self.chargingCurrentMilliAmps = chargingCurrentMilliAmps
        self.gasGaugeChip = gasGaugeChip
    }

    /// Whether the battery is in a healthy condition (no permanent failure).
    public var isHealthyCondition: Bool { conditionRaw == 0 }

    /// Battery voltage in volts.
    public var voltage: Double { Double(voltageMilliVolts) / 1000 }
}
