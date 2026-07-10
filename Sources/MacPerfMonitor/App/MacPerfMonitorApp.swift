import AppKit
import Combine
import MacPerfMonitorCore
import MacPerfMonitorIPC
import ServiceManagement
import SwiftUI
import UserNotifications

/// Process entry point.
///
/// There must be no `main.swift` in this target: the `@main` attribute on
/// `MacPerfMonitorMain` below is the entry point. The package builds this as an
/// SPM executable, which `Scripts/bundle.sh` wraps into `MacPerfMonitor.app`.
///
/// `main()` first handles the `--uninstall` maintenance flag, used by
/// `Scripts/MacPerfMonitor-Uninstall.sh` to tear down this app's Login Item and
/// privileged-helper Background Task Management registrations *from inside the
/// real bundle* before the bundle is deleted. Doing it here — rather than
/// letting the shell `rm -rf` the bundle while its `SMAppService` registrations
/// are still live — is what stops macOS leaving orphaned BTM records that
/// relaunch a deleted app. Any normal launch hands off to the SwiftUI lifecycle.
@main
enum MacPerfMonitorMain {
    static func main() {
        if CommandLine.arguments.contains("--uninstall") {
            ServiceUninstaller.runAndExit()
        }
        SingleInstanceGuard.activateExistingAndExitIfRunning()
        MacPerfMonitorApp.main()
    }
}

/// Backstop against more than one copy of the app running at once.
///
/// `LSMultipleInstancesProhibited` (Info.plist) asks LaunchServices to coalesce
/// repeat launches, but on macOS 26/27 a stale Background Task Management
/// registration can have RunningBoard demand-launch a *second* copy of the same
/// bundle directly, bypassing that. This in-process check is the safety net: if
/// another instance of this bundle id is already running as we start up, hand off
/// to it and exit — so a duplicate/stale registration can never leave two live
/// menubar apps that each respawn when the other is killed (the field-reported
/// "I quit it and it comes straight back" symptom). Runs before the SwiftUI
/// lifecycle so the duplicate never builds its menubar items or starts sampling.
private enum SingleInstanceGuard {
    static func activateExistingAndExitIfRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = NSRunningApplication.current.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != myPID && !$0.isTerminated }
        guard let existing else { return }
        NSLog(
            "MacPerfMonitor: another instance (pid \(existing.processIdentifier)) is already running — activating it and exiting"
        )
        existing.activate()
        exit(0)
    }
}

/// Best-effort teardown of the app's `SMAppService` registrations, invoked via
/// the `--uninstall` flag. Unregistering the Login Item (`SMAppService.mainApp`)
/// and the helper LaunchDaemon (`SMAppService.daemon`) removes their Background
/// Task Management records so the deleted app is not relaunched and no orphaned
/// "Open at Login" / daemon entries linger. Failures are logged, never fatal —
/// the shell uninstaller must keep going and finish removing everything else.
private enum ServiceUninstaller {
    static func runAndExit() -> Never {
        unregister(SMAppService.mainApp, label: "login item")
        unregister(
            SMAppService.daemon(plistName: HelperConstants.daemonPlistName),
            label: "helper daemon")
        exit(0)
    }

    private static func unregister(_ service: SMAppService, label: String) {
        do {
            try service.unregister()
            print("MacPerfMonitor --uninstall: unregistered \(label)")
        } catch {
            // Not-registered / not-found is the common, harmless case.
            print(
                "MacPerfMonitor --uninstall: \(label) unregister skipped: "
                    + error.localizedDescription)
        }
    }
}

