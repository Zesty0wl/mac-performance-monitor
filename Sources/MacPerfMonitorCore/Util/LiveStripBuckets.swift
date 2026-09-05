import Foundation

/// Time-anchored bucket extremes for strip charts that scroll by moving
/// pixels instead of repainting them.
///
/// A chart that draws each column once and then slides it needs every older
/// column to be final: the pixels for a stretch of time must not depend on
/// when they were drawn. `LiveSeriesDecimator` anchors its buckets to the
/// window's moving left edge, so every tick shifts every boundary and, very
/// slightly, every column. This reduction anchors buckets to absolute time
/// instead: bucket `b` always covers `[b * width, (b + 1) * width)` seconds
/// since the reference date, so a completed bucket's extremes never change and
/// a chart can draw it once, then only repaint the bucket that is still
/// filling.
/// What counts as missing data on a time chart.
///
/// A gap has to mean "we were not looking", so the threshold belongs to the
/// cadence of the series, not to the width of the window. Deriving it from the
/// span, as this app used to, put the threshold at two and a half minutes on an
/// hour's view, so a Mac that was asleep or an app that was not running for a
/// minute drew a straight line across the hole as if it had been measured.
public enum ChartGap {
    /// Three times the coarsest spacing the series legitimately has, floored so
    /// a single late tick never breaks the line.
    public static func threshold(expectedSpacing: TimeInterval) -> TimeInterval {
        max(expectedSpacing * 3, 15)
    }

    /// The coarsest spacing a series legitimately has, read from the series
    /// itself: the 90th percentile of the intervals between consecutive
    /// samples. A series can mix tiers (hour rows topped up with minute rows
    /// and then raw ones), and the median would follow whichever is more
    /// numerous and turn the coarse rows into islands; a high percentile
    /// follows the coarse rows, and the few real holes above it are what the
    /// threshold exists to find. Zero with fewer than two samples.
    public static func expectedSpacing(times: ArraySlice<Double>) -> Double {
        guard times.count > 1 else { return 0 }
        var deltas: [Double] = []
        deltas.reserveCapacity(times.count - 1)
        var previous = times[times.startIndex]
        for t in times.dropFirst() {
            deltas.append(t - previous)
            previous = t
        }
        deltas.sort()
        return deltas[min(deltas.count - 1, (deltas.count * 9) / 10)]
    }
}

public enum LiveStripBuckets {
    /// The extremes of one non-empty bucket.
    public struct Bucket: Equatable, Sendable {
        public var index: Int
        public var minTime: Double
        public var minValue: Double
        public var maxTime: Double
        public var maxValue: Double
        /// Running total and count of the samples in this bucket, so the mean
        /// can be drawn as the line with the extremes as a band behind it. A
        /// chart that draws only the extremes reads as a forest of spikes once
        /// more than one sample lands in a column: see docs/chart-rules.md.
        public var sum: Double
        public var count: Int
        /// True when the first sample in this bucket follows a pause longer
        /// than the gap threshold, so a line must not connect it to the
        /// previous bucket.
        public var gapBefore: Bool

        public init(
            index: Int, minTime: Double, minValue: Double, maxTime: Double, maxValue: Double,
            gapBefore: Bool, sum: Double? = nil, count: Int = 1
        ) {
            self.index = index
            self.minTime = minTime
            self.minValue = minValue
            self.maxTime = maxTime
            self.maxValue = maxValue
            self.gapBefore = gapBefore
            self.sum = sum ?? minValue
            self.count = count
        }

        /// The bucket's mean, which is what a line through the buckets should
        /// follow. Falls back to the single value when there is only one.
        public var mean: Double { count > 0 ? sum / Double(count) : minValue }

        /// Whether this bucket has a spread worth drawing as a band: more than
        /// one distinct sample, or a stored peak above a stored mean.
        public var isAggregate: Bool { maxValue > minValue }

        /// The bucket's one or two points in chronological order: a single
        /// point when both extremes are the same sample, else the earlier
        /// extreme first, so a line through the buckets keeps time order.
        public var orderedPoints: [(time: Double, value: Double)] {
            if minTime == maxTime { return [(minTime, minValue)] }
            if minTime < maxTime { return [(minTime, minValue), (maxTime, maxValue)] }
            return [(maxTime, maxValue), (minTime, minValue)]
        }
    }

    /// The bucket index that holds time `t` for buckets of `width` seconds.
    @inlinable
    public static func index(of t: Double, width: Double) -> Int {
        Int((t / width).rounded(.down))
    }

    /// Extremes for every non-empty bucket in `first...last`, from chronological
    /// `times` (seconds since the reference date) and `values`. `scale`
    /// multiplies every value. The sample just before the range (if any) is
    /// consulted so the first bucket's `gapBefore` is right.
    ///
    /// `highs`, when given, holds each sample's own peak (a stored tier row is
    /// a mean with the bucket's maximum beside it); it can only raise a
    /// bucket's maximum, never move its mean, so the band reaches the real
    /// spike while the line still follows the average.
    ///
    /// Cost is a binary search plus one pass over the samples inside the
    /// range, so a live edge of a few buckets costs a few dozen samples however
    /// long the window is.
    public static func buckets(
        times: ArraySlice<Double>, values: ArraySlice<Double>, highs: ArraySlice<Double>? = nil,
        width: Double, from first: Int, through last: Int, gapThreshold: Double,
        scale: Double = 1
    ) -> [Bucket] {
        guard width > 0, first <= last, !times.isEmpty, times.count == values.count else {
            return []
        }
        let highs = highs.flatMap { $0.count == times.count ? $0 : nil }
        let rangeStart = Double(first) * width
        let rangeEnd = Double(last + 1) * width

        // First sample at or after the range start.
        var lo = times.startIndex
        var hi = times.endIndex
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if times[mid] < rangeStart { lo = mid + 1 } else { hi = mid }
        }
        var previousTime: Double? = lo > times.startIndex ? times[lo - 1] : nil

        // The two slices may start at different indices (a window column is
        // a trimmed slice, a derived column a fresh array), so index `values`
        // by offset from `times`.
        let valueOffset = values.startIndex - times.startIndex
        let highOffset = highs.map { $0.startIndex - times.startIndex } ?? 0
        var out: [Bucket] = []
        var current: Bucket?
        var i = lo
        while i < times.endIndex {
            let t = times[i]
            if t >= rangeEnd { break }
            let v = values[i + valueOffset] * scale
            let h = highs.map { max(v, $0[i + highOffset] * scale) } ?? v
            let b = index(of: t, width: width)
            if var bucket = current, bucket.index == b {
                if v < bucket.minValue {
                    bucket.minValue = v
                    bucket.minTime = t
                }
                if h > bucket.maxValue {
                    bucket.maxValue = h
                    bucket.maxTime = t
                }
                bucket.sum += v
                bucket.count += 1
                current = bucket
            } else {
                if let bucket = current { out.append(bucket) }
                let gap = previousTime.map { t - $0 > gapThreshold } ?? false
                current = Bucket(
                    index: b, minTime: t, minValue: v, maxTime: t, maxValue: h, gapBefore: gap,
                    sum: v)
            }
            previousTime = t
            i += 1
        }
        if let bucket = current { out.append(bucket) }
        return out
    }
}
