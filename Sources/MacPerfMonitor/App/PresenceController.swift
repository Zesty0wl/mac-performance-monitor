import AppKit
import Combine

/// Owns the app's activation policy: whether it presents as a regular
/// application, with a Dock icon and the standard menus, or as a background
/// agent with neither.
///
/// The bundle declares `LSUIElement`, so the process always starts as an
/// accessory. That is deliberate: a login-item launch stays quiet and no Dock
/// icon flashes on the way up. From there the policy follows the windows.
///
/// Any window the user can see makes the app regular. That is what gives it the
/// application menu and Command-Q, and the Edit and Window menus that a
/// window-first app needs; an accessory app has none of them, which is why
/// opening Settings from the menu bar used to need a manual activate to come to
/// the front. Closing the last window drops the app back to accessory, so
/// nothing sits in the Dock while it is only recording history in the
/// background.
///
/// One preference pins the regular policy for people who want the app in the
/// Dock permanently. It is off by default and keeps the old `showDockIcon` key,
/// because the old meaning, "also show a Dock icon while running", is exactly
/// the case the pin now covers.
///
/// The policy only ever changes between windows, never under one (#178).
/// Switching policy while a window is being ordered in or torn down is what
/// left windows open but stuck behind other apps, with the app never becoming
/// active. So a requested window promotes the app before it opens
/// (`prepareForWindow`), and the drop back to accessory waits until the close
/// has settled and no window has been asked for in the meantime.
@MainActor
final class PresenceController {
    /// UserDefaults key shared with the Settings toggle. Reads as `false` when
    /// unset, so the Dock icon comes and goes with the windows until the user
    /// asks for it to stay.
    static let pinDefaultsKey = "showDockIcon"

    /// How long the app stays regular after its last window closes. Long
    /// enough for the window server to finish tearing the window down, short
    /// enough that the Dock icon still reads as going away with the window.
    static let demotionDelay: TimeInterval = 1.0

    /// How long after a window is asked for the app refuses to demote. A
    /// requested window can take a moment to appear, and demoting in that gap
    /// is the race this class exists to avoid.
    static let requestGrace: TimeInterval = 2.0

    private var cancellables = Set<AnyCancellable>()
    private var applyScheduled = false
    private var lastWindowRequest = Date.distantPast
    /// Bumped to cancel a scheduled demotion.
    private var demotionGeneration = 0
    private var demotionScheduled = false

    /// Apply the policy now, then re-apply whenever a window opens or closes and
    /// whenever the preference changes.
    func start() {
        let nc = NotificationCenter.default
        for name: Notification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            nc.publisher(for: name)
                .sink { [weak self] _ in self?.scheduleApply() }
                .store(in: &cancellables)
        }
        nc.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleApply() }
            .store(in: &cancellables)
        apply()
    }

    /// Whether the user has pinned the Dock icon for the background case.
    private var isPinned: Bool {
        UserDefaults.standard.bool(forKey: Self.pinDefaultsKey)
    }

    /// A window is about to be opened. Become regular now, before it is ordered
    /// in, so the policy is already settled when it appears, and hold off any
    /// pending demotion.
    func prepareForWindow() {
        lastWindowRequest = Date()
        cancelDemotion()
        setPolicy(.regular)
    }

    /// Re-evaluate on the next turn of the run loop. `willClose` arrives *before*
    /// the window leaves `NSApp.windows`, so counting on the next turn is what
    /// makes closing the last window read as zero rather than one. A window that
    /// has just been asked for may not exist yet either, so this runs again a
    /// beat later to catch it.
    func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            self.apply()
        }
        // A newly requested window is not in `NSApp.windows` yet, and it may
        // never become key, which is the notification this would otherwise wait
        // for. Look again once it has had time to appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.apply()
        }
    }

    private var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isRealAppWindow }
    }

    private func apply() {
        let hasVisibleWindow = hasVisibleWindow
        guard isPinned || hasVisibleWindow else {
            scheduleDemotion()
            return
        }
        cancelDemotion()
        let changed = setPolicy(.regular)
        // Becoming regular while the app is in the background can leave the new
        // menu bar unclaimed until something activates it. Every window in this
        // app opens because the user asked for one, so taking focus here is what
        // they expect, and it is much better than a window with no menus.
        if changed, hasVisibleWindow, !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Demotion

    /// Drop to accessory once the last close has settled. Re-checked when it
    /// fires, so a window that opened in the meantime keeps the app regular.
    private func scheduleDemotion() {
        guard !demotionScheduled, !isPolicy(.accessory) else { return }
        demotionScheduled = true
        let generation = demotionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.demotionDelay) { [weak self] in
            guard let self, generation == self.demotionGeneration else { return }
            self.demotionScheduled = false
            guard !self.isPinned, !self.hasVisibleWindow else { return }
            if Date().timeIntervalSince(self.lastWindowRequest) < Self.requestGrace {
                // A window was asked for and has not appeared yet. Wait for it.
                self.scheduleDemotion()
                return
            }
            self.setPolicy(.accessory)
        }
    }

    private func cancelDemotion() {
        demotionGeneration += 1
        demotionScheduled = false
    }

    // MARK: - Setting the policy

    /// Whether both AppKit and LaunchServices agree the app has `policy`.
    /// They are compared separately because they have been seen to disagree:
    /// trusting AppKit's answer alone would leave a desync in place for good.
    private func isPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        NSApp.activationPolicy() == policy
            && NSRunningApplication.current.activationPolicy == policy
    }

    /// Set the policy if it is not already in effect. Returns whether it changed.
    @discardableResult
    private func setPolicy(_ desired: NSApplication.ActivationPolicy) -> Bool {
        guard !isPolicy(desired) else { return false }
        let accepted = NSApp.setActivationPolicy(desired)
        AppLog.ui.notice(
            "activation policy: \(Self.name(desired), privacy: .public)\(accepted ? "" : " (refused)", privacy: .public)"
        )
        verifyPolicy(desired)
        return true
    }

    /// LaunchServices learns of a policy change asynchronously, so check a
    /// moment later that it did. If it has not, say so in the log and set it
    /// once more: a policy that silently failed to apply is how an app ends up
    /// with windows that never come to the front.
    private func verifyPolicy(_ desired: NSApplication.ActivationPolicy, retried: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, NSApp.activationPolicy() == desired else { return }
            let launchServices = NSRunningApplication.current.activationPolicy
            guard launchServices != desired else { return }
            AppLog.ui.error(
                "activation policy out of step: AppKit \(Self.name(desired), privacy: .public), LaunchServices \(Self.name(launchServices), privacy: .public)\(retried ? "" : "; setting it again", privacy: .public)"
            )
            guard !retried else { return }
            NSApp.setActivationPolicy(desired)
            self.verifyPolicy(desired, retried: true)
        }
    }

    private static func name(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    /// A one-line picture of the app's presence, for diagnostics.
    static func diagnostics() -> String {
        let key = NSApp.keyWindow.map { $0.identifier?.rawValue ?? "unnamed" } ?? "none"
        let real = NSApp.windows.filter(\.isRealAppWindow).count
        let appKit = name(NSApp.activationPolicy())
        let launchServices = name(NSRunningApplication.current.activationPolicy)
        return
            "policy \(appKit), LaunchServices \(launchServices), active \(NSApp.isActive), key \(key), real windows \(real)"
    }
}
