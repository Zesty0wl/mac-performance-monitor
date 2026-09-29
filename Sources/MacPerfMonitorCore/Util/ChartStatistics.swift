/// Geometry-independent statistics for time series. Intervals are anchored to
/// zero in the supplied time coordinate, not to the visible range or its pixels.
/// Use UTC epoch seconds (or consistent reference-date seconds) throughout.
public enum ChartStatistics {
    /// One nonempty interval fragment. A missing reading or a time gap splits
    /// the run even inside an interval, so several buckets can share an index.
    /// These are observed extrema and a weighted mean, never percentiles.
    public struct Bucket: Equatable, Sendable {
        public let index: Int
        /// Nominal, half-open interval [start, end), independent of observations.
        public let start: Double
        public let end: Double
        public let firstTime: Double
        /// Last actual sample time for raw rows, or covered-through time
        /// (source timestamp + duration) for aggregates. A subsequent explicit
        /// missing reading caps this coverage at its timestamp. This can exceed
        /// `end` if the caller supplied a source coarser than the chart interval.
        public fileprivate(set) var lastTime: Double
        public var mean: Double { weightedSum / weight }
        /// Nil if any contributing row has an unknown minimum or maximum,
        /// respectively. A stored mean is not a substitute for a lost extremum.
        public fileprivate(set) var minimum: Double?
        public fileprivate(set) var maximum: Double?
        /// Sum of known integral sample weights. Nil for unknown weights,
        /// fractional weights, or a count that cannot be represented as an Int.
        public fileprivate(set) var sampleCount: Int?
        public let gapBefore: Bool
        /// Largest contributing source duration, not the chart interval width.
        /// Zero denotes raw point samples. Durations never act as weights.
        public fileprivate(set) var sourceResolution: Double
        public fileprivate(set) var weight: Double
        public fileprivate(set) var weightedSum: Double
        /// True if a legacy NaN weight was replaced by one. The mean must then
        /// be labelled approximate by the caller, and sampleCount is unknown.
        public fileprivate(set) var hasUnknownWeight: Bool

        // Hard limits supplement the tolerance around the measured portion.
        // A known missing timestamp must not return a stale value at any tolerance.
        fileprivate var selectionLowerBound: Double
        fileprivate var selectionUpperBound: Double
    }

    public struct Summary: Equatable, Sendable {
        public let mean: Double
        public let minimum: Double?
        public let maximum: Double?
        public let sampleCount: Int?
        public let hasUnknownWeight: Bool
    }

    /// A fixed, nice interval targeting at most 120 full intervals per span.
    /// Partial edge intervals and gap-separated fragments can add buckets.
    /// The result rounds up to a multiple of the source resolution `minimum`.
    /// Invalid arguments or an unrepresentable interval return zero.
    public static func interval(span: Double, minimum: Double = 0) -> Double {
        guard span.isFinite, span > 0, minimum.isFinite, minimum >= 0 else { return 0 }
        let target = span / 120
        let steps: [Double] = [
            1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800,
            3600, 7200, 14400, 21600, 43200, 86400,
        ]
        var width = steps.first(where: { $0 >= target }) ?? 86400
        while width < target {
            width *= 2
            guard width.isFinite else { return 0 }
        }
        if minimum > 0 {
            let multiple = max(1, (width / minimum).rounded(.up))
            let aligned = multiple * minimum
            // A floating-point product can round just below the required width.
            width = aligned < width ? aligned + minimum : aligned
        }
        return width.isFinite && width > 0 ? width : 0
    }

