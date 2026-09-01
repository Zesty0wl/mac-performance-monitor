import AppKit
import Darwin
import MacPerfMonitorCore
import SwiftUI
import os.log

/// Shared actions for any row that shows a process: reveal its executable in
/// Finder and force quit it with `kill -9`. Killing is gated on a *live* sample
/// match (pid plus start time) by the callers, so a recycled PID can never be
/// the unintended target.
enum ProcessActions {
    /// Reveal a process's executable in Finder. No-op when the path is missing
    /// (for example the kernel) or no longer on disk.
    @discardableResult
    static func revealInFinder(path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    /// The result of a force-quit attempt, so callers can give precise feedback.
    enum KillOutcome: Equatable {
        case success
        /// The OS refused (a system process, or owned by another user / root).
        case notPermitted
        /// The process had already exited; effectively done.
        case alreadyGone
        /// Some other failure, carrying the raw errno.
        case failed(Int32)
    }

    /// Send `SIGKILL` to a pid. MacPerfMonitor runs unsandboxed as the user, so this
    /// works for the user's own processes; system or other-user processes return
    /// `notPermitted`.
    static func forceQuit(pid: Int32) -> KillOutcome {
        guard pid > 1 else { return .notPermitted }
        let result = kill(pid, SIGKILL)
        if result == 0 { return .success }
        switch errno {
        case EPERM: return .notPermitted
        case ESRCH: return .alreadyGone
        default: return .failed(errno)
        }
    }
}

/// The right-click menu shared by every process row. The host supplies the live
/// sample (for the reveal path and to confirm the process is still running) and
/// closures for inspecting its code signature and requesting a force quit, so the
/// same menu drives the table, the monitor legend, the insights cards, and the
/// menubar list. (Opening the detail is no longer a menu item — the table's detail
/// inspector follows the selection, and every surface still opens it on tap.)
struct ProcessActionMenu: View {
    let live: ProcessSample?
    let showCodesign: () -> Void
    let requestKill: () -> Void
    /// Open the standalone Memory Inspector window for this process. Supplied
    /// only by the Processes list (which has the `openWindow` action and the live
    /// uid/name to seed the inspector); when nil the item is omitted so other
    /// surfaces (the menubar) never reach for a window action they can't host.
    var inspectMemory: (() -> Void)? = nil
    /// Open the standalone window listing this process's open files and sockets.
    /// Supplied only by the Processes list (which has `openWindow` and the live
    /// uid/name to seed the window); when nil the item is omitted.
    var openFiles: (() -> Void)? = nil
    /// Open the standalone AI deep-dive window: profile the process and have the
    /// on-device model explain what it's doing. Supplied only by the Processes list;
    /// when nil the item is omitted.
    var deepDive: (() -> Void)? = nil
    /// Pin the process to the Performance Monitor overlay. Supplied only by
    /// surfaces that have the shared selection available (the Processes list);
    /// when nil the item is omitted so other surfaces (the menubar) never need it.
    var addToMonitor: (() -> Void)? = nil
    /// Whether the process is already pinned to Analytics, so the item can read
    /// "In Analytics" and disable itself.
    var isMonitored = false
    /// Whether the Monitor still has a free slot (eight maximum).
    var monitorHasRoom = true
    /// Add this process to an existing custom group (by id). Supplied only by the
    /// Processes list; when nil the "Add to Group" submenu is omitted.
    var addToGroup: ((ProcessGroup.ID) -> Void)? = nil
    /// Create a new custom group seeded with this process. Supplied alongside
    /// `addToGroup` so the submenu is useful even before any custom group exists.
    var newGroupFromProcess: (() -> Void)? = nil
    /// The custom groups offered as "add to" targets.
    var groupTargets: [ProcessGroup] = []

    private var revealPath: String? {
        guard let path = live?.executablePath, !path.isEmpty else { return nil }
        return path
    }