/// The MacPerfMonitor SwiftUI app.
///
/// The app is menubar-first (`LSUIElement` true, so no Dock icon). Sampling runs
/// from launch in the app delegate, independent of any window, so the menubar
/// stays live and within budget while the main window is closed. The window and
/// settings are opened from the menu.
struct MacPerfMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The combined menu bar item is an AppKit `NSStatusItem` managed by the app
        // delegate, not a SwiftUI `MenuBarExtra`. A `MenuBarExtra` cannot be removed at quit on
        // macOS 26/27 (retracting it spins SwiftUI into an infinite loop), which is
        // what let the system demand-relaunch the app after the user quit it; an
        // AppKit item removes cleanly. So this scene tree is only the app's windows.
        windows
    }

    /// The app's windows and settings scene.
    @SceneBuilder private var windows: some Scene {
        // The main window is the app's primary scene now that the MenuBarExtra is
        // gone, so SwiftUI would auto-present it at launch. This is a menu-bar app,
        // which must start to the menu bar rather than pop a (blank, not-yet-key)
        // window, so suppress the launch presentation. It still opens on demand via
        // `openWindow(id:)` from the menubar panels.
        Window(AppInfo.displayName, id: WindowID.main) {
            MainWindowGate()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.model.menuLists)
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.helperManager)
                .environmentObject(appDelegate.loginItemManager)
                .environmentObject(appDelegate.monitorSelection)
                .environmentObject(appDelegate.groupStore)
                .environmentObject(appDelegate.appModeManager)
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.alertSettings)
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.helperManager)
                .environmentObject(appDelegate.loginItemManager)
                .environmentObject(appDelegate.appModeManager)
                .environmentObject(appDelegate.menuBarConfiguration)
        }

        Window(AppInfo.onboardingWindowTitle, id: WindowID.onboarding) {
            OnboardingView()
                .environmentObject(appDelegate.onboarding)
                .environmentObject(appDelegate.appModeManager)
                .environmentObject(appDelegate.loginItemManager)
                .environmentObject(appDelegate.helperManager)
                .environmentObject(appDelegate.menuBarConfiguration)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // The Memory Inspector: one resizable window per inspected process,
        // keyed on a self-contained `InspectorTarget` value. It deliberately gets
        // only the helper manager (for the privileged read path) and NOT the
        // sampler model, so it never subscribes to the per-tick sample stream —
        // it shows on-demand tool snapshots, not live data.
        WindowGroup(id: WindowID.inspector, for: InspectorTarget.self) { $target in
            if let target {
                MemoryInspectorView(target: target)
                    .environmentObject(appDelegate.helperManager)
            }
        }
        .defaultSize(width: 800, height: 660)

        // Open files & sockets: one resizable window per process, keyed on a
        // self-contained `OpenFilesTarget`. Like the inspector it gets only the
        // helper manager (for the privileged read path) and never the sampler
        // model, so it doesn't subscribe to the per-tick sample stream — the
        // descriptor list is read once on demand with an explicit Refresh.
        WindowGroup(id: WindowID.openFiles, for: OpenFilesTarget.self) { $target in
            if let target {
                OpenFilesView(target: target)
                    .environmentObject(appDelegate.helperManager)
            }
        }
        .defaultSize(width: 600, height: 560)

        // AI deep dive: one window per process. Profiles the target with `sample`
        // (via the helper for protected processes) and has the on-device model
        // explain what it is doing. Gets the helper manager (privileged capture);
        // never the sampler model.
        WindowGroup(id: WindowID.deepDive, for: DeepDiveTarget.self) { $target in
            if let target {
                ProcessDeepDiveView(target: target)
                    .environmentObject(appDelegate.helperManager)
            }
        }
        .defaultSize(width: 500, height: 520)
    }
}

/// Product identity shown to the user. The bundle identifier, the os_log
/// subsystem, and the internal Swift module / SPM target names are intentionally
/// left as "MacPerfMonitor" (so the approved helper, the persisted data directory, and
/// logging keep working); the visible name and the bundle's executable file are
/// "Mac Performance Monitor", so the app both presents and reports its process
/// under that name rather than "MacPerfMonitor".
enum AppInfo {
    /// The product's display name, used in window titles and menu copy.
    static let displayName = "Mac Performance Monitor"
    /// The onboarding window's title. Also used as a window-lifecycle key, so it
    /// must stay in sync with the `Window(...)` title in the scene below.
    static let onboardingWindowTitle = "Welcome to \(displayName)"

    /// Marketing version (CFBundleShortVersionString), e.g. "1.0.0".
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    /// Build number (CFBundleVersion), e.g. "59" — bumped every release.
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
}

/// Stable scene identifiers used with `openWindow`.
enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
    static let inspector = "inspector"
    static let openFiles = "open-files"
    static let deepDive = "deep-dive"
}

/// Tracks whether the main window is currently open. The window's heavy content
/// (charts, the full process table) is gated on this so that closing the window
/// truly unmounts that view tree — otherwise SwiftUI keeps the closed window's
/// content subscribed to the model and re-renders it on every sample, ballooning
/// the footprint while the app is supposed to be idle in the menubar.
final class AppState: ObservableObject {
    @Published var mainWindowOpen = false

