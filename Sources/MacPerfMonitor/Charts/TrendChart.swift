import MacPerfMonitorCore
import SwiftUI

/// One plotted point on a `TrendChart`.
struct TrendPoint: Equatable {
    var date: Date
    var value: Double
}

/// One line (with optional area fill) on a `TrendChart`.
struct TrendSeries: Equatable {
    var points: [TrendPoint]
    var color: Color
    var filled: Bool = false
    var lineWidth: CGFloat = 2
}

/// A dashed horizontal threshold line with a small leading label (e.g. "Busy").
struct TrendRule: Equatable {
    var value: Double
    var label: String
    var color: Color
}

/// A lightweight, immediate-mode timeline chart drawn with two `Canvas` layers,
/// the same approach as the menu-bar `Sparkline`, generalised. It replaces
/// Swift Charts for every live timeline in the app, which built a SwiftUI view
/// per data point and re-ran full layout on every refresh (the app's #1 CPU
/// cost with a window open, and a layout-loop risk). A Canvas draws the whole
/// series in one pass, so a redraw is cheap even when the view re-renders.
///
/// The layers split the work by how often it changes. The value axis (Y
/// gridlines, their labels, the threshold rules, and a relative "time ago" axis
/// whose labels sit at fixed positions) lives in an `Equatable` layer SwiftUI
/// leaves alone between ticks. The series, the scrub marker and the moving
/// wall-clock gridlines are drawn in the live layer. Wall-clock labels are
/// SwiftUI `Text` views keyed by their tick time, so a tick only moves them;
/// resolving text inside a Canvas was the dearest part of a 4 Hz redraw.
///
/// Supports one or more series (line + optional gradient area fill), explicit
/// or auto Y domain/ticks, dashed threshold rules, gap-aware lines (a stretch of
/// missing data is left blank rather than bridged with a diagonal), optional
/// hover/drag scrubbing with a read-out of the nearest point, and a plot
/// border. A series denser than the plot is reduced to per-pixel extremes
/// before stroking.
struct TrendChart: View {
    /// How the time axis is labelled.
    enum TimeAxis: Equatable {
        /// Wall-clock times ("14:30") that slide left with the data.
        case clock
        /// Offsets from the live edge ("now", "15m", "1h") at fixed positions.
        case ago
    }

    var series: [TrendSeries]
    /// Fixed time range mapped across the plot. Live charts supply a trailing
    /// window ending at the newest recorded sample so every tick moves the
    /// existing trace left by exactly the sample delta divided by the window.
    /// Nil preserves the data-derived extent for static charts.
    var xDomain: ClosedRange<Date>? = nil
    /// Y range; computed from the data (0…peak×1.1) when nil.
    var yDomain: ClosedRange<Double>? = nil
    /// Y gridline/label positions; evenly spaced across the domain when nil.
    var yTicks: [Double]? = nil
    var yFormat: (Double) -> String = { String(Int($0)) }
    var rules: [TrendRule] = []
    /// When true, a row of time labels (with faint vertical gridlines) is drawn
    /// beneath the plot. Off by default so the compact dashboard charts keep
    /// their full height.
    var showsTimeAxis: Bool = false
    var timeAxis: TimeAxis = .clock
    /// Two consecutive points further apart than this are not joined. Nil
    /// derives a threshold from the window (or the median spacing); pass
    /// `.infinity` for a series the caller has already split.
    var gapThreshold: TimeInterval? = nil
    /// Draw a hairline frame around the plot.
    var plotBorder: Bool = false
    /// Hovering or dragging over the plot pins a marker and a read-out at the
    /// nearest point of any series.
    var scrubbable: Bool = false

    /// Width reserved for the Y axis labels. The default fits short tick
    /// strings ("85%", "1.2 GB"); charts whose ticks format as byte rates or
    /// large sizes ("38.4 MB/s", "460.4 GB") pass a wider gutter, because the
    /// canvas clips the label's left edge when it does not fit.
    var leftGutter: CGFloat = 38

    /// Horizontal scrub position as a fraction of the plot width, nil when idle.
    @State private var scrubFraction: CGFloat?

