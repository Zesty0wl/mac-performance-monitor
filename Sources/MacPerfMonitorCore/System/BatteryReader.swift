import Foundation
import IOKit
import IOKit.ps

/// Reads the Mac's battery state from IOKit. Three sources are merged into one
/// `BatterySample`:
///   1. The power-source snapshot (`IOKit.ps`) for the user-facing charge %,
///      charging/AC state, and time-remaining estimates.
///   2. The `AppleSmartBattery` IORegistry entry for the detailed hardware
///      figures (cycle count, design/raw capacity, temperature, voltage,
///      amperage, condition, serial).
///   3. The external power-adapter details, plus `ProcessInfo`'s Low Power Mode.
///
/// Every key is treated as optional and degrades field by field, so a firmware
/// that omits one figure yields a `nil` for that field rather than a failed
/// read. On a Mac with no internal battery (a desktop) `read()` returns `nil`.
///
/// Cheap enough (a couple of IORegistry lookups) to run on the fast system tick,
/// like `CPUReader`/`SystemMemoryReader`.
public struct BatteryReader: Sendable {
    public init() {}

    /// A full battery read, or `nil` on a Mac with no internal battery.
    public func read(now: Date = Date()) -> BatterySample? {
        // The AppleSmartBattery entry is the authority on presence: no entry
        // means no internal battery (desktop). We still read the power-source
        // snapshot for the charge % and time estimates.
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        let smart: [String: Any]?
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
                let dict = props?.takeRetainedValue() as? [String: Any]
            {
                smart = dict
            } else {
                smart = nil
            }
        } else {
            smart = nil
        }

        let ps = Self.internalBatteryDescription()

        // The AppleSmartBattery service existing is NOT enough: the Apple-silicon
        // Mac mini (and other desktops) expose that IORegistry entry too — it
        // shares the SMC power-management driver with laptops — but with
        // "BatteryInstalled" = No, zero capacity, and no power source. So require a
        // genuinely installed cell, or a real internal-battery power source.
        let batteryInstalled: Bool
        if let smart {
            if let installed = smart["BatteryInstalled"] as? Bool {
                batteryInstalled = installed
            } else {
                // Firmware that omits the flag: fall back to a non-zero capacity.
                // A real cell always reports a design capacity, so that's the most
                // reliable presence signal; the others are belt-and-braces.
                let capacity =
                    Self.intValue(smart, "DesignCapacity")
                    ?? Self.intValue(smart, "NominalChargeCapacity")
                    ?? Self.intValue(smart, "AppleRawMaxCapacity") ?? 0
                batteryInstalled = capacity > 0
            }
        } else {
            batteryInstalled = false
        }

        // The Mac's whole-machine power draw (watts), measured by the SMC. Present
        // on desktops too, which is what makes real energy figures possible there.
        let systemPowerWatts = Self.systemPowerWatts(from: smart)

        // No installed battery and no internal-battery power source → this Mac is a
        // desktop. If the AppleSmartBattery entry is still present (it is on an
        // Apple-silicon Mac mini), return a battery-absent sample carrying the
        // system power telemetry so the desktop energy view shows real watts. With
        // no entry at all there's nothing to report.
        if !batteryInstalled && ps == nil {
            guard smart != nil else { return nil }
            var desktop = BatterySample(timestamp: now, isPresent: false, isOnAC: true)
            desktop.systemPowerWatts = systemPowerWatts
            if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue()
                as? [String: Any]
            {
                desktop.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
                desktop.adapterName = adapter["Name"] as? String
            }
            desktop.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            return desktop
        }

        var sample = BatterySample(timestamp: now, isPresent: true)
        sample.systemPowerWatts = systemPowerWatts

        // MARK: Power-source snapshot (charge %, charging, AC, time estimates)
        if let ps {
            if let cur = ps[kIOPSCurrentCapacityKey] as? Double,
                let max = ps[kIOPSMaxCapacityKey] as? Double, max > 0
            {
                sample.chargePercent = min(100, max == 100 ? cur : cur / max * 100)
            }
            sample.isCharging = (ps[kIOPSIsChargingKey] as? Bool) ?? false
            if let state = ps[kIOPSPowerSourceStateKey] as? String {
                sample.isOnAC = (state == kIOPSACPowerValue)
            }
            if let present = ps[kIOPSIsPresentKey] as? Bool {
                sample.isPresent = present
            }
            // Time estimates report -1 while the system is still calculating.
            if let toEmpty = ps[kIOPSTimeToEmptyKey] as? Int, toEmpty >= 0, !sample.isOnAC {
                sample.timeToEmptyMinutes = toEmpty
            }
            if let toFull = ps[kIOPSTimeToFullChargeKey] as? Int, toFull >= 0, sample.isCharging {
                sample.timeToFullMinutes = toFull
            }
        }