    /// Whether any part of the main window is actually on screen (not occluded,
    /// not minimized). Live animations — the Battery tab's energy-flow Canvas —
    /// pause on this so a 60 fps redraw train doesn't run for no one (which also
    /// defeats App Nap). Driven from the window's occlusion-state notifications.
    @Published var mainWindowVisible = true

    /// A tab requested by a menu-bar action. Unlike the older one-off Energy and
    /// Network flags, this also lets a visible window return to Dashboard.
    @Published var requestedMainTab: MainWindowTab?

    /// A process the app should reveal in the Processes tab's detail inspector,
    /// set when the user clicks a per-process notification (a leak or ceiling
    /// alert). The main window observes this to switch to the Processes tab and
    /// select the process, then clears it. Nil when there is nothing pending.
    @Published var navigationTarget: ProcessIdentity?

    /// A process awaiting a force-quit confirmation. Any surface that lists a
    /// process sets this; the single confirmation hosted on the main window
    /// resolves it, so every surface shares one safe confirm-then-kill path.
    @Published var pendingForceQuit: ProcessIdentity?

    /// A binary the user asked to inspect the code signature of (from a process
    /// row's "Codesign…" menu). Captured with its path/name at click time so the
    /// sheet survives the process exiting; the sheet hosted on the main window
    /// presents it and clears it on close.
    @Published var codesignTarget: CodesignTarget?

    /// Set by the battery menubar panel to ask the main window to open on the
    /// Battery tab. `ContentView` observes it, switches tab, and clears it — the
    /// same pattern `navigationTarget` uses for the Processes tab.
    @Published var showBatteryTab = false

    /// Set by the network menubar panel to ask the main window to open on the
    /// Network tab. Same observe-then-clear pattern as `showBatteryTab`.
    @Published var showNetworkTab = false

    /// A `.mpmtrace` file opened from Finder, awaiting display. `ContentView`
    /// switches to the Analytics tab and `AnalyticsView` decodes and shows it,
    /// then clears this. Nil when nothing is pending.
    @Published var pendingTraceURL: URL?

    /// True when the one-time prompt offering elevated (helper-backed) coverage
    /// should be shown. Set on first launch; cleared once the user decides.
    @Published var helperPromptPending = false

    /// True when the one-time prompt offering to open the app at login should be
    /// shown. Armed on first launch, but sequenced *after* the helper prompt so
    /// the two never present at once; cleared once the user decides.
    @Published var loginItemPromptPending = false
}

extension Notification.Name {
    /// Posted when the user reopens the app (Finder/Spotlight/`open`), asking the
    /// menubar-first app to bring up its main window.
    static let macperfmonitorShowMainWindow = Notification.Name(
        "uk.co.bzwrd.macperfmonitor.showMainWindow")

    /// Posted to surface the first-run education flow (on first launch, or from
    /// the menu's "How MacPerfMonitor works…" action).
    static let macperfmonitorShowOnboarding = Notification.Name(
        "uk.co.bzwrd.macperfmonitor.showOnboarding")

    /// Posted to open the Settings window. The CPU menu bar item is an AppKit
    /// `NSPopover`, so it cannot use SwiftUI's `openSettings` action directly;
    /// it posts this and the always-present `MenuBarWindowRouter` (hosted in the
    /// primary status item, which has the action) opens Settings. More reliable than
    /// `NSApp.sendAction("showSettingsWindow:")`, which fails from the popover
    /// when there is no key window.
    static let macperfmonitorShowSettings = Notification.Name(
        "uk.co.bzwrd.macperfmonitor.showSettings")
}

