import MacPerfMonitorCore
import SwiftUI

/// A glanceable band for battery charge, mirroring `CPULevel`/`PressureLevel`.
/// Green for a comfortable charge, orange when it is getting low, red when it is
/// nearly empty — the same calm three-step language the rest of the app uses.
enum BatteryLevel: Int, CaseIterable {
    case critical
    case low
    case good

    /// Classify a charge percentage (0...100).
    init(percent: Double) {
        switch percent {
        case ..<20: self = .critical
        case ..<40: self = .low
        default: self = .good
        }
    }

    var color: Color {
        switch self {
        case .critical: return .red
        case .low: return .orange
        case .good: return .green
        }
    }

    var label: String {
        switch self {
        case .critical: return "Low"
        case .low: return "Getting low"
        case .good: return "Good"
        }
    }

    /// A battery SF Symbol roughly matching the charge level.
    var symbolName: String {
        switch self {
        case .critical: return "battery.25"
        case .low: return "battery.50"
        case .good: return "battery.100"
        }
    }
}

/// The energy-flow diagram's colour vocabulary, kept beside `BatteryLevel` so
/// the whole tab shares one language: green is the battery (charging or
/// discharging), blue is the wall adapter, and orange is the apps' draw. Three
/// well-separated hues so the conduits stay legible against each other.
enum BatteryStyle {
    /// The battery, as a source (discharging) or being filled (charging).
    static let battery = Color.green
    /// The AC adapter / wall power.
    static let charger = Color.blue
    /// An app drawing power.
    static let consumer = Color.orange
}

/// Formatting helpers for the battery read-outs, kept in one place so every
/// panel renders watts, capacities, temperature, and time-remaining the same way.
enum BatteryFormat {
    /// Power in watts, e.g. "12.4 W".
    static func watts(_ w: Double) -> String {
        String(format: "%.1f W", w)
    }

    /// A percentage, rounded, e.g. "87%".
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// A capacity in milliamp-hours, e.g. "4,821 mAh".
    static func mAh(_ value: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
        return "\(n) mAh"
    }

    /// Temperature in degrees Celsius, e.g. "31.2°C".
    static func celsius(_ c: Double) -> String {
        TemperatureFormat.string(c, fractionDigits: 1)
    }

    /// Voltage in volts, e.g. "11.86 V".
    static func volts(_ v: Double) -> String {
        String(format: "%.2f V", v)
    }

    /// Voltage in volts from a millivolt reading, e.g. 20000 → "20.00 V".
    static func volts(milliVolts: Int) -> String {
        volts(Double(milliVolts) / 1000)
    }

    /// Unsigned current in amps from a milliamp reading, e.g. 4800 → "4.80 A".
    static func amps(milliAmps: Int) -> String {
        String(format: "%.2f A", Double(milliAmps) / 1000)
    }

    /// Per-cell voltages, each in volts, e.g. [4333, 4334] → "4.33 · 4.33 V".
    static func cellVoltages(_ milliVolts: [Int]) -> String {
        milliVolts.map { String(format: "%.2f", Double($0) / 1000) }
            .joined(separator: " · ") + " V"
    }

    /// Signed current in milliamps with a direction sign, e.g. "−1,820 mA".
    static func milliAmps(_ mA: Int) -> String {
        let n = NumberFormatter.localizedString(
            from: NSNumber(value: abs(mA)), number: .decimal)
        let sign = mA < 0 ? "\u{2212}" : (mA > 0 ? "+" : "")
        return "\(sign)\(n) mA"
    }

    /// A "h:mm" duration from a minute count, or a fallback when unknown.
    /// nil → "Calculating…" while macOS settles the estimate.
    static func duration(minutes: Int?) -> String {
        guard let m = minutes else { return "Calculating\u{2026}" }
        if m <= 0 { return "—" }
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// A manufacture date with the battery's age, e.g. "Mar 2023 (3 yr 2 mo)".
    /// Month-and-year granularity — the packed day of manufacture isn't meaningful.
    static func manufactured(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        let when = formatter.string(from: date)
        guard let age = age(from: date, to: now) else { return when }
        return "\(when) (\(age))"
    }

    /// A compact age like "3 yr 2 mo", "5 mo", or nil for a future/zero span.
    private static func age(from date: Date, to now: Date) -> String? {
        let parts = Calendar.current.dateComponents([.year, .month], from: date, to: now)
        let years = parts.year ?? 0
        let months = parts.month ?? 0
        if years <= 0, months <= 0 { return nil }
        if years <= 0 { return "\(months) mo" }
        if months == 0 { return "\(years) yr" }
        return "\(years) yr \(months) mo"
    }
}
