import MacPerfMonitorCore
import SwiftUI

/// A single group's detail: the headline blended footprint (% of device
/// capacity) with absolute CPU/memory equivalents and an energy aside, a
/// combined timeline (score / CPU / memory), and the per-member contribution
/// bars that sum to the headline.
struct GroupDetailView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var groupStore: ProcessGroupStore

    let group: ProcessGroup

    @State private var window: HistoryWindow = .oneHour
    @State private var chartMetric: ChartMetric = .memory
    @State private var aggregation: Aggregation = .average
    @State private var report: GroupReport?
    @State private var loading = false
    @State private var showScoreInfo = false
    @State private var editorTarget: GroupEditorTarget?
    /// Identifies the range + rule the currently loaded `report` is for, so the
    /// chart can show a spinner whenever the selection has moved on from what's
    /// loaded — but not during the silent periodic refresh of the same data.
    @State private var loadedKey: LoadKey?

    /// The current definition of this group, read live from the store so an
    /// in-place edit (the Edit button) is reflected here the moment it is saved.
    /// Falls back to the value passed in at navigation time if it has since been
    /// deleted.
    private var liveGroup: ProcessGroup { groupStore.group(id: group.id) ?? group }

    /// True while the loaded report isn't for the currently selected range/rule:
    /// on first open, after changing the time range, or after editing the group.
    /// Drives the chart spinner. The periodic refresh reloads the same key, so it
    /// never trips this and the chart is not flashed.
    private var awaitingData: Bool {
        loadedKey != LoadKey(window: window, rule: liveGroup.rule)
    }

    /// What a loaded report corresponds to: its time range and the group rule it
    /// was built from.
    private struct LoadKey: Equatable {
        var window: HistoryWindow
        var rule: GroupRule
    }

    private enum ChartMetric: String, CaseIterable, Identifiable {
        case memory, cpu, score
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .memory: return "Memory"
            case .cpu: return "CPU"
            case .score: return "Score"
            }
        }
    }

    /// Whether the headline and chart show the window's mean or its peak. Applies
    /// to memory, CPU and the blended score alike. Both are carried in the loaded
    /// series, so toggling is instant — no reload, no spinner.
    private enum Aggregation: String, CaseIterable, Identifiable {
        case average, peak
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .average: return "Average"
            case .peak: return "Peak"
            }
        }
        var isPeak: Bool { self == .peak }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button {
                        editorTarget = .existing(liveGroup)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Spacer()
                    Picker("Window", selection: $window) {
                        ForEach(HistoryWindow.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .historyRangeGate()
                }
                headerCard
                chartCard
                membersCard
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(liveGroup.name)
        .onAppear(perform: reload)
        .onChange(of: window) { reload() }
        .onChange(of: liveGroup.rule) { reload() }
        .onChange(of: model.displayProcessesVersion) {
            if appState.mainWindowVisible { reload() }
        }
        .sheet(item: $editorTarget) { target in
            GroupEditorView(target: target)
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(liveGroup.name)
                    .font(.headline)
                Text(headlineValue)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 4) {
                    Text(headlineCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        showScoreInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("What does this score mean?")
                    .popover(isPresented: $showScoreInfo) { GroupScoreInfoView() }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                metric("Memory", memoryText)
                metric("CPU", coresEquivText)
                metric("Energy impact", energyText)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func metric(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Over time", systemImage: "chart.xyaxis.line").font(.headline)
                Spacer()
                Picker("Aggregation", selection: $aggregation) {
                    ForEach(Aggregation.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(
                    "Average smooths spikes over the window; Peak shows the highest the group reached."
                )
                Picker("Metric", selection: $chartMetric) {
                    ForEach(ChartMetric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if awaitingData {
                chartLoading
                    .frame(height: 200)
            } else if let series = chartSeries, series.points.count >= 2 {
                TrendChart(
                    series: [series], xDomain: chartDomain,
                    yFormat: chartYFormat, showsTimeAxis: true
                )
                .frame(height: 200)
            } else {
                placeholder("No history logged for this window yet.")
                    .frame(height: 200)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var chartSeries: TrendSeries? {
        guard let report else { return nil }
        let peak = aggregation.isPeak
        let points: [TrendPoint]
        switch chartMetric {
        case .score:
            points = report.scorePoints(peak: peak).map {
                TrendPoint(date: $0.date, value: $0.value)
            }
        case .cpu:
            points = report.series.map {
                TrendPoint(
                    date: $0.date,
                    value: (peak ? $0.cpuPeakPercent : $0.cpuPercent) / 100)  // cores-equivalent
            }
        case .memory:
            points = report.series.map {
                TrendPoint(
                    date: $0.date,
                    value: Double(peak ? $0.footprintPeak : $0.footprint) / 1_073_741_824)  // GB
            }
        }
        return TrendSeries(points: points, color: .accentColor, filled: true)
    }

    private var chartDomain: ClosedRange<Date>? {
        LiveChartGeometry.trailingDomain(latest: report?.series.last?.date, span: window.seconds)
    }

    private var chartYFormat: (Double) -> String {
        switch chartMetric {
        case .score: return { String(format: "%.1f%%", $0) }
        case .cpu: return { String(format: "%.1f", $0) }
        case .memory: return { String(format: "%.1f GB", $0) }
        }
    }

    // MARK: - Members

    private var membersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Member contributions", systemImage: "person.3").font(.headline)
            if let report, !report.members.isEmpty {
                let lookup = Dictionary(
                    report.members.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                VStack(spacing: 0) {
                    ForEach(Array(report.decomposition.contributions.enumerated()), id: \.offset) {
                        index, contribution in
                        if index > 0 { Divider() }
                        if let member = lookup[contribution.id] {
                            MemberRow(
                                member: member, contribution: contribution,
                                windowSeconds: window.seconds, tint: .accentColor)
                        }
                    }
                }
            } else {
                placeholder(loading ? "Loading…" : "No processes recorded in this window.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    /// A spinner that fills the chart's area while the first report for this
    /// window loads, shown in place of the chart itself.
    private var chartLoading: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("Loading\u{2026}")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }

    // MARK: - Derived text

    /// The group's CPU over the window (percent of one core; can exceed 100):
    /// the window mean, or its peak when the Peak lens is selected.
    private var totalCPUPercent: Double {
        guard let report else { return 0 }
        return aggregation.isPeak ? report.peakCPUPercent : report.averageCPUPercent
    }

    /// The group's physical footprint over the window, in bytes: the window mean
    /// of the concurrent member footprint, or its peak when the Peak lens is
    /// selected. Neither sums restarted processes as if they were co-resident.
    private var totalFootprint: UInt64 {
        guard let report else { return 0 }
        return aggregation.isPeak ? report.peakFootprint : report.averageFootprint
    }

    /// The big headline figure — follows the selected metric so it matches the
    /// chart: Memory as a % of RAM, CPU as a % of all cores, or the blended score
    /// (all as a share of this device).
    private var headlineValue: String {
        guard let report else { return loading ? "…" : "—" }
        let device = report.device
        switch chartMetric {
        case .memory:
            guard device.totalRAM > 0 else { return "—" }
            return String(format: "%.1f%%", Double(totalFootprint) / Double(device.totalRAM) * 100)
        case .cpu:
            guard device.cores > 0 else { return "—" }
            return String(format: "%.1f%%", totalCPUPercent / Double(device.cores))
        case .score:
            return String(format: "%.1f%%", aggregation.isPeak ? report.peakScore : report.score)
        }
    }

    private var headlineCaption: String {
        guard let report else { return t("of this device's capacity") }
        let device = report.device
        switch chartMetric {
        case .memory:
            return t(
                "%1$@ of %2$@ RAM", ByteFormat.string(totalFootprint),
                ByteFormat.string(device.totalRAM))
        case .cpu:
            return t("%1$.2f of %2$d cores", totalCPUPercent / 100, device.cores)
        case .score:
            return t("of this device's capacity (CPU + memory)")
        }
    }

    private var coresEquivText: String {
        guard report != nil else { return "—" }
        return t("%.2f cores", totalCPUPercent / 100)
    }

    private var memoryText: String {
        guard report != nil else { return "—" }
        return ByteFormat.string(totalFootprint)
    }

    private var energyText: String {
        guard let report else { return "—" }
        return String(format: "%.0f", report.totalEnergy)
    }

    // MARK: - Loading

    private func reload() {
        loading = true
        let requested = LoadKey(window: window, rule: liveGroup.rule)
        let glossary = ProcessGlossaryStore.shared.glossary
        model.loadGroupReport(group: liveGroup, window: requested.window, glossary: glossary) {
            report in
            self.report = report
            self.loadedKey = requested
            self.loading = false
        }
    }
}

/// The optional "what is this score?" explainer, shown from an info button on the
/// Groups list and a group's detail. Frames the score around the IT-admin use
/// case: quantifying a stack's cost to inform hardware choices.
struct GroupScoreInfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Footprint score", systemImage: "gauge.with.dots.needle.33percent")
                .font(.headline)

            Text(
                "A single figure for how much of **this Mac's capacity** a group of processes uses — an even blend of two shares:"
            )
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                bullet("CPU", "the group's CPU as a share of all cores")
                bullet("Memory", "its memory as a share of total RAM")
            }

            Text(
                "Energy is shown separately, not folded in. Each member's percentage is its share of the group's score."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            Text("Why a share of the device?").font(.callout.weight(.semibold))
            Text(
                "It's built to size hardware. The same security / IT stack reads as a bigger number on a smaller machine — a 10% footprint leaves far less headroom on an 8 GB laptop than on a 16 GB one. So you can see whether your tooling is pushing you toward more expensive Macs to keep users happy."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Note: memory usually dominates the blend.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func bullet(_ term: LocalizedStringKey, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(term).font(.callout.weight(.semibold)) + Text(" — \(t(desc))").font(.callout)
        }
    }
}

/// One member's contribution row: icon, name, its footprint score, and a bar of
/// its share of the group total.
///
/// A member is a program, not a PID: restarts and an app's concurrent helper
/// instances are already merged upstream (see `GroupMemberProgram`), so the row
/// carries an instance count and, when the program was not up for the whole
/// window, how much of it the program was actually around for. Its memory and CPU
/// are what the program's instances weighed **together while running**, so a
/// short-lived process reads at its true size rather than being diluted by the
/// time it was absent.
private struct MemberRow: View {
    let member: GroupMemberProgram
    let contribution: GroupFootprint.Contribution<String>
    /// The selected window, for the "ran x of y" read-out.
    let windowSeconds: TimeInterval
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: member.executablePath))
                .resizable().frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if member.instanceCount > 1 {
                        Text("\u{00D7}\(member.instanceCount)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help(instanceHelp)
                    }
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f%%", contribution.share * 100))
                        .font(.body.monospacedDigit().weight(.semibold))
                }
                GroupProportionBar(fraction: contribution.share, tint: tint)
                Text(secondaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .processRowActions(identity: member.representative)
    }

    private var secondaryLine: String {
        var line = t(
            "%1$@ · %2$.1f%% CPU · footprint %3$.1f%%",
            ByteFormat.string(member.averageFootprint), member.averageCPU, contribution.score)
        if let residency { line += " · \(residency)" }
        return line
    }

    /// "ran 12 of 60 min" when the program was up for less than the window,
    /// which is what explains a merged row whose average looks high against a
    /// modest share. Omitted for programs that ran throughout (the common case),
    /// with a little slack for sampling edges.
    private var residency: String? {
        guard windowSeconds > 0, member.residentSeconds < windowSeconds * 0.95 else { return nil }
        return t(
            "ran %1$@ of %2$@", DurationFormat.compact(member.residentSeconds),
            DurationFormat.compact(windowSeconds))
    }

    private var instanceHelp: String {
        let count = member.instanceCount
        return t(
            "%@ recorded runs of this program in the window (restarts and simultaneous instances), merged into one row.",
            String(count))
    }
}

/// Short human durations for the group member rows ("45 s", "12 min", "3 hr").
enum DurationFormat {
    static func compact(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 90 { return t("%@ s", String(s)) }
        if s < 90 * 60 { return t("%@ min", String(Int((Double(s) / 60).rounded()))) }
        if s < 48 * 3600 { return t("%@ hr", String(Int((Double(s) / 3600).rounded()))) }
        return t("%@ days", String(Int((Double(s) / 86_400).rounded())))
    }
}
