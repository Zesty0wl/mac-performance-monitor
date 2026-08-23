import Foundation

/// Pixel-budget decimation for live line charts.
///
/// A chart plot is only a few hundred points wide, so drawing every one of an
/// hour's 14,400 samples builds and strokes a path the renderer then has to
/// collapse anyway. This keeps, for each of `buckets` equal slices of the time
/// domain, the lowest and highest sample in chronological order, the classic
/// oscilloscope reduction: every spike and trough survives at pixel resolution,
/// the output is at most `2 * buckets` points, and the work is a single pass
/// with no intermediate allocation beyond the result.
///
/// Buckets are anchored to the domain's left edge, so for a trailing window
/// they slide with it. Because each bucket reproduces the true extremes of the
/// samples inside it, a one-tick shift changes the output only where the data
/// itself changed at that resolution.
public enum LiveSeriesDecimator {
    public struct Point: Equatable, Sendable {
        public var date: Date
        public var value: Double

        public init(date: Date, value: Double) {
            self.date = date
            self.value = value
        }
    }

    /// Reduce a chronological series to at most `2 * buckets` points. Series
    /// that already fit pass through unchanged (converted to `Point`). Elements
    /// whose `value` is nil are skipped, which preserves the gaps a chart draws
    /// for missing readings; elements outside `domain` land in the edge buckets.
    ///
    /// Inlinable on purpose: callers in other modules get a specialised copy.
    /// Through the unspecialised generic entry point every element (a 200-byte
    /// sample) was copied out via witness tables, which cost more than the
    /// drawing it was meant to save.
    @inlinable
    public static func decimate<C: RandomAccessCollection>(
        _ elements: C,
        buckets: Int,
        domain: ClosedRange<Date>,
        date: (C.Element) -> Date,
        value: (C.Element) -> Double?
    ) -> [Point] {
        let buckets = max(1, buckets)
        if elements.count <= 2 * buckets {
            var out: [Point] = []
            out.reserveCapacity(elements.count)
            for element in elements {
                if let v = value(element) { out.append(Point(date: date(element), value: v)) }
            }
            return out
        }

        let start = domain.lowerBound.timeIntervalSinceReferenceDate
        let span = max(domain.upperBound.timeIntervalSinceReferenceDate - start, 1e-9)
        let width = span / Double(buckets)

        var out: [Point] = []
        out.reserveCapacity(2 * buckets + 2)

        var currentBucket = Int.min
        var minPoint: Point?
        var maxPoint: Point?
        var minIndex = 0
        var maxIndex = 0
        var order = 0

        func flush() {
            guard let lo = minPoint, let hi = maxPoint else { return }
            if minIndex == maxIndex {
                out.append(lo)
            } else if minIndex < maxIndex {
                out.append(lo)
                out.append(hi)
            } else {
                out.append(hi)
                out.append(lo)
            }
            minPoint = nil
            maxPoint = nil
        }

        for element in elements {
            guard let v = value(element) else { continue }
            let t = date(element)
            let raw = Int(((t.timeIntervalSinceReferenceDate - start) / width).rounded(.down))
            let bucket = min(max(raw, 0), buckets - 1)
            if bucket != currentBucket {
                flush()
                currentBucket = bucket
            }
            order += 1
            let point = Point(date: t, value: v)
            if let lo = minPoint, let hi = maxPoint {
                if v < lo.value {
                    minPoint = point
                    minIndex = order
                }
                if v > hi.value {
                    maxPoint = point
                    maxIndex = order
                }
            } else {
                minPoint = point
                maxPoint = point
                minIndex = order
                maxIndex = order
            }
        }
        flush()
        return out
    }
}
