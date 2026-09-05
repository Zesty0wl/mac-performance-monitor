import Foundation

/// A trailing window of system samples stored column by column, for the live
/// Dashboard timelines.
///
/// Every chart and card on a live page reads one or two metrics from every
/// sample in the window, several times a tick. Held as an array of
/// `SystemHistoryPoint` that meant copying a 200-byte struct (with resilient
/// `Date` and optional fields, so not a plain memcpy) per metric per sample per
/// tick, which profiled as the dominant cost once the window held an hour of
/// 4 Hz samples. Here each metric is a contiguous `[Double]` and timestamps are
/// `timeIntervalSinceReferenceDate` doubles, so a pass over a column is a tight
/// loop the decimator can run in well under a millisecond for 14,400 samples.
///
/// Appends are amortised O(1): trimming advances a head index shared by all
/// columns and the arrays are compacted once the dead prefix is large. One
/// sample older than the window is retained so a line enters from the left
/// edge rather than starting a fraction inside the plot.
public struct SystemHistoryWindow {
    /// The metrics kept per sample.
    public enum Column: Int, CaseIterable, Sendable {
        case pressurePercent
        case cpuLoad
        case appMemory
        case wired
        case compressed
        case cachedFiles
        case swapUsed
        case networkInBytesPerSec
        case networkOutBytesPerSec
        case diskReadBytesPerSec
        case diskWriteBytesPerSec
        case gpuUtilization
        case gpuPowerWatts
        case anePowerWatts
        /// Hottest CPU die sensor. Like the GPU columns, unsampled ticks store
        /// 0 (the columnar store is non-optional); consumers with a floored
        /// y-domain should treat near-zero as "not sampled".
        case cpuDieC
        /// The bucket peaks behind the metrics above, for points read from
        /// the stored minute and hour tiers (`SystemHistoryPoint.peaks`). A raw
        /// sample's peak is the sample itself, so for live data these columns
        /// equal their metric and cost nothing to read alongside it. A chart
        /// pairs a metric with its peak column and the band rises to the peak
        /// where the line is a mean.
        case pressurePercentPeak
        case cpuLoadPeak
        case networkInPeak
        case networkOutPeak
        case diskReadPeak
        case diskWritePeak
        case gpuUtilizationPeak
        /// The kernel's load averages, so the Processes header's load card
        /// reads history like its neighbours instead of a ring that empties
        /// whenever the tab is remounted.
        case loadAverage1
        case loadAverage5
        case loadAverage15
        case loadAverage1Peak
    }

    /// Timestamps as `timeIntervalSinceReferenceDate`, oldest first.
    private var times: [Double] = []
    private var columns: [[Double]] = Array(repeating: [], count: Column.allCases.count)
    private var head = 0
    public private(set) var span: TimeInterval
    /// The newest sample in full, for the live read-outs.
    public private(set) var latest: SystemHistoryPoint?

    private static var compactionThreshold: Int { 1024 }

    public init(span: TimeInterval) {
        precondition(span > 0, "SystemHistoryWindow span must be positive")
        self.span = span
    }

    public var count: Int { times.count - head }
    public var isEmpty: Bool { count == 0 }

    /// Timestamps of the retained samples as reference-date seconds. Shares
    /// storage with the window.
    public var timestamps: ArraySlice<Double> { times[head...] }

    /// One metric across the retained samples. Shares storage with the window.
    public func values(_ column: Column) -> ArraySlice<Double> {
        columns[column.rawValue][head...]
    }

    /// The oldest retained sample's date, if any.
    public var oldestDate: Date? {
        head < times.count ? Date(timeIntervalSinceReferenceDate: times[head]) : nil
    }

    /// The fixed trailing time domain ending at the newest sample.
    public var xDomain: ClosedRange<Date>? {
        LiveChartGeometry.trailingDomain(latest: latest?.date, span: span)
    }

    /// Replace the window with chronological samples, optionally at a new span.
    public mutating func replace(_ points: [SystemHistoryPoint], span newSpan: TimeInterval? = nil)
    {
        if let newSpan {
            precondition(newSpan > 0, "SystemHistoryWindow span must be positive")
            span = newSpan
        }
        times.removeAll(keepingCapacity: true)
        for i in columns.indices { columns[i].removeAll(keepingCapacity: true) }
        head = 0
        latest = nil
        times.reserveCapacity(points.count)
        for i in columns.indices { columns[i].reserveCapacity(points.count) }
        for point in points { push(point) }
        trim()
    }