    var body: some View {
        let domain = resolvedDomain()
        let ticks = yTicks ?? Self.defaultTicks(domain)
        let geometry = TrendChartGeometry(
            leftGutter: leftGutter, showsTimeAxis: showsTimeAxis, plotBorder: plotBorder)
        let (tMin, tMax) = timeBounds()
        let span = max(tMax - tMin, 0.0001)
        let hasTime = tMax > tMin
        let agoTicks = showsTimeAxis && timeAxis == .ago && hasTime ? Self.agoTicks(span: span) : []
        let clockTicks =
            showsTimeAxis && timeAxis == .clock && hasTime ? Self.clockTicks(tMin, tMax) : []
        let scrub = scrubFraction.flatMap { nearestPoint(fraction: $0, tMin: tMin, span: span) }
        ZStack {
            TrendValueAxisLayer(
                geometry: geometry,
                domain: domain,
                ticks: ticks.map { TrendValueAxisLayer.Tick(value: $0, label: yFormat($0)) },
                rules: rules,
                agoTicks: agoTicks
            )
            .equatable()
            TrendLiveLayer(
                geometry: geometry,
                series: series,
                domain: domain,
                tMin: tMin,
                tMax: tMax,
                gapThreshold: resolvedGapThreshold(span: span),
                clockTickFractions: clockTicks.map(\.fraction),
                scrub: scrub
            )
            if !clockTicks.isEmpty {
                TrendClockLabels(geometry: geometry, ticks: clockTicks)
                    .allowsHitTesting(false)
            }
            if scrubbable {
                TrendScrubOverlay(geometry: geometry, point: scrub, yFormat: yFormat) {
                    scrubFraction = $0
                }
            }
        }
        // One accessibility element for the whole chart: the callers' label and
        // value describe the series, and without this each layer and axis label
        // repeated them to VoiceOver.
        .accessibilityElement(children: .ignore)
    }

    // MARK: - Helpers

    /// The explicit domain, or 0 up to a nice value just above the peak, so
    /// the static axis layer only redraws when the data crosses a rung.
    private func resolvedDomain() -> ClosedRange<Double> {
        if let yDomain { return yDomain }
        var peak = 0.0
        for s in series {
            for p in s.points where p.value > peak { peak = p.value }
        }
        return 0...LiveChartGeometry.niceCeiling(max(peak * 1.1, 1))
    }

    static func defaultTicks(_ domain: ClosedRange<Double>) -> [Double] {
        let n = 4
        return (0...n).map {
            domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double($0) / Double(n)
        }
    }

    /// Time bounds in `timeIntervalSinceReferenceDate` seconds: the fixed
    /// window, or the union of all series' dates.
    private func timeBounds() -> (Double, Double) {
        if let xDomain {
            return (
                xDomain.lowerBound.timeIntervalSinceReferenceDate,
                xDomain.upperBound.timeIntervalSinceReferenceDate
            )
        }
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for s in series {
            for p in s.points {
                let t = p.date.timeIntervalSinceReferenceDate
                if t < lo { lo = t }
                if t > hi { hi = t }
            }
        }
        return lo <= hi ? (lo, hi) : (0, 0)
    }

    /// A jump beyond the window's spacing × 15 (floored at 30 s) is treated as
    /// missing data, matching the previous Swift Charts behaviour. Nil asks the
    /// live layer to derive one from the median spacing instead.
    private func resolvedGapThreshold(span: Double) -> TimeInterval? {
        if let gapThreshold { return gapThreshold }
        return xDomain.map { _ in max(span / 360 * 15, 30) }
    }

    /// The point of any series nearest the scrubbed time.
    private func nearestPoint(fraction: CGFloat, tMin: Double, span: Double) -> TrendScrubPoint? {
        let target = tMin + Double(fraction) * span
        var best: TrendPoint?
        var bestDistance = Double.greatestFiniteMagnitude
        for s in series {
            for p in s.points {
                let distance = abs(p.date.timeIntervalSinceReferenceDate - target)
                if distance < bestDistance {
                    bestDistance = distance
                    best = p
                }
            }
        }
        guard let best else { return nil }
        return TrendScrubPoint(
            fraction: CGFloat((best.date.timeIntervalSinceReferenceDate - tMin) / span),
            date: best.date, value: best.value)
    }

    // MARK: - Gap runs

