import XCTest

@testable import MacPerfMonitorCore

/// The chart curve must pass through every point and never overshoot between
/// two of them: a bump on a monitoring chart has to be something measured.
final class MonotoneCubicTests: XCTestCase {
    /// The Hermite segment, evaluated through its Bezier form at `t`.
    private func bezier(
        _ p0: Double, _ c1: Double, _ c2: Double, _ p1: Double, _ t: Double
    )
        -> Double
    {
        let u = 1 - t
        return u * u * u * p0 + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * p1
    }

    /// Every segment of the curve through (xs, ys), sampled finely.
    private func samples(xs: [Double], ys: [Double]) -> [[Double]] {
        let m = MonotoneCubic.tangents(xs: xs, ys: ys)
        return (0..<(xs.count - 1)).map { i in
            let c = MonotoneCubic.controlPoints(
                x0: xs[i], y0: ys[i], x1: xs[i + 1], y1: ys[i + 1], m0: m[i], m1: m[i + 1])
            return (0...40).map { k in
                bezier(ys[i], c.c1y, c.c2y, ys[i + 1], Double(k) / 40)
            }
        }
    }

    func testMonotoneDataGivesAMonotoneCurve() {
        let xs = (0..<8).map(Double.init)
        let ys: [Double] = [0, 1, 1.2, 5, 5.1, 9, 9.5, 10]
        let m = MonotoneCubic.tangents(xs: xs, ys: ys)
        XCTAssertEqual(m.count, 8)
        XCTAssertTrue(m.allSatisfy { $0 >= 0 }, "rising data never gets a falling tangent")
        for segment in samples(xs: xs, ys: ys) {
            for (a, b) in zip(segment, segment.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b, a - 1e-9)
            }
        }
    }

    func testNoOvershootAroundASpike() {
        let xs = (0..<5).map(Double.init)
        let ys: [Double] = [0, 0, 10, 0, 0]
        let m = MonotoneCubic.tangents(xs: xs, ys: ys)
        XCTAssertEqual(m[2], 0, "a local maximum is flat, so the curve peaks exactly there")
        for (i, segment) in samples(xs: xs, ys: ys).enumerated() {
            let lo = min(ys[i], ys[i + 1])
            let hi = max(ys[i], ys[i + 1])
            for y in segment {
                XCTAssertGreaterThanOrEqual(y, lo - 1e-9)
                XCTAssertLessThanOrEqual(y, hi + 1e-9)
            }
        }
    }

    func testTwoPointsUseTheChordSlope() {
        XCTAssertEqual(MonotoneCubic.tangents(xs: [0, 2], ys: [0, 6]), [3, 3])
    }

    func testDegenerateInputsStayFinite() {
        XCTAssertEqual(MonotoneCubic.tangents(xs: [], ys: []), [])
        XCTAssertEqual(MonotoneCubic.tangents(xs: [1], ys: [4]), [0])
        let repeated = MonotoneCubic.tangents(xs: [0, 1, 1, 2], ys: [0, 1, 5, 6])
        XCTAssertTrue(repeated.allSatisfy(\.isFinite), "a repeated x is flat, not infinite")
    }

    func testControlPointsSitAThirdOfTheWayAlong() {
        let c = MonotoneCubic.controlPoints(x0: 0, y0: 0, x1: 3, y1: 3, m0: 1, m1: 1)
        XCTAssertEqual(c.c1x, 1)
        XCTAssertEqual(c.c1y, 1)
        XCTAssertEqual(c.c2x, 2)
        XCTAssertEqual(c.c2y, 2)
    }
}
