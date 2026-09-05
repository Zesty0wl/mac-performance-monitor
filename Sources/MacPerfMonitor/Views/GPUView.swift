import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

/// The GPU tab: what the GPU is doing, at what clock and power, who is using
/// it, how much of that is AI work, and whether the Neural Engine is busy.
///
/// Built like the Dashboard: the page is static SwiftUI chrome, every figure
/// that moves is an AppKit surface fed by `GPUTimelineStore` on each tick
/// (strip charts, card values and sparklines, read-outs, the state bars and
/// the category bar), and the "who is using the GPU" table is the process
/// table with GPU columns, its rows on screen refreshed at the dial rate and
/// re-ranked every 5 s. Device figures come from the IORegistry and IOReport
/// (see `docs/gpu-tab-design.md`); per-process GPU time from the AGX driver's
/// per-context accounting, no helper required.
struct GPUView: View {
    @Environment(\.samplerModel) private var model
    @EnvironmentObject private var appState: AppState
    @StateObject private var timeline = GPUTimelineStore()
    @State private var range: HistoryWindow = .oneHour
    @State private var loadedRange: HistoryWindow?
    @State private var rows: [ProcessNode] = []
    @State private var rowsRevision = 0
    @State private var idleContexts = 0
    @State private var showIdle = false
    @State private var selection: Set<ProcessIdentity> = []
    @State private var sortOrder = [
        KeyPathComparator(\ProcessNode.process.gpuPercentValue, order: .reverse)
    ]
    @State private var aiWorkloads: [AIWorkloadRow] = []
    /// Point-based backing for the temperature chart. Unlike the columnar
    /// feeds above, temperatures need gap-correct optionals (rows recorded
    /// before the thermal columns existed must gap, not draw a 0 line), so
    /// this panel takes the same points path as the Disk and Energy tabs.
    /// Appended on the thermal cadence, not the dial rate, so the SwiftUI
    /// chart re-renders about every 5 s and stays out of the live budget.
    @State private var thermalPoints: [SystemHistoryPoint] = []

    var body: some View {
        ScrollView {
            MainRailLayout {
                pageHeader
                headlineCards
                utilizationPanel
                powerPanel
                temperaturePanel
                processesPanel
            } rail: {
                devicePanel
                categoriesPanel
                aiPanel
            }
            .padding(20)
        }
        .onAppear {
            model?.addGPUConsumer()
            model?.addProcessConsumer()
            model?.requestImmediateTick()
            reload()
            rebuildRows()
        }
        .onDisappear {
            model?.removeGPUConsumer()
            model?.removeProcessConsumer()
        }
        .onChange(of: range) { reload() }
        .onChange(of: appState.mainWindowVisible) { _, visible in if visible { reload() } }
        .onReceive(liveTicks) { _ in
            guard appState.mainWindowVisible, let model else { return }
            timeline.append(model.liveSystem, gpu: model.latestGPU)
            appendThermalPoint(model)
        }
        .onReceive(tableTicks) { _ in
            if appState.mainWindowVisible { rebuildRows() }
        }
        .onChange(of: sortOrder) { _, _ in rebuildRows() }
        .onChange(of: showIdle) { _, _ in rebuildRows() }
    }

    private var liveTicks: AnyPublisher<Void, Never> {
        model?.liveTick.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }

    private var tableTicks: AnyPublisher<Int, Never> {
        model?.$displayProcessesVersion.dropFirst().eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
    }

    // MARK: - Data

    private func reload() {
        guard let model else { return }
        let requested = range
        model.loadSystemHistory(requested) { points in
            guard range == requested else { return }
            timeline.replace(
                points, span: requested.seconds, live: model.liveSystem, gpu: model.latestGPU)
            thermalPoints = points
            loadedRange = requested
        }
    }

    /// Append the live thermal reading, but only when a fresh SMC sample has
    /// actually landed (the reader throttles to ~5 s), so the points-based
    /// chart below re-renders at the thermal cadence rather than the dial rate.
    private func appendThermalPoint(_ model: SamplerModel) {
        guard let live = model.liveSystem, live.cpuDieC != nil else { return }
        if let last = thermalPoints.last {
            guard live.timestamp.timeIntervalSince(last.date) >= 4 else { return }
        }
        var point = SystemHistoryPoint(
            date: live.timestamp, pressurePercent: live.pressurePercent,
            appMemory: live.appMemory, wired: live.wired, compressed: live.compressed,
            cachedFiles: live.cachedFiles, swapUsed: live.swapUsed)
        point.cpuDieC = live.cpuDieC
        point.gpuDieC = live.gpuDieC
        point.fanRPM = live.fanRPM
        thermalPoints.append(point)
        let cutoff = Date().addingTimeInterval(-range.seconds)
        if thermalPoints.first.map({ $0.date < cutoff }) ?? false {
            thermalPoints.removeAll { $0.date < cutoff }
        }
    }

