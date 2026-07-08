import Charts
import MacPerfMonitorCore
import SwiftUI

/// One plotted point on a Performance Monitor series.
struct PerfPoint: Identifiable, Equatable {
    var date: Date
    var value: Double
    var id: Date { date }
}

/// One overlaid process line on the Performance Monitor: an identity, a display
/// name, an assigned colour, and the metric's time-series. The plotting `key` is
/// derived from the identity so two processes that happen to share a name still
/// draw as separate lines and map to distinct colours.
struct PerfSeries: Identifiable, Equatable {
    var id: ProcessIdentity
    var name: String
    var color: Color
    var points: [PerfPoint]

    /// Stable, unique key for the Swift Charts foreground-style scale.
    var key: String { "\(id.pid)/\(Int(id.startTime.timeIntervalSince1970))" }
}

/// The Performance Monitor's hero chart: several processes overlaid on one set
/// of axes for a single metric, in the spirit of the classic Windows
/// Performance Monitor. The X domain is supplied by the parent so the window
/// scrolls smoothly in live mode and stays fixed for a chosen historical span.
/// Hovering or dragging scrubs every series at once, pinning a combined
/// read-out of each process's value at that instant.
struct PerformanceChart: View, Equatable {
    let series: [PerfSeries]
    let xDomain: ClosedRange<Date>
    /// Floor for the Y domain's top so a flat-at-zero metric still renders a
    /// sensible axis rather than collapsing onto the baseline.
    var minTop: Double = 1
    /// Identity to emphasise (the legend row under the cursor); the others dim.
    var highlighted: ProcessIdentity?
    var accessibilityTitle: String = "Performance"
    /// When set (the Monitor's focused chart), the plot becomes interactive:
    /// drag pans, Option-drag rubber-band-selects a range to zoom into,
    /// double-click zooms out a step, pinch and scroll-wheel zoom about the
    /// cursor, and horizontal two-finger scroll pans. Scrubbing moves to
    /// hover-only. Nil (the grid cells) keeps the original hover/drag scrub.
    var zoomActions: ChartZoomActions? = nil
    /// When set (the grid cells), scroll-wheel and pinch zoom the shared window
    /// while hover and drag keep scrubbing, so scrolling over any chart zooms them
    /// all. `zoomActions` (the focused chart) supersedes this with full drag-pan /
    /// Option-select.
    var scrollZoom: ChartZoomActions? = nil
    let yFormat: (Double) -> String

    /// Used with `.equatable()` so the ~2,400 marks per cell are only rebuilt
    /// when the plotted data actually changes — not on every unrelated model
    /// publish that re-evaluates the parent. `yFormat` and `zoomActions` are
    /// deliberately ignored: pure functions/callbacks fixed per cell.
    static func == (lhs: PerformanceChart, rhs: PerformanceChart) -> Bool {
        lhs.series == rhs.series && lhs.xDomain == rhs.xDomain && lhs.minTop == rhs.minTop
            && lhs.highlighted == rhs.highlighted
            && lhs.accessibilityTitle == rhs.accessibilityTitle
    }

    @State private var scrubDate: Date?
    /// Last drag X while panning, so each change reports an incremental delta.
    @State private var panLastX: CGFloat?
    /// Rubber-band selection in overlay-local X, while an Option-drag is live.
    @State private var selection: (start: CGFloat, current: CGFloat)?
    /// Previous pinch magnification, so each change reports an incremental factor.
    @State private var magnifyLast: CGFloat = 1

    private var yMax: Double {
        let peak = series.flatMap(\.points).map(\.value).max() ?? 0
        // Sit the tallest spike near the top with a little breathing room, rather
        // than against an arbitrary fixed ceiling that leaves the data hugging
        // the floor. The floor only applies when everything is near zero.
        return max(peak * 1.12, minTop)
    }

    /// One drawable run of a series: a stretch of points with no gap, tagged with
    /// the parent process (for colour) and a unique id (so each run is its own
    /// Swift Charts line and the gaps between runs are left blank).
    private struct SeriesSegment: Identifiable {
        let id: String
        let processKey: String
        let points: [PerfPoint]
    }

    /// Every series split into gap-free runs. A process's history can be sparse
    /// (the database only retains the top consumers, so a pinned process has
    /// holes wherever it was not among them); splitting at the holes stops the
    /// chart from joining distant points with a straight diagonal.
    private var segments: [SeriesSegment] {
        series.flatMap { s -> [SeriesSegment] in
            let runs = Self.split(s.points)
            return runs.enumerated().map { index, run in
                SeriesSegment(id: "\(s.key)#\(index)", processKey: s.key, points: run)
            }
        }
    }