    /// Split a series into gap-free runs. Live charts pass a fixed threshold
    /// derived from the window so the split never needs a sort; static charts
    /// use the median spacing × 15 (floored at 30 s).
    static func runs(
        _ points: [TrendPoint], gapThreshold fixedThreshold: TimeInterval?
    ) -> [[TrendPoint]] {
        guard points.count > 1 else { return points.isEmpty ? [] : [points] }
        let threshold: TimeInterval
        if let fixedThreshold {
            threshold = fixedThreshold
        } else {
            var deltas: [TimeInterval] = []
            deltas.reserveCapacity(points.count - 1)
            for i in 1..<points.count {
                deltas.append(points[i].date.timeIntervalSince(points[i - 1].date))
            }
            deltas.sort()
            threshold = max(deltas[deltas.count / 2] * 15, 30)
        }
        // Fast path: no gaps, the whole series is one run and needs no copy.
        var hasGap = false
        for i in 1..<points.count
        where points[i].date.timeIntervalSince(points[i - 1].date) > threshold {
            hasGap = true
            break
        }
        if !hasGap { return [points] }
        var result: [[TrendPoint]] = []
        var current: [TrendPoint] = [points[0]]
        for pt in points.dropFirst() {
            if let last = current.last, pt.date.timeIntervalSince(last.date) > threshold {
                result.append(current)
                current = [pt]
            } else {
                current.append(pt)
            }
        }
        result.append(current)
        return result
    }

    // MARK: - Time axis ticks

    /// "now" / "15m" / "2h" offsets back from the live edge at round steps, as
    /// fractions of the plot width. Positions depend only on the window length,
    /// so the axis is static while the data slides beneath it.
    static func agoTicks(span: Double) -> [TrendAxisTick] {
        let step = niceAgoStep(span)
        var ticks: [TrendAxisTick] = []
        var offset: Double = 0
        while offset <= span + 0.5, ticks.count < 9 {
            ticks.append(TrendAxisTick(fraction: 1 - offset / span, label: agoLabel(offset)))
            offset += step
        }
        return ticks
    }

    /// A round tick interval giving roughly four labels across the window.
    private static func niceAgoStep(_ window: TimeInterval) -> TimeInterval {
        let target = max(window, 1) / 4
        let candidates: [TimeInterval] = [
            15, 30, 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60,
            3600, 2 * 3600, 3 * 3600, 6 * 3600, 12 * 3600,
            86_400, 2 * 86_400, 7 * 86_400,
        ]
        return candidates.first { $0 >= target } ?? target
    }

    /// "now" / "15m" / "2h" / "3d": how far a tick sits behind the live edge.
    private static func agoLabel(_ delta: TimeInterval) -> String {
        if delta < 45 { return t("now") }
        if delta < 3600 { return "\(Int((delta / 60).rounded()))m" }
        if delta < 48 * 3600 { return "\(Int((delta / 3600).rounded()))h" }
        return "\(Int((delta / 86_400).rounded()))d"
    }

    /// Wall-clock tick marks for the time axis: a "nice" step chosen for ~4–7
    /// labels across the visible span, aligned to local time so ticks land on
    /// round times (…:00, midnight) rather than UTC boundaries. Bounds are in
    /// `timeIntervalSinceReferenceDate` seconds.
    ///
    /// The step's granularity, and hence whether labels read as clock times or
    /// dates, follows the *actual data span*, not the selected window: a 7-day
    /// window with only two days of history logged still spans two days, so it
    /// gets day-granular date labels rather than midnight-crossing times.
    static func clockTicks(_ tMin: Double, _ tMax: Double) -> [TrendClockTick] {
        let span = tMax - tMin
        guard span > 0 else { return [] }
        let step = clockTickStep(forSpan: span)
        let fmt = tickFormatter(forStep: step)
        return clockTickTimes(from: tMin, to: tMax, step: step).map { t in
            let date = Date(timeIntervalSinceReferenceDate: t)
            return TrendClockTick(
                id: date, fraction: (t - tMin) / span, label: fmt.string(from: date))
        }
    }

    /// The wall-clock tick interval for a visible span. Past ~a day, whole
    /// days so labels read as dates; below that, seconds/minutes/hours so they
    /// read as clock times. Exposed so a strip chart can draw gridlines beyond
    /// the visible span at the same step as the visible labels.
    static func clockTickStep(forSpan span: Double) -> Double {
        let steps: [Double] =
            span > 86_400
            ? [86_400, 172_800, 604_800]  // 1d, 2d, 1w
            : [15, 30, 60, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200]  // 15s … 12h
        return steps.first { span / $0 <= 7 } ?? steps.last!
    }