        // MARK: AppleSmartBattery hardware detail
        if let smart {
            let capacity = Self.capacityReadout(from: smart)
            sample.cycleCount = capacity.cycleCount
            sample.designCapacitymAh = capacity.designCapacitymAh
            sample.maxCapacitymAh = capacity.maxCapacitymAh
            sample.currentCapacitymAh = capacity.currentCapacitymAh
            sample.healthPercent = capacity.healthPercent

            sample.conditionRaw = (smart["PermanentFailureStatus"] as? Int) ?? 0
            sample.serialNumber = smart["Serial"] as? String
            sample.manufactureDate = Self.manufactureDate(from: smart, now: now)
            sample.manufacturer = (smart["Serial"] as? String)
                .flatMap { Self.manufacturer(fromSerial: $0) }

            let extra = Self.electricalDetail(from: smart)
            sample.cellVoltagesMilliVolts = extra.cellVoltagesMilliVolts
            sample.adapterVoltageMilliVolts = extra.adapterVoltageMilliVolts
            sample.adapterAmperageMilliAmps = extra.adapterAmperageMilliAmps
            sample.chargingCurrentMilliAmps = extra.chargingCurrentMilliAmps
            sample.gasGaugeChip = extra.gasGaugeChip

            if let voltage = smart["Voltage"] as? Int { sample.voltageMilliVolts = voltage }
            // Amperage can arrive as a sign-extended 64-bit value or a raw 32-bit
            // one; normalise through Int32 so the sign survives either way.
            if let ampRaw = (smart["InstantAmperage"] as? Int) ?? (smart["Amperage"] as? Int) {
                sample.amperageMilliAmps = Int(Int32(truncatingIfNeeded: ampRaw))
            }
            if let tempRaw = smart["Temperature"] as? Int {
                sample.temperatureCelsius = Self.temperatureCelsius(fromCenti: tempRaw)
            }
        }

        // Power magnitude in watts: |mA| * mV / 1e6. Charging sign comes from the
        // power-source snapshot above; amperage sign is a secondary fallback.
        if sample.voltageMilliVolts > 0, sample.amperageMilliAmps != 0 {
            sample.powerWatts =
                Double(abs(sample.amperageMilliAmps)) * Double(sample.voltageMilliVolts) / 1_000_000
            if ps?[kIOPSIsChargingKey] == nil {
                sample.isCharging = sample.amperageMilliAmps > 0
            }
        }

