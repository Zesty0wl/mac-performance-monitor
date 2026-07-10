import Charts
import MacPerfMonitorCore
import SwiftUI

/// The Insights tab (PRD section 8.5): the `InsightEngine`'s ranked,
/// plain-language findings as severity-tinted headline cards, then the visual
/// evidence behind them — a pressure timeline with each spike marked, leak
/// cards with the actual growth curves, a proportional top-consumers
/// leaderboard, and the Rosetta cost. Reads run off the main thread via
/// `SamplerModel`; the live snapshot backs the Rosetta view.
struct InsightsView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState

    @State private var bundle = SamplerModel.InsightsBundle()
    @State private var window: HistoryWindow = .oneHour
    @State private var metric: ConsumerMetric = .averageFootprint
    @State private var consumers: [ProcessConsumer] = []
    @State private var loadingBundle = false
    @State private var loadingConsumers = false
    @State private var loadedOnce = false
    /// The Rosetta cost snapshot, refreshed once per reload (see `reloadAll`).
    @State private var rosetta: (cost: RosettaCost, processes: [ProcessSample])?

    /// The identities the leak board currently flags, so the top-consumers list
    /// can mark the same suspects with the shared leak icon.
    private var leakingIDs: Set<ProcessIdentity> { Set(bundle.leaks.map(\.identity)) }

    var body: some View {
        Group {
            if !loadedOnce {
                loadingState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !model.hasHistory {
                            unavailableNote
                        }

                        HeadlineInsightsSection(insights: bundle.insights)

                        PressureTimelineSection(
                            history: bundle.pressureHistory, events: bundle.events)

                        if !bundle.leaks.isEmpty {
                            LeakBoardSection(entries: bundle.leaks, series: bundle.leakSeries)
                        }

                        TopConsumersSection(
                            consumers: consumers,
                            window: $window,
                            metric: $metric,
                            leakingIDs: leakingIDs,
                            loading: loadingConsumers
                        )

                        if let rosetta {
                            RosettaSection(summary: rosetta)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear(perform: reloadAll)
        .onChange(of: window) { reloadConsumers() }
        .onChange(of: metric) { reloadConsumers() }
        .onChange(of: model.displayProcessesVersion) {
            if appState.mainWindowVisible { reloadAll() }
        }
    }

    private var unavailableNote: some View {
        Label(
            "History store unavailable. Showing live data only where possible.",
            systemImage: "externaldrive.badge.xmark"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Shown until the first bundle load lands, so the page never sits blank with
    /// no sign that anything is happening. A large, centred spinner that fills the
    /// tab rather than a small one stranded at the top.
    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .scaleEffect(1.4)
            Text("Loading insights\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func reloadAll() {
        loadingBundle = true
        // Snapshotted once per reload (the table cadence): as a body-inline call
        // this O(processes) filter+sort re-ran on every body evaluation.
        rosetta = model.rosettaSummary()
        model.loadInsightsBundle {
            self.bundle = $0
            self.loadingBundle = false
            self.loadedOnce = true
        }
        reloadConsumers()
    }

    private func reloadConsumers() {
        loadingConsumers = true
        model.loadTopConsumers(window: window, metric: metric) {
            self.consumers = $0
            self.loadingConsumers = false
        }
    }
}

// MARK: - Section container

/// A titled card used by each History section, matching the app's panel style.
private struct HistorySection<Content: View>: View {
    let title: String
    let systemImage: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(
        _ title: String, systemImage: String, subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

/// A thin capsule bar showing a value's share of the section maximum, so a
/// leaderboard reads at a glance instead of as a column of numbers.
private struct ProportionBar: View {
    let fraction: Double
    var tint: Color = .blue

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Headline insights

/// UI styling for the engine's insights. Kept here because `MacPerfMonitorCore` is
/// intentionally free of any SwiftUI dependency.
extension InsightEngine.Insight {
    var tint: Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .advisory: return .blue
        case .info: return .teal
        case .allClear: return .green
        }
    }

    var symbolName: String {
        switch kind {
        case .leak: return "arrow.up.right.circle.fill"
        case .pressure: return "waveform.path.ecg"
        case .attribution: return "scope"
        case .stepChange: return "bolt.fill"
        case .swap: return "internaldrive"
        case .rosetta: return "cpu"
        case .cpu: return "gauge.with.dots.needle.67percent"
        case .network: return "network"
        case .allClear: return "checkmark.circle.fill"
        }
    }
}

private struct HeadlineInsightsSection: View {
    let insights: [InsightEngine.Insight]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What's happening", systemImage: "sparkles")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 340), spacing: 10)],
                alignment: .leading, spacing: 10
            ) {
                ForEach(insights) { insight in
                    InsightCard(insight: insight)
                }
            }
        }
        .animation(.default, value: insights.map(\.id))
    }
}

private struct InsightCard: View {
    let insight: InsightEngine.Insight

    var body: some View {
        if let identity = insight.identity {
            card.processRowActions(identity: identity)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.symbolName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(insight.tint.gradient, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(insight.headline)
                    .font(.body.weight(.semibold))
                Text(insight.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let metricText = insight.metricText {
                Text(metricText)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(insight.tint)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(insight.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(insight.tint.opacity(0.25))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.headline). \(insight.detail)")
    }
}

// MARK: - Pressure timeline

private struct PressureTimelineSection: View {
    let events: [PressureEvent]

    /// Cap the plotted points so two hours of 2-second samples stay cheap.
    /// Thinned once at construction — as a computed property this re-bucketed
    /// the full window on every body evaluation (it is read several times per
    /// render).
    private let points: [SystemHistoryPoint]
    private let windowColor: Color

    init(history: [SystemHistoryPoint], events: [PressureEvent]) {
        self.events = events
        let points = history.chartDownsampled(span: 2 * 3600, to: 360)
        self.points = points
        let peak = points.lazy.map(\.pressurePercent).max() ?? 0
        if peak >= 67 {
            self.windowColor = .red
        } else if peak >= 34 {
            self.windowColor = .orange
        } else {
            self.windowColor = .green
        }
    }

    var body: some View {
        HistorySection(
            "Pressure events", systemImage: "waveform.path.ecg",
            subtitle: "The last 2 hours of memory pressure, with each spike marked."
        ) {
            if points.count >= 2 {
                chart
                    .frame(height: 140)
                    .padding(.bottom, 4)
            }
            if events.isEmpty {
                EmptyRow(
                    text: "No pressure events in the last 2 hours. Memory has stayed comfortable.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider() }
                        PressureEventRow(event: event)
                    }
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            RuleMark(y: .value("Warning", 34))
                .foregroundStyle(.orange.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("Critical", 67))
                .foregroundStyle(.red.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Pressure", point.pressurePercent)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [windowColor.opacity(0.35), windowColor.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Pressure", point.pressurePercent)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(windowColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }

            ForEach(events) { event in
                PointMark(
                    x: .value("Time", event.date),
                    y: .value("Pressure", pressure(at: event.date))
                )
                .foregroundStyle(event.level.color)
                .symbolSize(90)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 34, 67, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)") }
                }
            }
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Memory pressure timeline with pressure events marked")
        .reducedMotionAware()
    }

    /// The plotted pressure nearest an event's moment, so its marker sits on the
    /// curve.
    private func pressure(at date: Date) -> Double {
        points.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })?.pressurePercent ?? 0
    }
}

private struct PressureEventRow: View {
    let event: PressureEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.level.symbolName)
                .foregroundStyle(event.level.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pressure rose to \(event.level.label)")
                    .font(.body.weight(.medium))
                Text(driverLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(event.date.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                Text(event.date.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var driverLine: String {
        if let name = event.dominantName {
            return "Largest consumer: \(name) (\(ByteFormat.string(event.dominantFootprint)))"
        }
        return "No dominant process recorded"
    }
}

// MARK: - Leak board

private struct LeakBoardSection: View {
    let entries: [LeakBoardEntry]
    let series: [ProcessIdentity: [ProcessHistoryPoint]]

    var body: some View {
        HistorySection(
            "Suspected leaks", systemImage: "arrow.up.right.circle.fill",
            subtitle: "Processes growing steadily over the last 2 hours, with their growth curves."
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 10)],
                alignment: .leading, spacing: 10
            ) {
                ForEach(entries) { entry in
                    LeakCard(
                        entry: entry,
                        values: (series[entry.identity] ?? []).map { Double($0.footprint) }
                    )
                }
            }
        }
    }
}

private struct LeakCard: View {
    let entry: LeakBoardEntry
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(
                    nsImage: ProcessIconProvider.shared.icon(forPath: entry.executablePath)
                )
                .resizable()
                .frame(width: 18, height: 18)
                Text(entry.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.isTranslated { RosettaBadge() }
                Spacer(minLength: 8)
                Text("\(Int((entry.finding.confidence * 100).rounded()))% confident")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }

            if values.count >= 2 {
                Sparkline(values: values)
                    .tint(.orange)
                    .frame(height: 40)
            }

            HStack(spacing: 18) {
                stat("Grew", "+\(ByteFormat.string(entry.finding.totalGrowth))")
                stat(
                    "Rate",
                    "~\(ByteFormat.string(UInt64(max(entry.finding.slopeBytesPerSecond, 0))))/s")
                stat("Now", ByteFormat.string(entry.latestFootprint))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.2))
        )
        .processRowActions(identity: entry.identity)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Top consumers

private struct TopConsumersSection: View {
    let consumers: [ProcessConsumer]
    @Binding var window: HistoryWindow
    @Binding var metric: ConsumerMetric
    var leakingIDs: Set<ProcessIdentity> = []
    var loading: Bool = false

    private func value(_ consumer: ProcessConsumer) -> Double {
        switch metric {
        case .averageFootprint: return Double(consumer.averageFootprint)
        case .peakFootprint: return Double(consumer.peakFootprint)
        case .averageCPU: return consumer.averageCPU
        case .averageEnergy: return consumer.averageEnergy
        case .averageNetwork: return consumer.averageNetwork
        case .averageDisk: return consumer.averageDisk
        }
    }

    var body: some View {
        HistorySection(
            "Top consumers", systemImage: "chart.bar.fill",
            subtitle: consumerSubtitle
        ) {
            HStack {
                Picker("Window", selection: $window) {
                    ForEach(HistoryWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .historyRangeGate()

                if loading {
                    ProgressView().controlSize(.small).padding(.leading, 6)
                }

                Spacer(minLength: 12)

                Picker("Rank by", selection: $metric) {
                    ForEach(ConsumerMetric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if consumers.isEmpty {
                EmptyRow(text: "No data logged for this window yet.")
            } else {
                let top = consumers.map(value).max() ?? 1
                VStack(spacing: 0) {
                    ForEach(Array(consumers.enumerated()), id: \.element.id) { index, consumer in
                        if index > 0 { Divider() }
                        ConsumerRow(
                            rank: index + 1, consumer: consumer, metric: metric,
                            fraction: top > 0 ? value(consumer) / top : 0,
                            isLeaking: leakingIDs.contains(consumer.identity))
                    }
                }
            }
        }
    }

    private var consumerSubtitle: String {
        switch metric {
        case .averageFootprint, .peakFootprint:
            return "Heaviest memory users over the selected window."
        case .averageCPU: return "Highest average CPU use over the selected window."
        case .averageEnergy: return "Highest average energy impact over the selected window."
        case .averageNetwork: return "Highest average network throughput over the selected window."
        case .averageDisk: return "Highest attributed disk throughput over the selected window."
        }
    }
}

private struct ConsumerRow: View {
    let rank: Int
    let consumer: ProcessConsumer
    let metric: ConsumerMetric
    let fraction: Double
    var isLeaking = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Image(
                nsImage: ProcessIconProvider.shared.icon(forPath: consumer.executablePath)
            )
            .resizable()
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(consumer.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if consumer.isTranslated {
                        RosettaBadge()
                    }
                    if isLeaking {
                        LeakIndicator()
                    }
                    Spacer(minLength: 8)
                    Text(primaryText)
                        .font(.body.monospacedDigit().weight(.semibold))
                }
                ProportionBar(fraction: fraction, tint: isLeaking ? .orange : .blue)
                Text(secondaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .processRowActions(identity: consumer.identity)
    }

    private var primaryText: String {
        switch metric {
        case .averageFootprint: return ByteFormat.string(consumer.averageFootprint)
        case .peakFootprint: return ByteFormat.string(consumer.peakFootprint)
        case .averageCPU: return String(format: "%.1f%%", consumer.averageCPU)
        case .averageEnergy: return String(format: "%.0f", consumer.averageEnergy)
        case .averageNetwork: return ByteFormat.rate(consumer.averageNetwork)
        case .averageDisk: return ByteFormat.rate(consumer.averageDisk)
        }
    }

    private var secondaryLine: String {
        switch metric {
        case .averageFootprint:
            return
                "peak \(ByteFormat.string(consumer.peakFootprint)) · \(consumer.sampleCount) samples"
        case .peakFootprint:
            return
                "avg \(ByteFormat.string(consumer.averageFootprint)) · \(consumer.sampleCount) samples"
        case .averageCPU:
            return
                "avg \(ByteFormat.string(consumer.averageFootprint)) memory · \(consumer.sampleCount) samples"
        case .averageEnergy:
            return "relative energy impact · \(consumer.sampleCount) samples"
        case .averageNetwork:
            return "download + upload · \(consumer.sampleCount) samples"
        case .averageDisk:
            return "attributed read + write · \(consumer.sampleCount) samples"
        }
    }
}

// MARK: - Rosetta

private struct RosettaSection: View {
    let summary: (cost: RosettaCost, processes: [ProcessSample])

    var body: some View {
        HistorySection(
            "Rosetta cost", systemImage: "cpu",
            subtitle: "Memory used right now by Intel apps running under translation."
        ) {
            if summary.cost.processCount == 0 {
                EmptyRow(
                    text: "No translated processes running. Everything is native Apple silicon.")
            } else {
                HStack(spacing: 24) {
                    metric("Processes", "\(summary.cost.processCount)")
                    metric("Total footprint", ByteFormat.string(summary.cost.totalFootprint))
                }
                .padding(.bottom, 4)

                let top = summary.processes.first?.physFootprint ?? 1
                VStack(spacing: 0) {
                    ForEach(Array(summary.processes.prefix(8).enumerated()), id: \.element.id) {
                        index, process in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Image(
                                nsImage: ProcessIconProvider.shared.icon(
                                    forPath: process.executablePath)
                            )
                            .resizable()
                            .frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(process.displayName)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(ByteFormat.string(process.physFootprint))
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                ProportionBar(
                                    fraction: top > 0
                                        ? Double(process.physFootprint) / Double(top) : 0,
                                    tint: .orange)
                            }
                        }
                        .padding(.vertical, 6)
                        .processRowActions(identity: process.id)
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared

private struct RosettaBadge: View {
    var body: some View {
        Text("Rosetta")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
    }
}
