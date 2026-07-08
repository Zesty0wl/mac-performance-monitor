import Combine
import MacPerfMonitorCore
import SwiftUI

/// The Performance Monitor (the History tab): a Windows-Performance-Monitor-style
/// surface where you pick a metric (memory, CPU, file descriptors, disk I/O),
/// add any running processes from a picker, and watch them overlaid on one
/// chart. A span control switches between a live, self-scrolling window and
/// fixed historical windows drawn from the logged time-series. Live mode streams
/// straight from the sampler's in-memory trail so processes can be watched
/// responding in real time.
struct PerformanceMonitorView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var monitor: MonitorSelection
    @EnvironmentObject private var appState: AppState

    /// The per-app network opt-in. The network chart is per-process, so it only
    /// appears here when this is on; system-wide network lives on the Network tab.
    @AppStorage(SamplerModel.perAppNetworkDefaultsKey) private var trackPerAppNetwork = true

    @State private var span: PerfSpan = .live

    /// The overlaid processes, in the order they were added. The canonical list
    /// lives in the shared `MonitorSelection`, so other surfaces (the Processes
    /// list's right-click menu) can pin a process and have it show up here, and
    /// the selection survives while the Monitor tab is off screen.
    private var selected: [ProcessIdentity] { monitor.identities }
    /// Captured display names, so an exited process keeps its label on the chart.
    @State private var names: [ProcessIdentity: String] = [:]
    /// Palette slot per process, held stable across additions and removals.
    @State private var colorSlots: [ProcessIdentity: Int] = [:]
    /// Raw per-process points backing every metric; the chart derives the
    /// selected metric (and the disk rate) from these on the fly.
    @State private var rawSeries: [ProcessIdentity: [ProcessHistoryPoint]] = [:]

    /// The chart-ready series per metric, rebuilt only when the underlying data
    /// changes (`rebuildChartSeries()`), never during a body evaluation. Deriving
    /// them in `body` re-ran the metric transform + downsample over every
    /// process's full raw window — up to ~76k point transforms — on every model
    /// publish and every legend hover.
    @State private var seriesByMetric: [PerfMetric: [PerfSeries]] = [:]

    /// When a fixed historical span last did a full window re-read. Between
    /// re-reads the right edge is extended live by `appendTick`, so the full
    /// re-read only needs to run when the backing tier can actually have new
    /// finalised data (minute buckets close once a minute) — not on every tick.
    @State private var lastHistoricalReload = Date.distantPast
    private static let historicalReloadInterval: TimeInterval = 60

    /// True while a span-change (or first) history read is in flight, so the chart
    /// cells show a spinner over dimmed series rather than silently holding the
    /// previous span's data. Set only on a span switch / initial load / a process
    /// being added — never on the 5 s background refresh, which would flicker it.
    @State private var isLoading = false

    @State private var highlighted: ProcessIdentity?
    @State private var pickerPresented = false
    @State private var pickerPresentedEmpty = false
    /// Right edge of the chart's X window: the latest sample time.
    @State private var now = Date()

    // MARK: Focus & zoom state

    /// When set, the grid is replaced by this one metric's chart, full size and
    /// interactive (zoom/pan). Nil shows the 2x2/3x2 grid.
    @State private var focusedMetric: PerfMetric?
    /// The zoomed-in visible window of the focused chart; nil means the full
    /// span window. Absolute dates, clamped into the span window on every change.
    @State private var zoomDomain: ClosedRange<Date>?
    /// The focused chart's series, rebuilt for the visible domain at focused
    /// resolution (twice the grid's point budget) whenever the data, the zoom,
    /// or the focus changes.
    @State private var focusedSeries: [PerfSeries] = []
    /// Optional statistics overlay for the focused chart (average, peak, trend
    /// per process over the visible window). Persisted so the choice sticks.
    @AppStorage("perfmon.showFocusedStats") private var showStats = false
    /// The per-process stats backing that overlay, rebuilt with the focused series.
    @State private var focusedStats: [SeriesStat] = []
    /// A finer-tier re-read of the zoomed interval (see `fetchDetailIfUseful`):
    /// zooming a coarse span into a window that raw/minute retention still
    /// covers swaps in real higher-resolution points instead of stretching the
    /// span tier's buckets.
    @State private var zoomDetail: ZoomDetail?
    /// Debounce/invalidation token for the detail fetch: bumped on every zoom
    /// change and reset, so only the latest scheduled fetch lands.
    @State private var detailFetchToken = 0

    private struct ZoomDetail {
        /// The interval the detail can serve. The lower bound is `distantPast`
        /// because the series is stitched: below `stitchAt` it carries the span
        /// tier's own points, so any leftward pan stays covered.
        let domain: ClosedRange<Date>
        let granularity: HistoryWindow.Granularity
        /// Where the finer tier takes over from the span tier's points —
        /// normally the finer tier's retention edge.
        let stitchAt: Date
        let series: [ProcessIdentity: [ProcessHistoryPoint]]
    }

    /// Point budget for the focused (full-width) chart.
    private static let maxPointsFocused = 600
    /// Tightest allowed zoom: ~10 raw samples across the plot.
    private static let minZoomSpan: TimeInterval = 20

    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .red, .indigo,
    ]
    /// Cap on points drawn per series so the four overlaid charts stay fluid.
    /// Lower than a single full-width chart would need, since each chart in the
    /// 2x2 grid is roughly half width and wants far fewer points than pixels.
    private static let maxPointsPerSeries = 300

    /// The legend's fixed row height and the most rows shown before it scrolls.
    /// The panel grows one row at a time as processes are added; the chart grid
    /// above is the greedy element that absorbs the rest, so the page is always
    /// filled with no dead space at the bottom.
    private static let legendRowHeight: CGFloat = 40
    private static let maxVisibleLegendRows = 5

    var body: some View {
        VStack(spacing: 14) {
            controlBar
            chartArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !selected.isEmpty {
                timelineScrubber
            }
            seriesPanel
        }
        .padding(16)
        .onAppear {
            now = latestSampleDate
            syncDerivedState()
            reload(spinner: true)
        }
        .onChange(of: span) {
            // A new span means a new full window: any zoom (and its fetched
            // detail) belongs to the old one.
            zoomDomain = nil
            zoomDetail = nil
            detailFetchToken += 1
            reload(spinner: true)
        }
        .onChange(of: monitor.identities) { syncDerivedState() }
        .onChange(of: showStats) { rebuildFocusedStats() }
        .onReceive(liveTimestamps) { ts in
            guard appState.mainWindowVisible else { return }
            let previous = now
            now = ts
            advanceZoomIfFollowingLive(from: previous, to: ts)
            appendTick()
        }
        .onChange(of: model.displayProcessesVersion) {
            guard !span.isLive, appState.mainWindowVisible else { return }
            // `appendTick` keeps the right edge live between full re-reads, so
            // the re-read runs on the tier's own cadence, not the refresh dial's.
            if Date().timeIntervalSince(lastHistoricalReload) >= Self.historicalReloadInterval {
                reload()
            }
        }
        .onChange(of: appState.mainWindowVisible) { _, visible in if visible { reload() } }
    }

    /// The middle of the tab: a single empty-state card until processes are
    /// added, then a 2x2 grid showing all four metrics at once so the page reads
    /// like a live instrument cluster rather than one switchable chart.
    @ViewBuilder
    private var chartArea: some View {
        if selected.isEmpty {
            emptyChartState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        } else if let focusedMetric {
            focusedCell(focusedMetric)
        } else {
            chartGrid
        }
    }

    /// All four metrics, each in its own cell, sharing the selected processes,
    /// their colours, the time window and the span. Two rows of two, each cell
    /// an equal quarter of the available space.
    private var chartGrid: some View {
        VStack(spacing: 12) {
            if trackPerAppNetwork {
                // Per-app network is on, so the per-process network chart is
                // meaningful: a 3 + 2 grid with a filler to keep cells equal width.
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
                // Without per-app data the network chart would be a flat zero, so
                // omit it and keep the original 2 x 2 grid.
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

    /// The shared time-range scrubber under the charts. It marks the visible
    /// window inside the full span; dragging, scrolling, or pinching it drives
    /// the same zoom the focused chart uses, so in the grid every chart pans and
    /// zooms together.
    private var timelineScrubber: some View {
        TimelineScrubber(
            fullDomain: xDomain,
            visibleDomain: visibleDomain,
            minSpan: Self.minZoomSpan,
            onScrub: { setVisibleWindow($0) },
            onZoom: { applyZoom(anchor: $0, factor: $1) },
            onPan: { applyPan(deltaSeconds: $0) }
        )
    }

    /// Fires every base sampling tick (~1 Hz), so the Analytics chart's live edge
    /// updates at the sampling rate — independent of the main window's coarser
    /// Refresh-interval publish. A new point only actually lands as fast as the
    /// per-process trail advances (the scan/logging cadence), so this streams at
    /// the high-res rate without pinning the whole app to it.
    private var liveTimestamps: AnyPublisher<Date, Never> {
        model.liveTick
            .map { _ in Date() }
            .eraseToAnyPublisher()
    }

    /// The chart's right-edge time. Real time, so the live window tracks "now"
    /// smoothly at the 1 Hz tick rather than jumping when the coarser table-cadence
    /// `latest` snapshot publishes. The data itself ends at the latest trail point.
    private var latestSampleDate: Date { Date() }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            spanPicker
            Spacer(minLength: 12)
        }
    }

    private var spanPicker: some View {
        Picker("Span", selection: $span) {
            ForEach(PerfSpan.allCases) { s in
                Text(s.label).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Live streams in real time; the others show logged history.")
    }

    // MARK: - Chart card

    /// One metric's cell in the grid: a compact title over its chart, with a
    /// "collecting" hint until two points exist. Every metric is available at
    /// every span now that file descriptors and disk I/O are carried into the
    /// long-span aggregates.
    private func metricCell(_ metric: PerfMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // The title doubles as the focus affordance, alongside the
                // explicit expand button.
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
                xDomain: visibleDomain,
                minTop: metric.minTop,
                highlighted: highlighted,
                accessibilityTitle: metric.label,
                scrollZoom: ChartZoomActions(
                    zoom: { applyZoom(anchor: $0, factor: $1) },
                    pan: { applyPan(deltaSeconds: $0) },
                    selectRange: { applySelect($0) }
                ),
                yFormat: metric.format
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Dim the previous span's series and spin while the new window loads,
            // so switching span reads as "loading" rather than stale data.
            .opacity(isLoading ? 0.3 : 1)
            .overlay {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if series.allSatisfy({ $0.points.count < 2 }) {
                    Text(model.hasHistory ? "Collecting data\u{2026}" : "Live data only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    /// The focused layout: one metric's chart filling the whole chart area,
    /// with zoom/pan interactions and its own header controls. Esc first
    /// resets the zoom, then returns to the grid.
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

                Text(
                    "Scroll or pinch to zoom \u{00B7} drag to pan \u{00B7} \u{2325}-drag to select"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                Toggle(isOn: $showStats) {
                    Label("Stats", systemImage: "chart.bar.xaxis")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show average, peak, current and trend for the visible window")

                HStack(spacing: 2) {
                    Button {
                        applyZoom(anchor: visibleMidpoint, factor: 0.5)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .disabled(zoomDomain == nil)
                    .help("Zoom out")
                    Button {
                        applyZoom(anchor: visibleMidpoint, factor: 2)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom in")
                    Button("Fit") {
                        resetZoom()
                    }
                    .disabled(zoomDomain == nil)
                    .help("Back to the full window")
                }
                .controlSize(.small)
            }

            PerformanceChart(
                series: focusedSeries,
                xDomain: visibleDomain,
                minTop: metric.minTop,
                highlighted: highlighted,
                accessibilityTitle: metric.label,
                zoomActions: ChartZoomActions(
                    zoom: { applyZoom(anchor: $0, factor: $1) },
                    pan: { applyPan(deltaSeconds: $0) },
                    selectRange: { applySelect($0) }
                ),
                yFormat: metric.format
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isLoading ? 0.3 : 1)
            .overlay {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if focusedSeries.allSatisfy({ $0.points.count < 2 }) {
                    Text(model.hasHistory ? "Collecting data\u{2026}" : "Live data only")
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

            // Hidden Esc handler: reset the zoom first, then leave focus.
            Button("") {
                if zoomDomain != nil { resetZoom() } else { exitFocus() }
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
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    /// The floating statistics table over the focused chart: one row per process
    /// with its average, peak, current value and trend across the visible window.
    private func statsCard(metric: PerfMetric) -> some View {
        let window = Self.durationLabel(
            visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound))
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

    /// "viewing 42 min of 6 hr \u{00B7} 1-min buckets \u{2192} raw 2-sec samples" — what's
    /// on screen and the resolution it is drawn from, so the zoom's detail
    /// gain (and the retention seam, when the window straddles it) is visible.
    private var detailCaption: String {
        let domain = visibleDomain
        let visible = Self.durationLabel(domain.upperBound.timeIntervalSince(domain.lowerBound))
        let sourceTier =
            span.window.map { Self.tierLabel($0.granularity) } ?? "1-sec live samples"
        let tier: String
        if let detail = activeDetail {
            if domain.lowerBound >= detail.stitchAt {
                tier = Self.tierLabel(detail.granularity)
            } else {
                // The visible window straddles the finer tier's retention
                // edge: coarse on the left, fine on the right.
                tier = "\(sourceTier) \u{2192} \(Self.tierLabel(detail.granularity))"
            }
        } else {
            tier = sourceTier
        }
        guard zoomDomain != nil else { return "\(visible) \u{00B7} \(tier)" }
        return "viewing \(visible) of \(span.label) \u{00B7} \(tier)"
    }

    private static func tierLabel(_ granularity: HistoryWindow.Granularity) -> String {
        switch granularity {
        case .raw:
            return "raw \(Int(SamplerModel.configuredHighResInterval().rounded()))-sec samples"
        case .minute:
            let s = Int(SamplerModel.configuredStandardResInterval().rounded())
            return s < 60 ? "\(s)-sec buckets" : "\(s / 60)-min buckets"
        case .hour: return "1-hr buckets"
        }
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 120 { return "\(s) sec" }
        if s < 2 * 3600 { return "\(s / 60) min" }
        if s < 2 * 86_400 { return "\(s / 3600) hr" }
        return "\(s / 86_400) days"
    }

    private var emptyChartState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Add a process to start plotting")
                .font(.headline)
            Text("Overlay as many as eight processes and watch them live or over time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                pickerPresentedEmpty = true
            } label: {
                Label("Add process", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .popover(isPresented: $pickerPresentedEmpty, arrowEdge: .bottom) { processPicker }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Series panel (legend)

    private var seriesPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Processes")
                    .font(.subheadline.weight(.semibold))
                Text("\(selected.count)/\(monitor.capacity)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    pickerPresented = true
                } label: {
                    Label("Add process", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(monitor.isFull)
                .popover(isPresented: $pickerPresented, arrowEdge: .top) { processPicker }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !selected.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(selected.enumerated()), id: \.element) { index, id in
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
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    /// Exact height for the legend list: one row per pinned process up to the
    /// visible cap, then it scrolls. Sizing to content (rather than letting a
    /// greedy ScrollView reserve a fixed block) is what lets the chart grid grow
    /// to fill the remaining space, so a single process no longer leaves a gap.
    private var legendListHeight: CGFloat {
        let visible = min(selected.count, Self.maxVisibleLegendRows)
        guard visible > 0 else { return 0 }
        // One divider sits between each pair of visible rows.
        return CGFloat(visible) * Self.legendRowHeight + CGFloat(visible - 1)
    }

    private func legendRow(for id: ProcessIdentity) -> some View {
        let sample = model.currentSample(for: id)
        let isLive = sample != nil
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color(for: id))
                .frame(width: 11, height: 11)

            Image(nsImage: ProcessIconProvider.shared.icon(forPath: sample?.executablePath))
                .resizable()
                .frame(width: 18, height: 18)
                .opacity(isLive ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 1) {
                Text(name(for: id))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isLive ? "PID \(id.pid)" : "Exited \u{00B7} PID \(id.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(currentValueString(for: id))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(isLive ? .primary : .secondary)

            Button {
                remove(id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove from chart")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.legendRowHeight)
        .contentShape(Rectangle())
        .background(highlighted == id ? color(for: id).opacity(0.08) : .clear)
        .onHover { hovering in
            highlighted = hovering ? id : (highlighted == id ? nil : highlighted)
        }
        .processRowActions(identity: id)
    }

    // MARK: - Process picker

    private var processPicker: some View {
        ProcessPickerList(
            candidates: pickerCandidates,
            metric: .memory,
            isSelected: { selected.contains($0) },
            canAddMore: !monitor.isFull,
            onToggle: toggle
        )
    }

    /// Live processes available to add, readable only, sorted by memory
    /// footprint so the heaviest are easiest to reach. (Memory is the app's
    /// headline metric and the picker's trailing read-out.)
    private var pickerCandidates: [ProcessSample] {
        let processes = (model.latest?.processes ?? []).filter { $0.footprintReadable }
        return processes.sorted { PerfMetric.memory.weight($0) > PerfMetric.memory.weight($1) }
    }

    // MARK: - Derived chart data

    private var xDomain: ClosedRange<Date> {
        let upper = now
        let lower = upper.addingTimeInterval(-span.seconds)
        return lower...upper
    }

    /// What the focused chart shows: the zoomed window, or the full span.
    private var visibleDomain: ClosedRange<Date> { zoomDomain ?? xDomain }

    private var visibleMidpoint: Date {
        let domain = visibleDomain
        return domain.lowerBound.addingTimeInterval(
            domain.upperBound.timeIntervalSince(domain.lowerBound) / 2)
    }

    // MARK: - Focus & zoom

    private func focus(_ metric: PerfMetric) {
        focusedMetric = metric
        // Keep the current visible window (the timeline's zoom) so focusing a
        // chart opens it exactly where the grid was.
        rebuildFocusedSeries()
    }

    private func exitFocus() {
        focusedMetric = nil
        // Keep zoomDomain + zoomDetail: the timeline's window is shared, so the
        // grid stays where the user left it after leaving focus.
        focusedSeries = []
        focusedStats = []
    }

    /// Zoom about `anchor`, keeping it fixed on screen. factor > 1 zooms in.
    private func applyZoom(anchor: Date, factor: Double) {
        guard factor > 0, factor.isFinite else { return }
        let current = visibleDomain
        let currentSpan = current.upperBound.timeIntervalSince(current.lowerBound)
        let fullSpan = span.seconds
        let newSpan = min(max(currentSpan / factor, Self.minZoomSpan), fullSpan)
        let pinned = min(max(anchor, current.lowerBound), current.upperBound)
        let fraction =
            currentSpan > 0 ? pinned.timeIntervalSince(current.lowerBound) / currentSpan : 0.5
        setZoom(lower: pinned.addingTimeInterval(-fraction * newSpan), span: newSpan)
    }

    private func applyPan(deltaSeconds: TimeInterval) {
        guard let current = zoomDomain else { return }  // full view: nothing to pan
        let currentSpan = current.upperBound.timeIntervalSince(current.lowerBound)
        setZoom(lower: current.lowerBound.addingTimeInterval(deltaSeconds), span: currentSpan)
    }

    /// When the zoom window's right edge is riding the live edge, slide it forward
    /// with each new sample so the zoomed chart keeps streaming in real time. If
    /// the user has panned back into history, leave the window where they put it.
    /// A fresh finer-tier detail is scheduled so the sliding window stays sharp.
    private func advanceZoomIfFollowingLive(from previous: Date, to current: Date) {
        guard let zoom = zoomDomain else { return }
        let delta = current.timeIntervalSince(previous)
        guard delta > 0, delta < 60 else { return }  // ignore wake/clock jumps
        // "Following live" = the right edge sat within a couple of sample intervals
        // of the previous latest sample.
        let tolerance = max(2 * SamplerModel.configuredHighResInterval(), 4)
        guard zoom.upperBound >= previous.addingTimeInterval(-tolerance) else { return }
        let width = zoom.upperBound.timeIntervalSince(zoom.lowerBound)
        zoomDomain = current.addingTimeInterval(-width)...current
        scheduleDetailFetch()
    }

    private func applySelect(_ range: ClosedRange<Date>) {
        let selectedSpan = max(
            range.upperBound.timeIntervalSince(range.lowerBound), Self.minZoomSpan)
        setZoom(lower: range.lowerBound, span: selectedSpan)
    }

    /// Set the visible window from the timeline scrubber: enforce the minimum
    /// span, then reuse `setZoom` to clamp it into the full window and snap back
    /// to the full view when it covers the whole span.
    private func setVisibleWindow(_ range: ClosedRange<Date>) {
        let newSpan = max(
            range.upperBound.timeIntervalSince(range.lowerBound), Self.minZoomSpan)
        setZoom(lower: range.lowerBound, span: newSpan)
    }

    /// Clamp the requested window into the span's full window; snap back to
    /// the full view (nil) when zoomed all the way out.
    private func setZoom(lower: Date, span newSpan: TimeInterval) {
        let full = xDomain
        if newSpan >= span.seconds - 0.5 {
            if zoomDomain != nil { resetZoom() }
            return
        }
        var lo = lower
        if lo < full.lowerBound { lo = full.lowerBound }
        if lo.addingTimeInterval(newSpan) > full.upperBound {
            lo = full.upperBound.addingTimeInterval(-newSpan)
        }
        let domain = lo...lo.addingTimeInterval(newSpan)
        guard domain != zoomDomain else { return }
        zoomDomain = domain
        rebuildChartSeries()
        scheduleDetailFetch()
    }

    private func resetZoom() {
        zoomDomain = nil
        zoomDetail = nil
        detailFetchToken += 1  // cancel any pending fetch
        rebuildChartSeries()
    }

    /// Recompute the focused chart's series for the visible domain: slice the
    /// backing points (preferring the fetched finer-tier detail when it covers
    /// the window), project the metric, and downsample to the focused budget.
    /// The fetched zoom detail, but only while it covers the current zoom.
    private var activeDetail: ZoomDetail? {
        guard let zoomDetail, let zoom = zoomDomain,
            zoomDetail.domain.lowerBound <= zoom.lowerBound,
            zoomDetail.domain.upperBound >= zoom.upperBound
        else { return nil }
        return zoomDetail
    }

    private func rebuildFocusedSeries() {
        guard let metric = focusedMetric else { return }
        let domain = visibleDomain
        let visibleSpan = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let bucketWidth = visibleSpan / Double(Self.maxPointsFocused)
        let detail = activeDetail
        focusedSeries = selected.compactMap {
            buildSeries(
                id: $0, metric: metric, domain: domain,
                bucketWidth: bucketWidth, detail: detail)
        }
        rebuildFocusedStats()
    }

    /// The points inside `domain` plus one on each side, so lines run off the
    /// chart edges (the scale clips them) and the disk-rate differencing keeps
    /// its left neighbour.
    private static func slice(
        _ points: [ProcessHistoryPoint], domain: ClosedRange<Date>
    ) -> [ProcessHistoryPoint] {
        guard let lo = points.firstIndex(where: { $0.date >= domain.lowerBound }),
            let hi = points.lastIndex(where: { $0.date <= domain.upperBound }),
            lo <= hi
        else { return [] }
        return Array(points[max(lo - 1, 0)...min(hi + 1, points.count - 1)])
    }

    /// Debounced: zoom gestures arrive continuously, and the fetch only matters
    /// once the user settles.
    private func scheduleDetailFetch() {
        detailFetchToken += 1
        let token = detailFetchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard token == detailFetchToken else { return }
            fetchDetailIfUseful()
        }
    }

    /// Re-read the zoomed interval from a finer tier when the span's own tier
    /// is too coarse for the zoom (fewer real points than the chart can draw).
    /// Prefers the finest tier whose retention covers the WHOLE zoom (raw
    /// keeps 2 h at ~2 s, minute 7 d); failing that, the finest that covers
    /// its tail — the fetched slice is stitched onto the span tier's points at
    /// the retention edge, so a zoom straddling that edge still shows raw
    /// samples where they exist and minute buckets where they don't. Fetched
    /// with padding so small pans reuse the same slice.
    private func fetchDetailIfUseful() {
        guard let zoom = zoomDomain, let window = span.window else { return }
        let sourceRes = Self.tierResolution(window.granularity)
        let zoomSpan = zoom.upperBound.timeIntervalSince(zoom.lowerBound)
        let desiredRes = zoomSpan / Double(Self.maxPointsFocused)
        guard sourceRes > desiredRes else { return }  // span tier already dense enough

        // Retention edges, with a margin for the trim that runs mid-view. Read the
        // user's live tier windows (not the fixed defaults), since the high-res and
        // standard ages are now configurable.
        let policy = SamplerModel.currentRetentionWindows()
        let reference = Date()
        func coverageStart(_ granularity: HistoryWindow.Granularity) -> Date {
            switch granularity {
            case .raw: return reference.addingTimeInterval(-(policy.rawWindow - 120))
            case .minute: return reference.addingTimeInterval(-(policy.minuteWindow - 3600))
            case .hour: return reference.addingTimeInterval(-(policy.hourWindow - 86_400))
            }
        }
        let finer = [HistoryWindow.Granularity.raw, .minute]
            .filter { Self.tierResolution($0) < sourceRes }
        guard
            let candidate = finer.first(where: { coverageStart($0) <= zoom.lowerBound })
                ?? finer.first(where: { coverageStart($0) < zoom.upperBound })
        else { return }  // nothing finer covers any part of this interval

        if let existing = zoomDetail, existing.granularity == candidate,
            existing.domain.lowerBound <= zoom.lowerBound,
            existing.domain.upperBound >= zoom.upperBound
        {
            return  // already covered at this tier
        }

        let pad = zoomSpan * 0.5
        let queryFrom = max(
            zoom.lowerBound.addingTimeInterval(-pad), coverageStart(candidate))
        let queryTo = zoom.upperBound.addingTimeInterval(pad)
        let token = detailFetchToken
        let ids = selected
        model.loadProcessHistoriesSlice(
            ids, granularity: candidate, from: queryFrom, to: queryTo
        ) { map in
            guard token == self.detailFetchToken, ids == self.selected,
                self.zoomDomain != nil
            else { return }
            // Stitch: below the fetched slice, the span tier's already-loaded
            // window points stand in — so the detail is valid for any pan and
            // the coarse-to-fine seam sits exactly at `queryFrom`.
            var merged: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
            for id in ids {
                let prefix = (self.rawSeries[id] ?? []).filter { $0.date < queryFrom }
                let suffix = map[id] ?? []
                if prefix.isEmpty && suffix.isEmpty { continue }
                merged[id] = prefix + suffix
            }
            self.zoomDetail = ZoomDetail(
                domain: Date.distantPast...queryTo, granularity: candidate,
                stitchAt: queryFrom, series: merged)
            self.rebuildChartSeries()
        }
    }

    private static func tierResolution(_ granularity: HistoryWindow.Granularity) -> TimeInterval {
        switch granularity {
        case .raw: return SamplerModel.configuredHighResInterval()
        case .minute: return SamplerModel.configuredStandardResInterval()
        case .hour: return 3600
        }
    }

    /// Recompute the memoized chart series for every metric. Called whenever
    /// `rawSeries` (or the selection-derived names/colours) change — after a
    /// reload, a live append, or a selection sync — so `body` only ever reads
    /// the prepared arrays.
    private func rebuildChartSeries() {
        let domain = visibleDomain
        let visibleSpan = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let bucketWidth = visibleSpan / Double(Self.maxPointsPerSeries)
        let detail = activeDetail
        var result: [PerfMetric: [PerfSeries]] = [:]
        for metric in PerfMetric.allCases {
            result[metric] = selected.compactMap {
                buildSeries(
                    id: $0, metric: metric, domain: domain,
                    bucketWidth: bucketWidth, detail: detail)
            }
        }
        seriesByMetric = result
        rebuildFocusedSeries()
    }

    /// Slice one process's backing points to `domain` (preferring the fetched
    /// finer-tier detail when it covers the window), project the metric, and
    /// downsample to `bucketWidth`. Shared by the grid and the focused chart so
    /// every chart honours the same visible window the timeline sets.
    private func buildSeries(
        id: ProcessIdentity, metric: PerfMetric, domain: ClosedRange<Date>,
        bucketWidth: TimeInterval, detail: ZoomDetail?
    ) -> PerfSeries? {
        let points = downsample(
            windowPoints(id: id, metric: metric, domain: domain, detail: detail),
            bucketWidth: bucketWidth)
        guard !points.isEmpty else { return nil }
        return PerfSeries(id: id, name: name(for: id), color: color(for: id), points: points)
    }

    /// The metric's points across `domain` (with `slice`'s one-sample edge
    /// padding), before downsampling — the shared input to both the plotted
    /// series and the statistics overlay, so they read exactly the same window.
    private func windowPoints(
        id: ProcessIdentity, metric: PerfMetric, domain: ClosedRange<Date>,
        detail: ZoomDetail?
    ) -> [PerfPoint] {
        let source: [ProcessHistoryPoint]
        if let detailPoints = detail?.series[id] {
            // Extend the fetched detail with any live samples newer than it, so a
            // zoom riding the live edge keeps streaming instead of freezing.
            let cutoff = detailPoints.last?.date ?? .distantPast
            let liveTail = (rawSeries[id] ?? []).filter { $0.date > cutoff }
            source = liveTail.isEmpty ? detailPoints : detailPoints + liveTail
        } else {
            source = rawSeries[id] ?? []
        }
        guard !source.isEmpty else { return [] }
        return metric.points(from: Self.slice(source, domain: domain))
    }

    /// Recompute the statistics overlay over the exact visible window from the
    /// raw projected points (not the peak-preserving downsample), so the average
    /// and minimum are honest. Only runs while the overlay is on and focused.
    private func rebuildFocusedStats() {
        guard showStats, let metric = focusedMetric else {
            if !focusedStats.isEmpty { focusedStats = [] }
            return
        }
        let domain = visibleDomain
        let detail = activeDetail
        focusedStats = selected.compactMap { id in
            let points = windowPoints(id: id, metric: metric, domain: domain, detail: detail)
                .filter { domain.contains($0.date) }
            return SeriesStat(points: points, id: id, name: name(for: id), color: color(for: id))
        }
    }

    // MARK: - Data loading

    private func reload(spinner: Bool = false) {
        now = latestSampleDate
        if span.isLive {
            // Seed immediately from the in-memory trail so there is something to
            // draw at once...
            isLoading = false
            var seeded: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
            for id in selected {
                seeded[id] = trimmed(model.trailSamples(for: id))
            }
            rawSeries = seeded
            rebuildChartSeries()
            // ...then backfill the full live window from the on-disk raw tier, so
            // it isn't empty (and slowly refilling) when those recent samples are
            // already recorded. The trail alone is capped and starts empty on open.
            let ids = selected
            let to = now
            let from = to.addingTimeInterval(-span.seconds)
            model.loadProcessHistoriesSlice(ids, granularity: .raw, from: from, to: to) { map in
                guard ids == self.selected, self.span.isLive else { return }
                var merged: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
                for id in ids {
                    let db = map[id] ?? []
                    // Stitch any trail points newer than the DB's last onto the
                    // backfill (the newest sample may not be persisted yet).
                    let cutoff = db.last?.date ?? .distantPast
                    let liveTail = self.model.trailSamples(for: id).filter { $0.date > cutoff }
                    let combined = self.trimmed(db + liveTail)
                    if !combined.isEmpty { merged[id] = combined }
                }
                guard !merged.isEmpty else { return }
                self.rawSeries = merged
                self.rebuildChartSeries()
            }
        } else if span.window != nil {
            // Pick the finest tier that actually has data covering this span (raw
            // where retention still reaches back that far, else the minute/hour
            // aggregates), so the grid renders at its true available resolution
            // rather than the span's fixed tier — then slice-read that tier over
            // the exact interval.
            let ids = selected
            lastHistoricalReload = Date()
            if spinner { isLoading = true }
            let to = now
            let from = to.addingTimeInterval(-span.seconds)
            model.loadFinestGranularity(from: from, to: to) { granularity in
                guard ids == self.selected else {
                    self.isLoading = false
                    return
                }
                self.model.loadProcessHistoriesSlice(
                    ids, granularity: granularity, from: from, to: to
                ) { map in
                    // The read is done regardless of whether this result still
                    // applies, so clear the spinner before deciding to use it.
                    self.isLoading = false
                    guard ids == self.selected else { return }
                    var merged = map
                    self.appendLive(into: &merged)
                    self.rawSeries = merged.mapValues { self.trimmed($0) }
                    self.rebuildChartSeries()
                }
            }
        }
    }

    /// Append the current live sample of each selected process to the right edge
    /// of its series, trimming to the active window. Drives both the live stream
    /// and the fresh right edge of the historical spans between reloads.
    private func appendTick() {
        var changed = false
        for id in selected {
            // Read the newest point from the in-memory trail, which advances at the
            // scan cadence (~high-res), not `latest.processes` (the coarser table
            // cadence) — so the live edge streams even while the main window is slow.
            guard let point = model.trailSamples(for: id).last else { continue }
            var points = rawSeries[id] ?? []
            if let last = points.last, point.date <= last.date { continue }
            points.append(point)
            rawSeries[id] = trimmed(points)
            changed = true
        }
        if changed { rebuildChartSeries() }
    }

    private func appendLive(into map: inout [ProcessIdentity: [ProcessHistoryPoint]]) {
        for id in selected {
            guard let point = model.trailSamples(for: id).last else { continue }
            var points = map[id] ?? []
            if let last = points.last {
                if point.date > last.date { points.append(point) }
            } else {
                points.append(point)
            }
            map[id] = points
        }
    }

    private func historyPoint(from s: ProcessSample) -> ProcessHistoryPoint {
        ProcessHistoryPoint(
            date: s.timestamp,
            footprint: s.physFootprint,
            cpuPercent: s.cpuPercent,
            fdTotal: Int(s.fdTotal),
            diskRead: s.diskBytesRead,
            diskWritten: s.diskBytesWritten,
            networkBytesPerSec: s.networkBytesPerSec
        )
    }

    private func trimmed(_ points: [ProcessHistoryPoint]) -> [ProcessHistoryPoint] {
        let cutoff = now.addingTimeInterval(-span.seconds)
        return points.filter { $0.date >= cutoff }
    }

    /// Collapse a dense series to one peak sample per fixed time bucket. The
    /// bucket boundaries are anchored to absolute time (not to the array's
    /// index), so they stay put as the live window advances: appending a sample
    /// only ever changes the rightmost bucket, and the middle of the chart holds
    /// still instead of shimmering. Keeping each bucket's maximum preserves
    /// spikes rather than averaging them away. Series already coarser than the
    /// bucket width pass through untouched.
    private func downsample(_ points: [PerfPoint], bucketWidth: TimeInterval) -> [PerfPoint] {
        guard bucketWidth > 0, points.count > 2 else { return points }
        var result: [PerfPoint] = []
        result.reserveCapacity(points.count)
        var currentBucket = bucketIndex(points[0].date, bucketWidth)
        var peak = points[0]
        for point in points.dropFirst() {
            let bucket = bucketIndex(point.date, bucketWidth)
            if bucket == currentBucket {
                if point.value > peak.value { peak = point }
            } else {
                result.append(peak)
                currentBucket = bucket
                peak = point
            }
        }
        result.append(peak)
        // Keep the live right edge tracking `now` at the data rate. The final
        // bucket's point sits at its peak's time, which can be up to a bucket
        // behind (e.g. ~12 s on a 1-hour span), so the endpoint looks frozen
        // between bucket boundaries even though samples arrive every ~2 s.
        // Appending the actual latest sample makes the endpoint advance every
        // tick, so the chart streams live regardless of the span's bucket width.
        if let last = points.last, last.date > peak.date {
            result.append(last)
        }
        return result
    }

    private func bucketIndex(_ date: Date, _ width: TimeInterval) -> Int {
        Int((date.timeIntervalSince1970 / width).rounded(.down))
    }

    // MARK: - Selection management

    private func toggle(_ id: ProcessIdentity) {
        monitor.toggle(id)
    }

    private func remove(_ id: ProcessIdentity) {
        monitor.remove(id)
    }

    /// Reconcile the per-process derived state (colour slot, captured name and
    /// chart series) with the shared pinned list. Sets up newly pinned processes
    /// — including ones pinned from another surface while this tab was off screen
    /// — and tears down state for unpinned ones. Idempotent, so it is safe to run
    /// on appear and on every change to the list.
    private func syncDerivedState() {
        let pinned = Set(monitor.identities)

        // Tear down state for processes no longer pinned.
        for gone in Set(colorSlots.keys).subtracting(pinned) {
            colorSlots[gone] = nil
            names[gone] = nil
            rawSeries[gone] = nil
            if highlighted == gone { highlighted = nil }
        }

        // Set up state for newly pinned processes.
        var addedAny = false
        for id in monitor.identities where colorSlots[id] == nil {
            assignColor(id)
            if let sample = model.currentSample(for: id) {
                names[id] = sample.displayName
            }
            rawSeries[id] = trimmed(model.trailSamples(for: id))
            addedAny = true
        }

        rebuildChartSeries()

        // The fetched zoom detail covers only the previous selection; refresh
        // it so a newly pinned process gains the same resolution.
        if addedAny, zoomDomain != nil {
            zoomDetail = nil
            scheduleDetailFetch()
        }

        // A historical span needs a database reload to fill the new series; live
        // mode streams them in from the next tick.
        if addedAny && !span.isLive { reload(spinner: true) }
    }

    private func assignColor(_ id: ProcessIdentity) {
        guard colorSlots[id] == nil else { return }
        let used = Set(colorSlots.values)
        let slot = (0..<Self.palette.count).first { !used.contains($0) } ?? colorSlots.count
        colorSlots[id] = slot
    }

    private func color(for id: ProcessIdentity) -> Color {
        Self.palette[(colorSlots[id] ?? 0) % Self.palette.count]
    }

    private func name(for id: ProcessIdentity) -> String {
        model.currentSample(for: id)?.displayName ?? names[id] ?? "PID \(id.pid)"
    }

    /// The legend's trailing read-out: the process's current memory footprint
    /// (the app's headline metric), taken live where possible and otherwise from
    /// the last recorded point so an exited process keeps its last value.
    private func currentValueString(for id: ProcessIdentity) -> String {
        if let sample = model.currentSample(for: id) {
            return PerfMetric.memory.format(Double(sample.physFootprint))
        }
        if let last = rawSeries[id]?.last {
            return PerfMetric.memory.format(Double(last.footprint))
        }
        return "\u{2014}"
    }
}

// MARK: - Statistics

/// One process's summary stats over the focused chart's visible window.
private struct SeriesStat: Identifiable {
    let id: ProcessIdentity
    let name: String
    let color: Color
    let average: Double
    let peak: Double
    let minimum: Double
    let current: Double
    let trend: TrendDirection
    /// Signed fraction the fitted trend line moves across the window, relative to
    /// the mean; drives the trend arrow and its percentage read-out.
    let changeFraction: Double

    var changeText: String {
        "\(Int((abs(changeFraction) * 100).rounded()))%"
    }

    init?(points: [PerfPoint], id: ProcessIdentity, name: String, color: Color) {
        guard let first = points.first, let last = points.last else { return nil }
        self.id = id
        self.name = name
        self.color = color
        let values = points.map(\.value)
        let count = Double(values.count)
        self.average = values.reduce(0, +) / count
        self.peak = values.max() ?? 0
        self.minimum = values.min() ?? 0
        self.current = last.value
        // Least-squares slope over (seconds since start, value), expressed as the
        // change the fitted line makes across the window.
        let t0 = first.date.timeIntervalSince1970
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for p in points {
            let x = p.date.timeIntervalSince1970 - t0
            sx += x
            sy += p.value
            sxx += x * x
            sxy += x * p.value
        }
        let denom = count * sxx - sx * sx
        let span = last.date.timeIntervalSince(first.date)
        let change: Double
        if denom != 0, span > 0 {
            change = (count * sxy - sx * sy) / denom * span
        } else {
            change = last.value - first.value
        }
        let fraction = change / max(abs(self.average), 1e-9)
        self.changeFraction = fraction
        if fraction > 0.05 {
            self.trend = .rising
        } else if fraction < -0.05 {
            self.trend = .falling
        } else {
            self.trend = .flat
        }
    }
}

private enum TrendDirection: Equatable {
    case rising, falling, flat

    var symbol: String {
        switch self {
        case .rising: return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .flat: return "arrow.right"
        }
    }

    var color: Color {
        switch self {
        case .rising: return .orange
        case .falling: return .green
        case .flat: return .secondary
        }
    }
}

// MARK: - Process picker list

/// The searchable add-process popover. Rows toggle membership in place so several
/// processes can be added without reopening, mirroring the classic "add counters"
/// dialog.
private struct ProcessPickerList: View {
    let candidates: [ProcessSample]
    let metric: PerfMetric
    let isSelected: (ProcessIdentity) -> Bool
    let canAddMore: Bool
    let onToggle: (ProcessIdentity) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var search = ""

    private var filtered: [ProcessSample] {
        guard !search.isEmpty else { return candidates }
        return candidates.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter processes", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { process in
                        row(for: process)
                        Divider()
                    }
                }
            }
        }
        .frame(width: 320, height: 400)
    }

    private func row(for process: ProcessSample) -> some View {
        let selected = isSelected(process.id)
        let disabled = !selected && !canAddMore
        return Button {
            onToggle(process.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                    .resizable()
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(process.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("PID \(process.pid)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(metric.weightString(process))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(disabled ? "Remove a process first (eight maximum)." : "")
        .contextMenu {
            ProcessActionMenu(
                live: process,
                showCodesign: {
                    ProcessRowIntent.showCodesign(
                        sample: process, appState: appState, bringWindowForward: false)
                },
                requestKill: { appState.pendingForceQuit = process.id }
            )
        }
    }
}
