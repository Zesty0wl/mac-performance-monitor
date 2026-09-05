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
    }

    /// Timestamps as `timeIntervalSinceReferenceDate`, oldest first.
    private var times: [Double] = []
    private var columns: [[Double]] = Array(repeating: [], count: Column.allCases.count)
    private var head = 0
    public private(set) var span: TimeInterval
    /// Width of the buckets appended samples are folded into, or zero to keep
    /// every sample as it arrives.
    ///
    /// A one hour window at a one second cadence holds 3,600 samples and is
    /// drawn perhaps 1,500 pixels wide, so more than two samples land in every
    /// column and the line is painted at the highest of them: the chart reads as
    /// a band of noise whose height is worst case rather than typical. Folding
    /// appends into buckets keeps the window at the resolution the chart can
    /// actually show, however long the app runs. Short ranges leave this at zero
    /// and keep every sample, because at five minutes the detail is the point.
    public private(set) var bucketSeconds: TimeInterval = 0
    /// How many samples the open bucket has absorbed, for the running mean.
    private var openBucketCount = 0
    /// The newest sample in full, for the live read-outs.
    public private(set) var latest: SystemHistoryPoint?

    private static var compactionThreshold: Int { 1024 }

    public init(span: TimeInterval, bucketSeconds: TimeInterval = 0) {
        precondition(span > 0, "SystemHistoryWindow span must be positive")
        self.span = span
        self.bucketSeconds = max(0, bucketSeconds)
    }

    /// Change the bucket width. Samples already held keep whatever resolution
    /// they were stored at; the caller reloads when it wants them re-bucketed.
    public mutating func setBucketSeconds(_ seconds: TimeInterval) {
        bucketSeconds = max(0, seconds)
        openBucketCount = 0
    }

    /// Which bucket a timestamp belongs to, as a bucket index.
    private func bucket(_ time: Double) -> Double {
        (time / bucketSeconds).rounded(.down)
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
    @discardableResult
    public mutating func append(_ point: SystemHistoryPoint) -> Bool {
        if let latest, point.date <= latest.date { return false }
        let time = point.date.timeIntervalSinceReferenceDate
        if bucketSeconds > 0, let lastTime = times.last, count > 0,
            bucket(lastTime) == bucket(time)
        {
            merge(point)
        } else {
            openBucketCount = 1
            push(point)
        }
        trim()
        return true
    }

    /// Fold a sample into the open bucket rather than starting a new one.
    ///
    /// Most metrics take a running mean, which is what makes a long window
    /// readable. The temperature column takes the maximum instead, matching the
    /// stored-history downsampler: averaging thermal readings erases the spikes,
    /// which are the reason to look at them at all. The timestamp stays at the
    /// bucket's first sample so the x axis does not creep.
    private mutating func merge(_ point: SystemHistoryPoint) {
        let n = Double(openBucketCount)
        let next = n + 1
        func mean(_ column: Column, _ value: Double) {
            let i = columns[column.rawValue].count - 1
            columns[column.rawValue][i] = (columns[column.rawValue][i] * n + value) / next
        }
        func peak(_ column: Column, _ value: Double) {
            let i = columns[column.rawValue].count - 1
            columns[column.rawValue][i] = Swift.max(columns[column.rawValue][i], value)
        }
        mean(.pressurePercent, point.pressurePercent)
        mean(.cpuLoad, point.cpuLoad)
        mean(.appMemory, Double(point.appMemory))
        mean(.wired, Double(point.wired))
        mean(.compressed, Double(point.compressed))
        mean(.cachedFiles, Double(point.cachedFiles))
        mean(.swapUsed, Double(point.swapUsed))
        mean(.networkInBytesPerSec, point.networkInBytesPerSec)
        mean(.networkOutBytesPerSec, point.networkOutBytesPerSec)
        mean(.diskReadBytesPerSec, point.diskReadBytesPerSec)
        mean(.diskWriteBytesPerSec, point.diskWriteBytesPerSec)
        mean(.gpuUtilization, point.gpuUtilization ?? 0)
        mean(.gpuPowerWatts, point.gpuPowerWatts ?? 0)
        mean(.anePowerWatts, point.anePowerWatts ?? 0)
        peak(.cpuDieC, point.cpuDieC ?? 0)
        openBucketCount += 1
        // The read-outs want the sample as it arrived, not the bucket's mean.
        latest = point
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
