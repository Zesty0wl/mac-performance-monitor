import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

/// The dashboard tab (PRD section 8.2): a page header with the machine's
/// identity and a single time-range control, the headline memory figures, then
/// consistent bordered panels for the memory-pressure timeline, the processor,
/// the live memory composition, and swap. The range control drives every
/// timeline (and the headline cards' trend sparklines); the composition and
/// core grid are live. Suspected leaks are highlighted in the Processes list,
/// not here.
///
/// Architecture: the SwiftUI tree here is static chrome. Every live element,
/// the six timelines, the card values and sparklines, the processor, network
/// and disk read-outs, the core grid and the memory composition, is an AppKit
/// surface that repaints itself from a feed the `DashboardTimelineStore`
/// publishes into on each sampler tick. Nothing in this tree observes the
/// tick, so a 4 Hz update never re-evaluates a SwiftUI body or re-measures
/// the scroll content; it costs exactly the pixels that changed. The page
/// re-renders for range changes, slow ranking refreshes, and user interaction.
struct DashboardView: View {
    @Environment(\.samplerModel) private var model
    @EnvironmentObject private var appState: AppState

    @StoredHistoryWindow("historyRange.dashboard") private var range

    /// `initialRange` lets the chart harness start on a short window, where the
    /// strip charts re-home often enough to be exercised in a minute.
    init(initialRange: HistoryWindow? = nil) {
        _range = StoredHistoryWindow("historyRange.dashboard", initialValue: initialRange)
    }
    @State private var timeline = DashboardTimelineStore()
    @State private var loadedRange: HistoryWindow?
    @State private var topDiskRanking: DashboardRanking?
    @State private var topCPURanking: DashboardRanking?
    @State private var detailSnapshot: DashboardDetailSnapshot?

    private let topology = CPUTopology.current

    /// True while the loaded data isn't for the selected range yet (first load or
    /// a range change still in flight). Drives the chart and card spinners.
    private var awaitingData: Bool { loadedRange != range }

    var body: some View {
        ScrollView {
            // Primary timelines run down the wide main column; the memory
            // composition and swap read-outs sit in the compact stats rail, so
            // the page uses its horizontal space instead of one tall column.
            MainRailLayout {
                pageHeader
                DashboardMetricCards(timeline: timeline, loading: awaitingData)
                pressurePanel
                processorPanel
                networkPanel
                diskPanel
            } rail: {
                coresPanel
                compositionPanel
                swapPanel
                thermalPanel
                topCPUPanel
                topDiskPanel
            }
            .padding(20)
        }
        .onAppear {
            reload()
            // Keep the GPU/SMC read path live while the dashboard is visible
            // so the thermal panel tracks in real time even when recording is
            // off. Balanced by onDisappear; TabGate unmounts hidden tabs.
            model?.addGPUConsumer()
        }
        .onDisappear { model?.removeGPUConsumer() }
        .onChange(of: range) { reload() }
        // Consumer rankings follow the table cadence. Chart history does not
        // reload here: the window grows in place as samples land.
        .onReceive(tableTicks) { _ in
            if appState.mainWindowVisible { reloadTopConsumers() }
        }
        .onReceive(liveTicks) { _ in
            guard let model else { return }
            // Collect even while the window is covered, and only skip the
            // drawing. Stopping the collection left a hole in the line for
            // however long the window was hidden, which the next reload then
            // quietly repaired: a gap on a monitoring chart has to mean "we were
            // not looking", never "you switched apps".
            timeline.append(
                model.liveSystem, cpu: model.smoothedCPU, liveCPU: model.liveCPU,
                networkRates: model.smoothedNetworkRates, diskRates: model.smoothedDiskRates,
                disk: model.latestDisk, publish: appState.mainWindowVisible)
        }
        .onChange(of: appState.mainWindowVisible) { _, visible in if visible { reload() } }
        .sheet(item: $detailSnapshot) { snapshot in
            DashboardDetailSheet(snapshot: snapshot)
        }
    }

    /// The table-cadence signal, as a publisher so the page can react without
    /// observing the model.
    private var tableTicks: AnyPublisher<Int, Never> {
        model?.$displayProcessesVersion.dropFirst().eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
    }

    private var liveTicks: AnyPublisher<Void, Never> {
        model?.liveTick.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }

    // MARK: - Page header

    /// The machine's identity on the left and the shared time-range control on
    /// the right, so the whole page reads as one instrument rather than a stack
    /// of loose charts.
    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(topology.brand)
                    .font(.headline)
                DashboardSystemSubtitle(timeline: timeline, topology: topology)
                DashboardUptime()
                    .padding(.top, 3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("HISTORY")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Picker("Range", selection: $range) {
                    ForEach(HistoryWindow.allCases) { r in Text(r.label).tag(r) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
                .historyRangeGate()
            }
        }
    }

    // MARK: - Panels

    private var pressurePanel: some View {
        DashboardPanel(.pressure, detailEnabled: !awaitingData, detail: { showDetail(.pressure) }) {
            LiveTrendChart(feed: timeline.pressureFeed, scrubbable: true)
                .frame(height: 180)
                .chartReloading(awaitingData)
            DashboardStatisticsNote(timeline: timeline, feed: timeline.pressureFeed)
            DashboardHistoryNote(timeline: timeline, hasHistory: model?.hasHistory ?? false)
        }
    }

    /// Smoothed read-outs so the figures settle; the timeline still plots raw
    /// history (real spikes intact).
    private var processorPanel: some View {
        let hasClusters = topology.efficiencyCoreCount > 0 && topology.performanceCoreCount > 0
        return DashboardPanel(
            .processor, detailEnabled: !awaitingData, detail: { showDetail(.processor) }
        ) {
            LiveTrendChart(feed: timeline.cpuFeed, scrubbable: true)
                .frame(height: 160)
                .chartReloading(awaitingData)
            DashboardStatisticsNote(timeline: timeline, feed: timeline.cpuFeed)

            Divider().opacity(0.5)

            HStack(alignment: .top, spacing: 24) {
                liveStat("Live total", timeline.cpuTotalFeed, .labelColor)
                if hasClusters {
                    liveStat(
                        "Live performance", timeline.cpuPerformanceFeed,
                        NSColor(CoreKind.performance.accent))
                    liveStat(
                        "Live efficiency", timeline.cpuEfficiencyFeed,
                        NSColor(CoreKind.efficiency.accent))
                }
                liveStat("Live load (1 min)", timeline.loadAverageFeed, .labelColor)
                Spacer(minLength: 0)
            }

            dashboardFootnote(
                "Live values are smoothed, not selected-range means. Total CPU is the share of all cores in use, 0-100%. Per-process CPU uses one core as 100%, so multi-threaded work can exceed 100%."
            )
        }
    }