    /// The table's rows: processes with a Metal context, ranked by the active
    /// sort. Contexts that are idle (no share and nothing submitted for a
    /// minute) are folded into a count unless "show idle" is on, so the table
    /// reads as "who is using the GPU" rather than "who has ever used it".
    private func rebuildRows() {
        guard let model else { return }
        let all = model.displayProcesses.filter { $0.gpuTimeNanos != nil }
        let shown = showIdle ? all : all.filter { Self.isRecentlyActive($0) }
        var nodes = ProcessListView.sortedNodes(shown, comparators: sortOrder)
        for index in nodes.indices {
            nodes[index].badge = model.gpuWorkload(for: nodes[index].id)?.category.label ?? ""
        }
        rows = nodes
        rowsRevision &+= 1
        idleContexts = all.count - shown.count
        timeline.publishShares(all, workloads: { model.gpuWorkload(for: $0) })
        aiWorkloads = all.compactMap { process -> AIWorkloadRow? in
            guard let info = model.gpuWorkload(for: process.id), info.category == .aiML else {
                return nil
            }
            return AIWorkloadRow(
                id: process.id, name: process.displayName, runtime: info.runtime,
                model: info.model, gpuPercent: process.gpuPercentValue,
                footprint: process.physFootprint, lastActive: process.gpuLastActive,
                active: Self.isRecentlyActive(process))
        }
        .sorted { $0.gpuPercent > $1.gpuPercent }
    }

    private static func isRecentlyActive(_ process: ProcessSample) -> Bool {
        process.isGPUActive || process.gpuIdleSeconds < 60
    }

