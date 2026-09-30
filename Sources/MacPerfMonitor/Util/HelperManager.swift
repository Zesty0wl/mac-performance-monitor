import Combine
import Darwin
import Foundation
import MacPerfMonitorCore
import MacPerfMonitorIPC
import ServiceManagement

/// User-facing state of the privileged helper, derived from the underlying
/// `SMAppService.Status` plus the user's own intent.
enum HelperCoverage: Equatable {
    /// The daemon is not present in the bundle (an unsigned or dev build), so
    /// elevated coverage cannot be offered at all.
    case unavailable
    /// Not registered. The app runs user-level only.
    case disabled
    /// Registered, but the user must approve it in System Settings before the
    /// daemon may run.
    case requiresApproval
    /// Approved and active. The helper fills coverage gaps.
    case enabled

    /// Whether full coverage is actually in effect.
    var isActive: Bool { self == .enabled }
}

/// Owns the privileged helper lifecycle: registers and unregisters the root
/// LaunchDaemon via `SMAppService`, tracks approval status, and wires a
/// `HelperConnection` into the sampler whenever coverage is active.
///
/// The helper is strictly opt-in. Until the user enables it the app reads only
/// what it can at user level; enabling it restores footprint coverage for the
/// system and other-user processes the unprivileged app cannot see.
///
/// All access happens on the main thread (SwiftUI actions and AppKit delegate
/// callbacks), so the published state and `SMAppService` calls stay main-bound
/// without needing actor isolation that would complicate the delegate's setup.
final class HelperManager: ObservableObject {
    /// Current effective coverage state, observed by the UI.
    @Published private(set) var coverage: HelperCoverage = .disabled
    /// Last registration error, surfaced in Settings; nil when healthy.
    @Published private(set) var lastError: String?

    private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    private weak var model: SamplerModel?
    private var connection: HelperConnection?

    private let decidedKey = "helper.decisionMade"
    private let intentKey = "helper.enabledIntent"

    /// Whether the user has been asked at least once, so the one-time prompt is
    /// shown only once. The user's actual choice is the daemon's own
    /// registration state (which `SMAppService` persists), not a separate flag.
    private(set) var hasDecided: Bool {
        get { UserDefaults.standard.bool(forKey: decidedKey) }
        set { UserDefaults.standard.set(newValue, forKey: decidedKey) }
    }

    /// The user's standing intent: did they last turn the helper *on*? Persisted
    /// separately from `SMAppService`'s registration so the app can self-heal —
    /// a reinstall (or any OS-side reset) drops the registration to
    /// `.notRegistered`/`.notFound`, and `refresh()` re-registers automatically
    /// when this is set, rather than silently reverting to user-level and making
    /// the user re-enable by hand. Set in `enable()`/`disable()`.
    private var wantsHelper: Bool {
        get { UserDefaults.standard.bool(forKey: intentKey) }
        set { UserDefaults.standard.set(newValue, forKey: intentKey) }
    }

    private let registeredVersionKey = "helper.registeredVersion"

    /// The app build (`CFBundleVersion`) at which the daemon was last registered.
    /// When the running build differs — an update replaced the bundle — the
    /// launchd job must be re-registered so it points at the new helper binary;
    /// otherwise it can read as enabled yet fail to launch after a reboot.
    private var registeredVersion: String? {
        get { UserDefaults.standard.string(forKey: registeredVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: registeredVersionKey) }
    }

    private static var appBuildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Whether to surface the one-time first-launch prompt: only when the helper
    /// is available but not yet registered, and the user has not decided yet. If
    /// a registration already exists (enabled or awaiting approval), the toggle
    /// and the in-context button represent it instead of a modal prompt.
    var shouldOfferFirstRunPrompt: Bool {
        !hasDecided && coverage == .disabled
    }

    /// Connect the manager to the sampler and read the current status.
    func attach(to model: SamplerModel) {
        self.model = model
        // Auto-recover whenever root reads start failing while coverage is meant to
        // be on — so a wedged/stale helper (e.g. after an update) is repaired
        // without the user toggling the feature off and on.
        model.setPrivilegedReadFailureHandler { [weak self] in self?.recoverHelper() }
        refresh()
    }

    /// Re-read the daemon status (call on launch and when the app reactivates,
    /// since approval happens out of process in System Settings) and apply the
    /// reader accordingly.
    func refresh() {
        refresh(status: service.status)
    }

    /// Reads the status off the main thread, then applies it. For activation:
    /// `service.status` is a round trip to Background Task Management that
    /// takes hundreds of milliseconds when it is busy, and activation is the
    /// moment someone presses on the title bar to drag the window, so a stall
    /// there swallows the drag.
    func refreshInBackground() {
        let service = service
        DispatchQueue.global(qos: .userInitiated).async {
            let status = service.status
            DispatchQueue.main.async { self.refresh(status: status) }
        }
    }

