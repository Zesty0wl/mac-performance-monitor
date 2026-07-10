import Charts
import MacPerfMonitorCore
import SwiftUI

/// The dashboard tab (PRD section 8.2): a page header with the machine's
/// identity and a single time-range control, the headline memory figures, then
/// consistent bordered panels for the memory-pressure timeline, the processor,
/// the live memory composition, and swap. The range control drives every
/// timeline (and the headline cards' trend sparklines); the composition and
/// core grid are live. Suspected leaks are highlighted in the Processes list,
/// not here.
struct DashboardView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState

    @State private var range: HistoryWindow = .oneHour
    @State private var history: [SystemHistoryPoint] = []
    /// The downsampled timeline + live point, memoized in @State and recomputed
    /// only when the source data changes. Computing this inside the chart/card
    /// bodies re-ran `chartDownsampled` on every layout pass (several times per
    /// render) and handed Charts a fresh array each time — a layout loop.
    @State private var points: [SystemHistoryPoint] = []
    /// The range the loaded `history` / `points` are for, so the charts and cards
    /// can show a spinner while a range change is still loading — but not during
    /// the silent 5-second refresh of the same range.
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
                headlineNumbers
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
        // Reload at the global refresh interval — driven by the sampler's
        // table-cadence data signal so this honours the toolbar interval control
        // rather than a fixed timer. Skipped while the window is off screen.
        .onChange(of: model.displayProcessesVersion) {
            if appState.mainWindowVisible { reload() }
        }
        .onChange(of: model.latest?.system.timestamp) { _, _ in
            if appState.mainWindowVisible { rebuildPoints() }
        }
        .onChange(of: appState.mainWindowVisible) { _, visible in if visible { reload() } }
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
                Text(systemSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// "10 cores (6P + 4E) · 32 GB memory", omitting parts that aren't known yet.
    private var systemSubtitle: String {
        var parts: [String] = []
        let cores = topology.logicalCores
        if topology.performanceCoreCount > 0 && topology.efficiencyCoreCount > 0 {
            parts.append(
                "\(cores) cores (\(topology.performanceCoreCount)P + \(topology.efficiencyCoreCount)E)"
            )
        } else {
            parts.append("\(cores) core\(cores == 1 ? "" : "s")")
        }
        if let ram = model.latest?.system.totalRAM, ram > 0 {
            parts.append("\(ByteFormat.string(ram)) memory")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Headline numbers

    /// The headline memory figures as the shared metric cards (no inline header —
    /// the page header carries the context), each with a trend over the range.
    private var headlineNumbers: some View {
        MetricCardsRow(
            cards: MemoryMetrics.cards(
                system: model.latest?.system, history: points, span: range.seconds),
            loading: awaitingData)
    }

    // MARK: - Panels

    private var pressurePanel: some View {
        DashboardPanel("Memory pressure", systemImage: "gauge.with.dots.needle.50percent") {
            PressureChart(
                points: points,
                currentLevel: model.latest?.system.pressureLevel ?? .normal,
                showsTimeAxis: true
            )
            .frame(height: 180)
            .chartReloading(awaitingData)
            buildingHistoryNote
        }
    }

    private var processorPanel: some View {
        // Smoothed for the instantaneous read-outs and the core grid so they
        // settle; the timeline still plots raw history (real spikes intact).
        let cpu = model.smoothedCPU
        let level = CPULevel(fraction: cpu?.totalUsage ?? 0)
        let hasClusters = topology.efficiencyCoreCount > 0 && topology.performanceCoreCount > 0
        return DashboardPanel("Processor", systemImage: "cpu") {
            CPUChart(points: points, currentLevel: level, showsTimeAxis: true)
                .frame(height: 160)
                .chartReloading(awaitingData)

            Divider().opacity(0.5)

            HStack(alignment: .top, spacing: 28) {
                cpuStat("Total", cpu.map { percent($0.totalUsage) } ?? "—", level.color)
                if hasClusters {
                    cpuStat(
                        "Performance", cpu.map { percent($0.performanceUsage) } ?? "—",
                        CoreKind.performance.accent)
                    cpuStat(
                        "Efficiency", cpu.map { percent($0.efficiencyUsage) } ?? "—",
                        CoreKind.efficiency.accent)
                }
                cpuStat(
                    "Load avg", cpu.map { String(format: "%.2f", $0.loadAverage1) } ?? "—",
                    .primary)
                Spacer(minLength: 0)
            }

            footnote(
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
            CoreGridView(cores: model.smoothedCPU?.cores ?? [])
        }
    }

    private var compositionPanel: some View {
        DashboardPanel("Memory composition", systemImage: "chart.bar.fill") {
            TaxonomySection(
                slices: taxonomySlices, total: model.latest?.system.totalRAM ?? 0)
        }
    }

    private var networkPanel: some View {
        // Live smoothed rates for the read-out; the timeline plots logged history.
        let rates = model.smoothedNetworkRates
        return DashboardPanel("Network", systemImage: "network") {
            HStack(spacing: 24) {
                networkStat(
                    "Download", rates?.inBytesPerSec, NetworkStyle.download, NetworkStyle.downSymbol
                )
                networkStat(
                    "Upload", rates?.outBytesPerSec, NetworkStyle.upload, NetworkStyle.upSymbol)
                Spacer(minLength: 0)
            }
            NetworkChart(points: points, showsTimeAxis: true)
                .frame(height: 150)
                .chartReloading(awaitingData)
            footnote(
                "Download and upload throughput across the Wi-Fi and Ethernet interfaces. "
                    + "Turn on per-app network tracking in Settings to see which apps are responsible."
            )
        }
    }

    private func networkStat(
        _ label: String, _ bytesPerSec: Double?, _ tint: Color, _ symbol: String
    )
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(bytesPerSec.map { ByteFormat.rate($0) } ?? "—")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
    }

    private var swapPanel: some View {
        DashboardPanel("Swap", systemImage: "internaldrive") {
            SwapChart(points: points)
                .frame(height: 110)
                .chartReloading(awaitingData)
            footnote(
                "Swap is memory moved out to disk. A flat line at zero is ideal; a sustained climb "
                    + "under pressure is the real warning sign.")
        }
    }

    private var diskPanel: some View {
        let rates = model.smoothedDiskRates
        let disk = model.latestDisk
        return DashboardPanel("Physical disk", systemImage: "internaldrive") {
            HStack(spacing: 24) {
                diskStat("Read", rates?.readBytesPerSec, DiskStyle.read)
                diskStat("Write", rates?.writeBytesPerSec, DiskStyle.write)
                if let disk {
                    cpuStat(
                        "IOPS",
                        "\(Int((disk.readOperationsPerSec + disk.writeOperationsPerSec).rounded()))",
                        .primary)
                }
                Spacer(minLength: 0)
            }
            DiskChart(points: points, showsTimeAxis: true)
                .frame(height: 150)
                .chartReloading(awaitingData)
            footnote(
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
            footnote("Kernel-attributed I/O; it may not add up to physical traffic.")
        }
    }

    private func diskStat(_ label: String, _ value: Double?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value.map { ByteFormat.rate($0) } ?? "--")
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    // MARK: - Shared bits

    @ViewBuilder private var buildingHistoryNote: some View {
        if points.count < 2 {
            footnote(
                model.hasHistory
                    ? "Building history for this range…"
                    : "History store unavailable; showing live data only.")
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func cpuStat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    // MARK: - Derived

    private var taxonomySlices: [TaxonomySlice] {
        guard let system = model.latest?.system else { return [] }
        return TaxonomyBreakdown.compute(system)
    }

    /// Cap on plotted points: the timelines redraw as each live point lands, so
    /// the raw window is collapsed to a bounded series the redraw can afford.
    private static let maxChartPoints = 360

    /// Recompute the memoized `points`: the pre-thinned loaded history plus the
    /// latest live sample appended on the right edge so the chart tracks the
    /// current tick. The downsampling itself happens on the model's read queue
    /// (`downsampledTo:`), so this per-tick step is O(chart points), not
    /// O(raw window). Called only when `history` reloads or a new sample lands
    /// — never during a layout pass.
    private func rebuildPoints() {
        var pts = history
        if let system = model.latest?.system {
            let live = SystemHistoryPoint(
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
                diskWriteOperationsPerSec: system.diskWriteOperationsPerSec
            )
            if let last = pts.last {
                if live.date > last.date { pts.append(live) }
            } else {
                pts.append(live)
            }
        }
        points = pts
    }

    private func reload() {
        let requested = range
        model.loadSystemHistory(requested, downsampledTo: Self.maxChartPoints) { pts in
            self.history = pts
            self.loadedRange = requested
            self.rebuildPoints()
        }
        model.loadTopConsumers(window: requested, metric: .averageDisk, limit: 6) { rows in
            guard self.range == requested else { return }
            self.topDiskConsumers = rows
        }
    }
}

/// A titled, bordered content card — the dashboard's one structural unit, so
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
