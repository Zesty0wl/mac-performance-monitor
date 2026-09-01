import Combine
import Foundation
import MacPerfMonitorCore

/// The app's function mode — how much of the app runs.
///
/// Two modes trade history for footprint:
/// - `.full` — the live menu bar items *and* the on-disk history database. Every
///   sample is logged to SQLite, so the dashboard's history ranges, the leak
///   board, and the pressure-events timeline all work.
/// - `.menuBarOnly` — the live menu bar items only. Nothing is written to the
///   database, so the app stays as light as possible. The dashboard still opens
///   for live read-outs, but its history ranges are unavailable until logging is
///   turned back on.
enum AppMode: String, CaseIterable, Codable, Sendable {
    case full
    case menuBarOnly

    /// Whether this mode logs samples to the on-disk history database.
    var logsHistory: Bool { self == .full }

    /// Short title for the Settings picker and the menu-bar toggle.
    var title: String {
        switch self {
        case .full: return String(localized: "Full")
        case .menuBarOnly: return String(localized: "Menu bar only")
        }
    }

    /// A one-line explanation, shown under the Settings picker and in the wizard.
    var summary: String {
        switch self {
        case .full:
            return t(
                "Menu bar read-outs plus a local history database: you get the dashboard's history ranges, the leak board, and pressure events."
            )
        case .menuBarOnly:
            return t(
                "Just the live menu bar read-outs. Nothing is written to disk, so the app stays as light as possible; history is unavailable until you turn logging back on."
            )
        }
    }

    /// SF Symbol representing the mode.
    var symbol: String {
        switch self {
        case .full: return "internaldrive"
        case .menuBarOnly: return "menubar.rectangle"
        }
    }
}

/// The user's chosen `AppMode`, persisted across launches in `UserDefaults`.
///
/// Published so the Settings picker, the menu-bar quick toggle, the startup
/// wizard, and the dashboard's history gate all bind to one source of truth; the
/// app delegate observes it and turns database logging on or off live (see
/// `SamplerModel.setPersistenceEnabled`).
final class AppModeManager: ObservableObject {
    @Published var mode: AppMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.defaultsKey) }
    }

    /// UserDefaults key for the persisted mode. Shared with the launch-time read
    /// in `loggingEnabledFromDefaults`.
    static let defaultsKey = "appMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.defaultsKey), let stored = AppMode(rawValue: raw)
        {
            mode = stored
        } else {
            mode = .full
        }
    }

    /// Whether the app should currently be writing samples to the history
    /// database.
    var isLoggingEnabled: Bool { mode.logsHistory }

    /// Read the persisted mode's logging flag directly from `UserDefaults`,
    /// without instantiating a manager. Used as the default for
    /// `SamplerModel.init(persistenceEnabled:)` so the store is opened at launch
    /// only when the saved mode is `.full` — a fresh launch in menu-bar-only mode
    /// never creates the database file.
    static func loggingEnabledFromDefaults(_ defaults: UserDefaults = .standard) -> Bool {
        guard let raw = defaults.string(forKey: defaultsKey), let mode = AppMode(rawValue: raw)
        else {
            return true  // Absent / unrecognised → default `.full`.
        }
        return mode.logsHistory
    }
}
