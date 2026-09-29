import CoreGraphics
import MacPerfMonitorCore

/// Builds the smooth curve every chart line and band edge is drawn with.
///
/// The shape is `MonotoneCubic`'s: it passes through every point and never
/// overshoots between two of them, so what looks like a peak is a point that
/// was measured. Fewer than three points fall back to straight segments.
enum MonotoneCurve {
    /// Append the curve through `points` (x increasing) to `path`. With
    /// `reversed` the same curve is traced from the last point back to the
    /// first, which is how a band closes along its lower edge. `move` starts
    /// a subpath at the first point; otherwise a straight line joins it to the
    /// path's current point.
    static func add(
        _ points: [CGPoint], to path: CGMutablePath, reversed: Bool = false, move: Bool = true
    ) {
        guard !points.isEmpty else { return }
        func begin(_ p: CGPoint) {
            if move { path.move(to: p) } else { path.addLine(to: p) }
        }
        if points.count < 3 {
            let sequence = reversed ? Array(points.reversed()) : points
            begin(sequence[0])
            for p in sequence.dropFirst() { path.addLine(to: p) }
            return
        }
        let m = MonotoneCubic.tangents(
            xs: points.map { Double($0.x) }, ys: points.map { Double($0.y) })
        if reversed {
            begin(points[points.count - 1])
            var i = points.count - 1
            while i > 0 {
                let p0 = points[i - 1]
                let p1 = points[i]
                let c = MonotoneCubic.controlPoints(
                    x0: Double(p0.x), y0: Double(p0.y), x1: Double(p1.x), y1: Double(p1.y),
                    m0: m[i - 1], m1: m[i])
                path.addCurve(
                    to: p0, control1: CGPoint(x: c.c2x, y: c.c2y),
                    control2: CGPoint(x: c.c1x, y: c.c1y))
                i -= 1
            }
        } else {
            begin(points[0])
            for i in 1..<points.count {
                let p0 = points[i - 1]
                let p1 = points[i]
                let c = MonotoneCubic.controlPoints(
                    x0: Double(p0.x), y0: Double(p0.y), x1: Double(p1.x), y1: Double(p1.y),
                    m0: m[i - 1], m1: m[i])
                path.addCurve(
                    to: p1, control1: CGPoint(x: c.c1x, y: c.c1y),
                    control2: CGPoint(x: c.c2x, y: c.c2y))
            }
        }
    }

    /// The curve through `points` as a fresh path.
    static func path(_ points: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        add(points, to: path)
        return path
    }
}