    /// Reduces chronological, finite timestamps within the inclusive `range`.
    /// All columns must have equal counts, but their slice indices may differ.
    /// Times must be nondecreasing. Supplied rows must not double-count samples
    /// through overlapping storage tiers; this reducer does not deduplicate.
    ///
    /// Missing lows/highs columns mean raw extrema equal to each value. A
    /// nonfinite entry in a supplied extrema column makes that bound unknown.
    /// Nil weights mean one per raw sample. NaN weights use an explicitly
    /// approximate weight of one. Finite zero-weight values are ignored; a
    /// nonfinite value always breaks the run, including when its weight is zero.
    ///
    /// Durations are source coverage lengths, zero for raw rows. Gaps compare
    /// each row's timestamp with the PREVIOUS source row's coverage end using
    /// `gapThreshold`, never the largest duration seen elsewhere in the series.
    /// Source aggregates are selected by their start timestamps and included
    /// whole, even if their support extends beyond the range or chart interval.
    /// They are never split, prorated, or fabricated into finer observations.
    /// Callers should choose an interval at least as large as every source
    /// duration and aligned to the source grid.
    ///
    /// Binary searches bound the reduction. Nearby boundary rows are consulted
    /// for gap/selection metadata only, never statistics. Ignored zero-weight
    /// rows may need to be traversed to find that context. Complete intervals
    /// therefore agree between full and partial redraws of the same input.
    /// Invalid scalar arguments, column lengths, inspected timestamps/metadata,
    /// or arithmetic overflow return an empty result rather than invented data.
    ///
    /// `end` is nominal, not a future observation. A renderer placing means at
    /// interval ends should cap an open interval's position at `lastTime`.
    public static func buckets(
        times: ArraySlice<Double>, values: ArraySlice<Double>,
        lows: ArraySlice<Double>? = nil, highs: ArraySlice<Double>? = nil,
        weights: ArraySlice<Double>? = nil, durations: ArraySlice<Double>? = nil,
        width: Double, range: ClosedRange<Double>, gapThreshold: Double,
        scale: Double = 1
    ) -> [Bucket] {
        guard width.isFinite, width > 0, gapThreshold.isFinite, gapThreshold >= 0,
            scale.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite,
            range.lowerBound <= range.upperBound, !times.isEmpty,
            times.count == values.count,
            [lows, highs, weights, durations].allSatisfy({
                ($0?.count ?? times.count) == times.count
            })
        else { return [] }

        let input = Input(
            times: times, values: values, lows: lows, highs: highs,
            weights: weights, durations: durations)
        do {
            let first = try input.bound(range.lowerBound, upper: false)
            let limit = try input.bound(range.upperBound, upper: true)
            guard first < limit else { return [] }
            var previous = try input.neighbor(from: first - 1, step: -1)
            var reduction = Reduction()
            for i in first..<limit {
                guard let row = try input.row(at: i) else { continue }
                let edge = try Edge(previous: previous, next: row, threshold: gapThreshold)
                reduction.restrictPrevious(edge)
                if edge.breaksRun { reduction.flush() }
                if row.value.isFinite {
                    try reduction.append(row, edge: edge, width: width, scale: scale)
                }
                previous = row
            }
            if let next = try input.neighbor(from: limit, step: 1) {
                let edge = try Edge(previous: previous, next: next, threshold: gapThreshold)
                reduction.restrictPrevious(edge)
            }
            reduction.flush()
            return reduction.output
        } catch {
            return []
        }
    }

    /// Combines sufficient statistics, not an unweighted mean of bucket means.
    /// Unknown extrema/counts propagate independently. No samples are invented
    /// for empty intervals or gaps. Returns nil for no buckets or overflow.
    public static func summary(_ buckets: [Bucket]) -> Summary? {
        guard let first = buckets.first else { return nil }
        var weight = first.weight
        var sum = first.weightedSum
        var minimum = first.minimum
        var maximum = first.maximum
        var count = first.sampleCount
        var unknown = first.hasUnknownWeight
        for bucket in buckets.dropFirst() {
            weight += bucket.weight
            sum += bucket.weightedSum
            minimum = combined(minimum, bucket.minimum, using: min)
            maximum = combined(maximum, bucket.maximum, using: max)
            count = adding(count, bucket.sampleCount)
            unknown = unknown || bucket.hasUnknownWeight
        }
        guard weight.isFinite, weight > 0, sum.isFinite, (sum / weight).isFinite else {
            return nil
        }
        return Summary(
            mean: sum / weight, minimum: minimum, maximum: maximum,
            sampleCount: unknown ? nil : count, hasUnknownWeight: unknown)
    }

