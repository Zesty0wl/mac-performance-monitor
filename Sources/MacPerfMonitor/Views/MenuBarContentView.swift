import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The menubar dropdown panel (window style): a pressure summary with a live
/// sparkline, the top ten processes by footprint, and the standard actions.
struct MenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var updateController: UpdateController
    @EnvironmentObject private var menuClock: MenuClock
    @EnvironmentObject private var appMode: AppModeManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var embedded = false

    var body: some View {
        // Re-render once a second while the menu is open (and not at all while
        // closed), so the live read-outs tick at 1 Hz independently of the main
        // window's refresh rate. Depend on the clock's tick explicitly; refcount it
        // open/closed from this view's lifecycle.
        _ = menuClock.tick
        return
            panel
            .background(MenuBarDismissOnResignKey())
            .onAppear { if !embedded { menuClock.open() } }
            .onDisappear { if !embedded { menuClock.close() } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            topProcesses
            if !embedded {
                Divider()
                actions
                MenuVersionFooter()
            }
        }
        .padding(embedded ? 0 : 12)
        .frame(width: embedded ? nil : 380)
    }

    // MARK: - Header

    private var header: some View {
        let system = model.liveSystem
        let level = system?.pressureLevel ?? .normal
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: level.symbolName)
                    .foregroundStyle(level.color)
                Text(level.label)
                    .font(.headline)
                    .foregroundStyle(level.color)
                Spacer()
                if let percent = system?.pressurePercent {
                    Text("\(Int(percent.rounded()))%")
                        .font(.headline.monospacedDigit())
                }
            }

            MenuTrendChart(
                values: model.systemHistory.elements().map(\.pressurePercent), color: level.color,
                domain: 0...100, ticks: [0, 50, 100], label: { "\(Int($0))" }
            )
            .frame(height: MenuChart.height)

            if let system {
                HStack {
                    Text("\(ByteFormat.string(usedBytes(system))) used")
                    Spacer()
                    Text("\(ByteFormat.string(system.totalRAM)) total")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Activity Monitor's "Memory Used": app memory plus wired plus compressed.
    /// Cached files are reclaimable and excluded.
    private func usedBytes(_ system: SystemSample) -> UInt64 {
        system.appMemory &+ system.wired &+ system.compressed
    }

    // MARK: - Top processes

    private var topProcesses: some View {
        let top = menuLists.topFootprint
        return VStack(alignment: .leading, spacing: 0) {
            Text("Top memory")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if top.isEmpty {
                Text("Sampling…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(top) { process in
                    MenuProcessRow(
                        process: process,
                        trail: model.trail(for: process.id),
                        isLeaking: model.leakingProcessIDs.contains(process.id)
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 2) {
            MenuActionButton(title: "Open \(AppInfo.displayName)", systemImage: "macwindow") {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }

            // Quick switch between the two function modes without opening Settings.
            // Full logs samples to the on-disk history; menu-bar-only stops all
            // writes and keeps just the live read-outs.
            MenuActionButton(
                title: appMode.mode == .full
                    ? "Pause history logging" : "Resume history logging",
                systemImage: appMode.mode == .full ? "pause.circle" : "record.circle"
            ) {
                appMode.mode = appMode.mode == .full ? .menuBarOnly : .full
            }

            // A plain SettingsLink does not reliably surface the Settings window
            // from an accessory (LSUIElement) menubar app: the window can open
            // behind everything while the app stays unactivated, so the click
            // looks like it does nothing. Open settings programmatically and
            // activate the app so the window comes to the front.
            MenuActionButton(title: "Settings…", systemImage: "gearshape") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }

            MenuActionButton(
                title: "How \(AppInfo.displayName) works\u{2026}",
                systemImage: "questionmark.circle"
            ) {
                openWindow(id: WindowID.onboarding)
                NSApp.activate(ignoringOtherApps: true)
            }

            MenuActionButton(title: "About \(AppInfo.displayName)", systemImage: "info.circle") {
                showStandardAboutPanel()
            }

            MenuActionButton(title: "Check for Updates\u{2026}", systemImage: "arrow.down.circle") {
                updateController.checkForUpdates()
                NSApp.activate(ignoringOtherApps: true)
            }
            .disabled(!updateController.canCheckForUpdates)

            MenuActionButton(title: "Quit \(AppInfo.displayName)", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }
}

/// One row in the top-memory list: icon, name, trend sparkline, footprint, and
/// an always-visible actions menu (the menubar panel can't rely on right-click).
/// A single click anywhere on the row opens the process in the main window; the
/// ellipsis menu and right-click still carry Reveal and Force Quit.
struct MenuProcessRow: View {
    let process: ProcessSample
    let trail: [Double]
    var isLeaking = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            // Let the name group take all the free width so long names use the
            // space instead of truncating early next to a wide empty gap. Use
            // displayName, not name: the kernel's p_comm is capped at 16 chars,
            // so names like "wdavdaemon_unprivileged" or "Code Helper (Renderer)"
            // arrive pre-truncated and displayName recovers the full name from
            // the executable path. The trailing sparkline/value/menu keep their
            // intrinsic widths and stay aligned on the right edge.
            HStack(spacing: 4) {
                Text(process.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isLeaking {
                    LeakIndicator()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Sparkline(values: trail)
                .tint(.secondary)
                .frame(width: 34, height: 14)
            Text(ByteFormat.string(process.physFootprint))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            ProcessRowMenuButton(identity: process.id, bringWindowForward: true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.accentColor.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens this process in the main window")
        .processRowActions(identity: process.id, bringWindowForward: true, openOnSingleTap: true)
    }

    private var accessibilityLabel: String {
        let base = "\(process.displayName), \(ByteFormat.string(process.physFootprint))"
        return isLeaking ? "\(base), possible memory leak" : base
    }
}

/// The app version + build, shown centred at the bottom of every menu-bar
/// dropdown. Reads CFBundleShortVersionString / CFBundleVersion via `AppInfo`.
struct MenuVersionFooter: View {
    var body: some View {
        Text("\(AppInfo.displayName) \(AppInfo.version) (\(AppInfo.build))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel("Version \(AppInfo.version), build \(AppInfo.build)")
    }
}

/// Show the standard macOS About panel — app name + icon, "Version X (build)"
/// from Info.plist, and the copyright line. Activates the app first so the panel
/// comes to the front from a menu-bar popover (an accessory app isn't frontmost).
@MainActor func showStandardAboutPanel() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [:])
}

/// A full-width, hover-highlighted menu action button.
struct MenuActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuActionButtonStyle())
    }
}

struct MenuActionButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.accentColor.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Closes the memory MenuBarExtra's `.window` panel when it stops being the key
/// window — the user clicked another menu-bar item, a window, or the desktop.
/// SwiftUI's `.window`-style `MenuBarExtra` does not dismiss itself when the click
/// lands on another status item (the CPU/Energy/Network items, which are AppKit
/// popovers), so without this the pressure panel would stay open. Ordering the
/// panel out matches what SwiftUI itself does when the label is toggled closed, so
/// the next click on the label reopens it normally.
private struct MenuBarDismissOnResignKey: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if context.coordinator.window == nil {
            DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private(set) weak var window: NSWindow?
        private var token: NSObjectProtocol?

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            if let token { NotificationCenter.default.removeObserver(token) }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak window] _ in
                window?.orderOut(nil)
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