/// Owns the single `SamplerModel` and starts sampling at launch, so the menubar
/// is live even before any window is opened.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = SamplerModel()
    let appModeManager = AppModeManager()
    let alertSettings = AlertSettings()
    let alertCenter = AlertCenter()
    let appState = AppState()
    let onboarding = OnboardingState()
    let helperManager = HelperManager()
    let loginItemManager = LoginItemManager()
    let updateController = UpdateController()
    let monitorSelection = MonitorSelection()
    let groupStore = ProcessGroupStore.shared
    let menuBarConfiguration = CombinedMenuBarConfiguration()
    /// The app's single AppKit-managed menu bar item and combined metric panel.
    private var combinedStatusItem: CombinedStatusItemController?
    /// Shows/hides the optional Dock icon, in sync with the Settings toggle.
    private var dockIconController: DockIconController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.ui.notice("app launched (menubar)")

        // Per-app network tracking now uses a cheap one-shot nettop, so it's on by
        // default; a registered default makes the launch read below (and @AppStorage
        // toggles) see ON unless the user has explicitly turned it off.
        UserDefaults.standard.register(defaults: [SamplerModel.perAppNetworkDefaultsKey: true])

        // Install one combined AppKit status item. It owns the shared popover,
        // compact read-out strip, sampling gates, and window-opening router.
        let combinedStatusItem = CombinedStatusItemController(
            model: model, appState: appState, helperManager: helperManager,
            updateController: updateController,
            appModeManager: appModeManager, configuration: menuBarConfiguration)
        combinedStatusItem.start()
        self.combinedStatusItem = combinedStatusItem

        // Per-app network attribution is opt-in (it runs a `nettop`): apply the
        // saved setting now and keep the sampler in sync with the Settings toggle,
        // the same live-from-UserDefaults pattern the menubar items use.
        model.setPerAppNetworkTracking(
            UserDefaults.standard.bool(forKey: SamplerModel.perAppNetworkDefaultsKey))
        // Apply the saved process-table interval (default 2 s) and keep it in sync
        // with the Settings control live.
        model.setTableInterval(UserDefaults.standard.double(forKey: SamplerModel.tableIntervalKey))
        // The high-resolution logging interval — the raw-tier write frequency,
        // independent of the UI refresh interval. Retention windows/bucket are
        // pulled live inside the maintenance pass, so only the cadence needs wiring.
        model.setHighResInterval(
            UserDefaults.standard.double(forKey: SamplerModel.highResIntervalKey))
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak model] _ in
                model?.setPerAppNetworkTracking(
                    UserDefaults.standard.bool(forKey: SamplerModel.perAppNetworkDefaultsKey))
                model?.setTableInterval(
                    UserDefaults.standard.double(forKey: SamplerModel.tableIntervalKey))
                model?.setHighResInterval(
                    UserDefaults.standard.double(forKey: SamplerModel.highResIntervalKey))
            }
            .store(in: &cancellables)

        // Optional Dock icon (off by default). Opt-in for users whose menu bar is
        // too crowded to see our items. Reads its own state from UserDefaults and
        // stays in sync with the Settings toggle, applying live.
        let dockIconController = DockIconController()
        dockIconController.start()
        self.dockIconController = dockIconController

        // Wire alerting: ask permission once, route fired alerts to notifications,
        // and keep the sampler's alert config in sync with the user's settings.
        alertCenter.setDelegate(self)
        alertCenter.requestAuthorization()
        model.onAlertsFired = { [alertCenter] alerts in alertCenter.deliver(alerts) }
        model.setAlertConfig(alertSettings.config)
        alertSettings.$config
            .sink { [weak model] config in model?.setAlertConfig(config) }
            .store(in: &cancellables)

        // Track the main window's lifecycle so its heavy content is mounted only
        // while it is actually open (keeps the menubar-only idle footprint low).
        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(mainWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(
            self, selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        // Track on-screen visibility (occlusion covers minimize, full cover by
        // other windows, and Space switches) so live animations can pause when
        // the window isn't visible.
        nc.addObserver(
            self, selector: #selector(mainWindowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)

        // Start sampling at launch so the menu bar is live immediately, even
        // before any window is opened.
        model.start()

        // Drive database logging from the app's function mode: full mode logs to
        // the on-disk history store; menu-bar-only mode releases it and stops all
        // writes. The explicit apply matches the store the model already opened at
        // launch (a no-op), and later changes — from Settings, the menu-bar
        // toggle, or the startup wizard — open or close it live.
        model.setPersistenceEnabled(appModeManager.isLoggingEnabled)
        appModeManager.$mode
            .sink { [weak model] mode in model?.setPersistenceEnabled(mode.logsHistory) }
            .store(in: &cancellables)

        // Wire the privileged helper: read its current status, install the
        // reader if the user already enabled it, and arm the one-time prompt
        // otherwise. Approval happens out of process, so the status is also
        // re-read whenever the app reactivates (see applicationDidBecomeActive).
        helperManager.attach(to: model)
        appState.helperPromptPending = helperManager.shouldOfferFirstRunPrompt

        // Before Sparkle installs an update it replaces the app bundle but knows
        // nothing about our root LaunchDaemon. Stop the helper first so the new
        // binary replaces a stopped one and is demand-launched fresh (parity with
        // the pkg installer's preinstall).
        updateController.onWillInstallUpdate = { [weak self] in
            self?.helperManager.stopForUpdate()
        }

        // Offer "open at login" on first run too. If the helper prompt is going
        // to show first, ContentView arms this once that one is dismissed (the
        // two are sequenced so they never present together); otherwise arm it now.
        loginItemManager.refresh()
        if !appState.helperPromptPending {
            appState.loginItemPromptPending = loginItemManager.shouldOfferFirstRunPrompt
        }

        // Pull the latest signed catalogs (diagnostic checks + the process glossary)
        // so the deep dive and detail view show the freshest data; both fall back to
        // their bundled copy on any failure.
        CheckCatalogStore.shared.refreshInBackground()
        ProcessGlossaryStore.shared.refreshInBackground()

        // On first ever launch, surface the education flow so the menubar-first
        // app still teaches its core idea even though no window opens
        // automatically. Deferred so the menubar scene (which holds the
        // `openWindow` action) is mounted and listening before the post.
        // First run — or first run after updating to a build with the setup
        // wizard — surface the wizard. New users get the education screens plus
        // the config steps; users who already saw the education get the config
        // steps only. Deferred so the menubar scene (which holds the `openWindow`
        // action) is mounted and listening before the post.
        if !onboarding.hasCompletedSetup {
            onboarding.autoConfigOnly = onboarding.hasCompleted
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .macperfmonitorShowOnboarding, object: nil)
            }
        }

        // Check for updates on every cold start (silent unless one is available),
        // and again whenever the Mac wakes — a menubar app can stay running across
        // many sleep/wake cycles, so wake is the practical "new session" moment.
        // The 24-hour periodic check is handled by Sparkle's own scheduler
        // (SUEnableAutomaticChecks + SUScheduledCheckInterval in Info.plist).
        DispatchQueue.main.async { [updateController] in
            updateController.checkInBackground()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// The Mac woke from sleep: run a silent update check (no UI unless an update
    /// is found). Coalesced by Sparkle if a check is already in flight.
    @objc private func systemDidWake(_ note: Notification) {
        updateController.checkInBackground()
    }

    /// Guards the one-shot quit teardown so the deferred `.terminateNow` reply
    /// (which re-enters this method) doesn't loop.
    private var didTearDownForQuit = false

    /// Remove the menu bar item before the process exits, so macOS 26/27's
    /// `MenuBarAgent` records a deliberate removal and does not demand-relaunch the
    /// app to restore a persisted status item.
    ///
    /// On those releases MenuBarAgent persists menu-bar status items; when a quit
    /// app just lets its item vanish it logs "No server elements for status item"
    /// and bootstraps the owner again ("launch job demand") — the app comes
    /// straight back and can't be quit (confirmed on 27.0 26A5353q; macOS 25 and
    /// earlier just drop the item). The combined item is an AppKit `NSStatusItem`,
    /// so `removeStatusItem` is a clean synchronous deregistration. We defer the
    /// actual termination one brief beat so the removals flush to MenuBarAgent
    /// first; this is safe because — unlike the old `MenuBarExtra` — there is no
    /// SwiftUI scene to reconcile, so nothing loops on the terminate run loop.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if didTearDownForQuit { return .terminateNow }
        didTearDownForQuit = true
        combinedStatusItem?.tearDownForQuit()
        AppLog.ui.notice("quit: menu bar item removed; terminating")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// Stop the per-app network reader's `nettop` on a clean quit. An orphaned
    /// nettop would self-terminate on its next write once our pipe closes, but
    /// stopping it here is tidier and immediate.
    func applicationWillTerminate(_ notification: Notification) {
        model.setPerAppNetworkTracking(false)
    }

    /// One-shot guard so the main window registers exactly one per-process consumer
    /// while open (`didBecomeKey` can fire repeatedly), released on close — and,
    /// with hysteresis, while occluded (minimized, fully covered, other Space):
    /// an occluded window's content is unmounted (`MainWindowGate`), so keeping
    /// the heavy scan and its main-thread rebuilds running for it bought nothing.
    private var mainWindowProcessConsumerActive = false
    /// Pending occlusion release, so a Space flip or brief cover doesn't cycle
    /// the scan on and off.
    private var occlusionReleaseTimer: Timer?

    @objc private func mainWindowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, window.title == AppInfo.displayName else {
            return
        }
        // A key window is, by definition, on screen. Force `mainWindowVisible`
        // true here as a safety net so that even if a host's occlusion
        // notifications are unreliable, the content mounts rather than leaving a
        // blank window (MainWindowGate gates content on visibility).
        MainActor.assumeIsolated {
            appState.mainWindowOpen = true
            appState.mainWindowVisible = true
        }
        // The window's tabs (Processes, Memory, etc.) consume the per-process scan,
        // so keep it running while the window is up — including in menu-bar-only
        // mode, where it is otherwise skipped. Released in `mainWindowWillClose`
        // (and, after a grace period, on occlusion).
        occlusionReleaseTimer?.invalidate()
        occlusionReleaseTimer = nil
        if !mainWindowProcessConsumerActive {
            mainWindowProcessConsumerActive = true
            model.addProcessConsumer()
            // The UI-side publishes idle while nothing consumes them, so refresh
            // immediately rather than showing data as stale as the idle stretch.
            model.requestImmediateTick()
        }
    }

    @objc private func mainWindowOcclusionChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, window.title == AppInfo.displayName else {
            return
        }
        let visible = window.occlusionState.contains(.visible)
        MainActor.assumeIsolated {
            if appState.mainWindowVisible != visible { appState.mainWindowVisible = visible }
            if visible {
                occlusionReleaseTimer?.invalidate()
                occlusionReleaseTimer = nil
                if appState.mainWindowOpen, !mainWindowProcessConsumerActive {
                    mainWindowProcessConsumerActive = true
                    model.addProcessConsumer()
                    // The scan may have idled while occluded; refresh at once so
                    // the re-shown tabs don't sit a full table interval stale.
                    model.requestImmediateTick()
                }
            } else if mainWindowProcessConsumerActive, occlusionReleaseTimer == nil {
                occlusionReleaseTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) {
                    [weak self] _ in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.occlusionReleaseTimer = nil
                        guard !self.appState.mainWindowVisible,
                            self.mainWindowProcessConsumerActive
                        else { return }
                        self.mainWindowProcessConsumerActive = false
                        self.model.removeProcessConsumer()
                    }
                }
            }
        }
    }

    @objc private func mainWindowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        let title = window.title
        if title == AppInfo.displayName {
            MainActor.assumeIsolated {
                appState.mainWindowOpen = false
                occlusionReleaseTimer?.invalidate()
                occlusionReleaseTimer = nil
                MemoryReclaim.runAfterWindowClose()
                if mainWindowProcessConsumerActive {
                    mainWindowProcessConsumerActive = false
                    model.removeProcessConsumer()
                }
            }
        } else if title == AppInfo.onboardingWindowTitle {
            // The one-time onboarding window holds no live model subscription,
            // but reclaim its transient allocations so a mid-session replay from
            // Help doesn't leave a footprint bump behind.
            MainActor.assumeIsolated { MemoryReclaim.runAfterWindowClose() }
        }
    }

    /// "Reopening" (relaunching from Finder/Spotlight/`open`, or clicking the
    /// optional Dock icon when no window is open) should surface the main window
    /// rather than do nothing — the menubar-first app usually has no window up.
    /// The window is opened by the always-present menubar label, which holds the
    /// SwiftUI `openWindow` action.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
        }
        return true
    }

    /// Handle a `.mpmtrace` file opened from Finder (or the `open` command).
    /// Route it to the Analytics tab, opening the main window if the menubar-
    /// first app has none up. `AnalyticsView` decodes and displays it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard
            let url = urls.first(where: {
                $0.pathExtension.lowercased() == ProcessTraceCodec.fileExtension
            })
        else { return }
        appState.pendingTraceURL = url
        NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
    }

    /// Re-read the helper status whenever the app becomes active. Approval is
    /// granted out of process in System Settings, so this is how an enable that
    /// was pending approval becomes live coverage without a relaunch.
    func applicationDidBecomeActive(_ notification: Notification) {
        helperManager.refresh()
        loginItemManager.refresh()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present alert banners even while MacPerfMonitor is frontmost. As a menubar app
    /// it is often the active app, and without this the system would suppress
    /// the banner, so an alert could fire with nothing shown.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle a notification click. Always surface the main window; when the
    /// alert was about a specific process (a leak or per-process ceiling), reveal
    /// that process in the Processes tab's detail inspector rather than merely
    /// bringing the app forward.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let identity = AlertUserInfo.identity(from: userInfo) {
            // Set before opening the window so a freshly mounted Processes tab
            // consumes it on appear.
            appState.navigationTarget = identity
            AppLog.ui.notice(
                "notification click: revealing pid \(identity.pid, privacy: .public)")
        }
        NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
        completionHandler()
    }
}