    /// The label for a wall-clock tick at `t` (seconds since the reference
    /// date) on an axis stepping by `step`: a date past a day, a time below,
    /// with seconds when the step itself is sub-minute.
    static func clockTickLabel(_ t: Double, step: Double) -> String {
        tickFormatter(forStep: step).string(from: Date(timeIntervalSinceReferenceDate: t))
    }

    private static func tickFormatter(forStep step: Double) -> DateFormatter {
        if step >= 86_400 { return dayTickFormatter }
        if step >= 60 { return timeTickFormatter }
        return secondsTickFormatter
    }

    /// Tick times at `step` within `from...to`, aligned to local wall-clock
    /// boundaries. `timeIntervalSinceReferenceDate` is UTC-anchored, so the
    /// local offset is applied before rounding and removed after.
    static func clockTickTimes(from: Double, to: Double, step: Double) -> [Double] {
        guard step > 0, to >= from else { return [] }
        let tz = Double(TimeZone.current.secondsFromGMT())
        var t = ceil((from + tz) / step) * step - tz
        var out: [Double] = []
        while t <= to + 0.5 {
            out.append(t)
            t += step
        }
        return out
    }

    /// Shared axis-label formatters. Allocating and configuring a DateFormatter
    /// inside the draw path re-ran on every redraw of every timeline (per tick,
    /// per chart); these are built once. Main-thread only, like the Canvas that
    /// uses them. "Jun 30" / "14:30" respectively.
    private static let dayTickFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = .autoupdatingCurrent
        fmt.setLocalizedDateFormatFromTemplate("MMMd")
        return fmt
    }()
    private static let timeTickFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = .autoupdatingCurrent
        fmt.setLocalizedDateFormatFromTemplate("Hmm")
        return fmt
    }()
    private static let secondsTickFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = .autoupdatingCurrent
        fmt.setLocalizedDateFormatFromTemplate("Hmmss")
        return fmt
    }()
}

/// The plot rectangle shared by the layers, so gridlines, labels, the series
/// and the scrub overlay agree on where the axes are.
struct TrendChartGeometry: Equatable {
    var leftGutter: CGFloat
    var showsTimeAxis: Bool
    var plotBorder: Bool = false
    var topPad: CGFloat = 6
    var bottomPad: CGFloat = 4
    var rightPad: CGFloat = 6

    /// No gutters or padding: the plot is the whole view (card sparklines).
    static let bare = TrendChartGeometry(
        leftGutter: 0, showsTimeAxis: false, plotBorder: false, topPad: 0, bottomPad: 0,
        rightPad: 0)

    func plotRect(in size: CGSize) -> CGRect {
        let xAxisHeight: CGFloat = showsTimeAxis ? 16 : 0
        return CGRect(
            x: leftGutter, y: topPad,
            width: max(1, size.width - leftGutter - rightPad),
            height: max(1, size.height - topPad - bottomPad - xAxisHeight))
    }

    /// Keep edge labels inside the plot so they don't clip.
    static func timeLabelPlacement(
        x: CGFloat, y: CGFloat, in plot: CGRect
    ) -> (
        CGPoint, UnitPoint
    ) {
        if x < plot.minX + 14 { return (CGPoint(x: plot.minX, y: y), .topLeading) }
        if x > plot.maxX - 14 { return (CGPoint(x: plot.maxX, y: y), .topTrailing) }
        return (CGPoint(x: x, y: y), .top)
    }
}

/// A tick on the static "time ago" axis: a fraction of the plot width.
struct TrendAxisTick: Equatable {
    var fraction: Double
    var label: String
}

/// A wall-clock tick, identified by its time so its label view persists while
/// the window slides and only its position changes.
struct TrendClockTick: Identifiable, Equatable {
    var id: Date
    var fraction: Double
    var label: String
}

/// The scrubbed point: where it sits across the plot and what it reads.
struct TrendScrubPoint: Equatable {
    var fraction: CGFloat
    var date: Date
    var value: Double
}