    /// Selects only within the nominal interval containing `time`, then within
    /// `tolerance` seconds of that fragment's measured portion. It never reaches
    /// into a neighboring empty interval, crosses a large time gap, or crosses
    /// a known missing boundary. At an exact interval end, only the next
    /// interval is eligible. Ties prefer the later fragment.
    public static func selection(
        at time: Double, in buckets: [Bucket], tolerance: Double
    ) -> Bucket? {
        guard time.isFinite, tolerance.isFinite, tolerance >= 0 else { return nil }
        var lo = 0
        var hi = buckets.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if buckets[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, time < buckets[lo - 1].end else { return nil }
        let index = buckets[lo - 1].index
        var selected: Bucket?
        var nearest = Double.infinity
        var i = lo - 1
        while i >= 0, buckets[i].index == index {
            let bucket = buckets[i]
            if time >= bucket.selectionLowerBound, time <= bucket.selectionUpperBound {
                let distance = max(bucket.firstTime - time, time - bucket.lastTime, 0)
                if distance <= tolerance, distance < nearest {
                    selected = bucket
                    nearest = distance
                }
            }
            i -= 1
        }
        return selected
    }

    private enum InvalidInput: Error { case invalid }

    private struct Row {
        let time: Double
        let value: Double
        let minimum: Double?
        let maximum: Double?
        let weight: Double
        let count: Int?
        let unknown: Bool
        let duration: Double
        let coverageEnd: Double
    }

    private struct Input {
        let times: ArraySlice<Double>
        let values: ArraySlice<Double>
        let lows: ArraySlice<Double>?
        let highs: ArraySlice<Double>?
        let weights: ArraySlice<Double>?
        let durations: ArraySlice<Double>?

        func bound(_ time: Double, upper: Bool) throws -> Int {
            var lo = 0
            var hi = times.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                let t = times[times.startIndex + mid]
                guard t.isFinite else { throw InvalidInput.invalid }
                if t < time || (upper && t == time) { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        func row(at offset: Int) throws -> Row? {
            let time = times[times.startIndex + offset]
            let value = values[values.startIndex + offset]
            guard time.isFinite else { throw InvalidInput.invalid }
            let rawWeight = weights.map { $0[$0.startIndex + offset] } ?? 1
            if value.isFinite, rawWeight == 0 { return nil }
            let duration = durations.map { $0[$0.startIndex + offset] } ?? 0
            let coverageEnd = time + duration
            guard duration.isFinite, duration >= 0, coverageEnd.isFinite else {
                throw InvalidInput.invalid
            }
            // Missing values break runs regardless of their count or extrema.
            if !value.isFinite {
                return Row(
                    time: time, value: value, minimum: nil, maximum: nil, weight: 0,
                    count: nil, unknown: false, duration: duration, coverageEnd: coverageEnd)
            }
            guard rawWeight.isNaN || (rawWeight.isFinite && rawWeight > 0) else {
                throw InvalidInput.invalid
            }
            let low = lows.map { $0[$0.startIndex + offset] } ?? value
            let high = highs.map { $0[$0.startIndex + offset] } ?? value
            return Row(
                time: time, value: value,
                minimum: low.isFinite ? low : nil, maximum: high.isFinite ? high : nil,
                weight: rawWeight.isNaN ? 1 : rawWeight,
                count: rawWeight.isNaN ? nil : Int(exactly: rawWeight),
                unknown: rawWeight.isNaN, duration: duration, coverageEnd: coverageEnd)
        }

        func neighbor(from offset: Int, step: Int) throws -> Row? {
            var i = offset
            while i >= 0, i < times.count {
                if let row = try row(at: i) { return row }
                i += step
            }
            return nil
        }
    }

    private struct Edge {
        var breaksRun = false
        var lower = -Double.infinity
        var upper = Double.infinity
        var coverageEnd = Double.infinity

        init(previous: Row?, next: Row, threshold: Double) throws {
            if let previous {
                guard previous.time <= next.time else { throw InvalidInput.invalid }
                if next.time - previous.coverageEnd > threshold {
                    breaksRun = true
                    lower = next.time
                    upper = previous.coverageEnd
                    coverageEnd = previous.coverageEnd
                }
                if !previous.value.isFinite {
                    breaksRun = true
                    // Aggregate missingness covers its source duration. A later
                    // actual reading can supersede that coverage if they overlap.
                    let missingEnd = max(previous.time.nextUp, previous.coverageEnd)
                    lower = max(lower, min(next.time, missingEnd))
                }
            }
            if !next.value.isFinite {
                breaksRun = true
                upper = min(upper, next.time.nextDown)
                coverageEnd = min(coverageEnd, next.time)
            }
        }
    }

    private struct Reduction {
        var output: [Bucket] = []
        var current: Bucket?

        mutating func flush() {
            if let current { output.append(current) }
            current = nil
        }

        mutating func restrictPrevious(_ edge: Edge) {
            if var bucket = current {
                bucket.lastTime = min(bucket.lastTime, edge.coverageEnd)
                bucket.selectionUpperBound = min(bucket.selectionUpperBound, edge.upper)
                current = bucket
            } else if let i = output.indices.last {
                output[i].lastTime = min(output[i].lastTime, edge.coverageEnd)
                output[i].selectionUpperBound = min(output[i].selectionUpperBound, edge.upper)
            }
        }

        mutating func append(_ row: Row, edge: Edge, width: Double, scale: Double) throws {
            let quotient = (row.time / width).rounded(.down)
            guard quotient.isFinite, let index = Int(exactly: quotient) else {
                throw InvalidInput.invalid
            }
            let (nextIndex, overflow) = index.addingReportingOverflow(1)
            guard !overflow else { throw InvalidInput.invalid }
            let start = Double(index) * width
            let end = Double(nextIndex) * width
            let value = row.value * scale
            let sum = value * row.weight
            guard start.isFinite, end.isFinite, end > start, value.isFinite, sum.isFinite else {
                throw InvalidInput.invalid
            }
            let minimum = try ChartStatistics.scaled(
                scale < 0 ? row.maximum : row.minimum, by: scale)
            let maximum = try ChartStatistics.scaled(
                scale < 0 ? row.minimum : row.maximum, by: scale)
            if current?.index != index { flush() }
            if var bucket = current {
                bucket.weight += row.weight
                bucket.weightedSum += sum
                guard bucket.weight.isFinite, bucket.weightedSum.isFinite, bucket.mean.isFinite
                else {
                    throw InvalidInput.invalid
                }
                bucket.lastTime = max(bucket.lastTime, row.coverageEnd)
                bucket.minimum = ChartStatistics.combined(bucket.minimum, minimum, using: min)
                bucket.maximum = ChartStatistics.combined(bucket.maximum, maximum, using: max)
                bucket.sampleCount = ChartStatistics.adding(bucket.sampleCount, row.count)
                bucket.hasUnknownWeight = bucket.hasUnknownWeight || row.unknown
                bucket.sourceResolution = max(bucket.sourceResolution, row.duration)
                current = bucket
            } else {
                guard (sum / row.weight).isFinite else { throw InvalidInput.invalid }
                current = Bucket(
                    index: index, start: start, end: end, firstTime: row.time,
                    lastTime: row.coverageEnd, minimum: minimum, maximum: maximum,
                    sampleCount: row.count, gapBefore: edge.breaksRun,
                    sourceResolution: row.duration, weight: row.weight, weightedSum: sum,
                    hasUnknownWeight: row.unknown,
                    selectionLowerBound: max(start, edge.lower), selectionUpperBound: end.nextDown)
            }
        }
    }

    private static func scaled(_ value: Double?, by scale: Double) throws -> Double? {
        guard let value else { return nil }
        let result = value * scale
        guard result.isFinite else { throw InvalidInput.invalid }
        return result
    }

    private static func combined(
        _ a: Double?, _ b: Double?, using operation: (Double, Double) -> Double
    ) -> Double? {
        guard let a, let b else { return nil }
        return operation(a, b)
    }

    private static func adding(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : sum
    }
}
