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

        /// Whether this bucket holds more than the one sample a column can show
        /// directly, and so has a band worth drawing.
        public var isAggregate: Bool { count > 1 && maxValue > minValue }

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
    /// Cost is a binary search plus one pass over the samples inside the
    /// range, so a live edge of a few buckets costs a few dozen samples however
    /// long the window is.
    public static func buckets(
        times: ArraySlice<Double>, values: ArraySlice<Double>, width: Double,
        from first: Int, through last: Int, gapThreshold: Double, scale: Double = 1
    ) -> [Bucket] {
        guard width > 0, first <= last, !times.isEmpty, times.count == values.count else {
            return []
        }
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
        var out: [Bucket] = []
        var current: Bucket?
        var i = lo
        while i < times.endIndex {
            let t = times[i]
            if t >= rangeEnd { break }
            let v = values[i + valueOffset] * scale
            let b = index(of: t, width: width)
            if var bucket = current, bucket.index == b {
                if v < bucket.minValue {
                    bucket.minValue = v
                    bucket.minTime = t
                }
                if v > bucket.maxValue {
                    bucket.maxValue = v
                    bucket.maxTime = t
                }
                bucket.sum += v
                bucket.count += 1
                current = bucket
            } else {
                if let bucket = current { out.append(bucket) }
                let gap = previousTime.map { t - $0 > gapThreshold } ?? false
                current = Bucket(
                    index: b, minTime: t, minValue: v, maxTime: t, maxValue: v, gapBefore: gap)
            }
            previousTime = t
            i += 1
        }
        if let bucket = current { out.append(bucket) }
        return out
    }
}
