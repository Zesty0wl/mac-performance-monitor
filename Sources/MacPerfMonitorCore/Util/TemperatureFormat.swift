import Foundation

/// The temperature unit the person chose in the app's Settings.
public enum TemperatureUnitChoice: String, CaseIterable, Sendable {
    /// Follow System Settings > General > Language & Region > Temperature.
    case system
    case celsius
    case fahrenheit
}

/// Shows temperatures in the unit this Mac is set to.
///
/// Everything the app measures, stores, compares and exports stays in Celsius
/// (the history database, alert rules, trace files and the AI agents' views,
/// whose columns say `_c`). Only what reaches the screen goes through here, so
/// switching unit is instant and loses nothing.
///
/// The unit comes from the app's own setting when it names one, otherwise from
/// macOS. `UnitTemperature(forLocale:)` follows the system Temperature setting
/// (stored as `AppleTemperatureUnit`) and the region's default, and is not
/// affected by the app's interface language, which can differ from the
/// system's and carries no unit preference of its own.
public enum TemperatureFormat {
    /// UserDefaults key for the Settings override, a `TemperatureUnitChoice` raw value.
    public static let defaultsKey = "temperatureUnit"

    public static var choice: TemperatureUnitChoice {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(TemperatureUnitChoice.init)
            ?? .system
    }

    /// Whether temperatures show in Fahrenheit right now.
    public static var usesFahrenheit: Bool {
        usesFahrenheit(choice: choice, locale: .autoupdatingCurrent)
    }

    static func usesFahrenheit(choice: TemperatureUnitChoice, locale: Locale) -> Bool {
        switch choice {
        case .celsius: return false
        case .fahrenheit: return true
        case .system:
            return UnitTemperature(forLocale: locale).symbol == UnitTemperature.fahrenheit.symbol
        }
    }

    /// "°C" or "°F".
    public static var symbol: String { usesFahrenheit ? "°F" : "°C" }

    /// The unit letter alone, "C" or "F", for axis and column headers.
    public static var letter: String { usesFahrenheit ? "F" : "C" }

    /// A Celsius reading in the display unit, for charts that plot it.
    public static func display(_ celsius: Double) -> Double {
        display(celsius, fahrenheit: usesFahrenheit)
    }

    static func display(_ celsius: Double, fahrenheit: Bool) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    /// A converter fixed to the current unit, for converting a whole series
    /// without resolving the unit once per point.
    public static func converter() -> (Double) -> Double {
        usesFahrenheit ? { $0 * 9 / 5 + 32 } : { $0 }
    }

    /// A Celsius reading as text in the display unit: "62°C" or "144°F".
    public static func string(_ celsius: Double, fractionDigits: Int = 0) -> String {
        label(display(celsius), fractionDigits: fractionDigits)
    }

    /// A value already in the display unit (a chart axis or a plotted point),
    /// with its unit.
    public static func label(_ displayValue: Double, fractionDigits: Int = 0) -> String {
        number(displayValue, fractionDigits: fractionDigits) + symbol
    }

    /// A Celsius reading as a bare number and degree sign, "62°" or "144°",
    /// for the menu bar where the unit letter does not fit.
    public static func degrees(_ celsius: Double) -> String {
        number(display(celsius), fractionDigits: 0) + "°"
    }

    private static func number(_ value: Double, fractionDigits: Int) -> String {
        guard value.isFinite else { return "--" }
        if fractionDigits <= 0 { return String(Int(value.rounded())) }
        return String(format: "%.\(fractionDigits)f", value)
    }
}
