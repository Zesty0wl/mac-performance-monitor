import Foundation
import MacPerfMonitorCore

/// A metric the Performance Monitor can plot. Memory, CPU, and file descriptors
/// read straight off each sample; disk I/O is a throughput rate derived from the
/// difference between consecutive cumulative counters.
enum PerfMetric: String, CaseIterable, Identifiable, Sendable {
    case memory
    case cpu
    case network
    case fileDescriptors
    case diskIO

    var id: String { rawValue }

    var label: String {
        switch self {
        case .memory: return "Memory footprint"
        case .cpu: return "CPU"
        case .network: return "Network"
        case .fileDescriptors: return "File descriptors"
        case .diskIO: return "Disk I/O"
        }
    }

    /// Compact label for the segmented control.
    var shortLabel: String {
        switch self {
        case .memory: return "Memory"
        case .cpu: return "CPU"
        case .network: return "Network"
        case .fileDescriptors: return "Files"
        case .diskIO: return "Disk"
        }
    }

    var systemImage: String {
        switch self {
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .network: return "network"
        case .fileDescriptors: return "doc.on.doc"
        case .diskIO: return "internaldrive"
        }
    }

    /// One-line description shown beside the chart title.
    var caption: String {
        switch self {
        case .memory: return "phys_footprint, the headline \u{201C}Memory\u{201D} figure"
        case .cpu: return "Percent of one core"
        case .network: return "Download + upload throughput (per-app tracking required)"
        case .fileDescriptors: return "Open files, sockets, and pipes"
        case .diskIO: return "Read + write throughput between ticks"
        }
    }

    /// Floor for the chart's Y-axis top, used only when every value is near zero
    /// so a flat-idle metric still renders a sensible axis instead of collapsing
    /// onto the baseline. Active data drives the axis from its own peak.
    var minTop: Double {
        switch self {
        case .memory: return 1
        case .cpu: return 1
        case .network: return 1
        case .fileDescriptors: return 10
        case .diskIO: return 1
        }
    }

    /// Format a value in the metric's natural units for axes and read-outs.
    func format(_ value: Double) -> String {
        let v = max(value, 0)
        switch self {
        case .memory:
            return ByteFormat.string(Self.clampedByteCount(v))
        case .cpu:
            return String(format: "%.0f%%", v)
        case .network:
            return ByteFormat.rate(v)
        case .fileDescriptors:
            return String(format: "%.0f", v)
        case .diskIO:
            return "\(ByteFormat.string(Self.clampedByteCount(v)))/s"
        }
    }

    private static func clampedByteCount(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        if value >= Double(UInt64.max) { return UInt64.max }
        return UInt64(value)
    }

    /// Project a raw per-process series onto this metric. Memory, CPU, and FDs
    /// map point-for-point; disk I/O becomes a bytes-per-second rate from the
    /// delta between consecutive cumulative counters (resets clamp to zero), so
    /// its series starts one sample in.
    func points(from raw: [ProcessHistoryPoint]) -> [PerfPoint] {
        switch self {
        case .memory:
            return raw.map { PerfPoint(date: $0.date, value: Double($0.footprint)) }
        case .cpu:
            return raw.map { PerfPoint(date: $0.date, value: $0.cpuPercent) }
        case .network:
            // Stored as an instantaneous rate already, so it maps point-for-point
            // like CPU (no cumulative-counter differencing as disk needs).
            return raw.map { PerfPoint(date: $0.date, value: $0.networkBytesPerSec) }
        case .fileDescriptors:
            return raw.map { PerfPoint(date: $0.date, value: Double($0.fdTotal)) }
        case .diskIO:
            guard raw.count > 1 else { return [] }
            var out: [PerfPoint] = []
            out.reserveCapacity(raw.count - 1)
            for i in 1..<raw.count {
                let prev = raw[i - 1]
                let cur = raw[i]
                let dt = cur.date.timeIntervalSince(prev.date)
                guard dt > 0 else { continue }
                let readDelta =
                    cur.diskRead >= prev.diskRead ? Double(cur.diskRead - prev.diskRead) : 0
                let writeDelta =
                    cur.diskWritten >= prev.diskWritten
                    ? Double(cur.diskWritten - prev.diskWritten) : 0
                out.append(PerfPoint(date: cur.date, value: (readDelta + writeDelta) / dt))
            }
            return out
        }
    }

