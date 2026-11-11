import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The main window's size limits. The tabs are a segmented control centred in
/// the toolbar (`MainWindowTabPicker`), and the window's only drag handle is
/// the empty toolbar on either side of it. macOS 26's own TabView strip made
/// every tab as wide as the longest title and never shrank, so the window's
/// minimum grew with the language: about 1,100 pt in English, 1,420 pt in
/// French and 2,070 pt in Russian, wider than many screens (#188). The picker
/// shows titles while they fit with room to grab the window on either side,
/// and icons alone below that, so one minimum works in every language.
enum MainWindowSize {
    static let minimumHeight: CGFloat = 520
    static let defaultHeight: CGFloat = 720
    /// The narrowest width every page is designed for, set by the GPU page:
    /// its six headline cards stay on one row (6 x 150 pt cards, 5 x 12 pt
    /// gaps, 20 pt padding each side, and a scroll bar where scroll bars are
    /// always shown), which keeps its process table on the first screenful. The icon picker, traffic lights and trailing buttons
    /// need far less.
    static let minimumWidth: CGFloat = 1020

    /// Room each side of the centred picker: the trailing buttons' ~100 pt
    /// (the traffic lights need less) plus about 40 pt to grab the window.
    static let sideReserve: CGFloat = 100 + 40

    /// The narrowest window that shows the tab titles. A language change
    /// relaunches the app, so measuring once is enough.
    static var labelledWidth: CGFloat {
        (MainWindowTabPicker.labelledWidth + 2 * sideReserve).rounded(.up)
    }

    static func showsTabTitles(windowWidth: CGFloat) -> Bool {
        windowWidth >= labelledWidth
    }

    /// Opens with titles in every shipped language.
    static var defaultWidth: CGFloat { max(1280, labelledWidth + 40) }
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

    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .processes: return "list.bullet.rectangle"
        case .gpu: return "display"
        case .battery: return "bolt.fill"
        case .network: return "network"
        case .diskUsage: return "internaldrive"
        case .hardware: return "macbook"
        case .analytics: return "waveform.path.ecg.rectangle"
        case .insights: return "lightbulb"
        case .groups: return "square.stack.3d.up"
        }
    }
}

/// The main window's tabs, as a segmented control in the toolbar. Titles show
/// while the window is wide enough (`MainWindowSize.showsTabTitles`); below
/// that each segment is its icon, with the title as its tooltip and its
/// VoiceOver label. AppKit's control, because SwiftUI's segmented picker gives
/// every segment the width of the widest title, which is what made the old
/// strip so wide in French and Russian; this one fits each segment to its own.
struct MainWindowTabPicker: NSViewRepresentable {
    @Binding var selection: MainWindowTab
    let showsTitles: Bool

