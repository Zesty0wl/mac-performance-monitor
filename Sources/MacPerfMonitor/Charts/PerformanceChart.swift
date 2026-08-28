import AppKit
import MacPerfMonitorCore
import SwiftUI

/// One plotted point on a Performance Monitor series.
struct PerfPoint: Identifiable, Equatable, Sendable {
    var date: Date
    var value: Double
    var id: Date { date }
}

/// One overlaid process line on the Performance Monitor: an identity, a display
/// name, an assigned colour, and the metric's time-series.
struct PerfSeries: Identifiable, Equatable {
    var id: ProcessIdentity
    var name: String
    var color: Color
    var points: [PerfPoint]

    /// Stable, unique key for a series, used to tag its gap-free runs.
    var key: String { "\(id.pid)/\(id.startTime.timeIntervalSince1970.bitPattern)" }
}

/// The Performance Monitor's hero chart: several processes overlaid on one set
/// of axes for a single metric, in the spirit of the classic Windows
/// Performance Monitor. The X domain is supplied by the parent so the window
/// scrolls smoothly in live mode and stays fixed for a chosen historical span.
/// Hovering or dragging scrubs every series at once, pinning a combined
/// read-out of each process's value at that instant.
///
/// Drawn with the Canvas `TrendChart` plus a small decoration canvas (the
/// series-end dots and the scrub marker). This was a Swift Charts view built
/// from one mark per data point; a full grid re-laid-out ~14,000 marks every
/// time the live window slid one tick, which is what made the Analytics tab
/// the most expensive page in the app. The Canvas layers draw the same series
/// in well under a millisecond, and a scrub move repaints only the decoration
/// layer and the read-out card, never the series.
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
    /// cursor. Scrubbing moves to hover-only. Nil (the grid cells) keeps the
    /// original hover/drag scrub.
    var zoomActions: ChartZoomActions? = nil
    /// When set (the grid cells), scroll-wheel and pinch zoom the shared window
    /// while hover and drag keep scrubbing, so scrolling over any chart zooms them
    /// all. `zoomActions` (the focused chart) supersedes this with full drag-pan /
    /// Option-select.
    var scrollZoom: ChartZoomActions? = nil
    let yFormat: (Double) -> String

    /// Used with `.equatable()` so the series pipeline only re-runs when the
    /// plotted data actually changes — not on every unrelated model publish
    /// that re-evaluates the parent. `yFormat` and the zoom callbacks are
    /// deliberately ignored: pure functions/callbacks fixed per cell.
    static func == (lhs: PerformanceChart, rhs: PerformanceChart) -> Bool {
        lhs.series == rhs.series && lhs.xDomain == rhs.xDomain && lhs.minTop == rhs.minTop
            && lhs.highlighted == rhs.highlighted
            && lhs.accessibilityTitle == rhs.accessibilityTitle
    }

    @State private var scrubDate: Date?
    /// Last drag X while panning, so each change reports an incremental delta.
    @State private var panLastX: CGFloat?
    /// Rubber-band selection in local X, while an Option-drag is live.
    @State private var selection: (start: CGFloat, current: CGFloat)?
    /// Previous pinch magnification, so each change reports an incremental factor.
    @State private var magnifyLast: CGFloat = 1

    /// Mirrors the geometry `TrendChart` lays its plot out with, so the
    /// interaction overlays and decorations agree with the drawn axes. The
    /// gutter fits the widest metric tick strings ("38.4 MB/s").
    private static let chartGeometry = TrendChartGeometry(
        leftGutter: 52, showsTimeAxis: true, plotBorder: true)

    /// Snapped to a nice ceiling so the axis holds still between ticks instead
    /// of trembling with the peak.
    private var yMax: Double {
        let peak = series.flatMap(\.points).map(\.value).max() ?? 0
        return LiveChartGeometry.niceCeiling(max(peak * 1.12, minTop))
    }

    /// Every series split into gap-free runs, each run drawn as its own
    /// `TrendSeries` (so the gaps between runs stay blank), coloured with the
    /// dimming already applied.
    private var trendSeries: [TrendSeries] {
        series.flatMap { s -> [TrendSeries] in
            Self.split(s.points).map { run in
                TrendSeries(
                    points: run.map { TrendPoint(date: $0.date, value: $0.value) },
                    color: displayColor(s), filled: false, lineWidth: 1.8)
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

    var body: some View {
        GeometryReader { geo in
            let plot = Self.chartGeometry.plotRect(in: geo.size)
            let readout = scrubReadout
            ZStack(alignment: .topLeading) {
                TrendChart(
                    series: trendSeries,
                    xDomain: xDomain,
                    yDomain: 0...yMax,
                    yFormat: yFormat,
                    showsTimeAxis: true,
                    timeAxis: .clock,
                    gapThreshold: .infinity,
                    plotBorder: true,
                    leftGutter: Self.chartGeometry.leftGutter
                )
                PerfDecorLayer(
                    plot: plot,
                    xDomain: xDomain,
                    yMax: yMax,
                    scrubX: scrubDate.map { xFor($0, in: plot) },
                    endDots: endDots,
                    scrubDots: readout.compactMap { entry in
                        isDimmed(entry.series)
                            ? nil
                            : PerfDecorLayer.Dot(
                                date: entry.point.date, value: entry.point.value,
                                color: entry.series.color, radius: 3.9)
                    }
                )
                .allowsHitTesting(false)
                if let zoomActions {
                    zoomableOverlay(zoomActions, plot: plot)
                } else {
                    scrubOverlay(plot: plot)
                }
                if !readout.isEmpty {
                    scrubCard(readout)
                        .offset(x: cardLeft(in: plot), y: plot.minY + 6)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilitySummary)
        .reducedMotionAware()
    }

    /// A small solid dot pinning each series' current value, hidden for dimmed
    /// series so the highlighted line reads cleanly.
    private var endDots: [PerfDecorLayer.Dot] {
        series.compactMap { s in
            guard let last = s.points.last, !isDimmed(s) else { return nil }
            return PerfDecorLayer.Dot(
                date: last.date, value: last.value, color: s.color, radius: 2.9)
        }
    }

    // MARK: - Interaction overlays

    /// The grid cells' overlay: hover or drag scrubs the read-out, and (when
    /// `scrollZoom` is set) scroll-wheel and pinch zoom the shared window so every
    /// chart zooms together. The focused chart uses `zoomableOverlay` instead.
    private func scrubOverlay(plot: CGRect) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    updateScrub(at: location, plot: plot)
                case .ended:
                    scrubDate = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateScrub(at: value.location, plot: plot)
                    }
                    .onEnded { _ in scrubDate = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard let scrollZoom else { return }
                        let factor = value.magnification / magnifyLast
                        magnifyLast = value.magnification
                        scrollZoom.zoom(
                            dateAt(x: value.startLocation.x, in: plot), Double(factor))
                    }
                    .onEnded { _ in magnifyLast = 1 }
            )
            .background(
                Group {
                    if let scrollZoom {
                        ScrollWheelCatcher { location, dx, dy in
                            handleScroll(
                                scrollZoom, location: location, dx: dx, dy: dy, plot: plot)
                        }
                    }
                }
            )
    }

    /// The focused chart's interactive overlay: hover scrubs; drag pans;
    /// Option-drag draws a rubber-band selection and zooms to it; double-click
    /// zooms out a step; pinch and scroll-wheel zoom about the cursor.
    private func zoomableOverlay(_ actions: ChartZoomActions, plot: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear)
            if let selection {
                let x0 = min(selection.start, selection.current)
                let width = max(abs(selection.current - selection.start), 1)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.55), lineWidth: 1))
                    .frame(width: width, height: plot.height)
                    .offset(x: x0, y: plot.minY)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard panLastX == nil, selection == nil else { return }
                updateScrub(at: location, plot: plot)
            case .ended:
                scrubDate = nil
            }
        }
        .gesture(
            SpatialTapGesture(count: 2).onEnded { value in
                actions.zoom(dateAt(x: value.location.x, in: plot), 0.5)
            }
        )
        .simultaneousGesture(panOrSelectGesture(actions, plot: plot))
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let factor = value.magnification / magnifyLast
                    magnifyLast = value.magnification
                    actions.zoom(dateAt(x: value.startLocation.x, in: plot), Double(factor))
                }
                .onEnded { _ in magnifyLast = 1 }
        )
        .background(
            ScrollWheelCatcher { location, dx, dy in
                handleScroll(actions, location: location, dx: dx, dy: dy, plot: plot)
            }
        )
    }

    /// One drag serves two modes, decided by the Option key at drag start:
    /// plain drag pans the window; Option-drag rubber-bands a range to zoom to.
    private func panOrSelectGesture(_ actions: ChartZoomActions, plot: CGRect) -> some Gesture {
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
                    guard plot.width > 0 else { return }
                    // Dragging the plot right shows earlier data, like grabbing
                    // the chart paper.
                    actions.pan(-Double(dx / plot.width) * domainSpan)
                }
            }
            .onEnded { _ in
                if let sel = selection {
                    let x0 = min(sel.start, sel.current)
                    let x1 = max(sel.start, sel.current)
                    if x1 - x0 > 8 {
                        let d0 = dateAt(x: x0, in: plot)
                        let d1 = dateAt(x: x1, in: plot)
                        if d0 < d1 { actions.selectRange(d0...d1) }
                    }
                }
                selection = nil
                panLastX = nil
            }
    }

    /// Scroll-wheel routing: the dominant axis decides. Horizontal (two-finger
    /// swipe) pans; vertical zooms about the cursor — wheel/swipe up zooms in.
    private func handleScroll(
        _ actions: ChartZoomActions, location: CGPoint, dx: CGFloat, dy: CGFloat, plot: CGRect
    ) {
        if abs(dx) > abs(dy) {
            guard plot.width > 0 else { return }
            actions.pan(-Double(dx / plot.width) * domainSpan)
        } else if dy != 0 {
            actions.zoom(dateAt(x: location.x, in: plot), exp(Double(dy) * 0.006))
        }
    }

    private var domainSpan: TimeInterval {
        xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
    }

    /// The date under a local X position, extrapolating linearly beyond the
    /// plot edges (matching the old ChartProxy behaviour, so a scrub or zoom
    /// anchor just outside the plot still lands sensibly).
    private func dateAt(x: CGFloat, in plot: CGRect) -> Date {
        let fraction = Double((x - plot.minX) / max(plot.width, 1))
        return xDomain.lowerBound.addingTimeInterval(fraction * domainSpan)
    }

    private func xFor(_ date: Date, in plot: CGRect) -> CGFloat {
        guard domainSpan > 0 else { return plot.minX }
        return plot.minX
            + CGFloat(date.timeIntervalSince(xDomain.lowerBound) / domainSpan) * plot.width
    }

    /// The colour a series draws in, dimmed when another series is highlighted.
    private func displayColor(_ s: PerfSeries) -> Color {
        isDimmed(s) ? s.color.opacity(0.16) : s.color
    }

    private func isDimmed(_ s: PerfSeries) -> Bool {
        guard let highlighted else { return false }
        return s.id != highlighted
    }

    /// Map a cursor location to a time on the X axis, quantised to the chart's
    /// point spacing: a move within one bucket republishes nothing, while the
    /// read-out still lands on exactly the same nearest samples.
    private func updateScrub(at location: CGPoint, plot: CGRect) {
        let date = dateAt(x: location.x, in: plot)
        let bucket = max(domainSpan / 300, 1)
        let quantised = Date(
            timeIntervalSince1970: (date.timeIntervalSince1970 / bucket).rounded() * bucket)
        if scrubDate != quantised { scrubDate = quantised }
    }

    /// Where the read-out card's leading edge sits: centred on the scrub rule,
    /// clamped so the card (at most 240 wide) stays inside the plot.
    private func cardLeft(in plot: CGRect) -> CGFloat {
        guard let scrubDate else { return plot.minX }
        let half: CGFloat = 120
        let centre = xFor(scrubDate, in: plot)
        return min(max(centre - half, plot.minX), max(plot.minX, plot.maxX - 2 * half))
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

/// The decorations the base chart does not draw: the series-end value dots,
/// and (while scrubbing) the vertical rule with a dot on each series' nearest
/// sample. A separate Canvas so a scrub move repaints only this layer and
/// never the series beneath it.
private struct PerfDecorLayer: View {
    struct Dot {
        var date: Date
        var value: Double
        var color: Color
        var radius: CGFloat
    }

    let plot: CGRect
    let xDomain: ClosedRange<Date>
    let yMax: Double
    let scrubX: CGFloat?
    let endDots: [Dot]
    let scrubDots: [Dot]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
            let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
            guard span > 0, yMax > 0 else { return }
            func x(_ d: Date) -> CGFloat {
                plot.minX
                    + CGFloat(d.timeIntervalSince(xDomain.lowerBound) / span) * plot.width
            }
            func y(_ v: Double) -> CGFloat {
                plot.maxY - CGFloat(min(max(v / yMax, 0), 1)) * plot.height
            }
            if let scrubX {
                let xx = min(max(scrubX, plot.minX), plot.maxX)
                var rule = Path()
                rule.move(to: CGPoint(x: xx, y: plot.minY))
                rule.addLine(to: CGPoint(x: xx, y: plot.maxY))
                ctx.stroke(rule, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            }
            for dot in endDots + scrubDots {
                let cx = x(dot.date)
                guard cx >= plot.minX - dot.radius, cx <= plot.maxX + dot.radius else { continue }
                let rect = CGRect(
                    x: cx - dot.radius, y: y(dot.value) - dot.radius,
                    width: 2 * dot.radius, height: 2 * dot.radius)
                ctx.fill(Path(ellipseIn: rect), with: .color(dot.color))
            }
        }
    }
}
