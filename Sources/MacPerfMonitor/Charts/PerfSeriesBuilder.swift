// SPDX-License-Identifier: MIT

import MacPerfMonitorCore
import SwiftUI

/// Pure, data-source-agnostic helpers shared by the live Analytics view
/// (`PerformanceMonitorView`) and the imported-trace viewer (`TraceViewerView`):
/// time-anchored downsampling, window slicing, and the per-series statistics
/// summary. Kept here so both surfaces draw and summarise series identically
/// without duplicating the (carefully tuned) maths.
enum PerfSeriesBuilder {
    private struct PeakAccumulator {
        let bucketWidth: TimeInterval
        var currentBucket: Int?
        var peak: PerfPoint?
        var latest: PerfPoint?
        var result: [PerfPoint] = []

        init(bucketWidth: TimeInterval) {
            self.bucketWidth = bucketWidth
            result.reserveCapacity(1_024)
        }

        mutating func append(_ point: PerfPoint) {
            latest = point
            let bucket = PerfSeriesBuilder.bucketIndex(point.date, bucketWidth)
            if bucket != currentBucket {
                if let peak { result.append(peak) }
                currentBucket = bucket
                peak = point
            } else if point.value > (peak?.value ?? -.infinity) {
                peak = point
            }
        }

        mutating func finish() -> [PerfPoint] {
            if let peak { result.append(peak) }
            if let latest, let peak, latest.date > peak.date { result.append(latest) }
            return result
        }
    }

    /// The epoch-anchored bucket a timestamp falls in for a given bucket width.
    static func bucketIndex(_ date: Date, _ width: TimeInterval) -> Int {
        Int((date.timeIntervalSince1970 / width).rounded(.down))
    }

    /// Collapse a dense series to one peak sample per fixed time bucket. The
    /// bucket boundaries are anchored to absolute time (not to the array's
    /// index), so they stay put as the live window advances: appending a sample
    /// only ever changes the rightmost bucket, and the middle of the chart holds
    /// still instead of shimmering. Keeping each bucket's maximum preserves
    /// spikes rather than averaging them away. Series already coarser than the
    /// bucket width pass through untouched.
    static func downsample(_ points: [PerfPoint], bucketWidth: TimeInterval) -> [PerfPoint] {
        guard bucketWidth > 0, points.count > 2 else { return points }
        var result: [PerfPoint] = []
        result.reserveCapacity(min(points.count, 1_024))
        var currentBucket = bucketIndex(points[0].date, bucketWidth)
        var peak = points[0]
        for point in points.dropFirst() {
            let bucket = bucketIndex(point.date, bucketWidth)
            if bucket == currentBucket {
                if point.value > peak.value { peak = point }
            } else {
                result.append(peak)
                currentBucket = bucket
                peak = point
            }
        }
        result.append(peak)
        // Keep the live right edge tracking the newest sample: the final bucket's
        // point sits at its peak's time, which can be up to a bucket behind, so
        // appending the actual latest sample makes the endpoint advance every
        // tick instead of looking frozen between bucket boundaries.
        if let last = points.last, last.date > peak.date {
            result.append(last)
        }
        return result
    }

    /// The points inside `domain` plus one on each side, so lines run off the
    /// chart edges (the scale clips them) and the disk-rate differencing keeps
    /// its left neighbour.
    static func slice(
        _ points: [ProcessHistoryPoint], domain: ClosedRange<Date>
    ) -> [ProcessHistoryPoint] {
        guard !points.isEmpty else { return [] }

        var low = 0
        var high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].date < domain.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let first = low