    /// Break a series into gap-free runs. A gap is a jump well beyond the
    /// LOCAL sample spacing — the median of the trailing few intervals in the
    /// current run, times a factor, with a floor — so ordinary jitter or one
    /// slow tick is bridged while a genuine absence (the process unsampled,
    /// the Mac asleep) is left blank. Local rather than the global median the
    /// detail inspector's `MetricChart` uses: a zoomed Monitor series changes
    /// density mid-stream (minute buckets stitched into raw samples where
    /// retention allows), and a global median computed mostly from the dense
    /// half would shred the coarse half into disconnected dots.
    private static func split(_ points: [PerfPoint]) -> [[PerfPoint]] {
        guard points.count > 2 else { return points.isEmpty ? [] : [points] }
        var runs: [[PerfPoint]] = []
        var current: [PerfPoint] = [points[0]]
        var recent: [TimeInterval] = []  // trailing intervals of the current run
        for i in 1..<points.count {
            let dt = points[i].date.timeIntervalSince(points[i - 1].date)
            let local: TimeInterval
            if recent.isEmpty {
                // A fresh run has no trailing context; borrow the spacing just
                // ahead so an isolated point still splits away cleanly.
                let lookahead = (i..<min(i + 4, points.count - 1)).map {
                    points[$0 + 1].date.timeIntervalSince(points[$0].date)
                }
                local = lookahead.isEmpty ? dt : Self.median(lookahead)
            } else {
                local = Self.median(recent)
            }
            // Floor above the default heartbeat bucket (~60 s): change-gated rows
            // mean an active run's local spacing is ~1 s, so the FIRST idle
            // heartbeat gap (~60 s) as a process goes quiet would otherwise clear
            // 15× a 1 s median and split spuriously. 150 s bridges that transition
            // while still breaking on a genuine multi-minute absence.
            if dt > max(local * 15, 150) {
                runs.append(current)
                current = [points[i]]
                recent.removeAll(keepingCapacity: true)
            } else {
                current.append(points[i])
                recent.append(dt)
                if recent.count > 9 { recent.removeFirst() }
            }
        }
        runs.append(current)
        return runs
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Map each series to its value at the scrub time (nearest sample), sorted
    /// by value descending so the heaviest process reads at the top of the card.
    private var scrubReadout: [(series: PerfSeries, point: PerfPoint)] {
        guard let scrubDate else { return [] }
        return
            series
            .compactMap { s -> (PerfSeries, PerfPoint)? in
                guard
                    let nearest = s.points.min(by: {
                        abs($0.date.timeIntervalSince(scrubDate))
                            < abs($1.date.timeIntervalSince(scrubDate))
                    })
                else { return nil }
                return (s, nearest)
            }
            .sorted { $0.1.value > $1.1.value }
    }

    private var accessibilitySummary: String {
        guard !series.isEmpty else { return "No processes added yet." }
        let parts = series.compactMap { s -> String? in
            guard let latest = s.points.last?.value else { return nil }
            return "\(s.name) \(yFormat(latest))"
        }
        return parts.isEmpty ? "Collecting data." : parts.joined(separator: ", ")
    }

    private var xLabelFormat: Date.FormatStyle {
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        if span <= 600 { return .dateTime.minute().second() }
        if span <= 26 * 3600 { return .dateTime.hour().minute() }
        return .dateTime.month(.abbreviated).day()
    }

    var body: some View {
        // Evaluated once per render: the nearest-sample scan runs per series, so
        // referencing the computed property from several places in the builder
        // multiplied it.
        let readout = scrubReadout
        return Chart {
            // Crisp lines only, no fills: a clean instrument-style plot where
            // the gridlines and values stay readable even with eight processes
            // overlaid. Each contiguous RUN of a series is drawn as its own line
            // ("Segment"), so the line breaks wherever a process's history is
            // missing rather than bridging the hole with a misleading straight
            // diagonal (the sawtooth/flat-then-jump artifact). Colour stays keyed
            // to the process, so all of a process's runs share one colour.
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value),
                        series: .value("Segment", segment.id)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(by: .value("Process", segment.processKey))
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }

                // A run with a single sample draws no line, so mark it with a dot
                // to keep an isolated reading visible across the gaps around it.
                if segment.points.count == 1, let point = segment.points.first {
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(by: .value("Process", segment.processKey))
                    .symbolSize(18)
                }
            }

