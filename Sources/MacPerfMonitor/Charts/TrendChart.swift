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

/// A lightweight, immediate-mode timeline chart drawn entirely with a single
/// `Canvas` — the same approach as the menu-bar `Sparkline`, generalised. It
/// replaces Swift Charts for the dashboard/tab timelines, which built a SwiftUI
/// view per data point and re-ran full layout on every refresh (the app's #1 CPU
/// cost with a window open, and a layout-loop risk). A Canvas draws the whole
/// series in one pass, so a redraw is cheap even when the view re-renders.
///
/// Supports one or two series (line + optional gradient area fill), explicit or
/// auto Y domain/ticks, dashed threshold rules, and gap-aware lines (a stretch of
/// missing data is left blank rather than bridged with a diagonal).
struct TrendChart: View {
    var series: [TrendSeries]
    /// Y range; computed from the data (0…peak×1.1) when nil.
    var yDomain: ClosedRange<Double>? = nil
    /// Y gridline/label positions; evenly spaced across the domain when nil.
    var yTicks: [Double]? = nil
    var yFormat: (Double) -> String = { String(Int($0)) }
    var rules: [TrendRule] = []
    /// When true, a row of wall-clock time labels (with faint vertical
    /// gridlines) is drawn beneath the plot. Off by default so the compact
    /// dashboard charts keep their full height.
    var showsTimeAxis: Bool = false

    /// Width reserved for the Y axis labels. The default fits short tick
    /// strings ("85%", "1.2 GB"); charts whose ticks format as byte rates or
    /// large sizes ("38.4 MB/s", "460.4 GB") pass a wider gutter, because the
    /// canvas clips the label's left edge when it does not fit.
    var leftGutter: CGFloat = 38
    private let topPad: CGFloat = 6
    private let bottomPad: CGFloat = 4

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let xAxisHeight: CGFloat = showsTimeAxis ? 16 : 0
            let plot = CGRect(
                x: leftGutter, y: topPad,
                width: max(1, size.width - leftGutter - 6),
                height: max(1, size.height - topPad - bottomPad - xAxisHeight))