        low = first
        high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].date <= domain.upperBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let afterLast = low

        guard first < afterLast else { return [] }
        return Array(points[max(first - 1, 0)...min(afterLast, points.count - 1)])
    }

    /// The trace equivalent of `slice`, using binary search over the codec's
    /// validated timestamp ordering and returning a view into the original
    /// point buffer instead of copying the selected window.
    static func traceSlice(
        _ points: [ProcessTracePoint], domain: ClosedRange<Date>
    ) -> ArraySlice<ProcessTracePoint> {
        guard !points.isEmpty else { return [] }
        let lower = domain.lowerBound.timeIntervalSince1970
        let upper = domain.upperBound.timeIntervalSince1970

        var low = 0
        var high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].t < lower {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let first = low

        low = first
        high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].t <= upper {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let afterLast = low

        guard first < afterLast else { return [] }
        let start = max(first - 1, 0)
        let end = min(afterLast, points.count - 1)
        return points[start...end]
    }

    /// Project every trace metric and downsample it in one traversal. The old
    /// path mapped the full slice into five temporary arrays before reducing
    /// each to about 300 points, multiplying both work and peak allocation.
    static func traceDownsampled(
        _ points: ArraySlice<ProcessTracePoint>, bucketWidth: TimeInterval
    ) -> [PerfMetric: [PerfPoint]] {
        traceDownsampled(points, bucketWidth: bucketWidth, isCancelled: { false }) ?? [:]
    }

    static func traceDownsampled(
        _ points: ArraySlice<ProcessTracePoint>,
        bucketWidth: TimeInterval,
        isCancelled: () -> Bool
    ) -> [PerfMetric: [PerfPoint]]? {
        guard bucketWidth > 0, points.count > 2 else {
            return Dictionary(
                uniqueKeysWithValues: PerfMetric.allCases.map {
                    ($0, $0.points(from: points))
                })
        }

        var memory = PeakAccumulator(bucketWidth: bucketWidth)
        var cpu = PeakAccumulator(bucketWidth: bucketWidth)
        var network = PeakAccumulator(bucketWidth: bucketWidth)
        var descriptors = PeakAccumulator(bucketWidth: bucketWidth)
        var disk = PeakAccumulator(bucketWidth: bucketWidth)
        var previous: ProcessTracePoint?

        for (offset, point) in points.enumerated() {
            if offset.isMultiple(of: 1_024), isCancelled() { return nil }
            let date = Date(timeIntervalSince1970: point.t)
            memory.append(PerfPoint(date: date, value: Double(point.footprint)))
            cpu.append(PerfPoint(date: date, value: point.cpu))
            network.append(PerfPoint(date: date, value: point.net))
            descriptors.append(PerfPoint(date: date, value: Double(point.fd)))
            if let previous {
                let interval = point.t - previous.t
                if interval > 0 {
                    let readDelta =
                        point.diskRead >= previous.diskRead
                        ? Double(point.diskRead - previous.diskRead) : 0
                    let writeDelta =
                        point.diskWritten >= previous.diskWritten
                        ? Double(point.diskWritten - previous.diskWritten) : 0
                    disk.append(
                        PerfPoint(date: date, value: (readDelta + writeDelta) / interval))
                }
            }
            previous = point
        }

        var result: [PerfMetric: [PerfPoint]] = [
            .memory: memory.finish(),
            .cpu: cpu.finish(),
            .network: network.finish(),
            .fileDescriptors: descriptors.finish(),
            .diskIO: disk.finish(),
        ]
        if points.count - 1 <= 2 {
            result[.diskIO] = PerfMetric.diskIO.points(from: points)
        }
        if isCancelled() { return nil }
        return result
    }

    static func traceDownsampled(
        _ points: ArraySlice<ProcessTracePoint>,
        metric: PerfMetric,
        bucketWidth: TimeInterval
    ) -> [PerfPoint] {
        traceDownsampled(
            points, metric: metric, bucketWidth: bucketWidth,
            isCancelled: { false }) ?? []
    }

    static func traceDownsampled(
        _ points: ArraySlice<ProcessTracePoint>,
        metric: PerfMetric,
        bucketWidth: TimeInterval,
        isCancelled: () -> Bool
    ) -> [PerfPoint]? {
        let projectedCount = metric == .diskIO ? max(points.count - 1, 0) : points.count
        guard bucketWidth > 0, projectedCount > 2 else { return metric.points(from: points) }
        var accumulator = PeakAccumulator(bucketWidth: bucketWidth)
        var previous: ProcessTracePoint?
        for (offset, point) in points.enumerated() {
            if offset.isMultiple(of: 1_024), isCancelled() { return nil }
            let date = Date(timeIntervalSince1970: point.t)
            let value: Double?
            switch metric {
            case .memory: value = Double(point.footprint)
            case .cpu: value = point.cpu
            case .network: value = point.net
            case .fileDescriptors: value = Double(point.fd)
            case .diskIO:
                if let previous {
                    let interval = point.t - previous.t
                    let readDelta =
                        point.diskRead >= previous.diskRead
                        ? Double(point.diskRead - previous.diskRead) : 0
                    let writeDelta =
                        point.diskWritten >= previous.diskWritten
                        ? Double(point.diskWritten - previous.diskWritten) : 0
                    value = interval > 0 ? (readDelta + writeDelta) / interval : nil
                } else {
                    value = nil
                }
            }
            if let value { accumulator.append(PerfPoint(date: date, value: value)) }
            previous = point
        }
        if isCancelled() { return nil }
        return accumulator.finish()
    }

    static func traceStatistics(
        _ points: ArraySlice<ProcessTracePoint>,
        metric: PerfMetric,
        domain: ClosedRange<Date>,
        isCancelled: () -> Bool
    ) -> SeriesStatistics? {
        var previous: ProcessTracePoint?
        var firstDate: Date?
        var firstValue: Double?
        var lastDate: Date?
        var count = 0.0
        var sum = 0.0
        var peak = -Double.infinity
        var minimum = Double.infinity
        var current = 0.0
        var sx = 0.0
        var sxx = 0.0
        var sxy = 0.0

        for (offset, point) in points.enumerated() {
            if offset.isMultiple(of: 1_024), isCancelled() { return nil }
            let date = Date(timeIntervalSince1970: point.t)
            let value: Double?
            switch metric {
            case .memory: value = Double(point.footprint)
            case .cpu: value = point.cpu
            case .network: value = point.net
            case .fileDescriptors: value = Double(point.fd)
            case .diskIO:
                if let previous {
                    let interval = point.t - previous.t
                    let readDelta =
                        point.diskRead >= previous.diskRead
                        ? Double(point.diskRead - previous.diskRead) : 0
                    let writeDelta =
                        point.diskWritten >= previous.diskWritten
                        ? Double(point.diskWritten - previous.diskWritten) : 0
                    value = interval > 0 ? (readDelta + writeDelta) / interval : nil
                } else {
                    value = nil
                }
            }
            previous = point

            guard domain.contains(date), let value else { continue }
            if firstDate == nil {
                firstDate = date
                firstValue = value
            }
            let origin = firstDate ?? date
            let x = date.timeIntervalSince(origin)
            lastDate = date
            count += 1
            sum += value
            peak = max(peak, value)
            minimum = min(minimum, value)
            current = value
            sx += x
            sxx += x * x
            sxy += x * value
        }

        guard let firstDate, let lastDate, count > 0, !isCancelled() else { return nil }
        let average = sum / count
        let denominator = count * sxx - sx * sx
        let span = lastDate.timeIntervalSince(firstDate)
        let change: Double
        if denominator != 0, span > 0 {
            change = (count * sxy - sx * sum) / denominator * span
        } else {
            change = current - (firstValue ?? current)
        }
        let fraction = change / max(abs(average), 1e-9)
        let trend: TrendDirection
        if fraction > 0.05 {
            trend = .rising
        } else if fraction < -0.05 {
            trend = .falling
        } else {
            trend = .flat
        }
        return SeriesStatistics(
            average: average, peak: peak, minimum: minimum, current: current,
            trend: trend, changeFraction: fraction)
    }

}