    /// The control's width with titles, measured from the real control.
    static let labelledWidth: CGFloat = {
        let control = NSSegmentedControl()
        configure(control, showsTitles: true)
        return control.fittingSize.width.rounded(.up)
    }()

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityLabel(t("Page"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        if context.coordinator.showsTitles != showsTitles {
            context.coordinator.showsTitles = showsTitles
            Self.configure(control, showsTitles: showsTitles)
            control.invalidateIntrinsicContentSize()
        }
        control.selectedSegment = MainWindowTab.allCases.firstIndex(of: selection) ?? 0
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context
    ) -> CGSize? {
        nsView.fittingSize
    }

    private static func configure(_ control: NSSegmentedControl, showsTitles: Bool) {
        let tabs = MainWindowTab.allCases
        control.segmentCount = tabs.count
        control.trackingMode = .selectOne
        control.segmentDistribution = .fit
        for (index, tab) in tabs.enumerated() {
            if showsTitles {
                control.setImage(nil, forSegment: index)
                control.setLabel(tab.title, forSegment: index)
            } else {
                control.setLabel("", forSegment: index)
                control.setImage(
                    NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title),
                    forSegment: index)
            }
            control.setToolTip(tab.title, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<MainWindowTab>
        var showsTitles: Bool?

        init(selection: Binding<MainWindowTab>) { self.selection = selection }

        @objc func changed(_ sender: NSSegmentedControl) {
            let tabs = MainWindowTab.allCases
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = tabs[sender.selectedSegment]
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

    /// The window's tab, selection and Explorer workspace. Owned by
    /// `MainWindowGate`, which unmounts this view whenever the window is hidden
    /// (another Space, minimized, fully covered), so state kept here as @State
    /// would reset to the Dashboard each time it came back (#189).
    @ObservedObject var session: MainWindowSession

    private var tab: MainWindowTab {
        get { session.tab }
        nonmutating set { session.tab = newValue }
    }
    private var explorer: DataExplorerModel { session.explorer }
    /// The temperature unit, so the pages rebuild in the new unit when it
    /// changes: in Settings, or in System Settings while the app runs. Charts
    /// convert their points as they are built and the Hardware inventory is
    /// captured text, so a page left mounted would mix the two units.
    @AppStorage(TemperatureFormat.defaultsKey) private var temperatureUnit =
        TemperatureUnitChoice.system.rawValue
    @State private var localeRevision = 0

    var body: some View {
        page
            .id("\(temperatureUnit)-\(localeRevision)")
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSLocale.currentLocaleDidChangeNotification)
            ) { _ in
                localeRevision &+= 1
                HardwareExplorerModel.shared.refreshIfCaptured()
            }
            .onChange(of: temperatureUnit) { _, _ in
                HardwareExplorerModel.shared.refreshIfCaptured()
            }
            .frame(minWidth: MainWindowSize.minimumWidth, minHeight: MainWindowSize.minimumHeight)
            .forceQuitConfirmation(target: $appState.pendingForceQuit)
            .processControlHost(request: $appState.pendingProcessControl)
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

    /// Only the selected page is mounted. A page that is not showing would
    /// otherwise keep observing the model and re-render its charts on every
    /// sample, which was once the largest part of the app's own CPU and memory
    /// use. Each page keeps what must outlive a visit in a model or in
    /// `session`.
    @ViewBuilder private var page: some View {
        switch tab {
        case .dashboard: DashboardView()
        case .processes:
            ProcessesTab(
                selection: $session.processSelection,
                didAutoSelect: $session.didAutoSelectProcess)
        case .gpu: GPUView()
        case .battery: BatteryView()
        case .network: NetworkView()
        case .diskUsage: DiskUsageView()
        case .hardware: HardwareView()
        case .analytics:
            AnalyticsView(explorer: explorer, imported: $session.importedTrace)
                .id(session.investigationRevision)
        case .insights: InsightsView()
        case .groups: GroupsView()
        }
    }

    private func consumeExplorerFocus() {
        guard let link = appState.explorerFocus else { return }
        appState.explorerFocus = nil
        session.importedTrace = nil
        session.investigationRevision &+= 1
        for identity in monitor.identities { monitor.remove(identity) }
        for identity in link.processes { monitor.add(identity) }
        explorer.focus(link)
        tab = .analytics
    }

    private func consumeAlertInvestigation() {
        guard let request = appState.alertInvestigation else { return }
        appState.alertInvestigation = nil
        appState.navigationTarget = nil
        session.importedTrace = nil
        session.investigationRevision &+= 1
        for identity in monitor.identities { monitor.remove(identity) }
        for identity in request.identities { monitor.add(identity) }
        explorer.investigate(request)
        tab = .analytics
    }
}

/// What the main window remembers while it stays open. `MainWindowGate` owns
/// it, above the content it unmounts while the window is hidden, so switching
/// Spaces, minimizing or covering the window keeps the tab, the Processes
/// selection and the Explorer workspace. Closing the window releases it, and
/// the next window starts fresh on the Dashboard.
@MainActor
final class MainWindowSession: ObservableObject {
    @Published var tab: MainWindowTab = .dashboard
    /// The Processes tab's selection, kept here so it survives tab switches:
    /// only the selected page is mounted, so @State inside a page resets.
    @Published var processSelection: ProcessIdentity?
    @Published var didAutoSelectProcess = false
    /// Kept here, so switching tabs does not discard an open trace.
    @Published var importedTrace: ImportedTrace?
    let explorer = DataExplorerModel(preferences: .standard)
    @Published var investigationRevision = 0
}

/// The Processes tab: the M2/M3 system header above the live process list, with
/// a detail inspector for the selected row (PRD section 8.3 → 8.4).
struct ProcessesTab: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState
    @Binding var selection: ProcessIdentity?

    @AppStorage(ProcessListLayout.storageKey) private var layout = ProcessListLayout.initial

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
            if let selection, selection.isAppGroup {
                AppGroupDetailView(identity: selection, selection: $selection)
            } else if let selection {
                ProcessDetailView(identity: selection)
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
    /// process (the top row under the default footprint sort; the largest app
    /// in the Apps layout) so the user lands on something useful instead of an
    /// empty inspector. Runs once, never overrides an explicit selection or a
    /// notification's navigation target, and defers until the first sample
    /// carrying processes has arrived.
    private func autoSelectTopProcessIfNeeded() {
        guard !didAutoSelect,
            selection == nil,
            appState.navigationTarget == nil,
            let processes = model.latest?.processes,
            let top = processes.max(by: { $0.physFootprint < $1.physFootprint })
        else { return }
        didAutoSelect = true
        selection = top.id
        guard layout == .apps else { return }
        let (groups, _) = AppGrouping.group(processes)
        if let app = groups.max(by: { $0.total.physFootprint < $1.total.physFootprint }),
            app.total.physFootprint > top.physFootprint
        {
            selection = app.identity
        }
    }
}