    var body: some View {
        Button(action: showCodesign) {
            Label("Codesign\u{2026}", systemImage: "checkmark.seal")
        }
        .disabled(revealPath == nil)
        .help(
            "Inspect this binary's code signature, CDHash, Team/Signing ID and app.settings rule.")

        Button {
            ProcessActions.revealInFinder(path: revealPath)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .disabled(revealPath == nil)

        if let inspectMemory {
            Button(action: inspectMemory) {
                Label("Inspect Memory…", systemImage: "scope")
            }
            .help("Open a heap and footprint breakdown to track down a leak.")
        }

        if let openFiles {
            Button(action: openFiles) {
                Label("Open Files & Sockets…", systemImage: "doc.on.doc")
            }
            .help("List the files, sockets, and pipes this process currently has open.")
        }

        if let deepDive {
            Button(action: deepDive) {
                Label("Deep Dive…", systemImage: "stethoscope")
            }
            .help(
                "Profile this process: status, CPU/memory trends, threads, network endpoints, and open files."
            )
        }

        if let addToMonitor {
            Button(action: addToMonitor) {
                Label(
                    isMonitored ? "In Analytics" : "Add to Analytics",
                    systemImage: "chart.xyaxis.line")
            }
            .disabled(isMonitored || (!monitorHasRoom))
            .help(
                isMonitored
                    ? "Already shown on the Analytics tab."
                    : (monitorHasRoom
                        ? "" : "Remove a process from Analytics first (eight maximum)."))
        }

        if addToGroup != nil || newGroupFromProcess != nil {
            Menu {
                if let addToGroup {
                    ForEach(groupTargets) { group in
                        Button(group.name) { addToGroup(group.id) }
                    }
                }
                if !groupTargets.isEmpty && newGroupFromProcess != nil { Divider() }
                if let newGroupFromProcess {
                    Button("New Group from This\u{2026}", action: newGroupFromProcess)
                }
            } label: {
                Label("Add to Group", systemImage: "square.stack.3d.up")
            }
            .help("Track this process's footprint alongside others as a group.")
        }

        Divider()

        Button(role: .destructive, action: requestKill) {
            Label("Force Quit (kill -9)", systemImage: "xmark.octagon")
        }
        .disabled(live == nil)
    }
}

/// Attaches the standard process-row interactions to any view that displays a
/// process name: double-click to open its detail, and a right-click menu to
/// reveal it in Finder or force quit it. Force quits are routed through
/// `AppState.pendingForceQuit` so a single confirmation (hosted on the main
/// window) handles every surface.
struct ProcessRowActions: ViewModifier {
    let identity: ProcessIdentity
    /// Set for the menubar list, whose rows must first bring the main window
    /// forward before the detail or the kill confirmation can appear.
    var bringWindowForward = false
    /// When true a single click opens the detail. Used by the menubar list,
    /// whose rows are standalone affordances rather than rows of a selectable
    /// table, so a single click should navigate straight there. Tables keep the
    /// default double-click so one click still just selects the row.
    var openOnSingleTap = false

    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: openOnSingleTap ? 1 : 2, perform: openDetail)
            .contextMenu {
                ProcessActionMenu(
                    live: model.currentSample(for: identity),
                    showCodesign: showCodesign,
                    requestKill: requestKill
                )
            }
    }

    private func openDetail() {
        ProcessRowIntent.openDetail(
            identity: identity, appState: appState, bringWindowForward: bringWindowForward)
    }

    private func showCodesign() {
        guard let live = model.currentSample(for: identity) else { return }
        ProcessRowIntent.showCodesign(
            sample: live, appState: appState, bringWindowForward: bringWindowForward)
    }

    private func requestKill() {
        ProcessRowIntent.requestKill(
            identity: identity, appState: appState, bringWindowForward: bringWindowForward)
    }
}

/// The open-detail and force-quit intents shared by the row's right-click menu
/// and any visible affordance (such as the menubar list's per-row menu button),
/// so every surface drives the same single-confirmation kill path.
enum ProcessRowIntent {
    static func openDetail(
        identity: ProcessIdentity, appState: AppState, bringWindowForward: Bool
    ) {
        if bringWindowForward {
            NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
        }
        appState.navigationTarget = identity
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the code-signature sheet for a process's binary. The path/name are
    /// captured now (not looked up later) so the sheet survives the process
    /// exiting. From the menubar the main window is surfaced first, then the sheet
    /// is raised on it.
    static func showCodesign(
        sample: ProcessSample, appState: AppState, bringWindowForward: Bool
    ) {
        guard let path = sample.executablePath, !path.isEmpty else { return }
        let target = CodesignTarget(
            path: path, name: sample.displayName, pid: sample.pid, bundleID: sample.bundleID)
        guard bringWindowForward else {
            appState.codesignTarget = target
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            appState.codesignTarget = target
        }
    }

    static func requestKill(
        identity: ProcessIdentity, appState: AppState, bringWindowForward: Bool
    ) {
        guard bringWindowForward else {
            appState.pendingForceQuit = identity
            return
        }
        // From the menubar: surface the window first, then raise the confirmation
        // on the main window once it is up.
        NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let id = identity
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            appState.pendingForceQuit = id
        }
    }
}

/// A compact, always-visible per-row menu (an ellipsis button) carrying the
/// same actions as the right-click menu. The menubar dropdown is a
/// non-activating panel where SwiftUI's `.contextMenu` is unreliable, so this
/// guarantees Codesign / Reveal / Force Quit are always reachable there.
struct ProcessRowMenuButton: View {
    let identity: ProcessIdentity
    var bringWindowForward = false

    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Menu {
            ProcessActionMenu(
                live: model.currentSample(for: identity),
                showCodesign: {
                    guard let live = model.currentSample(for: identity) else { return }
                    ProcessRowIntent.showCodesign(
                        sample: live, appState: appState,
                        bringWindowForward: bringWindowForward)
                },
                requestKill: {
                    ProcessRowIntent.requestKill(
                        identity: identity, appState: appState,
                        bringWindowForward: bringWindowForward)
                }
            )
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions for this process")
        .accessibilityLabel("Process actions")
    }
}