    /// Append a sample newer than the latest one. Returns false, leaving the
    /// window untouched, when it is not.
    /// Samples are kept as they arrive, at full resolution.
    ///
    /// It is tempting to fold them into buckets here, since an hour at a one
    /// second cadence is 3,600 samples for a plot a fraction that wide. Do not:
    /// the charts draw a mean line inside a band of the real minimum and
    /// maximum, and averaging on the way in would throw away the extremes that
    /// band is made of. The reduction belongs at draw time, where both are
    /// still available. See docs/chart-rules.md.
    @discardableResult
    public mutating func append(_ point: SystemHistoryPoint) -> Bool {
        if let latest, point.date <= latest.date { return false }
        push(point)
        trim()
        return true
    }

    /// The window as points, oldest first. Allocates; for occasional use only
    /// (the charts read the columns directly).
    public func points() -> [SystemHistoryPoint] {
        var out: [SystemHistoryPoint] = []
        out.reserveCapacity(count)
        for i in head..<times.count {
            out.append(
                SystemHistoryPoint(
                    date: Date(timeIntervalSinceReferenceDate: times[i]),
                    pressurePercent: columns[Column.pressurePercent.rawValue][i],
                    appMemory: UInt64(columns[Column.appMemory.rawValue][i]),
                    wired: UInt64(columns[Column.wired.rawValue][i]),
                    compressed: UInt64(columns[Column.compressed.rawValue][i]),
                    cachedFiles: UInt64(columns[Column.cachedFiles.rawValue][i]),
                    swapUsed: UInt64(columns[Column.swapUsed.rawValue][i]),
                    cpuLoad: columns[Column.cpuLoad.rawValue][i],
                    loadAverage1: columns[Column.loadAverage1.rawValue][i],
                    loadAverage5: columns[Column.loadAverage5.rawValue][i],
                    loadAverage15: columns[Column.loadAverage15.rawValue][i],
                    networkInBytesPerSec: columns[Column.networkInBytesPerSec.rawValue][i],
                    networkOutBytesPerSec: columns[Column.networkOutBytesPerSec.rawValue][i],
                    diskReadBytesPerSec: columns[Column.diskReadBytesPerSec.rawValue][i],
                    diskWriteBytesPerSec: columns[Column.diskWriteBytesPerSec.rawValue][i]))
        }
        return out
    }

    /// The largest value in a column, or nil when the window is empty.
    public func peak(_ column: Column) -> Double? {
        values(column).max()
    }

    private mutating func push(_ point: SystemHistoryPoint) {
        times.append(point.date.timeIntervalSinceReferenceDate)
        columns[Column.pressurePercent.rawValue].append(point.pressurePercent)
        columns[Column.cpuLoad.rawValue].append(point.cpuLoad)
        columns[Column.appMemory.rawValue].append(Double(point.appMemory))
        columns[Column.wired.rawValue].append(Double(point.wired))
        columns[Column.compressed.rawValue].append(Double(point.compressed))
        columns[Column.cachedFiles.rawValue].append(Double(point.cachedFiles))
        columns[Column.swapUsed.rawValue].append(Double(point.swapUsed))
        columns[Column.networkInBytesPerSec.rawValue].append(point.networkInBytesPerSec)
        columns[Column.networkOutBytesPerSec.rawValue].append(point.networkOutBytesPerSec)
        columns[Column.diskReadBytesPerSec.rawValue].append(point.diskReadBytesPerSec)
        columns[Column.diskWriteBytesPerSec.rawValue].append(point.diskWriteBytesPerSec)
        columns[Column.gpuUtilization.rawValue].append(point.gpuUtilization ?? 0)
        columns[Column.gpuPowerWatts.rawValue].append(point.gpuPowerWatts ?? 0)
        columns[Column.anePowerWatts.rawValue].append(point.anePowerWatts ?? 0)
        columns[Column.cpuDieC.rawValue].append(point.cpuDieC ?? 0)
        let peaks = point.effectivePeaks
        columns[Column.pressurePercentPeak.rawValue].append(peaks.pressurePercent)
        columns[Column.cpuLoadPeak.rawValue].append(peaks.cpuLoad)
        columns[Column.networkInPeak.rawValue].append(peaks.networkInBytesPerSec)
        columns[Column.networkOutPeak.rawValue].append(peaks.networkOutBytesPerSec)
        columns[Column.diskReadPeak.rawValue].append(peaks.diskReadBytesPerSec)
        columns[Column.diskWritePeak.rawValue].append(peaks.diskWriteBytesPerSec)
        columns[Column.gpuUtilizationPeak.rawValue].append(
            peaks.gpuUtilization ?? point.gpuUtilization ?? 0)
        columns[Column.loadAverage1.rawValue].append(point.loadAverage1)
        columns[Column.loadAverage5.rawValue].append(point.loadAverage5)
        columns[Column.loadAverage15.rawValue].append(point.loadAverage15)
        columns[Column.loadAverage1Peak.rawValue].append(
            peaks.loadAverage1 ?? point.loadAverage1)
        latest = point
    }

