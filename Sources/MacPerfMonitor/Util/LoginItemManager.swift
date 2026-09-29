import Foundation
import MacPerfMonitorCore
import ServiceManagement

/// Owns the app's "open at login" state via `SMAppService.mainApp`: registering
/// the main app as a login item so the menubar-first app is running — and its
/// history unbroken — from the moment the user signs in.
///
/// Like the privileged helper this is strictly opt-in. A one-time first-run
/// prompt offers it; thereafter it is a Settings toggle. The user's choice is
/// the login item's own registration state (which `SMAppService` persists);
/// `decisionMade` only records that the prompt has been shown once.
///
/// All access is on the main thread (SwiftUI actions and the AppKit delegate),
/// so the published state and the `SMAppService` calls stay main-bound without
/// actor isolation.
final class LoginItemManager: ObservableObject {
    static let startMinimisedKey = "startup.startMinimised"

    @Published var startMinimised: Bool {
        didSet { defaults.set(startMinimised, forKey: Self.startMinimisedKey) }
    }

    /// Whether the app is currently registered to open at login, observed by the
    /// Settings toggle.
    @Published private(set) var isEnabled = false
    /// Last register/unregister error, surfaced in Settings; nil when healthy.
    @Published private(set) var lastError: String?

    private let service = SMAppService.mainApp
    private let decidedKey = "loginItem.decisionMade"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startMinimised = defaults.object(forKey: Self.startMinimisedKey) as? Bool ?? true
    }

    func shouldPresentMainWindow(menuBarEnabled: Bool) -> Bool {
        !menuBarEnabled || !startMinimised
    }

    /// Whether the user has been asked at least once, so the one-time prompt is
    /// shown only once. The actual choice is the login item's registration state,
    /// not a separate flag.
    private(set) var hasDecided: Bool {
        get { defaults.bool(forKey: decidedKey) }
        set { defaults.set(newValue, forKey: decidedKey) }
    }

    /// Surface the one-time first-launch prompt only when the user has not
    /// decided yet and the app is not already opening at login (e.g. enabled by
    /// hand in System Settings before the prompt ever showed).
    var shouldOfferFirstRunPrompt: Bool {
        !hasDecided && !isEnabled
    }

    /// Re-read the registration state. Call on launch and whenever the app
    /// reactivates, since the user can flip "Open at Login" in System Settings
    /// out of process.
    func refresh() {
        isEnabled = service.status == .enabled
        AppLog.ui.notice(
            "login item status: \(String(describing: self.service.status), privacy: .public)")
    }

    /// Register the app as a login item so it opens at sign-in.
    func enable() {
        hasDecided = true
        lastError = nil
        do {
            try service.register()
            AppLog.ui.notice("registered login item")
        } catch {
            // register() can throw when already registered; surface other
            // failures but always re-read the real status after.
            AppLog.ui.error(
                "login item register failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Unregister the login item so the app no longer opens at sign-in.
    func disable() {
        hasDecided = true
        lastError = nil
        do {
            try service.unregister()
            AppLog.ui.notice("unregistered login item")
        } catch {
            AppLog.ui.error(
                "login item unregister failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Record that the user declined the one-time prompt without enabling.
    func declineFirstRunPrompt() {
        hasDecided = true
    }
}