    private func refresh(status: SMAppService.Status) {
        var raw = status
        let appVersion = Self.appBuildVersion
        let dropped = (raw == .notRegistered || raw == .notFound)
        let updated = (registeredVersion != appVersion)
        // Self-heal, but re-register ONLY when the registration was actually
        // dropped (.notRegistered/.notFound — almost always a reinstall replacing
        // the bundle). We deliberately do NOT re-register on a mere version change.
        //
        // Why: on macOS 26/27 every SMAppService.register() mints a NEW Background
        // Task Management *generation* without retiring the prior (still-enabled)
        // one. Because this app's daemon plist carries AssociatedBundleIdentifiers,
        // each daemon re-registration also refreshes the parent *app* BTM record —
        // and accumulating enabled generations of this bundle is exactly what makes
        // RunningBoard demand-launch (and respawn-on-kill) duplicate copies of the
        // app. We confirmed this on a macOS 27 box: a 59→62 update drove refresh()
        // here to re-register, leaving multiple enabled app generations and two
        // live menubar instances. After an in-place update the embedded daemon
        // plist still resolves from the new bundle, so the registration needs no
        // refresh; only a stale *running* helper does, handled below without
        // touching the registration. We never act on .requiresApproval (the user's
        // to grant).
        if wantsHelper, dropped {
            do {
                try service.register()
                registeredVersion = appVersion
                AppLog.helper.notice(
                    "registered helper (was dropped: \(String(describing: raw), privacy: .public))")
            } catch {
                AppLog.helper.error(
                    "helper register failed: \(error.localizedDescription, privacy: .public)")
            }
            raw = service.status
        } else if updated {
            // Record the new build so `updated` doesn't stay true on every launch.
            // No re-registration (see above); the staleness check below replaces a
            // stale running helper if the update left one behind.
            registeredVersion = appVersion
        }
        coverage = Self.map(raw)
        AppLog.helper.notice(
            "helper status: \(String(describing: raw), privacy: .public) -> \(String(describing: self.coverage), privacy: .public)"
        )
        applyReader()
        // After an update replaced the bundle, an OLD helper process may still be
        // running its now-stale binary. Verify (via the build handshake) and, if so,
        // drop that process so launchd demand-launches the new binary.
        if updated, coverage == .enabled {
            verifyAndRecoverIfStale()
        }
    }