    /// The live per-core utilisation grid, in the rail rather than the Processor
    /// panel: the bars read better in the narrower column, and it keeps the
    /// Processor panel focused on the timeline and the headline read-outs.
    private var coresPanel: some View {
        DashboardPanel(.cores, detail: { showDetail(.cores) }) {
            CoreGridSurface(feed: timeline.coreFeed)
            dashboardFootnote(
                "Live use of each logical core. Hover for its current percentage and core type.")
        }
    }

    private var compositionPanel: some View {
        DashboardPanel(.composition, detail: { showDetail(.composition) }) {
            TaxonomySurface(feed: timeline.taxonomyFeed)
            dashboardFootnote(
                "Current RAM breakdown, not a range average. Hover a segment or legend item for exact values."
            )
        }
    }

    private var networkPanel: some View {
        DashboardPanel(.network, detailEnabled: !awaitingData, detail: { showDetail(.network) }) {
            HStack(spacing: 24) {
                networkStat(
                    "Live download", timeline.downloadFeed, NetworkStyle.download,
                    NetworkStyle.downSymbol)
                networkStat(
                    "Live upload", timeline.uploadFeed, NetworkStyle.upload, NetworkStyle.upSymbol)
                Spacer(minLength: 0)
            }
            LiveTrendChart(feed: timeline.networkFeed, scrubbable: true)
                .frame(height: 150)
                .chartReloading(awaitingData)
            DashboardStatisticsNote(timeline: timeline, feed: timeline.networkFeed)
            dashboardFootnote(
                "Live rates are smoothed, not selected-range means. Traffic covers physical network interfaces. Enable per-app network tracking in Settings to see which apps are responsible."
            )
        }
    }