    private mutating func trim() {
        guard let newest = times.last else { return }
        let cutoff = newest - span
        while head + 1 < times.count, times[head + 1] < cutoff {
            head += 1
        }
        if head >= Self.compactionThreshold, head >= times.count / 2 {
            times.removeFirst(head)
            for i in columns.indices { columns[i].removeFirst(head) }
            head = 0
        }
    }
}

extension LiveSeriesDecimator {
    /// The columnar fast path: timestamps and values as contiguous doubles,
    /// domain in reference-date seconds. Same reduction as `decimate`, in a
    /// loop over plain doubles.
    @inlinable
    public static func decimate(
        times: ArraySlice<Double>,
        values: ArraySlice<Double>,
        buckets: Int,
        domain: ClosedRange<Double>
    ) -> [Point] {
        precondition(times.count == values.count)
        let buckets = max(1, buckets)
        let n = times.count
        if n <= 2 * buckets {
            var out: [Point] = []
            out.reserveCapacity(n)
            var ti = times.startIndex
            var vi = values.startIndex
            while ti < times.endIndex {
                out.append(
                    Point(date: Date(timeIntervalSinceReferenceDate: times[ti]), value: values[vi]))
                ti += 1
                vi += 1
            }
            return out
        }

        let start = domain.lowerBound
        let width = max(domain.upperBound - start, 1e-9) / Double(buckets)
        var out: [Point] = []
        out.reserveCapacity(2 * buckets + 2)

        var currentBucket = Int.min
        var minT = 0.0
        var minV = 0.0
        var maxT = 0.0
        var maxV = 0.0
        var minIndex = 0
        var maxIndex = 0
        var hasBucket = false

        func flush(_ out: inout [Point]) {
            guard hasBucket else { return }
            if minIndex == maxIndex {
                out.append(Point(date: Date(timeIntervalSinceReferenceDate: minT), value: minV))
            } else if minIndex < maxIndex {
                out.append(Point(date: Date(timeIntervalSinceReferenceDate: minT), value: minV))
                out.append(Point(date: Date(timeIntervalSinceReferenceDate: maxT), value: maxV))
            } else {
                out.append(Point(date: Date(timeIntervalSinceReferenceDate: maxT), value: maxV))
                out.append(Point(date: Date(timeIntervalSinceReferenceDate: minT), value: minV))
            }
            hasBucket = false
        }

        var ti = times.startIndex
        var vi = values.startIndex
        var order = 0
        while ti < times.endIndex {
            let t = times[ti]
            let v = values[vi]
            ti += 1
            vi += 1
            let raw = Int(((t - start) / width).rounded(.down))
            let bucket = min(max(raw, 0), buckets - 1)
            if bucket != currentBucket {
                flush(&out)
                currentBucket = bucket
            }
            order += 1
            if hasBucket {
                if v < minV {
                    minV = v
                    minT = t
                    minIndex = order
                }
                if v > maxV {
                    maxV = v
                    maxT = t
                    maxIndex = order
                }
            } else {
                minV = v
                maxV = v
                minT = t
                maxT = t
                minIndex = order
                maxIndex = order
                hasBucket = true
            }
        }
        flush(&out)
        return out
    }
}
