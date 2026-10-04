import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The main window's size limits. The window's only drag handle is the empty
/// toolbar beside the tab strip. On macOS 26 and later the strip gives every tab
/// the width of the widest title and never shrinks: about 820 pt in English but
/// about 1,135 pt in French, where "Tableau de bord" sets every segment. When the
/// window is too narrow for the strip, the traffic lights and the trailing
/// buttons, nothing is left to grab and the window cannot be dragged at all,
/// which is how it always opened at the old 980 pt default. So the minimum is
/// measured from the localized titles. A language change relaunches the app, so
/// measuring once is enough.
enum MainWindowSize {
    static let minimumHeight: CGFloat = 520
    static let defaultHeight: CGFloat = 720

    static let minimumWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest =
            MainWindowTab.allCases.map {
                ($0.title as NSString).size(withAttributes: [.font: font]).width
            }.max() ?? 0
        // Each segment is its title plus about 16 pt; the strip is centred, so
        // each side needs the trailing buttons' ~100 pt plus room to grab.
        let strip = CGFloat(MainWindowTab.allCases.count) * (widest + 16) + 4
        return max(860, (strip + 2 * (100 + 40)).rounded(.up))
    }()

    static var defaultWidth: CGFloat { max(1280, minimumWidth + 100) }
}

enum MainWindowTab: Hashable, CaseIterable {
    case dashboard, processes, gpu, battery, network, diskUsage, hardware
    case analytics, insights, groups

