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
/// the five timelines, the card values and sparklines, the processor, network
/// and disk read-outs, the core grid and the memory composition, is an AppKit
/// surface that repaints itself from a feed the `DashboardTimelineStore`
/// publishes into on each sampler tick. Nothing in this tree observes the
/// tick, so a 4 Hz update never re-evaluates a SwiftUI body or re-measures
/// the scroll content; it costs exactly the pixels that changed. The page
/// re-renders only on a range change, a window resize, or hover.
struct DashboardView: View {
    @Environment(\.samplerModel) private var model
    @EnvironmentObject private var appState: AppState

    @State private var range: HistoryWindow

    /// `initialRange` lets the chart harness start on a short window, where the
    /// strip charts re-home often enough to be exercised in a minute.
    init(initialRange: HistoryWindow = .oneHour) {
        _range = State(initialValue: initialRange)
    }
    @State private var timeline = DashboardTimelineStore()
    @State private var loadedRange: HistoryWindow?
    @State private var topDiskConsumers: [ProcessConsumer] = []

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
                topDiskPanel
            }
            .padding(20)
        }
        .onAppear { reload() }
        .onChange(of: range) { reload() }
        // Consumer rankings follow the table cadence. Chart history does not
        // reload here: the window grows in place as samples land.
        .onReceive(tableTicks) { _ in
            if appState.mainWindowVisible { reloadTopConsumers() }
        }
        .onReceive(liveTicks) { _ in
            guard appState.mainWindowVisible, let model else { return }
            timeline.append(
                model.liveSystem, cpu: model.smoothedCPU,
                networkRates: model.smoothedNetworkRates, diskRates: model.smoothedDiskRates,
                disk: model.latestDisk)
        }
        .onChange(of: appState.mainWindowVisible) { _, visible in if visible { reload() } }
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
        DashboardPanel("Memory pressure", systemImage: "gauge.with.dots.needle.50percent") {
            LiveTrendChart(feed: timeline.pressureFeed)
                .frame(height: 180)
                .chartReloading(awaitingData)
            DashboardHistoryNote(timeline: timeline, hasHistory: model?.hasHistory ?? false)
        }
    }

    /// Smoothed read-outs so the figures settle; the timeline still plots raw
    /// history (real spikes intact).
    private var processorPanel: some View {
        let hasClusters = topology.efficiencyCoreCount > 0 && topology.performanceCoreCount > 0
        return DashboardPanel("Processor", systemImage: "cpu") {
            LiveTrendChart(feed: timeline.cpuFeed)
                .frame(height: 160)
                .chartReloading(awaitingData)

            Divider().opacity(0.5)

            HStack(alignment: .top, spacing: 28) {
                liveStat("Total", timeline.cpuTotalFeed, .labelColor)
                if hasClusters {
                    liveStat(
                        "Performance", timeline.cpuPerformanceFeed,
                        NSColor(CoreKind.performance.accent))
                    liveStat(
                        "Efficiency", timeline.cpuEfficiencyFeed,
                        NSColor(CoreKind.efficiency.accent))
                }
                liveStat("Load avg", timeline.loadAverageFeed, .labelColor)
                Spacer(minLength: 0)
            }

            dashboardFootnote(
                "Total CPU is the share of all cores in use, 0–100%. Per-process CPU (in the list "
                    + "and menubar) follows Activity Monitor — percent of one core, so a busy "
                    + "multi-threaded app can exceed 100%.")
        }
    }

    /// The live per-core utilisation grid, in the rail rather than the Processor
    /// panel: the bars read better in the narrower column, and it keeps the
    /// Processor panel focused on the timeline and the headline read-outs.
    private var coresPanel: some View {
        DashboardPanel("CPU cores", systemImage: "cpu") {
            CoreGridSurface(feed: timeline.coreFeed)
        }
    }

    private var compositionPanel: some View {
        DashboardPanel("Memory composition", systemImage: "chart.bar.fill") {
            TaxonomySurface(feed: timeline.taxonomyFeed)
        }
    }

    private var networkPanel: some View {
        DashboardPanel("Network", systemImage: "network") {
            HStack(spacing: 24) {
                networkStat(
                    "Download", timeline.downloadFeed, NetworkStyle.download,
                    NetworkStyle.downSymbol)
                networkStat(
                    "Upload", timeline.uploadFeed, NetworkStyle.upload, NetworkStyle.upSymbol)
                Spacer(minLength: 0)
            }
            LiveTrendChart(feed: timeline.networkFeed)
                .frame(height: 150)
                .chartReloading(awaitingData)
            dashboardFootnote(
                "Download and upload throughput across the Wi-Fi and Ethernet interfaces. "
                    + "Turn on per-app network tracking in Settings to see which apps are responsible."
            )
        }
    }

    private func networkStat(
        _ label: String, _ feed: TextFeed, _ tint: Color, _ symbol: String
    )
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
            liveStat(label, feed, NSColor(tint))
        }
    }

    private var swapPanel: some View {
        DashboardPanel("Swap", systemImage: "internaldrive") {
            LiveTrendChart(feed: timeline.swapFeed)
                .frame(height: 110)
                .chartReloading(awaitingData)
            dashboardFootnote(
                "Swap is memory moved out to disk. A flat line at zero is ideal; a sustained climb "
                    + "under pressure is the real warning sign.")
        }
    }

    private var diskPanel: some View {
        DashboardPanel("Physical disk", systemImage: "internaldrive") {
            HStack(spacing: 24) {
                liveStat("Read", timeline.diskReadFeed, NSColor(DiskStyle.read))
                liveStat("Write", timeline.diskWriteFeed, NSColor(DiskStyle.write))
                liveStat("IOPS", timeline.iopsFeed, .labelColor)
                Spacer(minLength: 0)
            }
            LiveTrendChart(feed: timeline.diskFeed)
                .frame(height: 150)
                .chartReloading(awaitingData)
            dashboardFootnote(
                "Physical traffic across real internal and external disks. Disk images are excluded."
            )
        }
    }

    private var topDiskPanel: some View {
        DashboardPanel("Top disk processes", systemImage: "list.number") {
            if topDiskConsumers.isEmpty {
                Text("No attributed disk activity in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(topDiskConsumers.prefix(6)) { process in
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
                        Text(ByteFormat.rate(process.averageDisk))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            dashboardFootnote("Kernel-attributed I/O; it may not add up to physical traffic.")
        }
    }

    /// A small uppercase caption over a live figure painted by AppKit.
    private func liveStat(_ label: String, _ feed: TextFeed, _ tint: NSColor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            LiveText(feed: feed, color: tint)
                .frame(width: 96)
        }
    }

    // MARK: - Loading

    /// Cap for minute/hour history. Raw windows keep their samples so every
    /// recorded point remains immutable and moves left intact.
    private static let maxChartPoints = 360

    private func reload() {
        guard let model else { return }
        let requested = range
        let pointLimit = requested.granularity == .raw ? nil : Self.maxChartPoints
        model.loadSystemHistory(requested, downsampledTo: pointLimit) { pts in
            guard self.range == requested else { return }
            self.timeline.replace(
                pts, span: requested.seconds, live: model.liveSystem, cpu: model.smoothedCPU,
                totalRAM: model.liveSystem?.totalRAM ?? model.latest?.system.totalRAM ?? 0)
            self.loadedRange = requested
        }
        reloadTopConsumers(window: requested)
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
        model.loadTopConsumers(window: requested, metric: .averageDisk, limit: 6) { rows in
            guard self.range == requested, rows != self.topDiskConsumers else { return }
            self.topDiskConsumers = rows
        }
    }
}

