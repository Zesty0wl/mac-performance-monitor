import Combine
import Foundation
import MacPerfMonitorCore

/// The user's choice of which optional components run, persisted across
/// launches, and the one source of truth for it.
///
/// Published so the Settings switches, the menu bar panel's pause action, the
/// setup wizard, the history gates in the interface, the status item controller
/// and the app delegate's quit rule all bind to the same state. The delegate
/// turns database logging on and off live from `$state` (see
/// `SamplerModel.setPersistenceEnabled`) and installs or removes the menu bar
/// item the same way.
///
/// Replaces `AppModeManager`, whose single `appMode` setting answered two
/// questions at once and could never turn the menu bar item off.
/// `AppComponentState.resolve` carries the old value forward.
final class AppComponentsManager: ObservableObject {
    /// UserDefaults keys. The legacy key is read once, for the migration, and
    /// then left alone: it is what a downgrade to 1.x would read.
    static let menuBarItemKey = "components.menuBarItem"
    static let historyLoggingKey = "components.historyLogging"
    static let legacyModeKey = "appMode"

    @Published var state: AppComponentState {
        didSet {
            guard state != oldValue else { return }
            defaults.set(state.menuBarItem, forKey: Self.menuBarItemKey)
            defaults.set(state.historyLogging, forKey: Self.historyLoggingKey)
        }
    }

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = Self.storedState(defaults)
        // Follow the stored values, so a write to these keys from anywhere else
        // in the app still takes effect. The `didSet` above ignores a write that
        // matches what is already published, so this cannot loop. Note this is
        // an in-process signal: macOS does not deliver it for a change made by
        // another process, so `defaults write` from a terminal needs a relaunch.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let stored = Self.storedState(self.defaults)
                if stored != self.state { self.state = stored }
            }
            .store(in: &cancellables)
    }

    /// Whether the read-out sits in the menu bar.
    var menuBarItem: Bool {
        get { state.menuBarItem }
        set { state.menuBarItem = newValue }
    }

    /// Whether samples are written to the history database.
    var historyLogging: Bool {
        get { state.historyLogging }
        set { state.historyLogging = newValue }
    }

    /// Read the stored state without instantiating a manager. Used as the
    /// default for `SamplerModel.init(persistenceEnabled:)`, so a launch with
    /// logging off never opens the database file at all.
    static func storedState(_ defaults: UserDefaults = .standard) -> AppComponentState {
        AppComponentState.resolve(
            menuBarItem: defaults.object(forKey: menuBarItemKey) as? Bool,
            historyLogging: defaults.object(forKey: historyLoggingKey) as? Bool,
            legacyAppMode: defaults.string(forKey: legacyModeKey))
    }

    /// Convenience for the sampler's launch-time default.
    static func loggingEnabledFromDefaults(_ defaults: UserDefaults = .standard) -> Bool {
        storedState(defaults).historyLogging
    }
}