    /// Project an imported trace window without first duplicating the complete
    /// document into `ProcessHistoryPoint` arrays.
    func points(from raw: ArraySlice<ProcessTracePoint>) -> [PerfPoint] {
        switch self {
        case .memory:
            return raw.map {
                PerfPoint(date: Date(timeIntervalSince1970: $0.t), value: Double($0.footprint))
            }
        case .cpu:
            return raw.map {
                PerfPoint(date: Date(timeIntervalSince1970: $0.t), value: $0.cpu)
            }
        case .network:
            return raw.map {
                PerfPoint(date: Date(timeIntervalSince1970: $0.t), value: $0.net)
            }
        case .fileDescriptors:
            return raw.map {
                PerfPoint(date: Date(timeIntervalSince1970: $0.t), value: Double($0.fd))
            }
        case .diskIO:
            guard raw.count > 1 else { return [] }
            var output: [PerfPoint] = []
            output.reserveCapacity(raw.count - 1)
            var previous = raw[raw.startIndex]
            for index in raw.indices.dropFirst() {
                let point = raw[index]
                let interval = point.t - previous.t
                if interval > 0 {
                    let readDelta =
                        point.diskRead >= previous.diskRead
                        ? Double(point.diskRead - previous.diskRead) : 0
                    let writeDelta =
                        point.diskWritten >= previous.diskWritten
                        ? Double(point.diskWritten - previous.diskWritten) : 0
                    output.append(
                        PerfPoint(
                            date: Date(timeIntervalSince1970: point.t),
                            value: (readDelta + writeDelta) / interval))
                }
                previous = point
            }
            return output
        }
    }

    /// Sort weight for the picker, so the heaviest processes for this metric
    /// surface first.
    func weight(_ s: ProcessSample) -> Double {
        switch self {
        case .memory: return Double(s.physFootprint)
        case .cpu: return s.cpuPercent
        case .network: return s.networkBytesPerSec
        case .fileDescriptors: return Double(s.fdTotal)
        case .diskIO: return Double(s.diskBytesRead &+ s.diskBytesWritten)
        }
    }

    /// The picker's trailing read-out for a candidate process.
    func weightString(_ s: ProcessSample) -> String {
        switch self {
        case .memory: return ByteFormat.string(s.physFootprint)
        case .cpu: return String(format: "%.1f%%", s.cpuPercent)
        case .network: return ByteFormat.rate(s.networkBytesPerSec)
        case .fileDescriptors: return "\(s.fdTotal)"
        case .diskIO: return ByteFormat.string(s.diskBytesRead &+ s.diskBytesWritten)
        }
    }
}

/// The chart's time window. `live` streams a short, self-scrolling window from
/// the sampler's in-memory trail; the others read logged history. The spans up
/// to two hours read raw 2-second samples (full resolution); the 24-hour and
/// 7-day spans read the minute/hour aggregates, which carry every metric
/// (footprint, CPU, file descriptors, and disk I/O) at a coarser resolution, so
/// leaks and trends can be seen over days without growing storage.
enum PerfSpan: String, CaseIterable, Identifiable {
    case live
    case oneHour
    case sixHours
    case oneDay
    case sevenDays

    var id: String { rawValue }

    var label: String {
        switch self {
        // A short, self-scrolling 2-minute window served from the in-memory trail
        // so any process plots instantly; the rest match the app-wide history set.
        case .live: return "2m"
        case .oneHour: return "1 hr"
        case .sixHours: return "6 hr"
        case .oneDay: return "24 hr"
        case .sevenDays: return "7 day"
        }
    }

    /// Width of the visible window in seconds.
    var seconds: TimeInterval {
        switch self {
        case .live: return 120
        case .oneHour: return 60 * 60
        case .sixHours: return 6 * 60 * 60
        case .oneDay: return 24 * 60 * 60
        case .sevenDays: return 7 * 24 * 60 * 60
        }
    }

    var isLive: Bool { self == .live }

    /// The shared history window backing the non-live spans (1h raw, the rest
    /// minute/hour aggregates); nil for the live in-memory stream.
    var window: HistoryWindow? {
        switch self {
        case .live: return nil
        case .oneHour: return .oneHour
        case .sixHours: return .sixHours
        case .oneDay: return .oneDay
        case .sevenDays: return .sevenDays
        }
    }

    /// True for spans that read the minute/hour aggregates (a coarser resolution)
    /// rather than raw 2-second samples.
    var usesAggregates: Bool {
        guard let window else { return false }
        return window.granularity != .raw
    }
}