    private func networkStat(
        _ label: LocalizedStringKey, _ feed: TextFeed, _ tint: Color, _ symbol: String
    )
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
            liveStat(label, feed, NSColor(tint))
        }
    }

    private var swapPanel: some View {
        DashboardPanel(.swap, detailEnabled: !awaitingData, detail: { showDetail(.swap) }) {
            LiveTrendChart(feed: timeline.swapFeed, scrubbable: true)
                .frame(height: 140)
                .chartReloading(awaitingData)
            DashboardStatisticsNote(timeline: timeline, feed: timeline.swapFeed)
            dashboardFootnote(
                "Swap is memory held on disk. A sustained rise alongside pressure matters more than a nonzero balance."
            )
        }
    }

    private var diskPanel: some View {
        DashboardPanel(.disk, detailEnabled: !awaitingData, detail: { showDetail(.disk) }) {
            HStack(spacing: 24) {
                liveStat("Live read", timeline.diskReadFeed, NSColor(DiskStyle.read))
                liveStat("Live write", timeline.diskWriteFeed, NSColor(DiskStyle.write))
                liveStat("Live IOPS", timeline.iopsFeed, .labelColor)
                Spacer(minLength: 0)
            }
            LiveTrendChart(feed: timeline.diskFeed, scrubbable: true)
                .frame(height: 150)
                .chartReloading(awaitingData)
            DashboardStatisticsNote(timeline: timeline, feed: timeline.diskFeed)
            dashboardFootnote(
                "Live throughput is smoothed, not a selected-range mean. Physical traffic covers real internal and external disks; disk images are excluded. IOPS counts operations per second."
            )
        }
    }

    private var topDiskPanel: some View {
        DashboardPanel(
            .topDisk, detailEnabled: topDiskRanking?.range == range,
            detail: { showDetail(.topDisk) }
        ) {
            if topDiskRanking?.range != range {
                ProgressView().controlSize(.small)
            } else if let ranking = topDiskRanking, !ranking.rows.isEmpty {
                ForEach(ranking.rows.prefix(6)) { process in
                    consumerRow(process, value: ByteFormat.rate(process.averageDisk))
                }
            } else {
                Text("No attributed disk activity in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            dashboardFootnote(
                "Mean attributed read + write in the selected range. It may not add up to physical traffic. Open details for up to 20 processes."
            )
        }
    }

    private var topCPUPanel: some View {
        DashboardPanel(
            .topCPU, detailEnabled: topCPURanking?.range == range, detail: { showDetail(.topCPU) }
        ) {
            if topCPURanking?.range != range {
                ProgressView().controlSize(.small)
            } else if let ranking = topCPURanking, !ranking.rows.isEmpty {
                ForEach(ranking.rows.prefix(6)) { process in
                    consumerRow(process, value: String(format: "%.1f%%", process.averageCPU))
                }
            } else {
                Text("No recorded CPU activity in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            dashboardFootnote(
                "Mean CPU in the selected range, as a percent of one core. Multi-threaded work can exceed 100%. Open details for up to 20 processes."
            )
        }
    }

    private func consumerRow(_ process: ProcessConsumer, value: String) -> some View {
        HStack(spacing: 7) {
            Image(
                nsImage: ProcessIconProvider.shared.icon(
                    forPath: process.executablePath)
            )
            .resizable()
            .frame(width: 16, height: 16)
            Text(process.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(t("%1$@: %2$@", process.displayName, value))
    }

    /// Die temperature over the selected range with the current read-outs, the
    /// dashboard-compact sibling of the Energy tab's Thermals section (which
    /// keeps the fan chart and the throttling log).
    private var thermalPanel: some View {
        DashboardPanel(.thermals, detailEnabled: !awaitingData, detail: { showDetail(.thermals) }) {
            LiveTrendChart(feed: timeline.thermalFeed, scrubbable: true)
                .frame(height: 140)
                .chartReloading(awaitingData)
            DashboardStatisticsNote(timeline: timeline, feed: timeline.thermalFeed)
            HStack(alignment: .top, spacing: 12) {
                liveStat(
                    "Live CPU", timeline.cpuTemperatureFeed, NSColor(ThermalStyle.cpu), width: 112)
                liveStat(
                    "Live GPU", timeline.gpuTemperatureFeed, NSColor(ThermalStyle.gpu), width: 112)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 12) {
                liveStat("Live fans", timeline.fanSpeedFeed, .labelColor, width: 112)
                liveStat("Live thermal state", timeline.thermalStateFeed, .labelColor, width: 112)
                Spacer(minLength: 0)
            }
            dashboardFootnote(
                "CPU die is orange; GPU die is red. A gap means an unavailable sensor reading, not zero. macOS reports thermal state separately; missing data is not treated as nominal."
            )
        }
    }

    /// A small uppercase caption over a live figure painted by AppKit.
    private func liveStat(
        _ label: LocalizedStringKey, _ feed: TextFeed, _ tint: NSColor, width: CGFloat = 96
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .textCase(.uppercase)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            LiveText(feed: feed, color: tint)
                .frame(width: width)
        }
    }

    // MARK: - Immutable detail snapshots

    /// Capture at the button action, not when a sheet body happens to run.
    /// Native grids get separate, single-publish feeds; timeline columns keep
    /// their value semantics while the Dashboard continues collecting.
    private func showDetail(_ kind: DashboardDetailKind) {
        if !kind.isCurrentState, !kind.isRanking, awaitingData { return }
        let capturedAt = Date()
        let system = model?.liveSystem
        let cpu = model?.liveCPU ?? model?.smoothedCPU
        let unavailable = t("Unavailable")
        func fact(_ label: String, _ value: String) -> DashboardDetailFact {
            DashboardDetailFact(label: t(label), value: value)
        }
        func number(_ value: Double?, format: String) -> String {
            guard let value, value.isFinite else { return unavailable }
            return String(format: format, value)
        }
        func bytes(_ value: UInt64?) -> String {
            value.map { ByteFormat.string($0) } ?? unavailable
        }
        func usage(_ value: Double?) -> String {
            number(value.map { $0 * 100 }, format: "%.1f%%")
        }

        let content: DashboardDetailSnapshot.Content
        var facts: [DashboardDetailFact] = []
        var dataTimestamp = timeline.window.latest?.date
        switch kind {
        case .pressure:
            content = .trend(timeline.pressureFeed.model)
            facts = [
                fact(
                    "Current pressure index", number(system?.pressurePercent, format: "%.1f / 100")),
                fact("macOS memory pressure", system?.pressureLevel.label ?? unavailable),
                fact("Compressed memory", bytes(system?.compressed)),
                fact("Swap used", bytes(system?.swapUsed)),
            ]
        case .processor:
            content = .trend(timeline.cpuFeed.model)
            facts = [
                fact("Current total CPU (smoothed)", timeline.cpuTotalFeed.text),
                fact("Logical cores", String(topology.logicalCores)),
                fact("Load average, 1 minute", number(cpu?.loadAverage1, format: "%.2f")),
                fact("Load average, 5 minutes", number(cpu?.loadAverage5, format: "%.2f")),
                fact("Load average, 15 minutes", number(cpu?.loadAverage15, format: "%.2f")),
            ]
            if topology.performanceCoreCount > 0 {
                facts.append(fact("Performance CPU (smoothed)", timeline.cpuPerformanceFeed.text))
            }
            if topology.efficiencyCoreCount > 0 {
                facts.append(fact("Efficiency CPU (smoothed)", timeline.cpuEfficiencyFeed.text))
            }
        case .network:
            content = .trend(timeline.networkFeed.model)
            facts = [
                fact("Current download (smoothed)", timeline.downloadFeed.text),
                fact("Current upload (smoothed)", timeline.uploadFeed.text),
                fact(
                    "Download in bytes/s (sample)",
                    number(system?.networkInBytesPerSec, format: "%.1f B/s")),
                fact(
                    "Upload in bytes/s (sample)",
                    number(system?.networkOutBytesPerSec, format: "%.1f B/s")),
            ]
        case .disk:
            content = .trend(timeline.diskFeed.model)
            facts = [
                fact("Current read (smoothed)", timeline.diskReadFeed.text),
                fact("Current write (smoothed)", timeline.diskWriteFeed.text),
                fact("Current IOPS", timeline.iopsFeed.text),
                fact("Read service time", number(system?.diskReadLatencyMs, format: "%.2f ms")),
                fact("Write service time", number(system?.diskWriteLatencyMs, format: "%.2f ms")),
                fact("Busiest device", number(system?.diskUtilizationPercent, format: "%.1f%%")),
            ]
        case .swap:
            content = .trend(timeline.swapFeed.model)
            facts = [
                fact("Swap used", bytes(system?.swapUsed)),
                fact("Allocated swap", bytes(system?.swapTotal)),
                fact("Installed RAM", bytes(system?.totalRAM)),
                fact("macOS memory pressure", system?.pressureLevel.label ?? unavailable),
            ]
        case .thermals:
            content = .trend(timeline.thermalFeed.model)
            dataTimestamp = timeline.thermalPoints.last?.date
            facts = [
                fact("Current CPU die", number(system?.cpuDieC, format: "%.1f°C")),
                fact("Current GPU die", number(system?.gpuDieC, format: "%.1f°C")),
                fact("Current fastest fan", number(system?.fanRPM, format: "%.0f rpm")),
                fact("macOS thermal state", system?.thermalPressure?.label ?? unavailable),
            ]
        case .cores:
            // Read the sampler now, rather than a SwiftUI-captured core array
            // from the most recent range load.
            content = .cores(DashboardCoreSnapshot(cores: cpu?.cores ?? []))
            dataTimestamp = cpu?.timestamp
            facts = [
                fact("Total busy (sample)", usage(cpu?.totalUsage)),
                fact("User (sample)", usage(cpu?.userFraction)),
                fact("System (sample)", usage(cpu?.systemFraction)),
                fact("Idle (sample)", usage(cpu?.idleFraction)),
            ]
        case .composition:
            content = .composition(
                DashboardCompositionSnapshot(
                    slices: system.map { TaxonomyBreakdown.compute($0) } ?? [],
                    total: system?.totalRAM ?? 0))
            dataTimestamp = system?.timestamp
            facts = [
                fact("macOS memory pressure", system?.pressureLevel.label ?? unavailable),
                fact("Swap used (not in RAM stack)", bytes(system?.swapUsed)),
                fact("Raw active memory", bytes(system?.active)),
                fact("Raw inactive memory", bytes(system?.inactive)),
            ]
        case .topCPU, .topDisk:
            guard let ranking = kind == .topCPU ? topCPURanking : topDiskRanking,
                ranking.range == range
            else { return }
            content = .processes(ranking.rows)
            dataTimestamp = ranking.loadedAt
            facts = [
                fact("Processes shown", String(ranking.rows.count)),
                fact("Selected range", range.label),
                fact("Ranking refresh", t("About once a minute")),
            ]
        }
        detailSnapshot = DashboardDetailSnapshot(
            kind: kind, range: range, capturedAt: capturedAt, dataTimestamp: dataTimestamp,
            content: content, facts: facts)
    }

    // MARK: - Loading

    /// Every range loads at its stored resolution. Nothing is folded on the
    /// way in: fixed statistical intervals use the recorded weights and bounds.
    private func reload() {
        guard let model else { return }
        let requested = range
        model.loadSystemHistory(requested) { pts in
            guard self.range == requested else { return }
            self.timeline.replace(
                pts, span: requested.seconds, storedSpacing: Self.storedSpacing(requested),
                live: model.liveSystem, cpu: model.smoothedCPU, liveCPU: model.liveCPU,
                totalRAM: model.liveSystem?.totalRAM ?? model.latest?.system.totalRAM ?? 0)
            self.loadedRange = requested
        }
        reloadTopConsumers(window: requested)
    }

    /// The coarsest spacing the loaded rows legitimately have: nothing beyond
    /// the logging interval for a raw range, the tier's bucket for the rest.
    /// The minute tier's bucket follows the standard-resolution dial.
    private static func storedSpacing(_ window: HistoryWindow) -> TimeInterval {
        var spacing = window.granularity.storedSpacing ?? 0
        if window.granularity == .minute {
            spacing = max(spacing, SamplerModel.configuredStandardResInterval())
        }
        return spacing
    }

    /// The ranking is an aggregation over the whole window's raw rows (at 1 s
    /// logging, about 50 ms of I/O-bound SQLite per run); a ranking over an
    /// hour does not move second to second, so refresh it sparingly.
    @State private var lastTopConsumersReload = Date.distantPast
    private static let topConsumersInterval: TimeInterval = 60

    private func reloadTopConsumers(window: HistoryWindow? = nil) {
        guard let model else { return }
        let requested = window ?? range
        let now = Date()
        if window == nil, now.timeIntervalSince(lastTopConsumersReload) < Self.topConsumersInterval
        {
            return
        }
        lastTopConsumersReload = now
        model.loadTopConsumers(window: requested, metric: .averageDisk, limit: 20) { rows in
            guard self.range == requested else { return }
            self.topDiskRanking = DashboardRanking(range: requested, loadedAt: Date(), rows: rows)
        }
        model.loadTopConsumers(window: requested, metric: .averageCPU, limit: 20) { rows in
            guard self.range == requested else { return }
            self.topCPURanking = DashboardRanking(range: requested, loadedAt: Date(), rows: rows)
        }
    }
}

// MARK: - Shared bits

private struct DashboardRanking {
    let range: HistoryWindow
    let loadedAt: Date
    let rows: [ProcessConsumer]
}

private func dashboardFootnote(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

private func percent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

struct DashboardUptime: View {
    private static let currentBootTime = SystemBootTime.read()
    var bootTime: Date? = DashboardUptime.currentBootTime

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Uptime")
                    .foregroundStyle(.secondary)
                Text(Self.value(since: bootTime, now: context.date))
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            .font(.callout)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .help(
                bootTime.map {
                    t("Last boot") + ": " + $0.formatted(date: .abbreviated, time: .standard)
                } ?? t("Not reported"))
        }
    }

    static func value(since bootTime: Date?, now: Date) -> String {
        guard let bootTime else { return t("Not reported") }
        let elapsed = now.timeIntervalSince(bootTime)
        guard elapsed.isFinite, elapsed >= 0, elapsed < Double(Int.max) else {
            return t("Not reported")
        }
        return HardwareUptime.string(since: bootTime, now: now)
    }
}

// MARK: - Live window and feeds

/// The Dashboard's live window and the feeds its surfaces paint from.
///
/// The window is a `SystemHistoryWindow` (columnar, O(1) append). On every
/// tick the store builds each chart's `TrendModel`, each card's figures and
/// every read-out string and publishes them into feeds; the AppKit surfaces
/// attached to those feeds repaint. The only published properties change on a
/// range load (`rangeVersion`) and once when enough history has accrued.
private final class DashboardTimelineStore: ObservableObject {
    @Published private(set) var rangeVersion = 0
    @Published private(set) var hasEnoughHistory = false
    private(set) var window = SystemHistoryWindow(span: 3600)
    private(set) var memoryScale: MemoryCardScale?
    private(set) var networkYDomain: ClosedRange<Double> = 0...1_024
    private(set) var diskYDomain: ClosedRange<Double> = 0...1_048_576
    private(set) var swapYDomain: ClosedRange<Double> = 0...1_048_576
    private(set) var statisticsInterval = ChartStatistics.interval(span: 3600)
    private(set) var totalRAM: UInt64 = 0
    private var pressureLevel: PressureLevel?
    private var cpuLevel: CPULevel = .light
    private var latestSystem: SystemSample?
    /// Keep optional sensor rows intact. Zero-filled window columns cannot
    /// distinguish an unavailable reading from a measured temperature.
    private(set) var thermalPoints: [SystemHistoryPoint] = []
    private var thermalNeedsRefresh = true

    let pressureFeed = TrendFeed()
    let cpuFeed = TrendFeed()
    let networkFeed = TrendFeed()
    let diskFeed = TrendFeed()
    let swapFeed = TrendFeed()
    let thermalFeed = TrendFeed()
    /// One per memory card, in `MemoryMetrics.cards` order.
    let cardFeeds: [MetricCardFeed] = (0..<6).map { _ in MetricCardFeed() }
    /// The cards' static parts, with their feeds attached. Rebuilt per range.
    private(set) var cardTemplates: [MetricCardData] = []

    let cpuTotalFeed = TextFeed()
    let cpuPerformanceFeed = TextFeed()
    let cpuEfficiencyFeed = TextFeed()
    let loadAverageFeed = TextFeed()
    let downloadFeed = TextFeed()
    let uploadFeed = TextFeed()
    let diskReadFeed = TextFeed("--")
    let diskWriteFeed = TextFeed("--")
    let iopsFeed = TextFeed("--")
    let coreFeed = CoreGridFeed()
    let taxonomyFeed = TaxonomyFeed()
    let cpuTemperatureFeed = TextFeed(t("Unavailable"))
    let gpuTemperatureFeed = TextFeed(t("Unavailable"))
    let fanSpeedFeed = TextFeed(t("Unavailable"))
    let thermalStateFeed = TextFeed(t("Unavailable"))

    var xDomain: ClosedRange<Date>? { window.xDomain }

    func replace(
        _ loaded: [SystemHistoryPoint], span: TimeInterval, storedSpacing: TimeInterval,
        live: SystemSample?, cpu: CPUSample?, liveCPU: CPUSample?, totalRAM: UInt64
    ) {
        window.replace(loaded, span: span)
        thermalPoints = loaded
        thermalNeedsRefresh = true
        latestSystem = live
        pressureLevel = live?.pressureLevel
        if let live {
            window.append(Self.point(from: live))
            appendThermalPoint(live)
        }
        // Freeze the interval for this load. Dropping an old source bucket
        // during live appends must not regroup the whole historical trace.
        let sourceResolution = window.values(.bucketDuration).reduce(0.0) { result, duration in
            duration.isFinite ? max(result, duration) : result
        }
        self.storedSpacing = max(storedSpacing, sourceResolution)
        statisticsInterval = ChartStatistics.interval(span: span, minimum: self.storedSpacing)
        cpuLevel = CPULevel(fraction: cpu?.totalUsage ?? 0)
        self.totalRAM = totalRAM
        memoryScale = MemoryMetrics.scale(window: window, total: totalRAM)
        refreshAutoDomains(reset: true)
        cardTemplates = MemoryMetrics.cards(system: live, window: window, scale: memoryScale)
            .enumerated().map { index, card in
                var template = card
                template.samples = []
                template.live = index < cardFeeds.count ? cardFeeds[index] : nil
                return template
            }
        publishCharts(resetDomains: true)
        publishReadouts(
            cpu: cpu, liveCPU: liveCPU, networkRates: nil, diskRates: nil, disk: nil)
        if window.count >= 2, !hasEnoughHistory { hasEnoughHistory = true }
        rangeVersion &+= 1
    }

    /// Add a sample. `publish` builds the chart models from it, which is the
    /// expensive half and pointless while the window is covered; the sample is
    /// kept either way so the line has no hole in it when the window returns.
    func append(
        _ system: SystemSample?, cpu: CPUSample?, liveCPU: CPUSample?,
        networkRates: (inBytesPerSec: Double, outBytesPerSec: Double)?,
        diskRates: (readBytesPerSec: Double, writeBytesPerSec: Double)?, disk: DiskSample?,
        publish: Bool = true
    ) {
        guard let system, window.append(Self.point(from: system)) else { return }
        latestSystem = system
        pressureLevel = system.pressureLevel
        cpuLevel = CPULevel(fraction: cpu?.totalUsage ?? 0)
        if totalRAM == 0, system.totalRAM > 0 { totalRAM = system.totalRAM }
        appendThermalPoint(system)
        guard publish else { return }
        refreshAutoDomains()
        publishCharts()
        publishReadouts(
            cpu: cpu, liveCPU: liveCPU, networkRates: networkRates, diskRates: diskRates,
            disk: disk)
        if window.count >= 2, !hasEnoughHistory { hasEnoughHistory = true }
    }

    /// A range load gets a fresh axis, including stored extrema. Live axes
    /// only expand when data crosses their current ceiling, avoiding a full
    /// strip repaint every time an old burst leaves the window.
    private func refreshAutoDomains(reset: Bool = false) {
        func peak(_ columns: [SystemHistoryWindow.Column]) -> Double {
            var result = 0.0
            for column in columns {
                for value in window.values(column) where value.isFinite {
                    result = max(result, value)
                }
            }
            return result
        }
        let networkPeak = peak([
            .networkInBytesPerSec, .networkOutBytesPerSec, .networkInPeak, .networkOutPeak,
        ])
        if reset || networkPeak > networkYDomain.upperBound {
            networkYDomain = 0...MenuChart.niceUpperBound(max(networkPeak * 1.25, 1_024))
        }
        let diskPeak = peak([
            .diskReadBytesPerSec, .diskWriteBytesPerSec, .diskReadPeak, .diskWritePeak,
        ])
        if reset || diskPeak > diskYDomain.upperBound {
            diskYDomain = 0...MenuChart.niceUpperBound(max(diskPeak * 1.25, 1_048_576))
        }
        let swapPeak = peak([.swapUsed, .swapUsedPeak])
        if reset || swapPeak > swapYDomain.upperBound {
            swapYDomain = 0...MenuChart.niceUpperBound(max(swapPeak * 1.25, 1_048_576))
        }
    }

    /// Record the thermal cadence even for GPU-only or wholly missing sensor
    /// readings. Explicit nil rows are boundaries, not rows to filter away.
    private func appendThermalPoint(_ live: SystemSample) {
        if let last = thermalPoints.last {
            guard live.timestamp.timeIntervalSince(last.date) >= 4 else { return }
        }
        thermalPoints.append(Self.point(from: live))
        let cutoff = live.timestamp.addingTimeInterval(-window.span)
        let firstInRange = thermalPoints.firstIndex { $0.date >= cutoff } ?? thermalPoints.count
        // Retain one boundary row, including a nil row, at the left edge.
        let removeCount = max(0, firstInRange - 1)
        if removeCount > 0 { thermalPoints.removeFirst(removeCount) }
        thermalNeedsRefresh = true
    }

    /// The spacing of the rows the current range loaded from the database:
    /// zero for a raw range, a minute or an hour for the stored tiers.
    private var storedSpacing: TimeInterval = 0

    /// Stored rows carry their covered duration. The remaining gap tolerance
    /// follows raw recording cadence, even in a window containing hour rows.
    private var gapThreshold: TimeInterval {
        ChartGap.threshold(
            expectedSpacing: max(1, SamplerModel.configuredHighResInterval()))
    }

    /// Build every chart's and card's model from the window and hand it to
    /// its feed.
    private func publishCharts(resetDomains: Bool = false) {
        let domain = window.xDomain
        let gap = gapThreshold
        pressureFeed.publish(
            Self.pressureModel(
                window, domain: domain, level: pressureLevel, gap: gap, interval: statisticsInterval
            ), replacingHistory: resetDomains)
        cpuFeed.publish(
            Self.cpuModel(window, domain: domain, gap: gap, interval: statisticsInterval),
            replacingHistory: resetDomains)
        networkFeed.publish(
            Self.networkModel(
                window, domain: domain, yDomain: networkYDomain, gap: gap,
                interval: statisticsInterval), replacingHistory: resetDomains)
        diskFeed.publish(
            Self.diskModel(
                window, domain: domain, yDomain: diskYDomain, gap: gap, interval: statisticsInterval
            ), replacingHistory: resetDomains)
        swapFeed.publish(
            Self.swapModel(
                window, domain: domain, yDomain: swapYDomain, gap: gap,
                interval: statisticsInterval), replacingHistory: resetDomains)
        var thermal =
            thermalNeedsRefresh
            ? TemperatureChart.statisticsModel(points: thermalPoints, xDomain: domain)
            : thermalFeed.model
        if !resetDomains, let previous = thermalFeed.model.yDomain,
            let measured = thermal.yDomain
        {
            let outside = thermal.series.contains { series in
                [series.column.values, series.column.highs ?? [], series.column.lows ?? []]
                    .contains { $0.contains { $0.isFinite && !previous.contains($0) } }
            }
            thermal.yDomain =
                outside
                ? min(
                    previous.lowerBound, measured.lowerBound)...max(
                        previous.upperBound, measured.upperBound)
                : previous
        }
        thermal.xDomain = domain
        thermal.statisticsInterval = statisticsInterval
        thermal.showsTimeAxis = true
        thermal.plotBorder = true
        for index in thermal.series.indices {
            thermal.series[index].filled = false
            if index == 0 {
                thermal.series[index].name = t("CPU die")
                thermal.series[index].color = ThermalStyle.cpu
            } else if index == 1 {
                thermal.series[index].name = t("GPU die")
                thermal.series[index].color = ThermalStyle.gpu
            }
        }
        thermalFeed.publish(thermal, replacingHistory: resetDomains)
        thermalNeedsRefresh = false
        let cards = MemoryMetrics.cards(
            system: latestSystem, window: window, scale: memoryScale, includeSamples: false)
        for (index, pair) in zip(cardFeeds, cards).enumerated() {
            let (feed, card) = pair
            let tint = index == 0 ? Color.orange : card.tint
            let peaks = card.column?.highs?.filter(\.isFinite)
            let peak = max(peaks?.max() ?? 0, card.column?.range?.max ?? 0)
            let oldCeiling = resetDomains ? 0 : (feed.yDomain?.upperBound ?? 0)
            let ceiling = max(
                card.yDomain?.upperBound ?? 1, oldCeiling, MenuChart.niceUpperBound(peak * 1.1))
            let domainY = index == 0 ? 0...100 : 0...ceiling
            feed.publish(
                value: card.value, tint: NSColor(tint), column: card.column,
                xDomain: domain, yDomain: domainY,
                peak: t("Axis max %@", card.unit.format(domainY.upperBound)),
                statisticsInterval: statisticsInterval, gapThreshold: gap,
                name: t(card.label), format: card.unit.format,
                statisticsNote: index == 1 && storedSpacing > 0
                    ? t(
                        "Free memory is derived from stored category averages. Its historical extrema cannot be recovered from those averages."
                    )
                    : nil, replacingHistory: resetDomains)
        }
    }

    /// The figures around the charts: processor, network and disk read-outs,
    /// the core grid, and the memory composition.
    private func publishReadouts(
        cpu: CPUSample?, liveCPU: CPUSample?,
        networkRates: (inBytesPerSec: Double, outBytesPerSec: Double)?,
        diskRates: (readBytesPerSec: Double, writeBytesPerSec: Double)?, disk: DiskSample?
    ) {
        cpuTotalFeed.publish(
            cpu.map { percent($0.totalUsage) } ?? t("Unavailable"), color: NSColor(cpuLevel.color))
        cpuPerformanceFeed.publish(cpu.map { percent($0.performanceUsage) } ?? t("Unavailable"))
        cpuEfficiencyFeed.publish(cpu.map { percent($0.efficiencyUsage) } ?? t("Unavailable"))
        loadAverageFeed.publish(
            cpu.map { String(format: "%.2f", $0.loadAverage1) } ?? t("Unavailable"))
        // The bars show the sample as measured; the percentages around them
        // stay smoothed, because a jittering number is unreadable and a still
        // core grid is uninformative.
        coreFeed.publish((liveCPU ?? cpu)?.cores ?? [])
        if let networkRates {
            downloadFeed.publish(ByteFormat.rate(networkRates.inBytesPerSec))
            uploadFeed.publish(ByteFormat.rate(networkRates.outBytesPerSec))
        }
        if let diskRates {
            diskReadFeed.publish(ByteFormat.rate(diskRates.readBytesPerSec))
            diskWriteFeed.publish(ByteFormat.rate(diskRates.writeBytesPerSec))
        }
        if let disk {
            iopsFeed.publish(
                "\(Int((disk.readOperationsPerSec + disk.writeOperationsPerSec).rounded()))")
        }
        if let system = latestSystem {
            taxonomyFeed.publish(slices: TaxonomyBreakdown.compute(system), total: system.totalRAM)
        }
        func temperature(_ value: Double?) -> String {
            guard let value, value.isFinite else { return t("Unavailable") }
            return String(format: "%.1f°C", value)
        }
        cpuTemperatureFeed.publish(temperature(latestSystem?.cpuDieC))
        gpuTemperatureFeed.publish(temperature(latestSystem?.gpuDieC))
        if let fan = latestSystem?.fanRPM, fan.isFinite {
            fanSpeedFeed.publish(fan == 0 ? t("Off") : String(format: "%.0f rpm", fan))
        } else {
            fanSpeedFeed.publish(t("Unavailable"))
        }
        thermalStateFeed.publish(
            latestSystem?.thermalPressure?.label ?? t("Unavailable"),
            color: latestSystem?.thermalPressure.map { NSColor($0.color) })
    }

    private static func pressureModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?, level: PressureLevel?,
        gap: TimeInterval, interval: TimeInterval
    ) -> TrendModel {
        let column = LiveColumn(
            window, .pressurePercent, peak: .pressurePercentPeak, minimum: .pressurePercentMinimum)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(
                column: column, color: .orange, filled: false, name: t("Pressure index"))
        ]
        model.xDomain = domain
        model.gapThreshold = gap
        model.statisticsInterval = interval
        model.yDomain = 0...100
        model.yTicks = [0, 34, 67, 100]
        model.detailFormat = { String(format: "%.2f / 100", $0) }
        model.rules = [
            TrendRule(value: 34, label: "Warning", color: .orange),
            TrendRule(value: 67, label: "Critical", color: .red),
        ]
        model.showsTimeAxis = true
        model.plotBorder = true
        model.accessibilityLabel = "Memory pressure timeline"
        if let latest = column.lastValue {
            model.accessibilityValue = t(
                "Latest recorded pressure index %1$@. macOS pressure %2$@. Hover for interval averages and ranges.",
                String(format: "%.1f", latest), level?.label.lowercased() ?? t("Unavailable"))
        } else {
            model.accessibilityValue = "No data yet."
        }
        return model
    }

    private static func cpuModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?,
        gap: TimeInterval, interval: TimeInterval
    ) -> TrendModel {
        let column = LiveColumn(window, .cpuLoad, peak: .cpuLoadPeak, minimum: .cpuLoadMinimum)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: column, scale: 100, color: .green, name: t("Total CPU"))
        ]
        model.xDomain = domain
        model.gapThreshold = gap
        model.statisticsInterval = interval
        model.yDomain = 0...100
        model.yFormat = { String(format: "%.0f%%", $0) }
        model.detailFormat = { String(format: "%.2f%%", $0) }
        model.yTicks = [0, 60, 85, 100]
        model.rules = [
            TrendRule(value: 60, label: "Busy", color: .orange),
            TrendRule(value: 85, label: "Heavy", color: .red),
        ]
        model.showsTimeAxis = true
        model.plotBorder = true
        model.accessibilityLabel = "Total CPU timeline"
        if let latest = column.lastValue {
            model.accessibilityValue = t(
                "Latest recorded total CPU %1$@ percent. Hover for interval averages and ranges.",
                String(format: "%.1f", latest * 100))
        } else {
            model.accessibilityValue = "No data yet."
        }
        return model
    }

    private static func networkModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?, yDomain: ClosedRange<Double>,
        gap: TimeInterval, interval: TimeInterval
    ) -> TrendModel {
        let download = LiveColumn(
            window, .networkInBytesPerSec, peak: .networkInPeak, minimum: .networkInMinimum)
        let upload = LiveColumn(
            window, .networkOutBytesPerSec, peak: .networkOutPeak, minimum: .networkOutMinimum)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: download, color: NetworkStyle.download, name: t("Download")),
            TrendSurfaceSeries(
                column: upload, color: NetworkStyle.upload, filled: false, lineWidth: 1.8,
                name: t("Upload")),
        ]
        model.xDomain = domain
        model.gapThreshold = gap
        model.statisticsInterval = interval
        model.yDomain = yDomain
        model.yFormat = { ByteFormat.rate(max($0, 0)) }
        model.showsTimeAxis = true
        model.plotBorder = true
        model.leftGutter = 56
        model.accessibilityLabel = "Network throughput trend"
        if let latestIn = download.lastValue, let latestOut = upload.lastValue {
            model.accessibilityValue = t(
                "Latest recorded download %1$@, upload %2$@. Hover for interval averages and ranges.",
                ByteFormat.rate(latestIn), ByteFormat.rate(latestOut))
        } else {
            model.accessibilityValue = "No data yet."
        }
        return model
    }

    private static func diskModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?, yDomain: ClosedRange<Double>,
        gap: TimeInterval, interval: TimeInterval
    ) -> TrendModel {
        let read = LiveColumn(
            window, .diskReadBytesPerSec, peak: .diskReadPeak, minimum: .diskReadMinimum)
        let write = LiveColumn(
            window, .diskWriteBytesPerSec, peak: .diskWritePeak, minimum: .diskWriteMinimum)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: read, color: DiskStyle.read, name: t("Read")),
            TrendSurfaceSeries(
                column: write, color: DiskStyle.write, filled: false, lineWidth: 1.8,
                name: t("Write")),
        ]
        model.xDomain = domain
        model.gapThreshold = gap
        model.statisticsInterval = interval
        model.yDomain = yDomain
        model.yFormat = { ByteFormat.rate(max($0, 0)) }
        model.showsTimeAxis = true
        model.plotBorder = true
        model.leftGutter = 56
        model.accessibilityLabel = "Physical disk throughput trend"
        if let latestRead = read.lastValue, let latestWrite = write.lastValue {
            model.accessibilityValue = t(
                "Latest recorded read %1$@, write %2$@. Hover for interval averages and ranges.",
                ByteFormat.rate(latestRead), ByteFormat.rate(latestWrite))
        } else {
            model.accessibilityValue = "No data yet."
        }
        return model
    }

    private static func swapModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?, yDomain: ClosedRange<Double>,
        gap: TimeInterval, interval: TimeInterval
    ) -> TrendModel {
        let swap = LiveColumn(window, .swapUsed, peak: .swapUsedPeak, minimum: .swapUsedMinimum)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: swap, color: .indigo, filled: false, name: t("Swap used"))
        ]
        model.xDomain = domain
        model.gapThreshold = gap
        model.statisticsInterval = interval
        model.yDomain = yDomain
        model.yFormat = { ByteFormat.string(UInt64(max($0, 0))) }
        model.showsTimeAxis = true
        model.plotBorder = true
        model.leftGutter = 56
        model.accessibilityLabel = "Swap usage trend"
        if let latest = swap.lastValue {
            model.accessibilityValue = t(
                "Latest recorded swap %1$@. Hover for interval averages and ranges.",
                ByteFormat.string(UInt64(max(latest, 0))))
        } else {
            model.accessibilityValue = "No data yet."
        }
        return model
    }

    private static func point(from system: SystemSample) -> SystemHistoryPoint {
        SystemHistoryPoint(
            date: system.timestamp,
            pressurePercent: system.pressurePercent,
            appMemory: system.appMemory,
            wired: system.wired,
            compressed: system.compressed,
            cachedFiles: system.cachedFiles,
            swapUsed: system.swapUsed,
            cpuLoad: system.cpuLoad,
            loadAverage1: system.loadAverage1,
            loadAverage5: system.loadAverage5,
            loadAverage15: system.loadAverage15,
            networkInBytesPerSec: system.networkInBytesPerSec,
            networkOutBytesPerSec: system.networkOutBytesPerSec,
            diskReadBytesPerSec: system.diskReadBytesPerSec,
            diskWriteBytesPerSec: system.diskWriteBytesPerSec,
            diskReadOperationsPerSec: system.diskReadOperationsPerSec,
            diskWriteOperationsPerSec: system.diskWriteOperationsPerSec,
            cpuDieC: system.cpuDieC, gpuDieC: system.gpuDieC,
            fanRPM: system.fanRPM, thermalPressure: system.thermalPressure)
    }
}