        // MARK: Power adapter + Low Power Mode
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue()
            as? [String: Any]
        {
            sample.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
            sample.adapterName = adapter["Name"] as? String
        }
        sample.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        return sample
    }

    /// The wear figures derived from an `AppleSmartBattery` property dictionary.
    struct CapacityReadout: Equatable {
        var cycleCount: Int?
        var designCapacitymAh: Int?
        var maxCapacitymAh: Int?
        var currentCapacitymAh: Int?
        var healthPercent: Double?
    }

    /// Derive cycle count, capacities and health from an `AppleSmartBattery`
    /// dictionary. Pure (no IOKit) so it can be unit-tested against the Apple-
    /// silicon firmware layouts seen across the fleet:
    ///   • Figures at the top level: `MaxCapacity` is a normalised 0–100 percent
    ///     (never a mAh), the real mAh under `NominalChargeCapacity`/`AppleRaw*`.
    ///   • Some Macs expose the same figures only inside the nested `BatteryData`.
    static func capacityReadout(from smart: [String: Any]) -> CapacityReadout {
        var out = CapacityReadout()
        out.cycleCount = intValue(smart, "CycleCount")

        // Design capacity (mAh) — the wear denominator. Without it there's no
        // health figure to show, so reading it from `BatteryData` when it's absent
        // up top is the crux of getting health on the machines that hid it there.
        let designCapacity = intValue(smart, "DesignCapacity")
        out.designCapacitymAh = designCapacity

        // Full-charge capacity (mAh) — the wear numerator. coconutBattery's health
        // is AppleRawMaxCapacity / DesignCapacity, so this prefers the raw key to
        // match it. `AppleRawMaxCapacity` is the gas-gauge's own measured FCC;
        // `NominalChargeCapacity` is the smoothed figure macOS's "Maximum Capacity"
        // (System Settings) uses, which runs a couple of percent higher — a fallback
        // for firmware that omits the raw key. The plain `MaxCapacity` is a
        // normalised 0–100 percent on Apple silicon, never a mAh, so it's not read.
        out.maxCapacitymAh =
            intValue(smart, "AppleRawMaxCapacity")
            ?? intValue(smart, "NominalChargeCapacity")

        // Current charge (mAh) — the raw gas-gauge figure.
        out.currentCapacitymAh = intValue(smart, "AppleRawCurrentCapacity")

        if let design = designCapacity, let full = out.maxCapacitymAh, design > 0 {
            out.healthPercent = min(100, Double(full) / Double(design) * 100)
        }
        return out
    }

    /// An integer property from the `AppleSmartBattery` dictionary, read from the
    /// top level first and then from the nested `BatteryData` sub-dictionary. The
    /// detailed hardware figures (capacities, cycle count) sit at the top level on
    /// most firmware but only under `BatteryData` on a fair number of Macs —
    /// checking both is what makes the health read work across the fleet rather
    /// than only where the top-level keys happen to be exposed.
    private static func intValue(_ smart: [String: Any], _ key: String) -> Int? {
        if let v = smart[key] as? Int { return v }
        if let data = smart["BatteryData"] as? [String: Any], let v = data[key] as? Int {
            return v
        }
        return nil
    }

    /// The cell's manufacture date from `AppleSmartBattery`. Two Apple-silicon
    /// firmware schemes are seen in the wild, each validated against a sane window
    /// so a misread can't surface a bogus date:
    ///   • Older 17-char serials: the date is encoded in the *battery serial* (the
    ///     `ManufactureDate` word holds junk on Apple silicon). See
    ///     `manufactureDate(fromSerial:now:)`.
    ///   • Modern serials that no longer encode a date: coconutBattery's "Battery
    ///     Age" path — `now` minus the gas-gauge's lifetime age counter in
    ///     `BatteryData/LifetimeData/Raw`. See `manufactureDate(fromLifetimeRaw:now:)`.
    /// Returns nil when neither yields a plausible date — some firmware omits the
    /// figure entirely, and a nil cleanly hides the row rather than inventing one.
    private static func manufactureDate(from smart: [String: Any], now: Date) -> Date? {
        // Apple silicon, older serials: decode the date out of the battery serial.
        if let serial = (smart["Serial"] as? String)
            ?? ((smart["BatteryData"] as? [String: Any])?["Serial"] as? String),
            let date = manufactureDate(fromSerial: serial, now: now)
        {
            return date
        }

        // Apple silicon, modern serials that no longer encode a date (e.g. this
        // Mac's 18-char "F5DH4A000U100000EB"): coconutBattery's age path. The
        // gas-gauge's BatteryData → LifetimeData → Raw blob opens with a big-endian
        // uint32 counting the battery's lifetime age in seconds, and `now − age` is
        // the cell's first-use, shown as the manufacture date. Confirmed to
        // reproduce coconutBattery exactly on an M3 Pro (Raw[0] 0x03E739E0 →
        // 2024-05-25).
        if let batteryData = smart["BatteryData"] as? [String: Any],
            let lifetime = batteryData["LifetimeData"] as? [String: Any],
            let raw = lifetime["Raw"] as? Data,
            let date = manufactureDate(fromLifetimeRaw: raw, now: now)
        {
            return date
        }
        return nil
    }

    /// Decode the manufacture date from a 17-character Apple-silicon battery
    /// serial, the scheme coconutBattery reads. The serial packs a single year
    /// digit at index 3 and a two-digit ISO week-of-year at indices 4–5
    /// (e.g. "F8Y2475H3CYQ1LTAP" → digit 2, week 47 → ISO week 47 of 2022).
    ///
    /// The lone year digit is ambiguous by decade, so it's resolved to the most
    /// recent year ending in that digit whose week isn't in the future: a battery
    /// can't be made later than today, and this serial format is Apple-silicon-era
    /// (2020+). The date returned is that ISO week's Thursday — the canonical day
    /// the week's year is defined by, and the safest point to read month/year from
    /// (no boundary slip). Only serials matching this exact 17-character shape are
    /// decoded; anything else returns nil rather than a guess.
    static func manufactureDate(fromSerial serial: String, now: Date) -> Date? {
        let chars = Array(serial)
        guard chars.count == 17 else { return nil }

        let yearChar = chars[3]
        guard yearChar.isASCII, let yearDigit = yearChar.wholeNumberValue else { return nil }
        let weekChars = chars[4...5]
        guard weekChars.allSatisfy({ $0.isASCII && $0.isNumber }),
            let week = Int(String(weekChars)), (1...53).contains(week)
        else { return nil }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone

        func thursday(ofWeek w: Int, year y: Int) -> Date? {
            // weekday 5 == Thursday in Foundation's 1=Sun…7=Sat numbering.
            calendar.date(from: DateComponents(weekday: 5, weekOfYear: w, yearForWeekOfYear: y))
        }

        // Resolve the year digit to the latest non-future year ending in it.
        let currentYear = calendar.component(.year, from: now)
        var year = (currentYear / 10) * 10 + yearDigit
        if year > currentYear { year -= 10 }

        let ceiling = now.addingTimeInterval(86_400)
        guard var date = thursday(ofWeek: week, year: year) else { return nil }
        // If that week hasn't happened yet this year, the real year is a decade back.
        if date > ceiling {
            year -= 10
            guard let earlier = thursday(ofWeek: week, year: year) else { return nil }
            date = earlier
        }
        guard year >= 2010, date <= ceiling else { return nil }
        return date
    }

    /// The battery's vendor prefix → pack-assembler name, the way coconutBattery
    /// resolves the manufacturer. Apple battery serials open with a two-character
    /// code identifying the pack assembler; coconut carries a private lookup table
    /// (the cell chemistry supplier in `ManufacturerData`, e.g. "ATL"/Amperex, is a
    /// separate thing). The lookup is the uppercased first two characters; an
    /// unknown prefix returns nil so the row hides rather than guessing.
    static let manufacturerByPrefix: [String: String] = {
        let groups: [(String, [String])] = [
            ("Amperex Technology Ltd.", ["AC", "AE", "AF", "AX", "AZ", "YF"]),
            ("Huizhou Desay Battery Company", ["43", "F5", "FD", "FU", "LD", "LY", "RE", "ZP"]),
            ("Sony", ["FX", "RD", "YG", "YV", "YW"]),
            ("Samsung", ["LZ", "SB", "ST"]),
            ("Huapu Technology", ["DV", "FG", "HH", "HT"]),
            ("Simplo Technology", ["D8", "D9", "W0"]),
            ("Sunwoda", ["64", "77", "79", "F8", "LM", "YS"]),
            ("LG Chem Ltd.", ["LN", "YH"]),
            ("Dynapack Electronics", ["9G", "C0", "DP"]),
            ("TianJin Lishen Battery", ["TP"]),
            ("Dongguan NVT Technology", ["FQ"]),
        ]
        var map: [String: String] = [:]
        for (vendor, codes) in groups {
            for code in codes { map[code] = vendor }
        }
        return map
    }()

    /// Resolve a battery serial to its pack assembler via the vendor-prefix table.
    static func manufacturer(fromSerial serial: String) -> String? {
        guard serial.count >= 2 else { return nil }
        let prefix = String(serial.prefix(2)).uppercased()
        return manufacturerByPrefix[prefix]
    }

    /// Decode the manufacture date the way coconutBattery does for modern Apple-
    /// silicon batteries whose serial no longer carries a production date. The gas-
    /// gauge's `BatteryData → LifetimeData → Raw` blob opens with a big-endian
    /// uint32 counting the battery's total age in seconds since first power-on, and
    /// `now − age` is the cell's first-use — which coconutBattery presents as the
    /// manufacture date. The counter advances with wall-clock time (the gauge is
    /// powered whenever a cell is installed), so `now − age` is a stable estimate
    /// rather than a value that drifts on each read.
    ///
    /// Validated against a sane window — a positive age under 25 years that lands
    /// on a date no earlier than the Apple-silicon era and not in the future — so a
    /// zeroed or garbage blob hides the row rather than inventing a date.
    static func manufactureDate(fromLifetimeRaw raw: Data, now: Date) -> Date? {
        guard raw.count >= 4 else { return nil }
        // Big-endian uint32 at offset 0 = the battery's lifetime age in seconds.
        let bytes = Array(raw.prefix(4))
        let ageSeconds =
            UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        guard ageSeconds > 0, ageSeconds < 25 * 365 * 86_400 else { return nil }

        let date = now.addingTimeInterval(-Double(ageSeconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let floor = calendar.date(from: DateComponents(year: 2015, month: 1, day: 1)),
            date >= floor, date <= now
        else { return nil }
        return date
    }

    /// The extra electrical figures coconutBattery-style apps surface, pulled from
    /// the `AppleSmartBattery` dictionary. All optional — each degrades to nil when
    /// its key is absent (e.g. the adapter figures while running on battery), so a
    /// UI row hides rather than showing a fabricated zero.
    struct ElectricalDetail: Equatable {
        var cellVoltagesMilliVolts: [Int]?
        var adapterVoltageMilliVolts: Int?
        var adapterAmperageMilliAmps: Int?
        var chargingCurrentMilliAmps: Int?
        var gasGaugeChip: String?
    }

    /// Extract the per-cell voltages, power-adapter output spec, live charging
    /// current and gas-gauge chip from an `AppleSmartBattery` dictionary. Pure (no
    /// IOKit) so it can be unit-tested against the on-AC and on-battery layouts.
    static func electricalDetail(from smart: [String: Any]) -> ElectricalDetail {
        var out = ElectricalDetail()

        // Per-cell voltages (mV) — `BatteryData.CellVoltage` is one entry per series
        // cell. Require every cell to read a positive value so a partial/garbage
        // array is dropped rather than shown.
        if let battery = smart["BatteryData"] as? [String: Any],
            let rawCells = battery["CellVoltage"] as? [Any]
        {
            let cells = rawCells.compactMap { $0 as? Int }
            if !cells.isEmpty, cells.count == rawCells.count, cells.allSatisfy({ $0 > 0 }) {
                out.cellVoltagesMilliVolts = cells
            }
        }

        // Power adapter output spec — only populated (and only > 0) while connected.
        if let adapter = smart["AdapterDetails"] as? [String: Any] {
            if let v = adapter["AdapterVoltage"] as? Int, v > 0 { out.adapterVoltageMilliVolts = v }
            if let a = adapter["Current"] as? Int, a > 0 { out.adapterAmperageMilliAmps = a }
        }

        // The charge controller's present charging current (mA). 0 when full / not
        // charging is meaningful, so keep it; reject only a missing/negative read.
        if let charger = smart["ChargerData"] as? [String: Any],
            let a = charger["ChargingCurrent"] as? Int, a >= 0
        {
            out.chargingCurrentMilliAmps = a
        }

        // The gas-gauge controller chip, e.g. "bq40z651".
        if let name = smart["DeviceName"] as? String, !name.isEmpty {
            out.gasGaugeChip = name
        }
        return out
    }

    /// Decode the AppleSmartBattery `Temperature` key (centi-degrees) to Celsius.
    /// Most controllers report centi-Celsius; a few report centi-Kelvin, which the
    /// detector spots from a value too hot to be a real Celsius reading. The
    /// threshold is 200: a battery cell much past 120 degrees is in thermal
    /// runaway, while a Kelvin reading below 200 would mean a battery below -73
    /// degrees, outside any operating spec, so 200 separates the two units with
    /// margin on each side. The previous 100 threshold sat right at the edge of
    /// plausible hot-Celsius and converted a genuine, if extreme, reading into a
    /// sub-absolute-zero value. Pure (no IOKit) so it can be unit-tested.
    static func temperatureCelsius(fromCenti raw: Int) -> Double {
        let scaled = Double(raw) / 100
        return scaled > 200 ? scaled - 273.15 : scaled
    }

    /// The Mac's instantaneous total system power draw in watts, from the SMC's
    /// `PowerTelemetryData.SystemLoad` (reported in milliwatts). This is the whole
    /// machine's consumption — reported on AC and on battery, on laptops and
    /// desktops alike. Returns 0 when the telemetry is unavailable.
    private static func systemPowerWatts(from smart: [String: Any]?) -> Double {
        guard let telemetry = smart?["PowerTelemetryData"] as? [String: Any] else { return 0 }
        let loadMilliWatts: Double
        if let i = telemetry["SystemLoad"] as? Int {
            loadMilliWatts = Double(i)
        } else if let d = telemetry["SystemLoad"] as? Double {
            loadMilliWatts = d
        } else {
            return 0
        }
        guard loadMilliWatts > 0 else { return 0 }
        return loadMilliWatts / 1000
    }

    /// The description dictionary of the *internal battery* power source, or nil
    /// if this Mac has none. Only a source whose type is `kIOPSInternalBatteryType`
    /// counts — a UPS or any other power source is deliberately ignored, so a
    /// desktop (Mac mini, Studio, iMac) is correctly seen as having no battery
    /// rather than fabricating a 0% one from an unrelated source.
    private static func internalBatteryDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard
                let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { continue }
            if let type = desc[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType {
                return desc
            }
        }
        return nil
    }
}
