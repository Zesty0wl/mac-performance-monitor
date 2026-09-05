import Foundation

/// Tangents for a monotone cubic Hermite spline: the curve beszel, and d3's
/// `curveMonotoneX` beneath it, draw through chart points.
///
/// A polyline through 120 reduced points reads as jagged. A Catmull-Rom or
/// natural cubic spline reads as smooth but overshoots, inventing a bump
/// between two real points. The monotone construction (Fritsch and Carlson's
/// tangent limits, with d3's three-point rule at the ends) is the one that is
/// both: between any two points the curve stays inside their vertical range,
/// so on a monitoring chart every peak is one that was measured.
public enum MonotoneCubic {
    /// One tangent (dy/dx) per point. `xs` should be increasing; a repeated x
    /// gets a flat tangent rather than an infinite one. Fewer than two points
    /// yield zeros, two yield the chord slope at both ends.
    public static func tangents(xs: [Double], ys: [Double]) -> [Double] {
        let n = min(xs.count, ys.count)
        guard n > 1 else { return Array(repeating: 0, count: n) }
        if n == 2 {
            let h = xs[1] - xs[0]
            let s = h > 0 ? (ys[1] - ys[0]) / h : 0
            return [s, s]
        }
        var m = Array(repeating: 0.0, count: n)
        for i in 1..<(n - 1) {
            m[i] = slope3(
                xs[i - 1], ys[i - 1], xs[i], ys[i], xs[i + 1], ys[i + 1])
        }
        m[0] = slope2(xs[0], ys[0], xs[1], ys[1], m[1])
        m[n - 1] = slope2(xs[n - 2], ys[n - 2], xs[n - 1], ys[n - 1], m[n - 2])
        return m
    }

    /// The cubic Bezier control points that realise the Hermite segment from
    /// (x0, y0) with tangent m0 to (x1, y1) with tangent m1.
    public static func controlPoints(
        x0: Double, y0: Double, x1: Double, y1: Double, m0: Double, m1: Double
    ) -> (c1x: Double, c1y: Double, c2x: Double, c2y: Double) {
        let dx = (x1 - x0) / 3
        return (x0 + dx, y0 + dx * m0, x1 - dx, y1 - dx * m1)
    }

    /// An interior tangent: zero at a local extremum or a flat, otherwise the
    /// smaller of twice each secant slope and the weighted mean of the two,
    /// which keeps the segment either side monotone.
    static func slope3(
        _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double
    ) -> Double {
        let h0 = x1 - x0
        let h1 = x2 - x1
        guard h0 > 0, h1 > 0 else { return 0 }
        let s0 = (y1 - y0) / h0
        let s1 = (y2 - y1) / h1
        guard s0 != 0, s1 != 0, (s0 < 0) == (s1 < 0) else { return 0 }
        let p = (s0 * h1 + s1 * h0) / (h0 + h1)
        let magnitude = 2 * min(abs(s0), abs(s1), 0.5 * abs(p))
        return s0 < 0 ? -magnitude : magnitude
    }

    /// An end tangent, from the end segment's chord and the tangent already
    /// fixed at its other end.
    static func slope2(
        _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ t: Double
    ) -> Double {
        let h = x1 - x0
        return h > 0 ? (3 * (y1 - y0) / h - t) / 2 : t
    }
}
