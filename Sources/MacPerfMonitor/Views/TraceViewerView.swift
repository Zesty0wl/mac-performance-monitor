// SPDX-License-Identifier: MIT

import MacPerfMonitorCore
import SwiftUI

/// A read-only viewer for an imported `.mpmtrace` file, shown inline in the
/// Analytics tab in place of the live Performance Monitor. It reuses the same
/// chart grid, focus/zoom, timeline scrubber, and statistics as the live view,
/// but draws from the fixed in-memory trace rather than the sampler or database,
/// so a shared trace can be explored exactly like live data, even when none of
/// its processes exist on this Mac.
struct TraceViewerView: View {
    let trace: ImportedTrace
    /// Return to the live Performance Monitor.
    let onClose: () -> Void

    @State private var identities: [ProcessIdentity] = []
    @State private var activeIdentities: [ProcessIdentity] = []
    @State private var seriesIndexes: [ProcessIdentity: Int] = [:]
    @State private var names: [ProcessIdentity: String] = [:]
    @State private var colorSlots: [ProcessIdentity: Int] = [:]
    @State private var hasNetworkData = false
    /// The whole covered window, computed once on appear (not per body pass).
    @State private var fullDomain: ClosedRange<Date> = Date()...Date().addingTimeInterval(1)

    @State private var zoom = ChartZoomState(fullDomain: Date()...Date().addingTimeInterval(1))
    @State private var focusedMetric: PerfMetric?
    @State private var seriesByMetric: [PerfMetric: [PerfSeries]] = [:]
    @State private var focusedSeries: [PerfSeries] = []
    @State private var focusedStats: [SeriesStat] = []
    @State private var showStats = false
    @State private var highlighted: ProcessIdentity?
    @State private var zoomUpdates = FrameCoalescedValue<ChartZoomState>()
    @State private var projectionWorker = TraceProjectionWorker()