    /// Enable elevated coverage: register the daemon and, if approval is
    /// pending, open the System Settings pane where the user grants it.
    func enable() {
        hasDecided = true
        wantsHelper = true
        lastError = nil
        do {
            try service.register()
            registeredVersion = Self.appBuildVersion
            AppLog.helper.notice("registered helper daemon")
        } catch {
            // Registration can throw when the daemon is already registered;
            // surface other failures but always re-read the real status after.
            AppLog.helper.error(
                "register failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
        if coverage == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Stop the running root helper before an app update installs, so the new
    /// binary replaces a stopped one and is demand-launched fresh on next use
    /// (mirroring the pkg installer's preinstall). Sparkle is unaware of the
    /// LaunchDaemon, so the app drives this from the updater's pre-install hook.
    /// Best-effort; the SMAppService registration and the user's approval are left
    /// intact. No-op when nothing is connected (so nothing is running to stop).
    func stopForUpdate() {
        // Even with no live connection this session, an enabled helper may be
        // running (demand-launched earlier and idling), so connect if needed and
        // tell it to exit before the bundle swap. Harmless if it is already down —
        // it is demand-launched fresh from the new binary on the next use. The
        // build handshake in `refresh()` is the post-update safety net for anything
        // this misses (e.g. an update applied without this hook running).
        guard coverage == .enabled else { return }
        if connection == nil { connection = HelperConnection() }
        AppLog.helper.notice("stopping helper for update")
        connection?.terminateHelper()
        connection = nil
        model?.setPrivilegedReader(nil)
    }

    /// Cooldown so a genuinely unrecoverable state can't spin `recoverHelper()` in
    /// a tight loop (it is driven by the sampler's repeated-failure callback).
    private var lastRecoveryAt: Date?
    private let recoveryCooldown: TimeInterval = 25

    /// After an in-place app update, ping the running daemon for the build it
    /// launched from; if it is not this app's build (stale binary) or is unreachable
    /// (nil), recover. Runs the blocking XPC off the main thread.
    private func verifyAndRecoverIfStale() {
        guard coverage == .enabled, let connection else { return }
        let expected = Self.appBuildVersion
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let running = connection.helperBuild()
            if running == expected { return }  // healthy and current
            AppLog.helper.notice(
                "helper build \(running ?? "unreachable", privacy: .public) != app \(expected, privacy: .public) after update — recovering"
            )
            DispatchQueue.main.async { self?.recoverHelper() }
        }
    }

    /// Reliably recover a helper that is registered and approved but not actually
    /// serving — wedged, crashed, or a stale launchd job after an update — WITHOUT
    /// the user toggling the feature. This does exactly what a manual disable+enable
    /// does: boot the launchd job out and bootstrap it again, so the old root
    /// process is dropped and a fresh one is demand-launched from the current
    /// binary, then rebuild the XPC connection (which resets the sampler's backoff
    /// so reads resume at once). Approval persists across this with a stable signing
    /// identity. Cooldown-guarded and only while the user wants coverage on.
    func recoverHelper() {
        guard wantsHelper, coverage == .enabled else { return }
        if let last = lastRecoveryAt, Date().timeIntervalSince(last) < recoveryCooldown { return }
        lastRecoveryAt = Date()
        AppLog.helper.notice(
            "recovering helper: dropping the stale/wedged root process and reconnecting")
        // Drop the old root process (best-effort) so launchd demand-launches a fresh
        // one from the CURRENT bundle on the next request, then rebuild the XPC
        // connection — which resets the sampler's backoff so reads resume at once.
        //
        // This deliberately does NOT unregister/register the SMAppService job. On
        // macOS 26/27 a re-register mints a new Background Task Management generation
        // without retiring the prior (enabled) one; accumulating enabled generations
        // is what makes RunningBoard demand-launch and respawn duplicate copies of
        // the app. The registration already points at the embedded plist in the
        // current bundle, so only the running process needs replacing.
        if connection == nil { connection = HelperConnection() }
        connection?.terminateHelper()
        connection?.invalidate()
        connection = nil
        coverage = Self.map(service.status)
        AppLog.helper.notice(
            "helper recovery -> \(String(describing: self.coverage), privacy: .public)")
        applyReader()
    }

    /// Disable elevated coverage: unregister the daemon and revert to user-level
    /// reads.
    func disable() {
        hasDecided = true
        wantsHelper = false
        lastError = nil
        do {
            try service.unregister()
            AppLog.helper.notice("unregistered helper daemon")
        } catch {
            AppLog.helper.error(
                "unregister failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Record that the user declined the one-time prompt without enabling.
    func declineFirstRunPrompt() {
        hasDecided = true
    }

    /// Open the System Settings Login Items pane (where a pending approval is
    /// granted).
    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Elevated process actions

    /// Whether elevated coverage is active and a helper connection is in hand,
    /// so callers can decide whether to escalate a denied user-level action
    /// (force quit, descriptor listing) to the root daemon.
    var canEscalate: Bool { coverage == .enabled && connection != nil }

    /// Force-terminate a process through the root helper (`SIGKILL`), so the app
    /// can stop system and other-user processes the user cannot signal directly.
    /// The XPC call runs off the main thread and the outcome is delivered on the
    /// main thread. Returns `.notPermitted` at once when elevated coverage is
    /// not active.
    func forceQuit(pid: Int32, completion: @escaping (ProcessActions.KillOutcome) -> Void) {
        guard coverage == .enabled, let connection else {
            completion(.notPermitted)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let code = connection.terminateProcess(pid: pid, signal: SIGKILL)
            let outcome: ProcessActions.KillOutcome
            switch code {
            case 0: outcome = .success
            case ESRCH: outcome = .alreadyGone
            case EPERM: outcome = .notPermitted
            default: outcome = .failed(code)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// List a process's open file descriptors through the root helper, so the
    /// app can show them for system and other-user processes. The XPC call runs
    /// off the main thread and the result is delivered on the main thread.
    /// Delivers nil when elevated coverage is not active or the daemon was
    /// unreachable, so the caller can fall back to a user-level read.
    func listOpenFiles(pid: Int32, completion: @escaping ([OpenFileDescriptor]?) -> Void) {
        guard coverage == .enabled, let connection else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fds = connection.listFileDescriptors(pid: pid)
            DispatchQueue.main.async { completion(fds) }
        }
    }

    /// Run an allow-listed Apple memory tool (`footprint`/`heap`/`leaks`) against
    /// a process through the root helper, so the memory inspector can examine
    /// system and other-user processes the app cannot read unprivileged. The XPC
    /// call runs off the main thread and the raw tool text is delivered on the
    /// main thread. Delivers nil when elevated coverage is not active or the
    /// daemon was unreachable, so the caller can fall back or explain.
    func runMemoryTool(
        _ tool: MemoryInspection.Tool, pid: Int32, completion: @escaping (String?) -> Void
    ) {
        guard coverage == .enabled, let connection else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = connection.runMemoryTool(tool, pid: pid)
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Install the helper-backed reader whenever the daemon is registered and
    /// approved; otherwise tear it down so sampling reverts cleanly to
    /// user-level only.
    private func applyReader() {
        if coverage == .enabled {
            if connection == nil { connection = HelperConnection() }
            model?.setPrivilegedReader(connection)
        } else {
            model?.setPrivilegedReader(nil)
            connection?.invalidate()
            connection = nil
        }
    }

    private static func map(_ status: SMAppService.Status) -> HelperCoverage {
        switch status {
        case .notRegistered: return .disabled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // `.notFound` means SMAppService has no current registration it can
        // resolve (commonly after the app bundle is replaced, which is exactly
        // our reinstall case). The daemon plist is still in the bundle, so it is
        // registerable: treat it as disabled so the user can enable and
        // re-register. A genuinely broken bundle surfaces via register()'s
        // thrown error in `lastError`.
        case .notFound: return .disabled
        @unknown default: return .unavailable
        }
    }
}