// MARK: - Per-series statistics

struct SeriesStatistics: Sendable {
    let average: Double
    let peak: Double
    let minimum: Double
    let current: Double
    let trend: TrendDirection
    let changeFraction: Double
}

/// One process's summary stats over a chart's visible window: average, peak,
/// current value, and a fitted trend. Shared by the live focused chart's stats
/// overlay and the trace viewer's.
struct SeriesStat: Identifiable {
    let id: ProcessIdentity
    let name: String
    let color: Color
    let average: Double
    let peak: Double
    let minimum: Double
    let current: Double
    let trend: TrendDirection
    /// Signed fraction the fitted trend line moves across the window, relative to
    /// the mean; drives the trend arrow and its percentage read-out.
    let changeFraction: Double

    var changeText: String {
        "\(Int((abs(changeFraction) * 100).rounded()))%"
    }

    init(
        statistics: SeriesStatistics,
        id: ProcessIdentity,
        name: String,
        color: Color
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.average = statistics.average
        self.peak = statistics.peak
        self.minimum = statistics.minimum
        self.current = statistics.current
        self.trend = statistics.trend
        self.changeFraction = statistics.changeFraction
    }

    init?(points: [PerfPoint], id: ProcessIdentity, name: String, color: Color) {
        guard let first = points.first, let last = points.last else { return nil }
        self.id = id
        self.name = name
        self.color = color
        let values = points.map(\.value)
        let count = Double(values.count)
        self.average = values.reduce(0, +) / count
        self.peak = values.max() ?? 0
        self.minimum = values.min() ?? 0
        self.current = last.value
        // Least-squares slope over (seconds since start, value), expressed as the
        // change the fitted line makes across the window.
        let t0 = first.date.timeIntervalSince1970
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for p in points {
            let x = p.date.timeIntervalSince1970 - t0
            sx += x
            sy += p.value
            sxx += x * x
            sxy += x * p.value
        }
        let denom = count * sxx - sx * sx
        let span = last.date.timeIntervalSince(first.date)
        let change: Double
        if denom != 0, span > 0 {
            change = (count * sxy - sx * sy) / denom * span
        } else {
            change = last.value - first.value
        }
        let fraction = change / max(abs(self.average), 1e-9)
        self.changeFraction = fraction
        if fraction > 0.05 {
            self.trend = .rising
        } else if fraction < -0.05 {
            self.trend = .falling
        } else {
            self.trend = .flat
        }
    }
}

enum TrendDirection: Equatable, Sendable {
    case rising, falling, flat

    var symbol: String {
        switch self {
        case .rising: return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .flat: return "arrow.right"
        }
    }

    var color: Color {
        switch self {
        case .rising: return .orange
        case .falling: return .green
        case .flat: return .secondary
        }
    }
}
