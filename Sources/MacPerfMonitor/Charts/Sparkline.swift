import MacPerfMonitorCore
import SwiftUI

/// A tiny, lightweight line sparkline drawn in a `Canvas` rather than Swift
/// Charts, so it is cheap enough to render ten at a time in the menubar panel
/// and six at 4 Hz on the Dashboard.
///
/// Values are normalised to their own min/max unless a fixed `yDomain` is
/// given; a flat series draws a centre line. A series denser than the plot
/// (thousands of samples in a 150 pt card) is reduced to the per-pixel minimum
/// and maximum before it is drawn, so the path stays a few hundred segments
/// however long the app has been sampling.
///
/// Canvas rather than a `Path` shape on purpose: a `Shape` hands SwiftUI a
/// display-list item it hashes and diffs on every update, which for a long path
/// cost more than drawing it.
struct Sparkline: View {
    var values: [Double]
    /// Optional timestamps and fixed viewport for a real-time sparkline. When
    /// both are present, horizontal placement follows elapsed time instead of
    /// redistributing the values evenly on every update.
    var dates: [Date]? = nil
    var xDomain: ClosedRange<Date>? = nil
    /// Fixed vertical scale for a live trace. Nil preserves data-relative
    /// scaling for static callers.
    var yDomain: ClosedRange<Double>? = nil
    /// Fixed number of equally spaced live slots when timestamps are not
    /// available. Existing points move left by one slot whenever a value lands.
    var sampleCapacity: Int? = nil
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let points = normalisedPoints(in: size)
            guard points.count >= 2 else { return }
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            ctx.stroke(
                path, with: .style(.tint),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private func normalisedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let minValue = yDomain?.lowerBound ?? values.min() ?? 0
        let maxValue = yDomain?.upperBound ?? values.max() ?? 0
        let domain = minValue...maxValue

        func y(_ value: Double) -> CGFloat {
            // Flat series: draw through the vertical centre.
            let fraction = LiveChartGeometry.normalizedY(value, in: domain)
            return size.height - CGFloat(fraction) * size.height
        }

        if let dates, dates.count == values.count, let xDomain {
            // Timestamped live trace: reduce to the plot's pixel columns first.
            let columns = max(1, Int(size.width.rounded(.up)))
            let indices = values.indices
            let reduced = LiveSeriesDecimator.decimate(
                indices, buckets: columns, domain: xDomain,
                date: { dates[$0] }, value: { values[$0] })
            return reduced.map { point in
                CGPoint(
                    x: CGFloat(LiveChartGeometry.normalizedX(point.date, in: xDomain)) * size.width,
                    y: y(point.value))
            }
        }

        return values.enumerated().map { index, value in
            let x: CGFloat
            if let sampleCapacity, sampleCapacity > 0 {
                x =
                    CGFloat(
                        LiveChartGeometry.normalizedSlot(
                            index: index, count: values.count, capacity: sampleCapacity)
                    ) * size.width
            } else {
                x = CGFloat(index) * size.width / CGFloat(values.count - 1)
            }
            return CGPoint(x: x, y: y(value))
        }
    }
}
