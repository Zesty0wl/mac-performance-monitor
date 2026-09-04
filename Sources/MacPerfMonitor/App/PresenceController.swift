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
@MainActor
final class PresenceController {
    /// UserDefaults key shared with the Settings toggle. Reads as `false` when
    /// unset, so the Dock icon comes and goes with the windows until the user
    /// asks for it to stay.
    static let pinDefaultsKey = "showDockIcon"

    private var cancellables = Set<AnyCancellable>()
    private var applyScheduled = false

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

    private func apply() {
        let wantsRegular = isPinned || NSApp.windows.contains { $0.isRealAppWindow }
        let desired: NSApplication.ActivationPolicy = wantsRegular ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        AppLog.ui.notice(
            "activation policy: \(desired == .regular ? "regular" : "accessory", privacy: .public)")
        // Becoming regular while the app is in the background can leave the new
        // menu bar unclaimed until something activates it. Every window in this
        // app opens because the user asked for one, so taking focus here is what
        // they expect, and it is much better than a window with no menus.
        if desired == .regular, !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
