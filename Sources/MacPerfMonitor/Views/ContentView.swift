import MacPerfMonitorCore
import SwiftUI

/// The main window's four tabs: Dashboard (pressure timeline, taxonomy, swap,
/// verdict), Processes (the live, sortable process list with a system header),
/// Analytics (the Performance-Monitor overlay chart), and Insights (cross-window
/// leak, top-consumer, pressure, and Rosetta analysis).
struct ContentView: View {
    // Note: this view deliberately does NOT observe SamplerModel. The tab host
    // only needs appState (navigation) and helper (coverage prompt). Observing
    // the sampler here would re-execute this whole body — rebuilding the TabView
    // and its four `.tabItem` labels, and re-instantiating every child view and
    // its observation bridge — on every 2-second sample. That re-render storm
    // was the cause of unbounded memory growth (hundreds of MB over hours). The
    // child views observe the sampler themselves, so live data still flows.
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var helper: HelperManager
    @EnvironmentObject private var loginItem: LoginItemManager

    private enum Tab: Hashable {
        case dashboard, processes, battery, network, analytics, insights, groups
    }
    @State private var tab: Tab = .dashboard

    /// The Processes tab's selection, hoisted here so it survives tab switches:
    /// `TabGate` unmounts an inactive tab's content entirely, which would reset
    /// any @State held inside the tab.
    @State private var processSelection: ProcessIdentity?
    @State private var didAutoSelectProcess = false
    /// Lives above `TabGate`, so switching tabs does not discard an open trace.
    /// Closing the main window still unmounts `ContentView` and releases it.
    @State private var importedTrace: ImportedTrace?

    var body: some View {
        TabView(selection: $tab) {
            TabGate(isActive: tab == .dashboard) { DashboardView() }
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.50percent") }
                .tag(Tab.dashboard)

            TabGate(isActive: tab == .processes) {
                ProcessesTab(selection: $processSelection, didAutoSelect: $didAutoSelectProcess)
            }
            .tabItem { Label("Processes", systemImage: "list.bullet.rectangle") }
            .tag(Tab.processes)

            TabGate(isActive: tab == .battery) { BatteryView() }
                .tabItem { Label("Energy", systemImage: "bolt.fill") }
                .tag(Tab.battery)

            TabGate(isActive: tab == .network) { NetworkView() }
                .tabItem { Label("Network", systemImage: "network") }
                .tag(Tab.network)

            TabGate(isActive: tab == .analytics) {
                AnalyticsView(imported: $importedTrace)
            }
            .tabItem { Label("Analytics", systemImage: "chart.xyaxis.line") }
            .tag(Tab.analytics)

            TabGate(isActive: tab == .insights) { InsightsView() }
                .tabItem { Label("Insights", systemImage: "lightbulb") }
                .tag(Tab.insights)

            TabGate(isActive: tab == .groups) { GroupsView() }
                .tabItem { Label("Groups", systemImage: "square.stack.3d.up") }
                .tag(Tab.groups)
        }
        .frame(minWidth: 860, minHeight: 520)
        // A global refresh-rate control in the toolbar, so it is reachable from
        // every tab and changing it applies app-wide. Self-contained (@AppStorage),
        // so it does not pull SamplerModel observation into this tab host.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                RefreshIntervalControl()
            }
        }
        .forceQuitConfirmation(target: $appState.pendingForceQuit)
        .sheet(item: $appState.codesignTarget) { target in
            CodesignSheet(target: target)
        }
        .alert("See every process?", isPresented: $appState.helperPromptPending) {
            Button("Enable Full Coverage") { helper.enable() }
            Button("Not Now", role: .cancel) { helper.declineFirstRunPrompt() }
        } message: {
            Text(
                "\(AppInfo.displayName) can install a small privileged helper so it can read the memory of system and other-user processes, such as WindowServer, that it otherwise cannot see. The helper runs only to read memory statistics and sends nothing off your Mac. You can change this any time in Settings."
            )
        }
        .alert("Open at login?", isPresented: $appState.loginItemPromptPending) {
            Button("Open at Login") { loginItem.enable() }
            Button("Not Now", role: .cancel) { loginItem.declineFirstRunPrompt() }
        } message: {
            Text(
                "\(AppInfo.displayName) lives in the menu bar and keeps a running history of your Mac's memory, CPU and battery. Opening it at login keeps that history unbroken, watching from the moment you sign in. You can change this any time in Settings."
            )
        }
        .onChange(of: appState.helperPromptPending) { _, pending in
            // The helper and login prompts are both armed on first run; show them
            // one at a time. Once the helper prompt is dismissed, offer login.
            if !pending && loginItem.shouldOfferFirstRunPrompt {
                appState.loginItemPromptPending = true
            }
        }
        .onAppear {
            AppLog.ui.notice("ContentView appeared")
            // A notification click may have set a target before this mounted.
            if appState.navigationTarget != nil { tab = .processes }
            // A Finder-opened trace routes to the Analytics tab.
            if appState.pendingTraceURL != nil { tab = .analytics }
            if appState.showBatteryTab {
                tab = .battery
                appState.showBatteryTab = false
            }
            if appState.showNetworkTab {
                tab = .network
                appState.showNetworkTab = false
            }
        }
        .onChange(of: appState.navigationTarget) { _, newValue in
            if newValue != nil { tab = .processes }
        }
        .onChange(of: appState.showBatteryTab) { _, requested in
            if requested {
                tab = .battery
                appState.showBatteryTab = false
            }
        }
        .onChange(of: appState.showNetworkTab) { _, requested in
            if requested {
                tab = .network
                appState.showNetworkTab = false
            }
        }
        .onChange(of: appState.pendingTraceURL) { _, url in
            if url != nil { tab = .analytics }
        }
    }
}

