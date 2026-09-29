import Foundation

/// Which of the app's optional components are switched on.
///
/// The app is three things a user can reason about: a window, a menu bar item,
/// and a background logger that fills the history database. The window is always
/// available; the other two are independent switches, and either can be off.
///
/// Before 2.0 there was one setting instead, `appMode`, with two values that
/// conflated the two questions: `full` meant a menu bar item *and* logging,
/// `menuBarOnly` meant a menu bar item and no logging. Neither could turn the
/// item off. `resolve` is the migration: an explicit new-style value wins, and
/// where there is none the old mode answers for logging while the item stays on,
/// which is what every existing install has today.
public struct AppComponentState: Equatable, Sendable {
    /// Whether the read-out sits in the menu bar.
    public var menuBarItem: Bool
    /// Whether samples are written to the on-disk history database.
    public var historyLogging: Bool

    public init(menuBarItem: Bool, historyLogging: Bool) {
        self.menuBarItem = menuBarItem
        self.historyLogging = historyLogging
    }

    /// A fresh install: everything on.
    public static let `default` = AppComponentState(menuBarItem: true, historyLogging: true)

    /// The value of the pre-2.0 `appMode` setting that meant "no history".
    public static let legacyMenuBarOnlyMode = "menuBarOnly"

    /// Work out the state from what is stored, old or new.
    ///
    /// - Parameters:
    ///   - menuBarItem: the stored new-style switch, or nil when never set.
    ///   - historyLogging: the stored new-style switch, or nil when never set.
    ///   - legacyAppMode: the pre-2.0 `appMode` string, or nil when absent.
    public static func resolve(
        menuBarItem: Bool?, historyLogging: Bool?, legacyAppMode: String?
    ) -> AppComponentState {
        let legacyLogging = legacyAppMode.map { $0 != legacyMenuBarOnlyMode }
        return AppComponentState(
            menuBarItem: menuBarItem ?? true,
            historyLogging: historyLogging ?? legacyLogging ?? true)
    }

    /// Whether the app has a reason to keep running once every window is closed.
    /// With no menu bar item and nothing being recorded it would be running
    /// invisibly and achieving nothing, so it quits instead.
    public var keepsRunningWithoutWindows: Bool {
        menuBarItem || historyLogging
    }
}