    // MARK: - Header

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            GPUPageTitle(timeline: timeline)
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
            }
        }
    }

    private var headlineCards: some View {
        MetricCardsRow(cards: timeline.cardTemplates, xDomain: nil, loading: false)
    }

    // MARK: - Main column

    private var utilizationPanel: some View {
        GPUPanel("GPU utilization", systemImage: "display") {
            VStack(alignment: .leading, spacing: 8) {
                LiveTrendChart(feed: timeline.utilizationFeed, scrubbable: true)
                    .frame(height: 170)
                HStack(spacing: 22) {
                    liveStat("DEVICE", timeline.utilizationText, NSColor.labelColor)
                    liveStat("RENDERER", timeline.rendererText, NSColor.labelColor)
                    liveStat("TILER", timeline.tilerText, NSColor.labelColor)
                    liveStat("ACTIVE", timeline.activeText, NSColor.labelColor)
                    Spacer()
                }
                Text(
                    "Device utilization is the share of the interval the GPU was busy with any work. The renderer and tiler figures are the two halves of the pipeline; the active figure is how much of the interval the GPU was powered and clocked at all."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var powerPanel: some View {
        GPUPanel("Power", systemImage: "bolt") {
            VStack(alignment: .leading, spacing: 8) {
                LiveTrendChart(feed: timeline.powerFeed, scrubbable: true)
                    .frame(height: 140)
                HStack(spacing: 22) {
                    liveStat("GPU", timeline.gpuWattsText, NSColor(DiskStyle.read))
                    liveStat("NEURAL ENGINE", timeline.aneWattsText, NSColor(.purple))
                    liveStat("CPU", timeline.cpuWattsText, NSColor.secondaryLabelColor)
                    Spacer()
                }
                Text(
                    "From the chip's energy counters (the same source as powermetrics), averaged over each tick. Neural Engine power is the signal that a Core ML model is running: it reads zero when the ANE is idle."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var temperaturePanel: some View {
        GPUPanel("Temperature", systemImage: "thermometer.medium") {
            VStack(alignment: .leading, spacing: 8) {
                TemperatureChart(
                    points: thermalPoints,
                    xDomain: LiveChartGeometry.trailingDomain(
                        latest: thermalPoints.last?.date, span: range.seconds),
                    showsTimeAxis: true
                )
                .frame(height: 140)
                HStack(spacing: 22) {
                    liveStat("GPU DIE", timeline.temperatureText, NSColor(ThermalStyle.gpu))
                    liveStat("FAN", timeline.fanText, NSColor.labelColor)
                    Spacer()
                }
                Text(
                    "Each line is the hottest sensor of its domain: CPU die in orange, GPU die in red. High numbers under load are normal; the Energy tab keeps the long-term thermal record and the throttling log."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var processesPanel: some View {
        GPUPanel("Who is using the GPU", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                ProcessOutlineTable(
                    rows: rows, revision: rowsRevision, showHierarchy: false, leakingIDs: [],
                    terminatedIDs: [], selection: $selection, sortOrder: $sortOrder,
                    menu: { _ in nil },
                    values: model?.processValuesTick.eraseToAnyPublisher()
                        ?? Empty().eraseToAnyPublisher(),
                    onVisibleRowsChange: { pids in model?.setVisibleProcesses(pids) },
                    columns: ProcessOutlineTable.ColumnSpec.gpu
                )
                .frame(height: max(180, CGFloat(min(rows.count, 14)) * 24 + 30))
                HStack {
                    Text(idleSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show idle contexts", isOn: $showIdle)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
                Text(
                    "GPU is the share of one GPU the process used over the last few seconds (the figure Activity Monitor calls % GPU); GPU ms/s is the same as milliseconds of GPU time per second. Browsers, Electron apps and Safari do their GPU work in helper processes, which appear under their own names."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var idleSummary: String {
        if idleContexts == 0 { return t("%@ processes with a Metal context.", String(rows.count)) }
        return t(
            "%1$@ using the GPU · %2$@ more hold an idle Metal context.",
            String(rows.count), String(idleContexts))
    }

    // MARK: - Rail

    private var devicePanel: some View {
        GPUPanel("Device", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(
                    alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6
                ) {
                    detailRow("Chip", timeline.chipText)
                    detailRow("Cores", timeline.coresText)
                    detailRow("Memory in use", timeline.memoryText)
                    detailRow("Allocated", timeline.allocatedText)
                    detailRow("Die temperature", timeline.temperatureText)
                    detailRow("Fan", timeline.fanText)
                    detailRow("Thermal limit", timeline.throttleText)
                    detailRow("Power cap", timeline.capText)
                    detailRow("GPU recoveries", timeline.recoveryText)
                }
                Text("CLOCK STATES")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                GPUStatesSurface(feed: timeline.statesFeed)
                Text(
                    "How the interval split across the GPU's performance states, lowest clock first; OFF is the share it was powered down. A thermal limit or a power cap shows here before it shows as lost frames."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var categoriesPanel: some View {
        GPUPanel("By category", systemImage: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: 8) {
                GPUShareSurface(feed: timeline.shareFeed)
                Text(
                    "Each process's GPU share, grouped by what it is: AI and ML runtimes, display and app UI, media, and everything else. Shares can overlap on the GPU, so the bar is the split of the busy time, not of the whole device."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var aiPanel: some View {
        GPUPanel("AI workloads", systemImage: "brain") {
            VStack(alignment: .leading, spacing: 8) {
                if aiWorkloads.isEmpty {
                    Text("No AI or ML runtime is using the GPU.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(aiWorkloads.prefix(8)) { row in
                        AIWorkloadRowView(row: row)
                    }
                }
                HStack(spacing: 6) {
                    Text("Neural Engine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    LiveText(
                        feed: timeline.aneStatusText, font: .systemFont(ofSize: 11, weight: .medium)
                    )
                    .frame(width: 150, alignment: .trailing)
                }
                Text(
                    "Recognised by name: Ollama, llama.cpp, MLX, LM Studio, Core ML hosts, Apple Intelligence and the media analysis daemons, plus a bare Python or Node whose command line loads a model framework. Neural Engine work is proxied through a system daemon, so it cannot be attributed to a process; its power is the signal."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bits

    private func liveStat(
        _ label: LocalizedStringKey, _ feed: TextFeed, _ tint: NSColor
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            LiveText(feed: feed, color: tint)
                .frame(width: 96)
        }
    }

    private func detailRow(_ label: LocalizedStringKey, _ feed: TextFeed) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            LiveText(
                feed: feed, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                alignment: .right
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The page title: chip name and core count, re-rendered only when the
/// device is first read.
private struct GPUPageTitle: View {
    @ObservedObject var timeline: GPUTimelineStore

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(timeline.chipName ?? "GPU")
                .font(.headline)
            Text(timeline.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One detected AI workload.
struct AIWorkloadRow: Identifiable, Equatable {
    var id: ProcessIdentity
    var name: String
    var runtime: String?
    var model: String?
    var gpuPercent: Double
    var footprint: UInt64
    var lastActive: Date?
    var active: Bool
}

private struct AIWorkloadRowView: View {
    let row: AIWorkloadRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(row.active ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.0f%%", row.gpuPercent))
                    .font(.callout.monospacedDigit().weight(.semibold))
                Text(ByteFormat.string(row.footprint))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let runtime = row.runtime { parts.append(runtime) }
        if let model = row.model { parts.append(model) }
        if !row.active { parts.append(t("idle")) }
        return parts.isEmpty ? "GPU" : parts.joined(separator: " · ")
    }
}

// MARK: - Panel chrome

private struct GPUPanel<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var content: () -> Content

    init(
        _ title: LocalizedStringKey, systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
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

// MARK: - Store

/// Owns the GPU page's window of system samples and every feed its surfaces
/// repaint from. Its only published values are the chip identity (set once),
/// so the page body re-evaluates a handful of times per session, never per
/// tick.
@MainActor
final class GPUTimelineStore: ObservableObject {
    @Published private(set) var chipName: String?
    @Published private(set) var subtitle = "Apple silicon GPU"

    private var window = SystemHistoryWindow(span: 3600)
    private var powerTop: Double = 5
    private var didDescribeDevice = false

    let utilizationFeed = TrendFeed()
    let powerFeed = TrendFeed()
    let cardFeeds: [MetricCardFeed] = (0..<5).map { _ in MetricCardFeed() }
    private(set) var cardTemplates: [MetricCardData] = []

    let utilizationText = TextFeed()
    let rendererText = TextFeed()
    let tilerText = TextFeed()
    let activeText = TextFeed()
    let gpuWattsText = TextFeed()
    let aneWattsText = TextFeed()
    let cpuWattsText = TextFeed()
    let chipText = TextFeed()
    let coresText = TextFeed()
    let memoryText = TextFeed()
    let allocatedText = TextFeed()
    let temperatureText = TextFeed()
    let fanText = TextFeed()
    let throttleText = TextFeed()
    let capText = TextFeed()
    let recoveryText = TextFeed()
    let aneStatusText = TextFeed()
    let statesFeed = GPUStatesFeed()
    let shareFeed = GPUShareFeed()

    init() {
        cardTemplates = Self.makeCardTemplates(feeds: cardFeeds)
    }

    func replace(
        _ points: [SystemHistoryPoint], span: TimeInterval, live: SystemSample?, gpu: GPUSample?
    ) {
        window.replace(points, span: span)
        if let live { window.append(Self.point(from: live)) }
        refreshPowerTop()
        publish(gpu)
    }

    func append(_ system: SystemSample?, gpu: GPUSample?) {
        if let system, window.append(Self.point(from: system)) {
            refreshPowerTop()
        }
        publish(gpu)
    }

    /// Group the processes' GPU shares by workload category for the bar.
    func publishShares(
        _ processes: [ProcessSample], workloads: (ProcessIdentity) -> GPUWorkloadInfo?
    ) {
        var totals: [GPUWorkloadCategory: Double] = [:]
        var counts: [GPUWorkloadCategory: Int] = [:]
        for process in processes where process.isGPUActive {
            let category = workloads(process.id)?.category ?? .other
            totals[category, default: 0] += process.gpuPercentValue
            counts[category, default: 0] += 1
        }
        let slices = GPUWorkloadCategory.allCases.map { category in
            GPUShareSlice(
                name: category.label, percent: totals[category] ?? 0,
                count: counts[category] ?? 0, color: Self.color(for: category))
        }
        shareFeed.publish(slices)
    }

    private func refreshPowerTop() {
        let peak = max(window.peak(.gpuPowerWatts) ?? 0, window.peak(.anePowerWatts) ?? 0)
        powerTop = LiveChartGeometry.niceCeiling(max(peak * 1.15, 1))
    }

    private func publish(_ gpu: GPUSample?) {
        let domain = window.xDomain
        let level = CPULevel(fraction: (gpu?.utilization ?? 0) / 100)

        // Timelines.
        var utilization = TrendModel()
        utilization.series = [
            TrendSurfaceSeries(
                column: LiveColumn(window, .gpuUtilization), color: level.color, filled: true)
        ]
        utilization.xDomain = domain
        utilization.yDomain = 0...100
        utilization.yTicks = [0, 25, 50, 75, 100]
        utilization.showsTimeAxis = true
        utilization.accessibilityLabel = t("GPU utilization timeline")
        utilization.accessibilityValue =
            gpu.map { t("Currently %@ percent.", String(Int($0.utilization.rounded()))) }
            ?? t("No data yet.")
        utilizationFeed.publish(utilization)

        var power = TrendModel()
        power.series = [
            TrendSurfaceSeries(
                column: LiveColumn(window, .gpuPowerWatts), color: DiskStyle.read, filled: true),
            TrendSurfaceSeries(
                column: LiveColumn(window, .anePowerWatts), color: .purple, filled: false,
                lineWidth: 1.8),
        ]
        power.xDomain = domain
        power.yDomain = 0...powerTop
        power.yFormat = { String(format: "%.1f W", $0) }
        power.showsTimeAxis = true
        power.leftGutter = 48
        power.accessibilityLabel = t("GPU and Neural Engine power timeline")
        power.accessibilityValue =
            gpu?.gpuPowerWatts.map { t("GPU %@ watts.", String(format: "%.2f", $0)) }
            ?? t("No data yet.")
        powerFeed.publish(power)

        // Cards.
        let watts: (Double?) -> String? = { $0.map { String(format: "%.2f W", $0) } }
        cardFeeds[0].publish(
            value: gpu.map { "\(Int($0.utilization.rounded()))%" }, tint: NSColor(level.color),
            column: LiveColumn(window, .gpuUtilization), xDomain: domain, yDomain: 0...100)
        cardFeeds[1].publish(
            value: watts(gpu?.gpuPowerWatts), tint: NSColor(DiskStyle.read),
            column: LiveColumn(window, .gpuPowerWatts), xDomain: domain, yDomain: 0...powerTop)
        let aneWatts = gpu?.anePowerWatts
        cardFeeds[2].publish(
            value: aneWatts.map { $0 < 0.01 ? "Idle" : String(format: "%.2f W", $0) },
            tint: NSColor(.purple), column: LiveColumn(window, .anePowerWatts), xDomain: domain,
            yDomain: 0...powerTop)
        cardFeeds[3].publish(
            value: gpu?.inUseMemoryBytes.map { ByteFormat.string($0) }, tint: NSColor(.teal),
            column: nil, xDomain: nil, yDomain: nil)
        cardFeeds[4].publish(
            value: gpu?.activeResidency.map { "\(Int($0.rounded()))%" }
                ?? gpu.map { _ in "--" }, tint: NSColor(.orange), column: nil, xDomain: nil,
            yDomain: nil)

        // Read-outs.
        utilizationText.publish(gpu.map { "\(Int($0.utilization.rounded()))%" } ?? "--")
        rendererText.publish(gpu?.renderUtilization.map { "\(Int($0.rounded()))%" } ?? "--")
        tilerText.publish(gpu?.tilerUtilization.map { "\(Int($0.rounded()))%" } ?? "--")
        activeText.publish(gpu?.activeResidency.map { "\(Int($0.rounded()))%" } ?? "--")
        gpuWattsText.publish(watts(gpu?.gpuPowerWatts) ?? "--")
        aneWattsText.publish(watts(gpu?.anePowerWatts) ?? "--")
        cpuWattsText.publish(watts(gpu?.cpuPowerWatts) ?? "--")
        memoryText.publish(gpu?.inUseMemoryBytes.map { ByteFormat.string($0) } ?? "--")
        allocatedText.publish(gpu?.allocatedMemoryBytes.map { ByteFormat.string($0) } ?? "--")
        temperatureText.publish(
            gpu?.dieTemperatureC.map { "\(Int($0.rounded()))\u{00B0}C" } ?? "--")
        // Read-out *values* need translating as much as the labels beside them.
        // "Thermal limit active" and "Power cap none" are disambiguating keys: a
        // bare "Active"/"None" already label other things, and en.lproj renders
        // these back to the short English words.
        fanText.publish(gpu?.fanRPM.map { $0 == 0 ? t("Off") : t("%@ rpm", String($0)) } ?? "--")
        if let throttled = gpu?.throttled {
            throttleText.publish(
                throttled ? t("Thermal limit active") : t("Thermal limit none"),
                color: throttled ? .systemOrange : nil)
        } else {
            throttleText.publish("--")
        }
        capText.publish(
            gpu?.powerCapPercent.map {
                $0 >= 99.5 ? t("Power cap none") : t("%@%% of max", String(Int($0.rounded())))
            } ?? "--")
        recoveryText.publish(gpu?.recoveryCount.map { "\($0)" } ?? "--")
        if let aneWatts {
            aneStatusText.publish(
                aneWatts < 0.01
                    ? t("Idle")
                    : t("Active · %@ W", String(format: "%.2f", aneWatts)),
                color: aneWatts < 0.01 ? nil : .systemPurple)
        } else {
            aneStatusText.publish("--")
        }
        statesFeed.publish(gpu?.performanceStates ?? [], active: gpu?.activeResidency)

        if !didDescribeDevice, let gpu {
            didDescribeDevice = true
            chipName = gpu.name ?? t("Apple silicon GPU")
            var parts: [String] = []
            if let cores = gpu.coreCount { parts.append(t("%@-core GPU", String(cores))) }
            parts.append(t("unified memory"))
            subtitle = parts.joined(separator: " · ")
            chipText.publish(gpu.name ?? "--")
            coresText.publish(gpu.coreCount.map { "\($0)" } ?? "--")
        }
    }

    private static func color(for category: GPUWorkloadCategory) -> NSColor {
        switch category {
        case .aiML: return .systemPurple
        case .displayUI: return .systemBlue
        case .media: return .systemTeal
        case .other: return .systemGray
        }
    }

    private static func point(from s: SystemSample) -> SystemHistoryPoint {
        SystemHistoryPoint(
            date: s.timestamp,
            pressurePercent: s.pressurePercent,
            appMemory: s.appMemory,
            wired: s.wired,
            compressed: s.compressed,
            cachedFiles: s.cachedFiles,
            swapUsed: s.swapUsed,
            cpuLoad: s.cpuLoad,
            gpuUtilization: s.gpuUtilization,
            gpuPowerWatts: s.gpuPowerWatts,
            anePowerWatts: s.anePowerWatts
        )
    }

    private static func makeCardTemplates(feeds: [MetricCardFeed]) -> [MetricCardData] {
        var cards = [
            MetricCardData(
                label: "GPU",
                tint: .green,
                unit: .percent,
                yDomain: 0...100,
                help: "How busy the GPU is right now, 0 to 100. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "The share of each interval the GPU spent executing work, from the graphics driver's own device utilisation counter. It is the same figure Activity Monitor's GPU History shows.",
                    calculation:
                        "IOAccelerator `Device Utilization %`, read from the IORegistry once a second; the sparkline is the value over the selected range."
                )
            ),
            MetricCardData(
                label: "GPU power",
                tint: DiskStyle.read,
                unit: .watts,
                help: "Power drawn by the GPU, in watts. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "How much power the GPU block is drawing. On Apple silicon the GPU shares the chip's power budget with the CPU, so a busy GPU can throttle everything.",
                    calculation:
                        "The chip's GPU energy counter (IOReport `Energy Model`, the source powermetrics uses) differenced between ticks and divided by the elapsed time."
                )
            ),
            MetricCardData(
                label: "Neural Engine",
                tint: .purple,
                unit: .watts,
                help:
                    "Neural Engine power; zero when no Core ML model is running. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "Power drawn by the Apple Neural Engine, the block Core ML runs models on. It reads zero when idle, so any reading means an on-device model is executing. Its work is proxied through a system daemon, so it cannot be attributed to a single process.",
                    calculation:
                        "The chip's ANE energy counter (IOReport `Energy Model`) differenced between ticks."
                )
            ),
            MetricCardData(
                label: "GPU memory",
                tint: .teal,
                unit: .bytes,
                help: "Unified memory currently mapped for the GPU. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "How much of the unified memory is currently in use by GPU clients: textures, buffers, and, for AI runtimes, the model weights. It counts against the same RAM the CPU uses.",
                    calculation:
                        "IOAccelerator `In use system memory`; the allocated figure in the Device panel is the larger amount reserved to GPU clients including cached allocations."
                )
            ),
            MetricCardData(
                label: "Active",
                tint: .orange,
                unit: .percent,
                yDomain: 0...100,
                help: "Share of the time the GPU was powered and clocked. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "How much of the interval the GPU was powered on at all. The difference between this and utilisation is time the GPU was awake but waiting; the Device panel shows which clock states it ran in.",
                    calculation:
                        "100 minus the residency of the OFF state in IOReport's GPU performance-state channel."
                )
            ),
        ]
        for index in cards.indices where index < feeds.count {
            cards[index].live = feeds[index]
        }
        return cards
    }
}

// MARK: - Clock-state bars

/// The GPU's performance-state residency, for a small bar-per-state surface.
final class GPUStatesFeed {
    private(set) var states: [GPUPerformanceState] = []
    private(set) var activeResidency: Double?
    private var observers: [UUID: () -> Void] = [:]

    func publish(_ states: [GPUPerformanceState], active: Double?) {
        guard states != self.states || active != activeResidency else { return }
        self.states = states
        self.activeResidency = active
        for observer in observers.values { observer() }
    }

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

struct GPUStatesSurface: NSViewRepresentable {
    let feed: GPUStatesFeed

    func makeNSView(context: Context) -> GPUStatesSurfaceView {
        let view = GPUStatesSurfaceView()
        view.attach(feed)
        return view
    }

    func updateNSView(_ view: GPUStatesSurfaceView, context: Context) {
        if view.feed !== feed { view.attach(feed) }
    }

    static func dismantleNSView(_ view: GPUStatesSurfaceView, coordinator: ()) {
        view.detach()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: GPUStatesSurfaceView, context: Context
    )
        -> CGSize?
    {
        CGSize(
            width: proposal.width ?? 260,
            height: GPUStatesSurfaceView.height(forStates: feed.states.count))
    }
}

final class GPUStatesSurfaceView: LiveSurfaceView {
    private(set) var feed: GPUStatesFeed?
    private var observation: UUID?
    private let labels = ChartLabelCache()
    private var shownCount = -1
    static let rowHeight: CGFloat = 16
    static let barInset: CGFloat = 44

    static func height(forStates count: Int) -> CGFloat {
        CGFloat(max(1, count + 1)) * rowHeight
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("GPU clock states")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { detach() }

    func attach(_ feed: GPUStatesFeed) {
        detach()
        self.feed = feed
        observation = feed.observe { [weak self] in self?.feedDidPublish() }
        feedDidPublish()
    }

    func detach() {
        if let feed, let observation { feed.stopObserving(observation) }
        observation = nil
        feed = nil
    }

    private func feedDidPublish() {
        guard let feed else { return }
        if feed.states.count != shownCount {
            shownCount = feed.states.count
            invalidateIntrinsicContentSize()
        }
        setAccessibilityValue(
            feed.states.map { "\($0.name) \(Int($0.residency.rounded())) percent" }
                .joined(separator: ", "))
        invalidateContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        labels.invalidate()
        invalidateContent()
    }

    override func paint(in context: CGContext, dirty: CGRect) {
        guard let feed else { return }
        var rows: [(String, Double, NSColor)] = []
        if let active = feed.activeResidency {
            rows.append(("OFF", max(0, 100 - active), .secondaryLabelColor))
        }
        for state in feed.states {
            rows.append((state.name, state.residency, .controlAccentColor))
        }
        guard !rows.isEmpty else {
            labels.label("Reading the GPU\u{2026}", style: .axis).draw(at: .zero, in: context)
            return
        }
        let width = bounds.width
        let barWidth = max(1, width - Self.barInset - 42)
        for (index, row) in rows.enumerated() {
            let y = CGFloat(index) * Self.rowHeight
            let name = labels.label(row.0, style: .legend)
            name.draw(at: CGPoint(x: 0, y: y + 2), in: context)
            let track = CGRect(x: Self.barInset, y: y + 4, width: barWidth, height: 8)
            context.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.15).cgColor)
            context.addPath(
                CGPath(roundedRect: track, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
            let fill = CGRect(
                x: track.minX, y: track.minY,
                width: max(0, track.width * CGFloat(min(100, row.1) / 100)), height: track.height)
            if fill.width > 0 {
                context.setFillColor(row.2.cgColor)
                context.addPath(
                    CGPath(roundedRect: fill, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.fillPath()
            }
            let value = labels.label("\(Int(row.1.rounded()))%", style: .legend)
            value.draw(at: CGPoint(x: width - value.size.width, y: y + 2), in: context)
        }
    }
}

// MARK: - Category share bar

struct GPUShareSlice: Equatable {
    var name: String
    /// The category's summed GPU share, percent of one GPU. Shares overlap on
    /// the GPU, so this is a weight for the bar, not a device figure.
    var percent: Double
    /// Processes in the category that are using the GPU.
    var count: Int
    var color: NSColor
}

final class GPUShareFeed {
    private(set) var slices: [GPUShareSlice] = []
    private var observers: [UUID: () -> Void] = [:]

    func publish(_ slices: [GPUShareSlice]) {
        guard slices != self.slices else { return }
        self.slices = slices
        for observer in observers.values { observer() }
    }

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

struct GPUShareSurface: NSViewRepresentable {
    let feed: GPUShareFeed

    func makeNSView(context: Context) -> GPUShareSurfaceView {
        let view = GPUShareSurfaceView()
        view.attach(feed)
        return view
    }

    func updateNSView(_ view: GPUShareSurfaceView, context: Context) {
        if view.feed !== feed { view.attach(feed) }
    }

    static func dismantleNSView(_ view: GPUShareSurfaceView, coordinator: ()) {
        view.detach()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: GPUShareSurfaceView, context: Context
    )
        -> CGSize?
    {
        CGSize(
            width: proposal.width ?? 260,
            height: GPUShareSurfaceView.height(forSlices: feed.slices.count))
    }
}

final class GPUShareSurfaceView: LiveSurfaceView {
    private(set) var feed: GPUShareFeed?
    private var observation: UUID?
    private let labels = ChartLabelCache()
    private var shownCount = -1
    static let barHeight: CGFloat = 14
    static let rowHeight: CGFloat = 18

    static func height(forSlices count: Int) -> CGFloat {
        barHeight + 10 + CGFloat(max(1, count)) * rowHeight
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("GPU share by category")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { detach() }

    func attach(_ feed: GPUShareFeed) {
        detach()
        self.feed = feed
        observation = feed.observe { [weak self] in self?.feedDidPublish() }
        feedDidPublish()
    }

    func detach() {
        if let feed, let observation { feed.stopObserving(observation) }
        observation = nil
        feed = nil
    }

    private func feedDidPublish() {
        guard let feed else { return }
        if feed.slices.count != shownCount {
            shownCount = feed.slices.count
            invalidateIntrinsicContentSize()
        }
        setAccessibilityValue(
            feed.slices.map { "\($0.name) \(Int($0.percent.rounded())) percent" }
                .joined(separator: ", "))
        invalidateContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        labels.invalidate()
        invalidateContent()
    }

    override func paint(in context: CGContext, dirty: CGRect) {
        guard let feed, !feed.slices.isEmpty else {
            labels.label("Waiting for the first scan\u{2026}", style: .axis).draw(
                at: .zero, in: context)
            return
        }
        let total = feed.slices.reduce(0.0) { $0 + $1.percent }
        let bar = CGRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        context.saveGState()
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.clip()
        context.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor)
        context.fill(bar)
        if total > 0 {
            var x: CGFloat = 0
            for slice in feed.slices where slice.percent > 0 {
                let width = bounds.width * CGFloat(slice.percent / total)
                context.setFillColor(slice.color.cgColor)
                context.fill(CGRect(x: x, y: 0, width: width, height: Self.barHeight))
                x += width
            }
        }
        context.restoreGState()

        for (index, slice) in feed.slices.enumerated() {
            let y = Self.barHeight + 10 + CGFloat(index) * Self.rowHeight
            context.setFillColor(slice.color.cgColor)
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: 0, y: y + 3, width: 9, height: 9), cornerWidth: 2,
                    cornerHeight: 2, transform: nil))
            context.fillPath()
            labels.label(slice.name, style: .legendName).draw(at: CGPoint(x: 14, y: y), in: context)
            let share = total > 0 ? slice.percent / total * 100 : 0
            // One key per grammatical number. The plural "es" used to be passed in
            // as an argument, which cannot survive translation: it surfaced verbatim
            // in the middle of the Chinese sentence.
            let text: String
            if slice.count == 0 {
                text = t("idle")
            } else if slice.count == 1 {
                text = t("%@%% of busy time · 1 process", String(format: "%.0f", share))
            } else {
                text = t(
                    "%1$@%% of busy time · %2$@ processes", String(format: "%.0f", share),
                    String(slice.count))
            }
            let value = labels.label(text, style: .legend)
            value.draw(at: CGPoint(x: bounds.width - value.size.width, y: y + 1), in: context)
        }
    }
}