/// The main window's content gate. When the window is open it shows the full
/// `ContentView`; when closed it collapses to a plain background that holds no
/// reference to the model, so the charts and process table are unmounted and
/// stop re-rendering. This is what keeps MacPerfMonitor inside its memory budget after
/// the window has been opened and closed again.
struct MainWindowGate: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            if appState.mainWindowOpen && appState.mainWindowVisible {
                // Mount the heavy content only while the window is genuinely on
                // screen. When it is minimized, covered, or on another Space,
                // unmount it entirely so the whole view tree stops re-laying-out
                // on every sample (the dominant background CPU cost) and any
                // animations (the energy-flow Canvas) stop — the menu bar is a
                // separate scene and stays live regardless.
                ContentView()
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .frame(minWidth: 860, minHeight: 520)
            }
        }
    }
}

/// An invisible, always-mounted SwiftUI view that carries the menu-bar app's
/// window-opening plumbing.
///
/// The primary menubar item is now an AppKit `NSStatusItem` with no SwiftUI label
/// (see `MemoryStatusItemController`), so the `openWindow`/`openSettings` actions
/// that used to live on the `MenuBarExtra` label need another always-present home.
/// `MemoryStatusItemController` hosts one of these inside its status item button
/// (whose window is live), so the notifications posted by the popovers, the
/// process actions, notification clicks, and reopen keep opening the right window.
struct MenuBarWindowRouter: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .macperfmonitorShowMainWindow)) {
                _ in
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .macperfmonitorShowOnboarding)) {
                _ in
                openWindow(id: WindowID.onboarding)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .macperfmonitorShowSettings)) {
                _ in
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// Rasterises the primary "Pressure" menubar read-out to an `NSImage` for the
/// AppKit-managed status item (`MemoryStatusItemController`). Mirrors
/// `CPUMenuBarImage`/`BatteryMenuBarImage` — a "Pressure" caption over the current
/// pressure percentage, tinted green/orange/red by level — with the same
/// once-per-change caching so an unchanged tick re-renders nothing. Non-template
/// so the tint survives (the menu bar flattens template images to one colour).
@MainActor
enum MemoryMenuBarImage {
    private static var lastRender:
        (percent: Int?, level: PressureLevel, isDark: Bool, image: NSImage)?

    static func image(percent: Int?, level: PressureLevel, isDark: Bool) -> NSImage {
        if let last = lastRender, last.percent == percent, last.level == level,
            last.isDark == isDark
        {
            return last.image
        }
        let image = MenuBarReadoutImage.captionedValue(
            caption: "Pressure", captionColor: MenuBarReadoutImage.captionColor(isDark: isDark),
            value: percent.map { "\($0)%" } ?? "\u{2013}\u{2013}",
            valueColor: NSColor(level.color), widthSample: "100%")
        lastRender = (percent, level, isDark, image)
        return image
    }
}

/// Rasterises the CPU menubar read-out to an `NSImage` for the AppKit-managed
/// status item (`CPUStatusItemController`). Mirrors `MemoryMenuBarImage`'s
/// rendering and the same once-per-change caching, kept separate so the two items
/// never invalidate each other.
@MainActor
enum CPUMenuBarImage {
    private static var lastRender: (percent: Int?, level: CPULevel, isDark: Bool, image: NSImage)?

    static func image(percent: Int?, level: CPULevel, isDark: Bool) -> NSImage {
        if let last = lastRender, last.percent == percent, last.level == level,
            last.isDark == isDark
        {
            return last.image
        }
        let image = MenuBarReadoutImage.captionedValue(
            caption: "CPU", captionColor: MenuBarReadoutImage.captionColor(isDark: isDark),
            value: percent.map { "\($0)%" } ?? "\u{2013}\u{2013}",
            valueColor: NSColor(level.color), widthSample: "100%")
        lastRender = (percent, level, isDark, image)
        return image
    }
}

/// Rasterises the GPU menubar read-out — a "GPU" caption over the utilization
/// percentage, tinted green/orange/red by load — mirroring `CPUMenuBarImage` with
/// the same once-per-change caching.
@MainActor
enum GPUMenuBarImage {
    private static var lastRender: (percent: Int?, level: CPULevel, isDark: Bool, image: NSImage)?

    static func image(percent: Int?, level: CPULevel, isDark: Bool) -> NSImage {
        if let last = lastRender, last.percent == percent, last.level == level,
            last.isDark == isDark
        {
            return last.image
        }
        let image = MenuBarReadoutImage.captionedValue(
            caption: "GPU", captionColor: MenuBarReadoutImage.captionColor(isDark: isDark),
            value: percent.map { "\($0)%" } ?? "\u{2013}\u{2013}",
            valueColor: NSColor(level.color), widthSample: "100%")
        lastRender = (percent, level, isDark, image)
        return image
    }
}

/// Rasterises the battery menubar read-out, mirroring `CPUMenuBarImage` so all
/// three items read as one app: a "Battery" caption over the charge percentage,
/// tinted green/orange/red by charge level. Same once-per-change caching.
@MainActor
enum BatteryMenuBarImage {
    private static var lastRender:
        (percent: Int?, level: BatteryLevel, isDark: Bool, image: NSImage)?

    static func image(percent: Int?, level: BatteryLevel, isDark: Bool) -> NSImage {
        if let last = lastRender, last.percent == percent, last.level == level,
            last.isDark == isDark
        {
            return last.image
        }
        let image = MenuBarReadoutImage.captionedValue(
            caption: "Battery", captionColor: MenuBarReadoutImage.captionColor(isDark: isDark),
            value: percent.map { "\($0)%" } ?? "\u{2013}\u{2013}",
            valueColor: NSColor(level.color), widthSample: "100%")
        lastRender = (percent, level, isDark, image)
        return image
    }
}

/// Rasterises a "Energy / N W" read-out for the menu bar on a Mac with no
/// battery (a desktop), so the item shows the measured whole-machine power draw
/// instead of a charge percentage. Whole watts (no decimal) keeps it from
/// jittering every tick; the width is reserved for the widest realistic value so
/// the item doesn't twitch as the figure changes.
@MainActor
enum EnergyWattsMenuBarImage {
    private static var lastRender: (watts: Int, isDark: Bool, image: NSImage)?

    static func image(watts: Double, isDark: Bool) -> NSImage {
        let rounded = Int(watts.rounded())
        if let last = lastRender, last.watts == rounded, last.isDark == isDark {
            return last.image
        }
        let image = MenuBarReadoutImage.captionedValue(
            caption: "Energy", captionColor: MenuBarReadoutImage.captionColor(isDark: isDark),
            value: "\(rounded) W", valueColor: NSColor(BatteryStyle.consumer), widthSample: "199 W")
        lastRender = (rounded, isDark, image)
        return image
    }
}

/// Rasterises the network menubar read-out: two stacked lines, a download rate
/// (↓) over an upload rate (↑), so the bar shows current throughput AND its
/// direction at a glance. Mirrors `CPUMenuBarImage`'s once-per-change caching;
/// the arrows are tinted by direction and the figures use the adaptive caption
/// colour so they stay legible on a light or dark bar (non-template image).
@MainActor
enum NetworkMenuBarImage {
    private static var lastRender: (down: String, up: String, isDark: Bool, image: NSImage)?

    static func image(downText: String, upText: String, isDark: Bool) -> NSImage {
        if let last = lastRender, last.down == downText, last.up == upText, last.isDark == isDark {
            return last.image
        }
        let image = MenuBarReadoutImage.networkRows(
            down: downText, up: upText,
            color: MenuBarReadoutImage.figureColor(isDark: isDark), widthSample: "999M")
        lastRender = (downText, upText, isDark, image)
        return image
    }
}

extension NSAppearance {
    /// Whether this appearance resolves to a dark menu bar. Read from a status
    /// item's button it tracks the real bar — dark in Dark Mode and under a dark
    /// desktop picture, light otherwise — which is what the rasterised read-outs
    /// key their caption colour on (they are non-template images, so the system
    /// won't invert them for us).
    var isDarkMenuBar: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