            // A small solid dot pins each series' current value. Hidden for
            // dimmed series so the highlighted line reads cleanly.
            ForEach(series) { s in
                if let last = s.points.last, !isDimmed(s) {
                    PointMark(
                        x: .value("Time", last.date),
                        y: .value("Value", last.value)
                    )
                    .foregroundStyle(by: .value("Process", s.key))
                    .symbolSize(26)
                }
            }

            if let scrubDate, !readout.isEmpty {
                RuleMark(x: .value("Time", scrubDate))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        // Fit on BOTH axes so the readout card can never run up
                        // out of the chart and behind the window's title/tab bar
                        // on the top row of charts; it stays clamped inside.
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        scrubCard(readout)
                    }

                ForEach(readout, id: \.series.id) { entry in
                    PointMark(
                        x: .value("Time", entry.point.date),
                        y: .value("Value", entry.point.value)
                    )
                    .foregroundStyle(by: .value("Process", entry.series.key))
                    .symbolSize(isDimmed(entry.series) ? 0 : 48)
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.key), range: series.map(displayColor))
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...yMax)
        .chartPlotStyle { plot in
            // A neutral panel with a crisp hairline frame reads as a
            // professional instrument rather than a decorative gradient.
            plot
                .border(Color.secondary.opacity(0.22), width: 0.5)
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                // Solid, clearly visible horizontal reference lines: these are
                // the value gridlines the monitor is read against.
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.28))
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(yFormat(v))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                // Lighter vertical gridlines so the horizontal value lines stay
                // dominant, but still clearly present.
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.14))
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: xLabelFormat)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let zoomActions {
                    zoomableOverlay(zoomActions, proxy: proxy, geometry: geometry)
                } else {
                    scrubOverlay(proxy: proxy, geometry: geometry)
                }
            }
        }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilitySummary)
        .reducedMotionAware()
    }

    // MARK: - Interaction overlays

    /// The grid cells' overlay: hover or drag scrubs the read-out, and (when
    /// `scrollZoom` is set) scroll-wheel and pinch zoom the shared window so every
    /// chart zooms together. The focused chart uses `zoomableOverlay` instead.
    private func scrubOverlay(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    updateScrub(at: location, proxy: proxy, geometry: geometry)
                case .ended:
                    scrubDate = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateScrub(at: value.location, proxy: proxy, geometry: geometry)
                    }
                    .onEnded { _ in scrubDate = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard let scrollZoom else { return }
                        let factor = value.magnification / magnifyLast
                        magnifyLast = value.magnification
                        let anchor =
                            plotDate(atX: value.startLocation.x, proxy: proxy, geometry: geometry)
                            ?? domainMidpoint
                        scrollZoom.zoom(anchor, Double(factor))
                    }
                    .onEnded { _ in magnifyLast = 1 }
            )
            .background(
                Group {
                    if let scrollZoom {
                        ScrollWheelCatcher { location, dx, dy in
                            handleScroll(
                                scrollZoom, location: location, dx: dx, dy: dy,
                                proxy: proxy, geometry: geometry)
                        }
                    }
                }
            )
    }

    /// The focused chart's interactive overlay: hover scrubs; drag pans;
    /// Option-drag draws a rubber-band selection and zooms to it; double-click
    /// zooms out a step; pinch and scroll-wheel zoom about the cursor.
    private func zoomableOverlay(
        _ actions: ChartZoomActions, proxy: ChartProxy, geometry: GeometryProxy
    ) -> some View {
        let plotRect = proxy.plotFrame.map { geometry[$0] } ?? geometry.frame(in: .local)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear)
            if let selection {
                let x0 = min(selection.start, selection.current)
                let width = max(abs(selection.current - selection.start), 1)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.55), lineWidth: 1))
                    .frame(width: width, height: plotRect.height)
                    .offset(x: x0, y: plotRect.minY)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard panLastX == nil, selection == nil else { return }
                updateScrub(at: location, proxy: proxy, geometry: geometry)
            case .ended:
                scrubDate = nil
            }
        }
        .gesture(
            SpatialTapGesture(count: 2).onEnded { value in
                let anchor =
                    plotDate(atX: value.location.x, proxy: proxy, geometry: geometry)
                    ?? domainMidpoint
                actions.zoom(anchor, 0.5)
            }
        )
        .simultaneousGesture(panOrSelectGesture(actions, proxy: proxy, geometry: geometry))
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let factor = value.magnification / magnifyLast
                    magnifyLast = value.magnification
                    let anchor =
                        plotDate(atX: value.startLocation.x, proxy: proxy, geometry: geometry)
                        ?? domainMidpoint
                    actions.zoom(anchor, Double(factor))
                }
                .onEnded { _ in magnifyLast = 1 }
        )
        .background(
            ScrollWheelCatcher { location, dx, dy in
                handleScroll(
                    actions, location: location, dx: dx, dy: dy,
                    proxy: proxy, geometry: geometry)
            }
        )
    }

    /// One drag serves two modes, decided by the Option key at drag start:
    /// plain drag pans the window; Option-drag rubber-bands a range to zoom to.
    private func panOrSelectGesture(
        _ actions: ChartZoomActions, proxy: ChartProxy, geometry: GeometryProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panLastX == nil, selection == nil {
                    scrubDate = nil
                    if NSEvent.modifierFlags.contains(.option) {
                        selection = (value.startLocation.x, value.location.x)
                    } else {
                        panLastX = value.startLocation.x
                    }
                }
                if selection != nil {
                    selection?.current = value.location.x
                } else if let last = panLastX {
                    let dx = value.location.x - last
                    panLastX = value.location.x
                    let width = plotWidth(proxy: proxy, geometry: geometry)
                    guard width > 0 else { return }
                    // Dragging the plot right shows earlier data, like grabbing
                    // the chart paper.
                    actions.pan(-Double(dx / width) * domainSpan)
                }
            }
            .onEnded { _ in
                if let sel = selection {
                    let x0 = min(sel.start, sel.current)
                    let x1 = max(sel.start, sel.current)
                    if x1 - x0 > 8,
                        let d0 = plotDate(atX: x0, proxy: proxy, geometry: geometry),
                        let d1 = plotDate(atX: x1, proxy: proxy, geometry: geometry),
                        d0 < d1
                    {
                        actions.selectRange(d0...d1)
                    }
                }
                selection = nil
                panLastX = nil
            }
    }

    /// Scroll-wheel routing: the dominant axis decides. Horizontal (two-finger
    /// swipe) pans; vertical zooms about the cursor — wheel/swipe up zooms in.
    private func handleScroll(
        _ actions: ChartZoomActions, location: CGPoint, dx: CGFloat, dy: CGFloat,
        proxy: ChartProxy, geometry: GeometryProxy
    ) {
        if abs(dx) > abs(dy) {
            let width = plotWidth(proxy: proxy, geometry: geometry)
            guard width > 0 else { return }
            actions.pan(-Double(dx / width) * domainSpan)
        } else if dy != 0 {
            let anchor =
                plotDate(atX: location.x, proxy: proxy, geometry: geometry) ?? domainMidpoint
            actions.zoom(anchor, exp(Double(dy) * 0.006))
        }
    }

    private var domainSpan: TimeInterval {
        xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
    }

    private var domainMidpoint: Date {
        xDomain.lowerBound.addingTimeInterval(domainSpan / 2)
    }

    /// The date under an overlay-local X position, or nil outside the plot.
    private func plotDate(atX x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        return proxy.value(atX: x - geometry[plotFrame].origin.x)
    }

    private func plotWidth(proxy: ChartProxy, geometry: GeometryProxy) -> CGFloat {
        proxy.plotFrame.map { geometry[$0].width } ?? geometry.size.width
    }

    /// The colour a series draws in, dimmed when another series is highlighted.
    private func displayColor(_ s: PerfSeries) -> Color {
        isDimmed(s) ? s.color.opacity(0.16) : s.color
    }

    private func isDimmed(_ s: PerfSeries) -> Bool {
        guard let highlighted else { return false }
        return s.id != highlighted
    }

    /// Map a cursor location in the overlay to a time on the X axis, quantised
    /// to the chart's point spacing. Every distinct `scrubDate` rebuilds the
    /// full mark set, so publishing the raw cursor time re-laid-out ~2,400
    /// marks on every mouse-move; snapping to the data's own resolution makes
    /// a move within one bucket free while the read-out still lands on exactly
    /// the same nearest samples.
    private func updateScrub(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        let x = location.x - origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        let bucket = max(span / 300, 1)
        let quantised = Date(
            timeIntervalSince1970: (date.timeIntervalSince1970 / bucket).rounded() * bucket)
        if scrubDate != quantised { scrubDate = quantised }
    }

    /// The floating read-out listing every series' value at the scrub time.
    private func scrubCard(_ readout: [(series: PerfSeries, point: PerfPoint)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let when = readout.first?.point.date {
                Text(when, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(readout.prefix(8), id: \.series.id) { entry in
                HStack(spacing: 6) {
                    Circle()
                        .fill(entry.series.color)
                        .frame(width: 7, height: 7)
                    Text(entry.series.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .leading)
                    Spacer(minLength: 8)
                    Text(yFormat(entry.point.value))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
        .frame(maxWidth: 240)
        .fixedSize()
    }
}
