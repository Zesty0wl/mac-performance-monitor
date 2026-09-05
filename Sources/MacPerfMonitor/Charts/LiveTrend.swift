import Foundation
import MacPerfMonitorCore

/// One metric over a window, as contiguous timestamp and value doubles: the
/// form the live charts draw from. Built zero-copy from a
/// `SystemHistoryWindow` column, or materialised from a small point array for
/// the static pages (the Disk, Energy and Network tabs hold a few hundred
/// points, so that copy is negligible there).
struct LiveColumn {
    /// `timeIntervalSinceReferenceDate` seconds, oldest first.
    var times: ArraySlice<Double>
    var values: ArraySlice<Double>
    /// Each sample's own peak, where the samples are stored means with the
    /// bucket maximum beside them (`SystemHistoryWindow.Column` peak columns).
    /// The band rises to these; the line ignores them.
    var highs: ArraySlice<Double>?

    init(times: ArraySlice<Double>, values: ArraySlice<Double>, highs: ArraySlice<Double>? = nil) {
        self.times = times
        self.values = values
        self.highs = highs
    }

    init(
        _ window: SystemHistoryWindow, _ column: SystemHistoryWindow.Column,
        peak: SystemHistoryWindow.Column? = nil
    ) {
        times = window.timestamps
        values = window.values(column)
        highs = peak.map { window.values($0) }
    }

    init(_ points: [SystemHistoryPoint], value: (SystemHistoryPoint) -> Double) {
        var t: [Double] = []
        var v: [Double] = []
        t.reserveCapacity(points.count)
        v.reserveCapacity(points.count)
        for point in points {
            t.append(point.date.timeIntervalSinceReferenceDate)
            v.append(value(point))
        }
        times = t[...]
        values = v[...]
    }

    var count: Int { times.count }
    var isEmpty: Bool { times.isEmpty }
    var lastValue: Double? { values.last }
    var lastDate: Date? { times.last.map { Date(timeIntervalSinceReferenceDate: $0) } }

    /// The smallest and largest value, without allocating.
    var range: (min: Double, max: Double)? {
        guard var lo = values.first else { return nil }
        var hi = lo
        for v in values {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        return (lo, hi)
    }
}

/// Builds the point lists the Canvas timelines draw from a live window.
///
/// The Dashboard's raw windows hold every sample the sampler produced, which at
/// 4 Hz is 14,400 points for an hour. A plot is a few hundred points wide, so
/// the series is reduced to at most `2 * buckets` points (each bucket's minimum
/// and maximum, in time order) before it ever reaches SwiftUI. That bounds the
/// per-tick work of every timeline to a constant no matter how long the app
/// has been running, keeps spikes intact, and never allocates a point per
/// sample per chart per tick.
enum LiveTrend {
    /// Time slices per series. At the Dashboard's plot widths (600 to 1,000 pt)
    /// this is about one bucket per point, so nothing visible is lost.
    static let buckets = 720

    /// Decimated points for one metric. `xDomain` anchors the buckets; without
    /// one (a static chart) the data's own extent is used.
    static func points(
        _ column: LiveColumn, xDomain: ClosedRange<Date>?, buckets: Int = LiveTrend.buckets
    ) -> [TrendPoint] {
        guard let first = column.times.first, let last = column.times.last else { return [] }
        let domain: ClosedRange<Double>
        if let xDomain {
            let lo = xDomain.lowerBound.timeIntervalSinceReferenceDate
            let hi = xDomain.upperBound.timeIntervalSinceReferenceDate
            domain = lo...hi
        } else {
            domain = min(first, last)...max(first, last)
        }
        return LiveSeriesDecimator.decimate(
            times: column.times, values: column.values, buckets: buckets, domain: domain
        ).map { TrendPoint(date: $0.date, value: $0.value) }
    }
}