extension View {
    /// Open the process detail (double-click by default, or single-click when
    /// `openOnSingleTap` is set for the menubar), plus a right-click menu to
    /// reveal in Finder or force quit. Use `bringWindowForward` for menubar rows.
    func processRowActions(
        identity: ProcessIdentity, bringWindowForward: Bool = false,
        openOnSingleTap: Bool = false
    ) -> some View {
        modifier(
            ProcessRowActions(
                identity: identity, bringWindowForward: bringWindowForward,
                openOnSingleTap: openOnSingleTap))
    }
}

/// Hosts the single force-quit confirmation for the whole app, driven by a
/// pending identity. Kept on the main window so every surface (table, monitor,
/// insights, and the menubar via the window) shares one consistent, safe
/// confirm-then-kill path with clear failure feedback.
struct ForceQuitConfirmation: ViewModifier {
    @Binding var target: ProcessIdentity?
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var helper: HelperManager
    @State private var failureMessage: String?

    private var confirming: Binding<Bool> {
        Binding(get: { target != nil }, set: { if !$0 { target = nil } })
    }

    private var showingFailure: Binding<Bool> {
        Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })
    }

    private var targetName: String {
        guard let target else { return t("this process") }
        return model.currentSample(for: target)?.displayName ?? "PID \(target.pid)"
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                t("Force quit %@?", targetName),
                isPresented: confirming,
                titleVisibility: .visible
            ) {
                Button("Force Quit", role: .destructive, action: performKill)
                Button("Cancel", role: .cancel) { target = nil }
            } message: {
                Text(
                    t(
                        "This sends SIGKILL (kill -9). The process stops at once "
                            + "without saving, so any unsaved work is lost."))
            }
            .alert("Couldn\u{2019}t force quit", isPresented: showingFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
    }

    private func performKill() {
        guard let identity = target else { return }
        let pid = identity.pid
        let name = targetName
        // Capture the last live sample now, before the kill lands, so the list
        // can keep drawing the row greyed out after the process leaves the
        // snapshot.
        let lastSample = model.currentSample(for: identity)
        self.target = nil

        // Defer to the next runloop tick so the confirmation dialog has fully
        // dismissed before we may present the failure alert. SwiftUI swallows an
        // alert presented in the same tick that a confirmation dialog is
        // dismissing, which made a denied kill (the common case for a process the
        // user does not own) fail silently with no feedback at all.
        DispatchQueue.main.async {
            switch ProcessActions.forceQuit(pid: pid) {
            case .success, .alreadyGone:
                self.model.markTerminated(identity, lastSample: lastSample)
                AppLog.ui.notice("force-quit pid \(pid, privacy: .public)")
            case .notPermitted:
                self.escalateKill(pid: pid, name: name, identity: identity, lastSample: lastSample)
            case .failed(let code):
                self.failureMessage =
                    t("\u{201C}%1$@\u{201D} could not be stopped (error %2$d).", name, code)
            }
        }
    }

    /// The user-level `kill` was refused, which means a system or other-user
    /// process. If the root helper is active, retry through it (root can stop
    /// almost anything); otherwise explain how to turn it on.
    private func escalateKill(
        pid: Int32, name: String, identity: ProcessIdentity, lastSample: ProcessSample?
    ) {
        guard helper.canEscalate else {
            failureMessage =
                t(
                    "macOS would not let %1$@ stop \u{201C}%2$@\u{201D}. It is likely a "
                        + "system process or owned by another user. Turn on Full Coverage in "
                        + "Settings to stop processes as root.", AppInfo.displayName, name)
            return
        }
        helper.forceQuit(pid: pid) { outcome in
            switch outcome {
            case .success, .alreadyGone:
                self.model.markTerminated(identity, lastSample: lastSample)
                AppLog.ui.notice("force-quit pid \(pid, privacy: .public) via helper")
            case .notPermitted:
                self.failureMessage =
                    t("Even with Full Coverage, macOS would not stop \u{201C}%@\u{201D}.", name)
            case .failed(let code):
                self.failureMessage =
                    t(
                        "\u{201C}%1$@\u{201D} could not be stopped through the helper "
                            + "(error %2$d).", name, code)
            }
        }
    }
}

extension View {
    /// Host the app's single force-quit confirmation, driven by `target`.
    func forceQuitConfirmation(target: Binding<ProcessIdentity?>) -> some View {
        modifier(ForceQuitConfirmation(target: target))
    }
}