/// Y gridlines, their labels, the dashed threshold rules, the optional border,
/// and the relative time axis. Equatable on its inputs, so it only redraws when
/// the axes actually change.
private struct TrendValueAxisLayer: View, Equatable {
    struct Tick: Equatable {
        var value: Double
        var label: String
    }

    let geometry: TrendChartGeometry
    let domain: ClosedRange<Double>
    let ticks: [Tick]
    let rules: [TrendRule]
    let agoTicks: [TrendAxisTick]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let plot = geometry.plotRect(in: size)
            func y(_ v: Double) -> CGFloat {
                plot.maxY - CGFloat(LiveChartGeometry.normalizedY(v, in: domain)) * plot.height
            }

            for tick in ticks {
                let yy = y(tick.value)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: yy))
                line.addLine(to: CGPoint(x: plot.maxX, y: yy))
                ctx.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
                let label = ctx.resolve(
                    Text(tick.label).font(.system(size: 9)).foregroundColor(.secondary))
                ctx.draw(label, at: CGPoint(x: plot.minX - 5, y: yy), anchor: .trailing)
            }

            for rule in rules {
                let yy = y(rule.value)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: yy))
                line.addLine(to: CGPoint(x: plot.maxX, y: yy))
                ctx.stroke(
                    line, with: .color(rule.color.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                let label = ctx.resolve(
                    Text(t(rule.label)).font(.system(size: 9)).foregroundColor(rule.color))
                ctx.draw(label, at: CGPoint(x: plot.minX + 3, y: yy - 7), anchor: .topLeading)
            }

            // The relative time axis: positions fixed by the window length, so
            // it is drawn here, once, rather than on every tick.
            let labelY = plot.maxY + 3
            for tick in agoTicks {
                let xx = plot.minX + CGFloat(tick.fraction) * plot.width
                var line = Path()
                line.move(to: CGPoint(x: xx, y: plot.minY))
                line.addLine(to: CGPoint(x: xx, y: plot.maxY))
                ctx.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
                let label = ctx.resolve(
                    Text(tick.label).font(.system(size: 9)).foregroundColor(.secondary))
                let (at, anchor) = TrendChartGeometry.timeLabelPlacement(
                    x: xx, y: labelY, in: plot)
                ctx.draw(label, at: at, anchor: anchor)
            }

            if geometry.plotBorder {
                ctx.stroke(Path(plot), with: .color(.secondary.opacity(0.22)), lineWidth: 0.5)
            }
        }
    }
}

/// The series, the moving wall-clock gridlines and the scrub marker, redrawn
/// every tick.
private struct TrendLiveLayer: View {
    let geometry: TrendChartGeometry
    let series: [TrendSeries]
    let domain: ClosedRange<Double>
    let tMin: Double
    let tMax: Double
    let gapThreshold: TimeInterval?
    let clockTickFractions: [Double]
    let scrub: TrendScrubPoint?

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let plot = geometry.plotRect(in: size)
            func y(_ v: Double) -> CGFloat {
                plot.maxY - CGFloat(LiveChartGeometry.normalizedY(v, in: domain)) * plot.height
            }
            let tSpan = max(tMax - tMin, 0.0001)
            func x(_ d: Date) -> CGFloat {
                plot.minX + CGFloat((d.timeIntervalSinceReferenceDate - tMin) / tSpan) * plot.width
            }

            for fraction in clockTickFractions {
                let xx = plot.minX + CGFloat(fraction) * plot.width
                var line = Path()
                line.move(to: CGPoint(x: xx, y: plot.minY))
                line.addLine(to: CGPoint(x: xx, y: plot.maxY))
                ctx.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
            }

            guard tMax > tMin else { return }

            // A series denser than the plot is reduced to per-pixel extremes so
            // the stroked path never has more segments than there are columns.
            let columns = max(1, Int(plot.width.rounded(.up)))
            let plotDomain =
                Date(
                    timeIntervalSinceReferenceDate: tMin)...Date(
                    timeIntervalSinceReferenceDate: tMax)

            // Series stay inside the plot: callers retain samples slightly
            // older than the window (so the line enters from the left edge),
            // and unclipped those points stroke through the axis gutter.
            var seriesCtx = ctx
            seriesCtx.clip(to: Path(plot))