    private var document: ProcessTraceDocument { trace.document }

    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .red, .indigo,
    ]
    private static let maxPointsPerSeries = 300
    private static let maxPointsFocused = 600
    private static let maxActiveProcesses = TraceViewerPreparation.maximumActiveProcesses
    private static let minZoomSpan: TimeInterval = 20
    private static let legendRowHeight: CGFloat = 40
    private static let maxVisibleLegendRows = 5

    var body: some View {
        VStack(spacing: 14) {
            banner
            chartArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !identities.isEmpty {
                TimelineScrubber(
                    fullDomain: fullDomain,
                    visibleDomain: zoom.visibleDomain,
                    minSpan: Self.minZoomSpan,
                    onScrub: { setVisibleWindow($0) },
                    onZoom: { applyZoom(anchor: $0, factor: $1) },
                    onPan: { applyPan(deltaSeconds: $0) })
            }
            seriesPanel
        }
        .padding(16)
        .onAppear(perform: prepare)
        .onDisappear {
            zoomUpdates.cancel()
            projectionWorker.cancel()
        }
    }

    // MARK: - Banner

    private var banner: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Imported trace")
                        .font(.subheadline.weight(.semibold))
                    Text(trace.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(provenanceLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button {
                onClose()
            } label: {
                Label("Close trace", systemImage: "xmark")
            }
            .help("Close this trace and return to live data.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.25)))
    }

    /// "3 processes · 6 hr · macOS 15.5 · MacBookPro18,3 · exported 8 Jul 2026, 14:32"
    private var provenanceLine: String {
        var parts: [String] = []
        let count = document.processes.count
        parts.append("\(count) \(count == 1 ? "process" : "processes")")
        parts.append(
            Self.durationLabel(fullDomain.upperBound.timeIntervalSince(fullDomain.lowerBound)))
        parts.append(document.source.osVersion)
        if let model = document.source.machineModel { parts.append(model) }
        parts.append("exported \(Self.exportedFormatter.string(from: document.exportedAt))")
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Chart area

    @ViewBuilder
    private var chartArea: some View {
        if identities.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14))
        } else if let focusedMetric {
            focusedCell(focusedMetric)
        } else {
            chartGrid
        }
    }

    private var chartGrid: some View {
        VStack(spacing: 12) {
            if hasNetworkData {
                HStack(spacing: 12) {
                    metricCell(.memory)
                    metricCell(.cpu)
                    metricCell(.network)
                }
                HStack(spacing: 12) {
                    metricCell(.fileDescriptors)
                    metricCell(.diskIO)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 12) {
                    metricCell(.memory)
                    metricCell(.cpu)
                }
                HStack(spacing: 12) {
                    metricCell(.fileDescriptors)
                    metricCell(.diskIO)
                }
            }
        }
    }

    private func metricCell(_ metric: PerfMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    focus(metric)
                } label: {
                    Label(metric.label, systemImage: metric.systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Focus this chart to zoom and pan")
                Button {
                    focus(metric)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Focus this chart to zoom and pan")
                Spacer(minLength: 6)
                Text(metric.caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            let series = seriesByMetric[metric] ?? []
            PerformanceChart(
                series: series,
                xDomain: zoom.visibleDomain,
                minTop: metric.minTop,
                highlighted: highlighted,
                accessibilityTitle: metric.label,
                scrollZoom: ChartZoomActions(
                    zoom: { applyZoom(anchor: $0, factor: $1) },
                    pan: { applyPan(deltaSeconds: $0) },
                    selectRange: { applySelect($0) }),
                yFormat: metric.format
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if series.allSatisfy({ $0.points.count < 2 }) {
                    Text("No data in this window")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12))
    }

    private func focusedCell(_ metric: PerfMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    exitFocus()
                } label: {
                    Label("All charts", systemImage: "square.grid.2x2")
                }
                .controlSize(.small)
                .help("Back to the chart grid (Esc)")

                Divider().frame(height: 14)

                Label(metric.label, systemImage: metric.systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(detailCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Toggle(isOn: $showStats) {
                    Label("Stats", systemImage: "chart.bar.xaxis")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show average, peak, current and trend for the visible window")
                .onChange(of: showStats) { requestProjection() }

                HStack(spacing: 2) {
                    Button {
                        applyZoom(anchor: zoom.visibleMidpoint, factor: 0.5)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .disabled(!zoom.isZoomed)
                    .help("Zoom out")
                    Button {
                        applyZoom(anchor: zoom.visibleMidpoint, factor: 2)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom in")
                    Button("Fit") { resetZoom() }
                        .disabled(!zoom.isZoomed)
                        .help("Back to the full window")
                }
                .controlSize(.small)
            }

            PerformanceChart(
                series: focusedSeries,
                xDomain: zoom.visibleDomain,
                minTop: metric.minTop,
                highlighted: highlighted,
                accessibilityTitle: metric.label,
                zoomActions: ChartZoomActions(
                    zoom: { applyZoom(anchor: $0, factor: $1) },
                    pan: { applyPan(deltaSeconds: $0) },
                    selectRange: { applySelect($0) }),
                yFormat: metric.format
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if focusedSeries.allSatisfy({ $0.points.count < 2 }) {
                    Text("No data in this window")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topLeading) {
                if showStats && !focusedStats.isEmpty {
                    statsCard(metric: metric)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }

            Button("") {
                if zoom.isZoomed { resetZoom() } else { exitFocus() }
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12))
    }

    private func statsCard(metric: PerfMetric) -> some View {
        let window = Self.durationLabel(
            zoom.visibleDomain.upperBound.timeIntervalSince(zoom.visibleDomain.lowerBound))
        return VStack(alignment: .leading, spacing: 5) {
            Text("Statistics \u{00B7} \(window)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("")
                    Text("Avg").gridColumnAlignment(.trailing)
                    Text("Peak").gridColumnAlignment(.trailing)
                    Text("Now").gridColumnAlignment(.trailing)
                    Text("Trend").gridColumnAlignment(.trailing)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                ForEach(focusedStats) { stat in
                    GridRow {
                        HStack(spacing: 5) {
                            Circle().fill(stat.color).frame(width: 7, height: 7)
                            Text(stat.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 140, alignment: .leading)
                        }
                        Text(metric.format(stat.average))
                        Text(metric.format(stat.peak))
                        Text(metric.format(stat.current))
                        trendLabel(stat)
                    }
                    .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
        .fixedSize()
    }

    @ViewBuilder
    private func trendLabel(_ stat: SeriesStat) -> some View {
        HStack(spacing: 3) {
            Image(systemName: stat.trend.symbol)
            if stat.trend != .flat {
                Text(stat.changeText)
            }
        }
        .foregroundStyle(stat.trend.color)
    }

    private var detailCaption: String {
        let domain = zoom.visibleDomain
        let visible = Self.durationLabel(domain.upperBound.timeIntervalSince(domain.lowerBound))
        guard zoom.isZoomed else { return visible }
        let full = Self.durationLabel(
            fullDomain.upperBound.timeIntervalSince(fullDomain.lowerBound))
        return "viewing \(visible) of \(full)"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("This trace has no processes")
                .font(.headline)
            Button {
                onClose()
            } label: {
                Label("Back to live", systemImage: "chevron.left")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Legend

    private var seriesPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Processes")
                    .font(.subheadline.weight(.semibold))
                Text("\(identities.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if identities.count > Self.maxActiveProcesses {
                    Text("\(activeIdentities.count) shown")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !identities.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(identities.enumerated()), id: \.element) { index, id in
                            if index > 0 { Divider() }
                            legendRow(for: id)
                        }
                    }
                }
                .frame(height: legendListHeight)
            }
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12))
    }

    private var legendListHeight: CGFloat {
        let visible = min(identities.count, Self.maxVisibleLegendRows)
        guard visible > 0 else { return 0 }
        return CGFloat(visible) * Self.legendRowHeight + CGFloat(visible - 1)
    }

    private func legendRow(for id: ProcessIdentity) -> some View {
        let series = traceSeries(for: id)
        let isActive = activeIdentities.contains(id)
        return HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color(for: id))
                .frame(width: 11, height: 11)

            Image(nsImage: ProcessIconProvider.shared.icon(forPath: series?.executablePath))
                .resizable()
                .frame(width: 18, height: 18)
                .opacity(0.85)

            VStack(alignment: .leading, spacing: 1) {
                Text(name(for: id))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("PID \(id.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(peakValueString(for: id))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.legendRowHeight)
        .contentShape(Rectangle())
        .background(highlighted == id ? color(for: id).opacity(0.08) : .clear)
        .onTapGesture { toggleActive(id) }
        .onHover { hovering in
            highlighted = hovering ? id : (highlighted == id ? nil : highlighted)
        }
    }

    /// The process's peak footprint across the whole trace, so the legend has a
    /// meaningful read-out even though nothing is live.
    private func peakValueString(for id: ProcessIdentity) -> String {
        let peak = trace.preparation.peakFootprints[id] ?? 0
        return PerfMetric.memory.format(Double(peak))
    }

    private func toggleActive(_ id: ProcessIdentity) {
        if let index = activeIdentities.firstIndex(of: id) {
            activeIdentities.remove(at: index)
        } else if activeIdentities.count < Self.maxActiveProcesses {
            activeIdentities.append(id)
        }
        requestProjection()
    }

    // MARK: - Focus & zoom

    private func focus(_ metric: PerfMetric) {
        focusedMetric = metric
        requestProjection()
    }

    private func exitFocus() {
        focusedMetric = nil
        focusedSeries = []
        focusedStats = []
        requestProjection()
    }

    private func applyZoom(anchor: Date, factor: Double) {
        var next = zoomUpdates.current(or: zoom)
        next.applyZoom(anchor: anchor, factor: factor)
        submitZoom(next)
    }

    private func applyPan(deltaSeconds: TimeInterval) {
        var next = zoomUpdates.current(or: zoom)
        next.applyPan(deltaSeconds: deltaSeconds)
        submitZoom(next)
    }

    private func applySelect(_ range: ClosedRange<Date>) {
        var next = zoomUpdates.current(or: zoom)
        next.applySelect(range)
        submitZoom(next)
    }

    private func setVisibleWindow(_ range: ClosedRange<Date>) {
        var next = zoomUpdates.current(or: zoom)
        next.setVisibleWindow(range)
        submitZoom(next)
    }

    private func resetZoom() {
        var next = zoomUpdates.current(or: zoom)
        next.reset()
        submitZoom(next)
    }

    private func submitZoom(_ next: ChartZoomState) {
        zoomUpdates.submit(next) { committed in
            zoom = committed
            requestProjection()
        }
    }

    // MARK: - Derived data

    private func prepare() {
        zoomUpdates.cancel()
        var nm: [ProcessIdentity: String] = [:]
        var slots: [ProcessIdentity: Int] = [:]
        var indexes: [ProcessIdentity: Int] = [:]
        var order: [ProcessIdentity] = []
        for (index, series) in document.processes.enumerated() {
            let id = series.identity
            order.append(id)
            indexes[id] = index
            nm[id] = series.name
            slots[id] = index % Self.palette.count
        }
        identities = order
        activeIdentities = trace.preparation.activeIdentities
        seriesIndexes = indexes
        names = nm
        colorSlots = slots
        hasNetworkData = trace.preparation.hasNetworkData
        let domain = trace.preparation.fullDomain
        fullDomain = domain
        zoom = ChartZoomState(fullDomain: domain, minSpan: Self.minZoomSpan)
        seriesByMetric = trace.preparation.gridSeries.mapValues { prepared in
            prepared.map {
                PerfSeries(
                    id: $0.identity, name: $0.name,
                    color: color(for: $0.identity), points: $0.points)
            }
        }
    }

    private func requestProjection() {
        let domain = zoom.visibleDomain
        let metric = focusedMetric
        let wantsStats = showStats && metric != nil
        projectionWorker.submit(
            document: document,
            activeIdentities: activeIdentities,
            domain: domain,
            focusedMetric: metric,
            showStats: wantsStats,
            gridPointBudget: Self.maxPointsPerSeries,
            focusedPointBudget: Self.maxPointsFocused
        ) { result in
            if metric == nil {
                seriesByMetric = result.gridSeries.mapValues { prepared in
                    prepared.map {
                        PerfSeries(
                            id: $0.identity, name: $0.name,
                            color: color(for: $0.identity), points: $0.points)
                    }
                }
                focusedSeries = []
                focusedStats = []
            } else {
                focusedSeries = result.focusedSeries.map {
                    PerfSeries(
                        id: $0.identity, name: $0.name,
                        color: color(for: $0.identity), points: $0.points)
                }
                focusedStats = result.focusedStats.map {
                    SeriesStat(
                        statistics: $0.statistics,
                        id: $0.identity,
                        name: $0.name,
                        color: color(for: $0.identity))
                }
            }
        }
    }

    private func color(for id: ProcessIdentity) -> Color {
        Self.palette[(colorSlots[id] ?? 0) % Self.palette.count]
    }

    private func name(for id: ProcessIdentity) -> String {
        names[id] ?? "PID \(id.pid)"
    }

    private func traceSeries(for id: ProcessIdentity) -> ProcessTraceSeries? {
        guard let index = seriesIndexes[id], document.processes.indices.contains(index) else {
            return nil
        }
        return document.processes[index]
    }

    // MARK: - Formatting

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 120 { return "\(s) sec" }
        if s < 2 * 3600 { return "\(s / 60) min" }
        if s < 2 * 86_400 { return "\(s / 3600) hr" }
        return "\(s / 86_400) days"
    }

    private static let exportedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