// MARK: - Leaves that re-render on a range load only

/// Captions describe the binning and available statistics, not a live numeric
/// readout. Freeze their model until the next range load so feed publications
/// cannot trigger SwiftUI layout or silently change the legend's interval.
private struct DashboardStatisticsNote: View {
    @ObservedObject var timeline: DashboardTimelineStore
    let feed: TrendFeed
    @State private var frozenModel: TrendModel

    init(timeline: DashboardTimelineStore, feed: TrendFeed) {
        self.timeline = timeline
        self.feed = feed
        _frozenModel = State(initialValue: feed.model)
    }

    var body: some View {
        TrendStatisticsCaption(model: frozenModel)
            .onAppear { frozenModel = feed.model }
            .onChange(of: timeline.rangeVersion) { _, _ in frozenModel = feed.model }
    }
}

/// "10 cores (6P + 4E) · 32 GB memory", omitting parts that aren't known yet.
private struct DashboardSystemSubtitle: View {
    @ObservedObject var timeline: DashboardTimelineStore
    let topology: CPUTopology

    var body: some View {
        Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var subtitle: String {
        var parts: [String] = []
        let cores = topology.logicalCores
        if topology.performanceCoreCount > 0 && topology.efficiencyCoreCount > 0 {
            parts.append(
                String(
                    format: String(localized: "%d cores (%dP + %dE)"), cores,
                    topology.performanceCoreCount, topology.efficiencyCoreCount)
            )
        } else {
            parts.append(
                String(format: String(localized: cores == 1 ? "%d core" : "%d cores"), cores)
            )
        }
        if timeline.totalRAM > 0 {
            parts.append(
                String(format: String(localized: "%@ memory"), ByteFormat.string(timeline.totalRAM))
            )
        }
        return parts.joined(separator: " · ")
    }
}

/// "Building history…" until the window holds two samples; the store
/// publishes that flip exactly once.
private struct DashboardHistoryNote: View {
    @ObservedObject var timeline: DashboardTimelineStore
    let hasHistory: Bool