            let domain = resolvedDomain()
            let span = max(domain.upperBound - domain.lowerBound, 0.0001)
            func y(_ v: Double) -> CGFloat {
                plot.maxY - CGFloat(
                    (min(max(v, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span)
                    * plot.height
            }

            // Time → X across the union of all series' dates.
            let (tMin, tMax) = timeBounds()
            let tSpan = max(tMax - tMin, 0.0001)
            func x(_ d: Date) -> CGFloat {
                plot.minX + CGFloat((d.timeIntervalSinceReferenceDate - tMin) / tSpan) * plot.width
            }

            // Gridlines + Y labels.
            for tick in yTicks ?? defaultTicks(domain) {
                let yy = y(tick)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: yy))
                line.addLine(to: CGPoint(x: plot.maxX, y: yy))
                ctx.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
                let label = ctx.resolve(
                    Text(yFormat(tick)).font(.system(size: 9)).foregroundColor(.secondary))
                ctx.draw(label, at: CGPoint(x: plot.minX - 5, y: yy), anchor: .trailing)
            }

            // Threshold rules (dashed, coloured) with a leading label.
            for rule in rules {
                let yy = y(rule.value)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: yy))
                line.addLine(to: CGPoint(x: plot.maxX, y: yy))
                ctx.stroke(
                    line, with: .color(rule.color.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                let label = ctx.resolve(
                    Text(rule.label).font(.system(size: 9)).foregroundColor(rule.color))
                ctx.draw(label, at: CGPoint(x: plot.minX + 3, y: yy - 7), anchor: .topLeading)
            }

            // Time axis: faint vertical gridlines and a row of wall-clock labels
            // below the plot, so a reading can be placed in time.
            if showsTimeAxis, tMax > tMin {
                let labelY = plot.maxY + 3
                for tick in xAxisTicks(tMin, tMax) {
                    let xx = x(tick.date)
                    var line = Path()
                    line.move(to: CGPoint(x: xx, y: plot.minY))
                    line.addLine(to: CGPoint(x: xx, y: plot.maxY))
                    ctx.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

                    let label = ctx.resolve(
                        Text(tick.label).font(.system(size: 9)).foregroundColor(.secondary))
                    // Keep edge labels inside the plot so they don't clip.
                    let anchor: UnitPoint
                    let at: CGPoint
                    if xx < plot.minX + 14 {
                        anchor = .topLeading
                        at = CGPoint(x: plot.minX, y: labelY)
                    } else if xx > plot.maxX - 14 {
                        anchor = .topTrailing
                        at = CGPoint(x: plot.maxX, y: labelY)
                    } else {
                        anchor = .top
                        at = CGPoint(x: xx, y: labelY)
                    }
                    ctx.draw(label, at: at, anchor: anchor)
                }
            }

            guard tMax > tMin else { return }

            // Each series: gap-aware runs, optional area fill, then the line.
            for s in series {
                for run in Self.runs(s.points) where run.count >= 1 {
                    let linePath = Path { p in
                        for (i, pt) in run.enumerated() {
                            let q = CGPoint(x: x(pt.date), y: y(pt.value))
                            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                        }
                    }
                    if s.filled, run.count >= 2 {
                        var fill = linePath
                        fill.addLine(to: CGPoint(x: x(run.last!.date), y: plot.maxY))
                        fill.addLine(to: CGPoint(x: x(run.first!.date), y: plot.maxY))
                        fill.closeSubpath()
                        ctx.fill(
                            fill,
                            with: .linearGradient(
                                Gradient(colors: [s.color.opacity(0.42), s.color.opacity(0.04)]),
                                startPoint: CGPoint(x: 0, y: plot.minY),
                                endPoint: CGPoint(x: 0, y: plot.maxY)))
                    }
                    if run.count >= 2 {
                        ctx.stroke(
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
                        ctx.fill(dot, with: .color(s.color))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func resolvedDomain() -> ClosedRange<Double> {
        if let yDomain { return yDomain }
        let peak = series.flatMap(\.points).map(\.value).max() ?? 1
        return 0...max(peak * 1.1, 1)
    }

    private func defaultTicks(_ domain: ClosedRange<Double>) -> [Double] {
        let n = 4
        return (0...n).map {
            domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double($0) / Double(n)
        }
    }

    private func timeBounds() -> (Double, Double) {
        let all = series.flatMap(\.points).map(\.date.timeIntervalSinceReferenceDate)
        return (all.min() ?? 0, all.max() ?? 0)
    }

    /// Wall-clock tick marks for the time axis: a "nice" step chosen for ~4–7
    /// labels across the visible span, aligned to local time so ticks land on
    /// round times (…:00, midnight) rather than UTC boundaries. Bounds are in
    /// `timeIntervalSinceReferenceDate` seconds (as `timeBounds`).
    ///
    /// The step's granularity — and hence whether labels read as clock times or
    /// dates — follows the *actual data span*, not the selected window: a 7-day
    /// window with only two days of history logged still spans two days, so it
    /// gets day-granular date labels rather than midnight-crossing times.
    private func xAxisTicks(_ tMin: Double, _ tMax: Double) -> [(date: Date, label: String)] {
        let span = tMax - tMin
        guard span > 0 else { return [] }

        // Past ~a day, step in whole days so labels read as dates; below that,
        // step in minutes/hours so they read as clock times.
        let steps: [Double] =
            span > 86_400
            ? [86_400, 172_800, 604_800]  // 1d, 2d, 1w
            : [60, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200]  // 1m … 12h
        let step = steps.first { span / $0 <= 7 } ?? steps.last!

        let fmt = step >= 86_400 ? Self.dayTickFormatter : Self.timeTickFormatter

        // timeIntervalSinceReferenceDate is UTC-anchored; shift by the local
        // offset so tick boundaries fall on local wall-clock times.
        let tz = Double(TimeZone.current.secondsFromGMT())
        var t = ceil((tMin + tz) / step) * step - tz
        var out: [(date: Date, label: String)] = []
        while t <= tMax + 0.5 {
            let date = Date(timeIntervalSinceReferenceDate: t)
            out.append((date, fmt.string(from: date)))
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

    /// Split a series into gap-free runs: a jump beyond the median spacing × 15
    /// (floored at 30 s) is treated as missing data and left blank, matching the
    /// previous Swift Charts behaviour.
    private static func runs(_ points: [TrendPoint]) -> [[TrendPoint]] {
        guard points.count > 1 else { return points.isEmpty ? [] : [points] }
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(points.count - 1)
        for i in 1..<points.count {
            deltas.append(points[i].date.timeIntervalSince(points[i - 1].date))
        }
        deltas.sort()
        let threshold = max(deltas[deltas.count / 2] * 15, 30)
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
}
