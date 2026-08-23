import MacPerfMonitorCore
import SwiftUI

/// Shared geometry, styling and drawing for the menu-bar dropdown header charts,
/// so CPU, memory, battery, power and network all read as one consistent family:
/// a thin line with a soft area fill on a marked (gridline + labelled) axis. The
/// fixed, labelled scale is what keeps a steady series readable — a flat line at
/// its true level instead of the solid block a baseline-filled bar chart became.
enum MenuChart {
    /// One height for every menu-bar header chart.
    static let height: CGFloat = 48
    /// The network chart is mirrored (download rises up / upload drops down from a
    /// centre line), so it gets roughly double the height — otherwise each direction
    /// only has ~22px and the trace is unreadable.
    static let networkHeight: CGFloat = 104
    /// Width reserved at the left for the axis tick labels.
    static let gutter: CGFloat = 30
    static let lineWidth: CGFloat = 1.5

    static let gridColor = Color.secondary.opacity(0.18)
    static let labelColor = Color.secondary
    static let labelFont = Font.system(size: 8, weight: .medium).monospacedDigit()

    /// Round a raw peak up to a "nice" 1–2–5×10ⁿ value, so an auto-scaled axis
    /// (power, network) only changes when the data crosses a magnitude rather than
    /// jittering its labels every tick.
    static func niceUpperBound(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let exponent = floor(log10(raw))
        let base = pow(10, exponent)
        let fraction = raw / base
        let step: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10
        return step * base
    }

    /// The plot rectangle inside a canvas of `size`: a left gutter for axis labels
    /// and a little vertical breathing room so the line never clips the edge.
    static func plotRect(in size: CGSize, reserveGutter: Bool = true) -> CGRect {
        let left = reserveGutter ? gutter : 2
        return CGRect(
            x: left, y: 2,
            width: max(1, size.width - left - 2), height: max(1, size.height - 4))
    }

    /// Stroke a polyline and fill the band between it and `baselineY` with a soft
    /// vertical gradient — the shared body of every menu-bar trend chart. The
    /// gradient runs from `gradientTop` (opaque end) to `gradientBottom` (faded).
    static func drawTrend(
        _ ctx: GraphicsContext, points: [CGPoint], baselineY: CGFloat,
        color: Color, gradientTop: CGFloat, gradientBottom: CGFloat
    ) {
        guard let first = points.first else { return }
        guard points.count >= 2 else {
            // A single sample still shows as a short flat tick at its level.
            var tick = Path()
            tick.move(to: CGPoint(x: first.x - 2, y: first.y))
            tick.addLine(to: CGPoint(x: first.x + 2, y: first.y))
            ctx.stroke(tick, with: .color(color), lineWidth: lineWidth)
            return
        }

        var area = Path()
        area.move(to: CGPoint(x: first.x, y: baselineY))
        for point in points { area.addLine(to: point) }
        area.addLine(to: CGPoint(x: points[points.count - 1].x, y: baselineY))
        area.closeSubpath()
        // A light fill gives the line body without becoming a solid block: it
        // fades to fully transparent, so even a steady high line reads as a line
        // with a soft glow under it rather than a filled rectangle.
        ctx.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.22), color.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: gradientTop),
                endPoint: CGPoint(x: 0, y: gradientBottom)))

        var line = Path()
        line.move(to: first)
        for point in points.dropFirst() { line.addLine(to: point) }
        ctx.stroke(
            line, with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

/// A compact line + soft-area trend for the menu-bar dropdown headers, drawn on a
/// fixed, labelled Y axis (gridlines + ticks in a left gutter) so a steady series
/// reads as a clear flat line at its true level rather than a solid block.
/// Canvas-drawn, cheap to redraw at 1 Hz. CPU/memory/battery pass a fixed 0–100
/// domain; power passes a rounded auto-peak via `MenuChart.niceUpperBound`.
struct MenuTrendChart: View {
    var values: [Double]
    /// Number of equally spaced samples in the live window. While the buffer is
    /// filling and after it wraps, each new value moves the trace one fixed slot.
    var sampleCapacity: Int? = nil
    var color: Color
    /// The fixed Y range the line is plotted against (baseline at `lowerBound`).
    var domain: ClosedRange<Double>
    /// Y values to draw a gridline + axis label at (within `domain`).
    var ticks: [Double]
    /// Formats a tick value for its axis label, e.g. `{ "\(Int($0))" }`.
    var label: (Double) -> String

    var body: some View {
        Canvas { ctx, size in
            let plot = MenuChart.plotRect(in: size)
            let lower = domain.lowerBound
            let span = max(domain.upperBound - lower, 0.0001)
            func y(_ value: Double) -> CGFloat {
                let fraction = min(1, max(0, (value - lower) / span))
                return plot.maxY - CGFloat(fraction) * plot.height
            }

            // Marked axis: a faint gridline at each tick, labelled in the gutter.
            for tick in ticks {
                let ty = y(tick)
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: ty))
                grid.addLine(to: CGPoint(x: plot.maxX, y: ty))
                ctx.stroke(grid, with: .color(MenuChart.gridColor), lineWidth: 0.5)
                ctx.draw(
                    Text(label(tick)).font(MenuChart.labelFont)
                        .foregroundColor(MenuChart.labelColor),
                    at: CGPoint(x: MenuChart.gutter - 4, y: min(max(ty, 5), size.height - 5)),
                    anchor: .trailing)
            }

            guard !values.isEmpty else { return }
            let points = values.enumerated().map { index, value in
                let x: CGFloat
                if let sampleCapacity, sampleCapacity > 0 {
                    let fraction = LiveChartGeometry.normalizedSlot(
                        index: index, count: values.count, capacity: sampleCapacity)
                    x = plot.minX + CGFloat(fraction) * plot.width
                } else {
                    let step = values.count >= 2 ? plot.width / CGFloat(values.count - 1) : 0
                    x = plot.minX + CGFloat(index) * step
                }
                return CGPoint(x: x, y: y(value))
            }
            MenuChart.drawTrend(
                ctx, points: points, baselineY: plot.maxY, color: color,
                gradientTop: plot.minY, gradientBottom: plot.maxY)
        }
        .accessibilityHidden(true)
    }
}