    var body: some View {
        if !timeline.hasEnoughHistory {
            dashboardFootnote(
                hasHistory
                    ? "Building history for this range…"
                    : "History store unavailable; showing live data only.")
        }
    }
}

/// The headline cards. Their chrome is rebuilt only on a range load
/// (`rangeVersion`); the values and sparklines inside are AppKit views on the
/// store's feeds.
private struct DashboardMetricCards: View {
    @ObservedObject var timeline: DashboardTimelineStore
    let loading: Bool

    var body: some View {
        MetricCardsRow(cards: timeline.cardTemplates, xDomain: nil, loading: loading)
    }
}

// MARK: - Panel chrome

/// A titled, bordered content card, the dashboard's one structural unit, so
/// every section reads with the same weight, spacing, and chrome. Matches the
/// metric cards' fill and hairline border so the whole page is of a piece.
private struct DashboardPanel<Content: View>: View {
    let kind: DashboardDetailKind
    let detailEnabled: Bool
    let detail: () -> Void
    let content: Content

    init(
        _ kind: DashboardDetailKind, detailEnabled: Bool = true,
        detail: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) {
        self.kind = kind
        self.detailEnabled = detailEnabled
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Button(action: detail) {
                    HStack(spacing: 7) {
                        Image(systemName: kind.systemImage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(kind.title)
                            .font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!detailEnabled)
                .help(t("Show %@ details", kind.title))
                .accessibilityLabel(t("Show %@ details", kind.title))
                .accessibilityIdentifier("dashboard.detail.\(kind.rawValue).title")
                Spacer(minLength: 8)
                Button(action: detail) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!detailEnabled)
                .help(t("Show %@ details", kind.title))
                .accessibilityLabel(t("Show %@ details", kind.title))
                .accessibilityHint("Opens a snapshot with a larger view, data, and explanations.")
                .accessibilityIdentifier("dashboard.detail.\(kind.rawValue)")
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