/// Mounts a tab's content only while that tab is selected. macOS's TabView
/// builds every tab's view tree up front and keeps it alive, so without this
/// gate all four tabs' charts re-render — and their reload timers keep firing —
/// on every 2-second sample even while invisible, which was the largest single
/// contributor to the app's own memory footprint (chart layer backing) and CPU.
private struct TabGate<Content: View>: View {
    let isActive: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isActive {
            content()
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// The Processes tab: the M2/M3 system header above the live process list, with
/// a detail inspector for the selected row (PRD section 8.3 → 8.4).
private struct ProcessesTab: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState
    @Binding var selection: ProcessIdentity?

    /// True once the tab has opened its initial selection, so the one-time
    /// auto-expand of the top process happens only on the first visit and never
    /// re-pops the inspector the user has since closed.
    @Binding var didAutoSelect: Bool

    var body: some View {
        // A fixed two-column layout, not SwiftUI's `.inspector`: the inspector is
        // a window-level trailing column, so showing/hiding it grew the window and
        // shifted the centred TabView tab bar (no other tab does that). Here the
        // detail is a fixed-width card *inside* the tab, so selecting a process
        // never changes the window width or moves the tabs — it just swaps the
        // card's content.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SystemHeaderView(snapshot: model.latest)
                Divider()
                ProcessListView(processes: model.displayProcesses, selection: $selection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            detailCard
                .frame(width: 360)
                .padding(12)
        }
        .onAppear {
            consumeNavigationTarget()
            autoSelectTopProcessIfNeeded()
        }
        .onChange(of: appState.navigationTarget) { _, _ in consumeNavigationTarget() }
        .onChange(of: model.latest?.processes.count) { _, _ in autoSelectTopProcessIfNeeded() }
    }

    /// The selected process's detail, presented as a bordered card matching the
    /// Dashboard/Battery panels. Always present (a placeholder when nothing is
    /// selected) so the column reserves a constant width and the layout never
    /// reflows on selection.
    private var detailCard: some View {
        Group {
            if let selection {
                ProcessDetailView(identity: selection)
                    .id(selection)
            } else {
                ContentUnavailableView(
                    "No process selected",
                    systemImage: "cpu",
                    description: Text("Select a process to see its history and details.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Reveal the process a notification click asked for: select it (which opens
    /// the detail inspector) and clear the pending target so it fires once.
    private func consumeNavigationTarget() {
        guard let target = appState.navigationTarget else { return }
        selection = target
        didAutoSelect = true
        appState.navigationTarget = nil
    }

    /// On the tab's first visit, open the detail inspector for the largest
    /// process (the top row under the default footprint sort) so the user lands
    /// on something useful instead of an empty inspector. Runs once, never
    /// overrides an explicit selection or a notification's navigation target,
    /// and defers until the first sample carrying processes has arrived.
    private func autoSelectTopProcessIfNeeded() {
        guard !didAutoSelect,
            selection == nil,
            appState.navigationTarget == nil,
            let top = model.latest?.processes.max(by: { $0.physFootprint < $1.physFootprint })
        else { return }
        didAutoSelect = true
        selection = top.id
    }
}