            // Each series: gap-aware runs, optional area fill, then the line.
            for s in series {
                for rawRun in TrendChart.runs(s.points, gapThreshold: gapThreshold)
                where !rawRun.isEmpty {
                    let run: [TrendPoint]
                    if rawRun.count > 2 * columns {
                        run = LiveSeriesDecimator.decimate(
                            rawRun, buckets: columns, domain: plotDomain,
                            date: { $0.date }, value: { $0.value }
                        ).map { TrendPoint(date: $0.date, value: $0.value) }
                    } else {
                        run = rawRun
                    }
                    var linePath = Path()
                    for (i, pt) in run.enumerated() {
                        let q = CGPoint(x: x(pt.date), y: y(pt.value))
                        if i == 0 { linePath.move(to: q) } else { linePath.addLine(to: q) }
                    }
                    if s.filled, run.count >= 2 {
                        var fill = linePath
                        fill.addLine(to: CGPoint(x: x(run.last!.date), y: plot.maxY))
                        fill.addLine(to: CGPoint(x: x(run.first!.date), y: plot.maxY))
                        fill.closeSubpath()
                        seriesCtx.fill(
                            fill,
                            with: .linearGradient(
                                Gradient(colors: [s.color.opacity(0.42), s.color.opacity(0.04)]),
                                startPoint: CGPoint(x: 0, y: plot.minY),
                                endPoint: CGPoint(x: 0, y: plot.maxY)))
                    }
                    if run.count >= 2 {
                        seriesCtx.stroke(
                            linePath, with: .color(s.color),
                            style: StrokeStyle(
                                lineWidth: s.lineWidth, lineCap: .round, lineJoin: .round))
                    } else if let only = run.first {
                        // A lone point draws a dot so an isolated reading is visible.
                        let r: CGFloat = 1.6
                        let dot = Path(
                            ellipseIn: CGRect(
                                x: x(only.date) - r, y: y(only.value) - r, width: 2 * r,
                                height: 2 * r))
                        seriesCtx.fill(dot, with: .color(s.color))
                    }
                }
            }

            if let scrub {
                let xx = plot.minX + scrub.fraction * plot.width
                var rule = Path()
                rule.move(to: CGPoint(x: xx, y: plot.minY))
                rule.addLine(to: CGPoint(x: xx, y: plot.maxY))
                ctx.stroke(rule, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                let r: CGFloat = 3
                let color = series.first?.color ?? .accentColor
                ctx.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: xx - r, y: y(scrub.value) - r, width: 2 * r, height: 2 * r)),
                    with: .color(color))
            }
        }
    }
}

/// Wall-clock labels as SwiftUI text keyed by tick time: a tick moves them,
/// it never re-lays-out their text.
private struct TrendClockLabels: View {
    let geometry: TrendChartGeometry
    let ticks: [TrendClockTick]

    var body: some View {
        GeometryReader { geo in
            let plot = geometry.plotRect(in: geo.size)
            ForEach(ticks) { tick in
                let xx = plot.minX + CGFloat(tick.fraction) * plot.width
                Text(tick.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(max(xx, plot.minX + 14), plot.maxX - 14), y: plot.maxY + 9)
            }
        }
    }
}

/// Hover/drag tracking over the plot plus the floating read-out for the
/// scrubbed point.
private struct TrendScrubOverlay: View {
    let geometry: TrendChartGeometry
    let point: TrendScrubPoint?
    let yFormat: (Double) -> String
    let onScrub: (CGFloat?) -> Void

    var body: some View {
        GeometryReader { geo in
            let plot = geometry.plotRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            onScrub(Self.fraction(of: location.x, in: plot))
                        case .ended:
                            onScrub(nil)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { onScrub(Self.fraction(of: $0.location.x, in: plot)) }
                            .onEnded { _ in onScrub(nil) }
                    )
                if let point {
                    let xx = plot.minX + point.fraction * plot.width
                    readout(point)
                        .fixedSize()
                        .allowsHitTesting(false)
                        .position(
                            x: min(max(xx, plot.minX + 44), plot.maxX - 44), y: plot.minY + 16)
                }
            }
        }
    }

    private static func fraction(of x: CGFloat, in plot: CGRect) -> CGFloat {
        min(max((x - plot.minX) / max(plot.width, 1), 0), 1)
    }

    private func readout(_ point: TrendScrubPoint) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(point.date, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(yFormat(point.value))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
    }
}
