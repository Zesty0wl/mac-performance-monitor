import AppKit
import Combine
import MacPerfMonitorCore
import Sparkle
import SwiftUI
import os

/// Owns the Sparkle updater for the directly-distributed (non-App-Store) build.
///
/// Scheduling is Sparkle's own: `SUEnableAutomaticChecks` and
/// `SUScheduledCheckInterval` (24 hours) in Info.plist, and from then on the
/// user's choice in Settings > General > Updates. Sparkle's timer runs on wall
/// time, so a check that fell due while the Mac slept fires on wake, and an
/// overdue check runs at launch. The app adds no checks of its own. It used to
/// add one at launch and one on every wake; the launch one was dropped (Sparkle
/// is still probing its installer at that moment, so `canCheckForUpdates` is
/// false), and the wake one ignored the user's setting and re-surfaced the same
/// update after every sleep (#177).
///
/// A scheduled check never puts a window up on its own. This is Sparkle's
/// "gentle reminders" contract (`SPUStandardUserDriverDelegate`): the standard
/// user driver hands a found update to us instead of showing it, and we publish
/// `pendingUpdateVersion` so the menu bar popover can offer "Update to x.y…".
/// For an accessory app Sparkle would otherwise show its alert unprompted, and
/// `PresenceController` would then treat that alert as a real window, flip the
/// app to regular and activate it, which pulled the alert in front of whatever
/// the user was doing. User-initiated checks still show Sparkle's alert at once.
///
/// With automatic install on, Sparkle downloads in the background and would
/// install on quit. A menu bar app rarely quits, so it takes the install over
/// (`updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`) and runs it
/// at the first quiet moment: no app window open and the app not frontmost.
///
/// Everything here is main-thread bound: it is created by the app delegate on
/// the main thread, and Sparkle calls both delegates on main.
///
/// It is also Sparkle's `SPUUpdaterDelegate` for the pre-install hook that stops
/// the privileged root helper. Sparkle only knows about the app bundle, not our
/// LaunchDaemon, so without it the old helper would keep running its old binary
/// across the swap (mirrors the pkg installer's preinstall).
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate,
    SPUStandardUserDriverDelegate
{
    /// Whether a manual check can be started right now (false briefly while a
    /// check is already running). Bound by the "Check for Updates…" menu item so
    /// it disables itself rather than starting overlapping checks. Stays true
    /// while a gentle reminder is pending, because checking again is how that
    /// update is brought into focus.
    @Published var canCheckForUpdates = false

    /// The version a scheduled check found and is holding for the user, shown as
    /// "Update to x.y…" in the menu bar popover. Nil when there is none.
    @Published private(set) var pendingUpdateVersion: String?

    /// Mirrors of Sparkle's settings, for the Settings toggles.
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var automaticallyInstalls = false

    /// Invoked on the main thread immediately before an update installs, so the
    /// app can stop the privileged helper before the bundle is replaced. Wired up
    /// by the app delegate to `HelperManager.stopForUpdate()`.
    var onWillInstallUpdate: (() -> Void)?

    private var controller: SPUStandardUpdaterController!

    /// The install Sparkle has handed over, waiting for a quiet moment.
    private var pendingQuietInstall: (() -> Void)?
    private var quietInstallRetryScheduled = false

    /// Set just before a quiet install so the relaunched copy knows not to open
    /// its main window. A timestamp rather than a flag, so a failed install can't
    /// suppress the window on some unrelated launch days later.
    private static let quietRelaunchKey = "update.quietRelaunchAt"

    /// Unified-log channel for update diagnostics. Sparkle collapses every
    /// failure (appcast unreachable, TLS rejected, DNS blocked, HTML returned
    /// instead of XML) into one generic "An error occurred in retrieving update
    /// information. Please try again later." alert, with the real cause dropped.
    /// Logging the underlying NSError here is the only way a field report can
    /// tell us *why* a user's check failed. Pull it from an affected machine:
    ///   log show --last 30m --info --predicate \
    ///     'subsystem == "uk.co.bzwrd.macperfmonitor" && category == "update"'
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "uk.co.bzwrd.macperfmonitor",
        category: "update")

    override init() {
        super.init()
        // startingUpdater: true starts the updater immediately, which begins the
        // scheduled background checks. Self as both delegates: the updater one
        // for the pre-install hook and quiet installs, the user-driver one for
        // gentle reminders.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)

        // Mirror Sparkle's own state into published properties so SwiftUI can
        // follow it (all KVO-observable on the updater).
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyInstalls)
    }

    // MARK: - Actions

    /// A user-initiated check: always shows UI, including an up-to-date result.
    /// With a gentle reminder pending, this brings that update into focus.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Whether this build may install without asking. False when Info.plist
    /// opts out (`SUAllowsAutomaticUpdates`), so Settings can disable the toggle.
    var allowsAutomaticInstall: Bool {
        controller.updater.allowsAutomaticUpdates
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
        log.notice("automatic update checks \(on ? "on" : "off", privacy: .public)")
    }

    func setAutomaticallyInstalls(_ on: Bool) {
        controller.updater.automaticallyDownloadsUpdates = on
        log.notice("automatic update install \(on ? "on" : "off", privacy: .public)")
    }

    /// The popover's update item: "Update to x.y…" while a found update is
    /// waiting, otherwise the plain manual check.
    var menuTitle: LocalizedStringKey {
        if let version = pendingUpdateVersion {
            return "Update to \(version)\u{2026}"
        }
        return "Check for Updates\u{2026}"
    }

    var menuSymbol: String {
        pendingUpdateVersion == nil ? "arrow.down.circle" : "arrow.down.circle.fill"
    }

    /// True once, for the launch that follows a quiet install. The app delegate
    /// asks this before opening the main window at launch, so an update that
    /// installed itself in the background doesn't then open a window over
    /// whatever the user is doing.
    static func consumeQuietRelaunch() -> Bool {
        let defaults = UserDefaults.standard
        guard let at = defaults.object(forKey: quietRelaunchKey) as? Date else { return false }
        defaults.removeObject(forKey: quietRelaunchKey)
        return Date().timeIntervalSince(at) < 120
    }

    // MARK: - SPUStandardUserDriverDelegate: gentle reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never let a scheduled check show the update window. The popover's update
    /// item is the reminder, and the user opens the alert from there.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        pendingUpdateVersion = update.displayVersionString
        log.notice(
            "update \(update.displayVersionString, privacy: .public) (build \(update.versionString, privacy: .public)) available: holding it for the menu bar"
        )
    }

    /// The session ended: installed, skipped, dismissed, or failed. Whatever was
    /// pending is no longer, and the next scheduled check will find it again if
    /// it still applies.
    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdateVersion = nil
    }

    // MARK: - SPUUpdaterDelegate: quiet install

    /// Sparkle has downloaded an update in the background and would install it
    /// when the app quits. Take that over and install at the first quiet moment.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        log.notice(
            "update \(item.displayVersionString, privacy: .public) downloaded: installing at the next quiet moment"
        )
        pendingQuietInstall = immediateInstallHandler
        installIfQuiet()
        return true
    }

    /// Install now if nobody is looking at the app, otherwise look again in a
    /// few minutes. Sparkle still installs on quit if that comes first.
    private func installIfQuiet() {
        guard let install = pendingQuietInstall else { return }
        let inUse = NSApp.isActive || NSApp.windows.contains { $0.isRealAppWindow }
        if !inUse {
            pendingQuietInstall = nil
            UserDefaults.standard.set(Date(), forKey: Self.quietRelaunchKey)
            log.notice("installing downloaded update quietly")
            install()
            return
        }
        guard !quietInstallRetryScheduled else { return }
        quietInstallRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.quietInstallRetryScheduled = false
            self?.installIfQuiet()
        }
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle is about to install an update and replace the app bundle. Stop the
    /// privileged helper first (Sparkle doesn't know about it) so the new binary
    /// replaces a stopped one and is demand-launched fresh.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        onWillInstallUpdate?()
    }

    // MARK: - SPUUpdaterDelegate: error surfacing

    /// Catch-all for any aborted update cycle. This is what fires when the
    /// appcast can't be retrieved or parsed (the "retrieving update information"
    /// alert). Logs the full NSError chain so the real cause is recoverable.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log.error("Update aborted: \(Self.describe(error), privacy: .public)")
    }

    /// The enclosure (full archive or binary delta) failed to download, a
    /// distinct phase from appcast retrieval, captured for the same reason.
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        log.error(
            "Failed to download update \(item.displayVersionString, privacy: .public) (build \(item.versionString, privacy: .public)): \(Self.describe(error), privacy: .public)"
        )
    }

    /// End of every update cycle. A non-nil `error` is the same failure as
    /// `didAbortWithError`; nil means the check completed cleanly (offered an
    /// update or confirmed up to date). Logging both ends confirms from a
    /// tester's log that the check actually ran and how it resolved.
    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
    ) {
        if let error {
            log.error(
                "Update check (kind \(updateCheck.rawValue)) finished with error: \(Self.describe(error), privacy: .public)"
            )
        } else {
            log.info("Update check (kind \(updateCheck.rawValue)) finished OK")
        }
    }

    /// Flatten an NSError and its underlying-error chain into one log line:
    /// `[domain code] description` per level, plus the failing URL when present.
    /// This is what turns "please try again" into an actionable cause, e.g.
    /// NSURLErrorDomain -1200 (TLS/cert), -1003 (host not found / DNS),
    /// -1009 (offline), -1001 (timeout), or a parse error from a proxy/portal
    /// returning HTML in place of the appcast XML.
    private static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 5 {
            var line = "[\(e.domain) \(e.code)] \(e.localizedDescription)"
            if let url = e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
                line += " url=\(url)"
            }
            parts.append(line)
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " ← ")
    }
}