// MARK: - Shared bits

private func dashboardFootnote(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

private func percent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
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
    private(set) var networkYDomain: ClosedRange<Double> = 0...(10 * 1_048_576)
    private(set) var diskYDomain: ClosedRange<Double> = 0...(100 * 1_048_576)
    private(set) var totalRAM: UInt64 = 0
    private var pressureLevel: PressureLevel = .normal
    private var cpuLevel: CPULevel = .light
    private var latestSystem: SystemSample?

    let pressureFeed = TrendFeed()
    let cpuFeed = TrendFeed()
    let networkFeed = TrendFeed()
    let diskFeed = TrendFeed()
    let swapFeed = TrendFeed()
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

    var xDomain: ClosedRange<Date>? { window.xDomain }

    func replace(
        _ loaded: [SystemHistoryPoint], span: TimeInterval, live: SystemSample?, cpu: CPUSample?,
        totalRAM: UInt64
    ) {
        window.replace(loaded, span: span)
        if let live {
            window.append(Self.point(from: live))
            latestSystem = live
            pressureLevel = live.pressureLevel
        }
        cpuLevel = CPULevel(fraction: cpu?.totalUsage ?? 0)
        self.totalRAM = totalRAM
        memoryScale = MemoryMetrics.scale(window: window, total: totalRAM)
        refreshAutoDomains()
        cardTemplates = MemoryMetrics.cards(system: live, window: window, scale: memoryScale)
            .enumerated().map { index, card in
                var template = card
                template.samples = []
                template.live = index < cardFeeds.count ? cardFeeds[index] : nil
                return template
            }
        publishCharts()
        publishReadouts(cpu: cpu, networkRates: nil, diskRates: nil, disk: nil)
        if window.count >= 2, !hasEnoughHistory { hasEnoughHistory = true }
        rangeVersion &+= 1
    }

    func append(
        _ system: SystemSample?, cpu: CPUSample?,
        networkRates: (inBytesPerSec: Double, outBytesPerSec: Double)?,
        diskRates: (readBytesPerSec: Double, writeBytesPerSec: Double)?, disk: DiskSample?
    ) {
        guard let system, window.append(Self.point(from: system)) else { return }
        latestSystem = system
        pressureLevel = system.pressureLevel
        cpuLevel = CPULevel(fraction: cpu?.totalUsage ?? 0)
        if totalRAM == 0, system.totalRAM > 0 { totalRAM = system.totalRAM }
        refreshAutoDomains()
        publishCharts()
        publishReadouts(cpu: cpu, networkRates: networkRates, diskRates: diskRates, disk: disk)
        if window.count >= 2, !hasEnoughHistory { hasEnoughHistory = true }
    }

    /// The network and disk axes follow the window's peak, snapped to a round
    /// ceiling so they hold still between ticks. A change repaints the whole
    /// strip of those charts, which the snapping keeps rare. One pass over
    /// four columns; a few tens of microseconds at an hour of 4 Hz samples.
    private func refreshAutoDomains() {
        let networkPeak = max(
            window.peak(.networkInBytesPerSec) ?? 0, window.peak(.networkOutBytesPerSec) ?? 0)
        networkYDomain = 0...MenuChart.niceUpperBound(max(networkPeak * 1.25, 10 * 1_048_576))
        let diskPeak = max(
            window.peak(.diskReadBytesPerSec) ?? 0, window.peak(.diskWriteBytesPerSec) ?? 0)
        diskYDomain = 0...MenuChart.niceUpperBound(max(diskPeak * 1.25, 100 * 1_048_576))
    }

    /// Build every chart's and card's model from the window and hand it to
    /// its feed.
    private func publishCharts() {
        let domain = window.xDomain
        pressureFeed.publish(Self.pressureModel(window, domain: domain, level: pressureLevel))
        cpuFeed.publish(Self.cpuModel(window, domain: domain, level: cpuLevel))
        networkFeed.publish(Self.networkModel(window, domain: domain, yDomain: networkYDomain))
        diskFeed.publish(Self.diskModel(window, domain: domain, yDomain: diskYDomain))
        swapFeed.publish(
            Self.swapModel(window, domain: domain, yDomain: 0...max(Double(totalRAM), 1)))
        let cards = MemoryMetrics.cards(
            system: latestSystem, window: window, scale: memoryScale, includeSamples: false)
        for (feed, card) in zip(cardFeeds, cards) {
            feed.publish(
                value: card.value, tint: NSColor(card.tint), column: card.column,
                xDomain: domain, yDomain: card.yDomain)
        }
    }

    /// The figures around the charts: processor, network and disk read-outs,
    /// the core grid, and the memory composition.
    private func publishReadouts(
        cpu: CPUSample?, networkRates: (inBytesPerSec: Double, outBytesPerSec: Double)?,
        diskRates: (readBytesPerSec: Double, writeBytesPerSec: Double)?, disk: DiskSample?
    ) {
        cpuTotalFeed.publish(
            cpu.map { percent($0.totalUsage) } ?? "—", color: NSColor(cpuLevel.color))
        cpuPerformanceFeed.publish(cpu.map { percent($0.performanceUsage) } ?? "—")
        cpuEfficiencyFeed.publish(cpu.map { percent($0.efficiencyUsage) } ?? "—")
        loadAverageFeed.publish(cpu.map { String(format: "%.2f", $0.loadAverage1) } ?? "—")
        coreFeed.publish(cpu?.cores ?? [])
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
    }

    private static func pressureModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?, level: PressureLevel
    ) -> TrendModel {
        let column = LiveColumn(window, .pressurePercent)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: column, color: level.color, filled: true)
        ]
        model.xDomain = domain
        model.yDomain = 0...100
        model.yTicks = [0, 34, 67, 100]
        model.rules = [
            TrendRule(value: 34, label: "Warning", color: .orange),
            TrendRule(value: 67, label: "Critical", color: .red),
        ]
        model.showsTimeAxis = true
        model.accessibilityLabel = "Memory pressure timeline"
        if let latest = column.lastValue {
            let range = column.range ?? (latest, latest)
            model.accessibilityValue =
                "Currently \(level.label.lowercased()) at \(Int(latest.rounded())) percent. "
                + "Window range \(Int(range.min.rounded())) to \(Int(range.max.rounded())) percent."
        } else {
            model.accessibilityValue = "No data yet."
        }
        return model
    }

    private static func cpuModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?, level: CPULevel
    ) -> TrendModel {
        let column = LiveColumn(window, .cpuLoad)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: column, scale: 100, color: level.color, filled: true)
        ]
        model.xDomain = domain
        model.yDomain = 0...100
        model.yTicks = [0, 60, 85, 100]
        model.rules = [
            TrendRule(value: 60, label: "Busy", color: .orange),
            TrendRule(value: 85, label: "Heavy", color: .red),
        ]
        model.showsTimeAxis = true
        model.accessibilityLabel = "Total CPU timeline"
        if let latest = column.lastValue {
            let range = column.range ?? (latest, latest)
            model.accessibilityValue =
                "Currently \(Int((latest * 100).rounded())) percent. Window range "
                + "\(Int((range.min * 100).rounded())) to \(Int((range.max * 100).rounded())) percent."
        } else {
            model.accessibilityValue = "No data yet."
        }
        return model
    }

    private static func networkModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?, yDomain: ClosedRange<Double>
    ) -> TrendModel {
        let download = LiveColumn(window, .networkInBytesPerSec)
        let upload = LiveColumn(window, .networkOutBytesPerSec)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: download, color: NetworkStyle.download, filled: true),
            TrendSurfaceSeries(
                column: upload, color: NetworkStyle.upload, filled: false, lineWidth: 1.8),
        ]
        model.xDomain = domain
        model.yDomain = yDomain
        model.yFormat = { ByteFormat.rate(max($0, 0)) }
        model.showsTimeAxis = true
        model.leftGutter = 56
        model.accessibilityLabel = "Network throughput trend"
        if let latestIn = download.lastValue, let latestOut = upload.lastValue {
            let peak = max(download.range?.max ?? 0, upload.range?.max ?? 0)
            model.accessibilityValue =
                peak < 1
                ? "No network traffic over the shown window."
                : "Currently \(ByteFormat.rate(latestIn)) down, \(ByteFormat.rate(latestOut)) up. "
                    + "Peak \(ByteFormat.rate(peak)) over the shown window."
        } else {
            model.accessibilityValue = "No data yet."
        }
        return model
    }

    private static func diskModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?, yDomain: ClosedRange<Double>
    ) -> TrendModel {
        let read = LiveColumn(window, .diskReadBytesPerSec)
        let write = LiveColumn(window, .diskWriteBytesPerSec)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: read, color: DiskStyle.read, filled: true),
            TrendSurfaceSeries(
                column: write, color: DiskStyle.write, filled: false, lineWidth: 1.8),
        ]
        model.xDomain = domain
        model.yDomain = yDomain
        model.yFormat = { ByteFormat.rate(max($0, 0)) }
        model.showsTimeAxis = true
        model.leftGutter = 56
        model.accessibilityLabel = "Physical disk throughput trend"
        if let latestRead = read.lastValue, let latestWrite = write.lastValue {
            let peak = max(read.range?.max ?? 0, write.range?.max ?? 0)
            model.accessibilityValue =
                peak < 1
                ? "No physical disk activity over the shown window."
                : "Currently \(ByteFormat.rate(latestRead)) read, \(ByteFormat.rate(latestWrite)) write. "
                    + "Peak \(ByteFormat.rate(peak)) over the shown window."
        } else {
            model.accessibilityValue = "No data yet."
        }
        return model
    }

    private static func swapModel(
        _ window: SystemHistoryWindow, domain: ClosedRange<Date>?, yDomain: ClosedRange<Double>
    ) -> TrendModel {
        let swap = LiveColumn(window, .swapUsed)
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: swap, color: .indigo, filled: true)
        ]
        model.xDomain = domain
        model.yDomain = yDomain
        model.yFormat = { ByteFormat.string(UInt64(max($0, 0))) }
        model.accessibilityLabel = "Swap usage trend"
        if let latest = swap.lastValue {
            let peak = UInt64(max(swap.range?.max ?? latest, 0))
            model.accessibilityValue =
                peak == 0
                ? "No swap in use over the shown window."
                : "Currently \(ByteFormat.string(UInt64(max(latest, 0)))). "
                    + "Peak \(ByteFormat.string(peak)) over the shown window."
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
            networkInBytesPerSec: system.networkInBytesPerSec,
            networkOutBytesPerSec: system.networkOutBytesPerSec,
            diskReadBytesPerSec: system.diskReadBytesPerSec,
            diskWriteBytesPerSec: system.diskWriteBytesPerSec,
            diskReadOperationsPerSec: system.diskReadOperationsPerSec,
            diskWriteOperationsPerSec: system.diskWriteOperationsPerSec)
    }
}

// MARK: - Leaves that re-render on a range load only

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
                "\(cores) cores (\(topology.performanceCoreCount)P + \(topology.efficiencyCoreCount)E)"
            )
        } else {
            parts.append("\(cores) core\(cores == 1 ? "" : "s")")
        }
        if timeline.totalRAM > 0 {
            parts.append("\(ByteFormat.string(timeline.totalRAM)) memory")
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
private struct DashboardPanel<Content: View, Accessory: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                accessory()
            }
            content()
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

extension DashboardPanel where Accessory == EmptyView {
    init(
        _ title: String, systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title, systemImage: systemImage, accessory: { EmptyView() }, content: content)
    }
}