    var title: String {
        switch self {
        case .dashboard: return t("Dashboard")
        case .processes: return t("Processes")
        case .gpu: return t("GPU")
        case .battery: return t("Energy")
        case .network: return t("Network")
        case .diskUsage: return t("Disk")
        case .hardware: return t("Hardware")
        case .analytics: return t("Explorer")
        case .insights: return t("Insights")
        case .groups: return t("Groups")
        }
    }
}

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
    @EnvironmentObject private var monitor: MonitorSelection

    @State private var navigation = TabNavigation()
    /// The selected tab. Every assignment bumps `navigation.generation`, which
    /// `TabGate` needs to tell a re-selected tab from one it has just hidden.
    private var tab: MainWindowTab {
        get { navigation.tab }
        nonmutating set { navigation.tab = newValue }
    }

    /// The Processes tab's selection, hoisted here so it survives tab switches:
    /// `TabGate` unmounts an inactive tab's content entirely, which would reset
    /// any @State held inside the tab.
    @State private var processSelection: ProcessIdentity?
    @State private var didAutoSelectProcess = false
    /// Lives above `TabGate`, so switching tabs does not discard an open trace.
    /// Closing the main window still unmounts `ContentView` and releases it.
    @State private var importedTrace: ImportedTrace?
    @State private var explorer = DataExplorerModel(preferences: .standard)
    @State private var investigationRevision = 0
    /// The temperature unit, so the pages rebuild in the new unit when it
    /// changes: in Settings, or in System Settings while the app runs. Charts
    /// convert their points as they are built and the Hardware inventory is
    /// captured text, so a page left mounted would mix the two units.
    @AppStorage(TemperatureFormat.defaultsKey) private var temperatureUnit =
        TemperatureUnitChoice.system.rawValue
    @State private var localeRevision = 0

    var body: some View {
        TabView(selection: $navigation.tab) {
            TabGate(isActive: tab == .dashboard, generation: navigation.generation) {
                DashboardView()
            }
            .tabItem {
                Label(
                    MainWindowTab.dashboard.title,
                    systemImage: "gauge.with.dots.needle.50percent")
            }
            .tag(MainWindowTab.dashboard)

            TabGate(isActive: tab == .processes, generation: navigation.generation) {
                ProcessesTab(selection: $processSelection, didAutoSelect: $didAutoSelectProcess)
            }
            .tabItem { Label(MainWindowTab.processes.title, systemImage: "list.bullet.rectangle") }
            .tag(MainWindowTab.processes)

            TabGate(isActive: tab == .gpu, generation: navigation.generation) { GPUView() }
                .tabItem { Label(MainWindowTab.gpu.title, systemImage: "display") }
                .tag(MainWindowTab.gpu)

            TabGate(isActive: tab == .battery, generation: navigation.generation) { BatteryView() }
                .tabItem { Label(MainWindowTab.battery.title, systemImage: "bolt.fill") }
                .tag(MainWindowTab.battery)

            TabGate(isActive: tab == .network, generation: navigation.generation) { NetworkView() }
                .tabItem { Label(MainWindowTab.network.title, systemImage: "network") }
                .tag(MainWindowTab.network)

            TabGate(isActive: tab == .diskUsage, generation: navigation.generation) {
                DiskUsageView()
            }
            .tabItem { Label(MainWindowTab.diskUsage.title, systemImage: "internaldrive") }
            .tag(MainWindowTab.diskUsage)

            TabGate(isActive: tab == .hardware, generation: navigation.generation) {
                HardwareView()
            }
            .tabItem { Label(MainWindowTab.hardware.title, systemImage: "macbook") }
            .tag(MainWindowTab.hardware)

            TabGate(isActive: tab == .analytics, generation: navigation.generation) {
                AnalyticsView(explorer: explorer, imported: $importedTrace)
                    .id(investigationRevision)
            }
            .tabItem {
                Label(MainWindowTab.analytics.title, systemImage: "waveform.path.ecg.rectangle")
            }
            .tag(MainWindowTab.analytics)

            TabGate(isActive: tab == .insights, generation: navigation.generation) {
                InsightsView()
            }
            .tabItem { Label(MainWindowTab.insights.title, systemImage: "lightbulb") }
            .tag(MainWindowTab.insights)

            TabGate(isActive: tab == .groups, generation: navigation.generation) { GroupsView() }
                .tabItem { Label(MainWindowTab.groups.title, systemImage: "square.stack.3d.up") }
                .tag(MainWindowTab.groups)
        }
        .id("\(temperatureUnit)-\(localeRevision)")
        .onReceive(
            NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
        ) { _ in
            localeRevision &+= 1
            HardwareExplorerModel.shared.refreshIfCaptured()
        }
        .onChange(of: temperatureUnit) { _, _ in HardwareExplorerModel.shared.refreshIfCaptured() }
        .frame(minWidth: MainWindowSize.minimumWidth, minHeight: MainWindowSize.minimumHeight)
        .forceQuitConfirmation(target: $appState.pendingForceQuit)
        .sheet(item: $appState.codesignTarget) { target in
            CodesignSheet(target: target)
        }
        .alert("See every process?", isPresented: $appState.helperPromptPending) {
            Button("Enable Full Coverage") { helper.enable() }
            Button("Not Now", role: .cancel) { helper.declineFirstRunPrompt() }
        } message: {
            Text(
                t(
                    "%@ can install a small privileged helper so it can read the memory of system and other-user processes, such as WindowServer, that it otherwise cannot see. The helper runs only to read memory statistics and sends nothing off your Mac. You can change this any time in Settings.",
                    AppInfo.displayName)
            )
        }
        .alert("Open at login?", isPresented: $appState.loginItemPromptPending) {
            Button("Open at Login") { loginItem.enable() }
            Button("Not Now", role: .cancel) { loginItem.declineFirstRunPrompt() }
        } message: {
            Text(
                t(
                    "%@ lives in the menu bar and keeps a running history of your Mac's memory, CPU and battery. Opening it at login keeps that history unbroken, watching from the moment you sign in. You can change this any time in Settings.",
                    AppInfo.displayName)
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
            if let requested = appState.requestedMainTab {
                tab = requested
                appState.requestedMainTab = nil
            }
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
            consumeAlertInvestigation()
            consumeExplorerFocus()
        }
        .onChange(of: appState.explorerFocus) { _, _ in consumeExplorerFocus() }
        .onChange(of: appState.navigationTarget) { _, newValue in
            if newValue != nil { tab = .processes }
        }
        .onChange(of: appState.requestedMainTab) { _, requested in
            if let requested {
                tab = requested
                appState.requestedMainTab = nil
            }
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
        .onChange(of: appState.alertInvestigation) { _, _ in consumeAlertInvestigation() }
    }

    private func consumeExplorerFocus() {
        guard let link = appState.explorerFocus else { return }
        appState.explorerFocus = nil
        importedTrace = nil
        investigationRevision &+= 1
        for identity in monitor.identities { monitor.remove(identity) }
        for identity in link.processes { monitor.add(identity) }
        explorer.focus(link)
        tab = .analytics
    }

    private func consumeAlertInvestigation() {
        guard let request = appState.alertInvestigation else { return }
        appState.alertInvestigation = nil
        appState.navigationTarget = nil
        importedTrace = nil
        investigationRevision &+= 1
        for identity in monitor.identities { monitor.remove(identity) }
        for identity in request.identities { monitor.add(identity) }
        explorer.investigate(request)
        tab = .analytics
    }
}

/// The main window's tab selection, plus a counter bumped on every change.
private struct TabNavigation {
    var tab: MainWindowTab = .dashboard {
        didSet { if tab != oldValue { generation &+= 1 } }
    }
    private(set) var generation = 0
}

/// Mounts a tab's content only while that tab is selected. macOS's TabView
/// builds every tab's view tree up front and keeps it alive, so without this
/// gate all four tabs' charts re-render — and their reload timers keep firing —
/// on every 2-second sample even while invisible, which was the largest single
/// contributor to the app's own memory footprint (chart layer backing) and CPU.
///
/// `isActive` alone is not enough on macOS 26 and later: TabView stops
/// applying updates to a tab once it is hidden, so the tab being left never
/// receives `isActive == false` and its page stayed mounted and live (observing
/// the model, feeding its charts, re-evaluating its body every sample) for as
/// long as the window was open. Every visited tab added its cost; a session
/// that had opened Processes, Dashboard and Insights spent about a fifth of the
/// main thread on those pages while another tab was showing. `onDisappear`
/// still reaches the hidden tab and its state change is applied, so the gate
/// also hides its content there. It records the generation it was hidden at,
/// so a later selection (always a newer generation, delivered because the tab
/// is then visible) mounts the content on its first frame with no blank flash.
private struct TabGate<Content: View>: View {
    let isActive: Bool
    let generation: Int
    @ViewBuilder let content: () -> Content
    @State private var hiddenAtGeneration: Int?

    var body: some View {
        ZStack {
            if isActive && hiddenAtGeneration != generation {
                content()
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .onAppear { hiddenAtGeneration = nil }
        .onDisappear { hiddenAtGeneration = generation }
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
