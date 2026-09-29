import AppKit
import MacPerfMonitorCore

@MainActor
final class GitHubStarPrompt {
    static let repositoryURL = URL(string: "https://github.com/Zesty0wl/mac-performance-monitor")!

    enum Surface {
        case menuBar, mainWindow
    }

    private static let firstUseKey = "githubStar.firstUse"
    private static let menuBarUsedKey = "githubStar.usedMenuBar"
    private static let mainWindowUsedKey = "githubStar.usedMainWindow"
    private static let promptShownKey = "githubStar.promptShown"
    private static let minimumUsageInterval: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recordLaunch(at date: Date = Date()) {
        guard defaults.object(forKey: Self.firstUseKey) == nil else { return }
        defaults.set(date, forKey: Self.firstUseKey)
    }

    func recordUse(_ surface: Surface, at date: Date = Date()) {
        recordLaunch(at: date)
        let key = surface == .menuBar ? Self.menuBarUsedKey : Self.mainWindowUsedKey
        if !defaults.bool(forKey: key) { defaults.set(true, forKey: key) }
    }

    func shouldOfferPrompt(at date: Date = Date()) -> Bool {
        guard !defaults.bool(forKey: Self.promptShownKey),
            defaults.bool(forKey: Self.menuBarUsedKey),
            defaults.bool(forKey: Self.mainWindowUsedKey),
            let firstUse = defaults.object(forKey: Self.firstUseKey) as? Date
        else { return false }
        return date.timeIntervalSince(firstUse) >= Self.minimumUsageInterval
    }

    func markPromptShown() {
        defaults.set(true, forKey: Self.promptShownKey)
    }

    @discardableResult
    func presentIfEligible(
        in window: NSWindow, isAppActive: Bool, otherPromptPending: Bool,
        at date: Date = Date(),
        openRepository: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        guard isAppActive, window.isKeyWindow, window.isVisible, !window.isMiniaturized,
            window.attachedSheet == nil, !otherPromptPending,
            shouldOfferPrompt(at: date)
        else { return false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = t("Enjoying %@?", AppInfo.displayName)
        alert.informativeText = t(
            "If %@ has been useful, please consider giving it a star on GitHub.",
            AppInfo.displayName)
        alert.addButton(withTitle: t("Star on GitHub"))
        alert.addButton(withTitle: t("No Thanks")).keyEquivalent = "\u{1b}"
        markPromptShown()
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { openRepository(Self.repositoryURL) }
        }
        return true
    }
}
