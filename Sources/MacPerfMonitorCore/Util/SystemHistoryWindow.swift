import Foundation

/// A trailing window of system samples stored column by column, for the live
/// Dashboard timelines.
///
/// Every chart and card on a live page reads one or two metrics from every
/// sample in the window, several times a tick. Held as an array of
/// `SystemHistoryPoint` that meant copying a large struct (with resilient
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
        /// Raw sample counts and source bucket widths, not chart bucket sizes.
        case sampleCount
        case bucketDuration
        /// True bucket minima. Unknown legacy extrema are NaN, never a mean
        /// substituted for a discarded minimum. Raw extrema equal the value.
        case pressurePercentMinimum
        case cpuLoadMinimum
        case networkInMinimum
        case networkOutMinimum
        case diskReadMinimum
        case diskWriteMinimum
        case appMemoryMinimum
        case appMemoryPeak
        case wiredMinimum
        case wiredPeak
        case compressedMinimum
        case compressedPeak
        case cachedFilesMinimum
        case cachedFilesPeak
        case swapUsedMinimum
        case swapUsedPeak
        case aneTimeMillisecondsPerSecond
        case aneTimeMinimum
        case aneTimePeak
        case aneTimeSampleCount
        case anePowerMinimum
        case anePowerPeak
        case anePowerSampleCount
        case gpuMemoryBytes
        case gpuMemoryMinimum
        case gpuMemoryPeak
        case gpuMemorySampleCount
        case gpuActiveResidency
        case gpuActiveMinimum
        case gpuActivePeak
        case gpuActiveSampleCount
        case gpuReadBandwidthGBps
        case gpuReadBandwidthMinimum
        case gpuReadBandwidthPeak
        case gpuReadBandwidthSampleCount
        case gpuWriteBandwidthGBps
        case gpuWriteBandwidthMinimum
        case gpuWriteBandwidthPeak
        case gpuWriteBandwidthSampleCount
        case gpuTotalBandwidthGBps
        case gpuTotalBandwidthMinimum
        case gpuTotalBandwidthPeak
        case gpuTotalBandwidthSampleCount
    }

    /// Timestamps as `timeIntervalSinceReferenceDate`, oldest first.
    private var times: [Double] = []
    private var columns: [[Double]] = Array(repeating: [], count: Column.allCases.count)
    /// Lossless snapshots for the occasional points() export. These are copied
    /// once on append, not scanned per metric on the chart hot path. Keeping
    /// the originals also preserves optional fields and exact UInt64 values
    /// that cannot all be reconstructed from the chart's Double columns.
    private var retainedPoints: [SystemHistoryPoint] = []
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
        retainedPoints.removeAll(keepingCapacity: true)
        head = 0
        latest = nil
        times.reserveCapacity(points.count)
        for i in columns.indices { columns[i].reserveCapacity(points.count) }
        retainedPoints.reserveCapacity(points.count)
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
        Array(retainedPoints[head...])
    }

    /// The largest value in a column, or nil when the window is empty or any
    /// retained value is unknown. A partial peak must not claim a full range.
    public func peak(_ column: Column) -> Double? {
        let values = values(column)
        guard !values.isEmpty else { return nil }
        var maximum = -Double.infinity
        for value in values {
            guard value.isFinite else { return nil }
            maximum = max(maximum, value)
        }
        return maximum
    }

    private mutating func push(_ point: SystemHistoryPoint) {
        times.append(point.date.timeIntervalSinceReferenceDate)
        retainedPoints.append(point)
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
        columns[Column.anePowerWatts.rawValue].append(point.anePowerWatts ?? .nan)
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
        columns[Column.sampleCount.rawValue].append(Double(point.sampleCount))
        columns[Column.bucketDuration.rawValue].append(point.bucketDuration)
        // Older callers mark aggregates with peaks but have no bucket width.
        // Do not mistake those points for raw samples and invent their minima.
        let isRaw = point.bucketDuration == 0 && point.sampleCount == 1 && point.peaks == nil
        let minima = point.minima ?? (isRaw ? peaks : nil)
        let memoryPeaks = point.peaks ?? (isRaw ? peaks : nil)
        columns[Column.pressurePercentMinimum.rawValue].append(minima?.pressurePercent ?? .nan)
        columns[Column.cpuLoadMinimum.rawValue].append(minima?.cpuLoad ?? .nan)
        columns[Column.networkInMinimum.rawValue].append(minima?.networkInBytesPerSec ?? .nan)
        columns[Column.networkOutMinimum.rawValue].append(minima?.networkOutBytesPerSec ?? .nan)
        columns[Column.diskReadMinimum.rawValue].append(minima?.diskReadBytesPerSec ?? .nan)
        columns[Column.diskWriteMinimum.rawValue].append(minima?.diskWriteBytesPerSec ?? .nan)
        columns[Column.appMemoryMinimum.rawValue].append(minima?.appMemory ?? .nan)
        columns[Column.appMemoryPeak.rawValue].append(memoryPeaks?.appMemory ?? .nan)
        columns[Column.wiredMinimum.rawValue].append(minima?.wired ?? .nan)
        columns[Column.wiredPeak.rawValue].append(memoryPeaks?.wired ?? .nan)
        columns[Column.compressedMinimum.rawValue].append(minima?.compressed ?? .nan)
        columns[Column.compressedPeak.rawValue].append(memoryPeaks?.compressed ?? .nan)
        columns[Column.cachedFilesMinimum.rawValue].append(minima?.cachedFiles ?? .nan)
        columns[Column.cachedFilesPeak.rawValue].append(memoryPeaks?.cachedFiles ?? .nan)
        columns[Column.swapUsedMinimum.rawValue].append(minima?.swapUsed ?? .nan)
        columns[Column.swapUsedPeak.rawValue].append(memoryPeaks?.swapUsed ?? .nan)
        columns[Column.aneTimeMillisecondsPerSecond.rawValue].append(
            point.aneTimeMillisecondsPerSecond ?? .nan)
        columns[Column.aneTimeMinimum.rawValue].append(minima?.aneTimeMillisecondsPerSecond ?? .nan)
        columns[Column.aneTimePeak.rawValue].append(peaks.aneTimeMillisecondsPerSecond ?? .nan)
        columns[Column.aneTimeSampleCount.rawValue].append(
            Double(point.aneSampleCount ?? (point.aneTimeMillisecondsPerSecond == nil ? 0 : 1)))
        columns[Column.anePowerMinimum.rawValue].append(minima?.anePowerWatts ?? .nan)
        columns[Column.anePowerPeak.rawValue].append(peaks.anePowerWatts ?? .nan)
        columns[Column.anePowerSampleCount.rawValue].append(
            Double(point.anePowerSampleCount ?? (point.anePowerWatts == nil ? 0 : 1)))
        columns[Column.gpuMemoryBytes.rawValue].append(point.gpuMemoryBytes ?? .nan)
        columns[Column.gpuMemoryMinimum.rawValue].append(minima?.gpuMemoryBytes ?? .nan)
        columns[Column.gpuMemoryPeak.rawValue].append(peaks.gpuMemoryBytes ?? .nan)
        columns[Column.gpuMemorySampleCount.rawValue].append(
            Double(point.gpuMemorySampleCount ?? (point.gpuMemoryBytes == nil ? 0 : 1)))
        columns[Column.gpuActiveResidency.rawValue].append(point.gpuActiveResidency ?? .nan)
        columns[Column.gpuActiveMinimum.rawValue].append(minima?.gpuActiveResidency ?? .nan)
        columns[Column.gpuActivePeak.rawValue].append(peaks.gpuActiveResidency ?? .nan)
        columns[Column.gpuActiveSampleCount.rawValue].append(
            Double(point.gpuActiveSampleCount ?? (point.gpuActiveResidency == nil ? 0 : 1)))
        columns[Column.gpuReadBandwidthGBps.rawValue].append(point.gpuReadBandwidthGBps ?? .nan)
        columns[Column.gpuReadBandwidthMinimum.rawValue].append(
            minima?.gpuReadBandwidthGBps ?? .nan)
        columns[Column.gpuReadBandwidthPeak.rawValue].append(peaks.gpuReadBandwidthGBps ?? .nan)
        columns[Column.gpuReadBandwidthSampleCount.rawValue].append(
            Double(point.gpuReadBandwidthSampleCount ?? (point.gpuReadBandwidthGBps == nil ? 0 : 1))
        )
        columns[Column.gpuWriteBandwidthGBps.rawValue].append(point.gpuWriteBandwidthGBps ?? .nan)
        columns[Column.gpuWriteBandwidthMinimum.rawValue].append(
            minima?.gpuWriteBandwidthGBps ?? .nan)
        columns[Column.gpuWriteBandwidthPeak.rawValue].append(peaks.gpuWriteBandwidthGBps ?? .nan)
        columns[Column.gpuWriteBandwidthSampleCount.rawValue].append(
            Double(
                point.gpuWriteBandwidthSampleCount ?? (point.gpuWriteBandwidthGBps == nil ? 0 : 1)))
        columns[Column.gpuTotalBandwidthGBps.rawValue].append(point.gpuTotalBandwidthGBps ?? .nan)
        columns[Column.gpuTotalBandwidthMinimum.rawValue].append(
            minima?.gpuTotalBandwidthGBps ?? .nan)
        columns[Column.gpuTotalBandwidthPeak.rawValue].append(peaks.gpuTotalBandwidthGBps ?? .nan)
        columns[Column.gpuTotalBandwidthSampleCount.rawValue].append(
            Double(
                point.gpuTotalBandwidthSampleCount ?? (point.gpuTotalBandwidthGBps == nil ? 0 : 1)))
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
            retainedPoints.removeFirst(head)
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
