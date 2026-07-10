// SPDX-License-Identifier: MIT

import Foundation

// A self-contained, versioned description of one or more processes' recorded
// time-series, made for sharing. It is deliberately decoupled from the internal
// `ProcessHistoryPoint` / `ProcessSample` types so the on-disk file format can
// stay stable across internal refactors: the only contract a reader depends on
// is this schema plus `formatVersion`. Bridging to and from the internal point
// type lives at the bottom of this file.

/// The top-level exported document: a set of per-process series over one time
/// window, at one nominal resolution, plus enough provenance for a recipient to
/// know where it came from. Encoded and compressed by `ProcessTraceCodec`.
public struct ProcessTraceDocument: Codable, Sendable, Equatable {
    /// Schema version of this JSON payload. Bumped only on a breaking change to
    /// the shape below; readers refuse a version they do not understand.
    public var formatVersion: Int
    /// Human-readable exporter identity, e.g. "Mac Performance Monitor 1.2.0 (127)".
    public var generator: String
    /// When the export was produced.
    public var exportedAt: Date
    /// Minimal, non-identifying provenance about the source machine.
    public var source: Source
    /// Inclusive start of the covered window.
    public var startDate: Date
    /// Inclusive end of the covered window.
    public var endDate: Date
    /// Nominal spacing between points, in seconds (2 for raw, 60 for the minute
    /// tier, 3600 for the hour tier). Advisory: gaps and irregular spacing are
    /// represented by the points themselves.
    public var resolutionSeconds: Double
    /// One entry per exported process, in the order they should be drawn.
    public var processes: [ProcessTraceSeries]

    /// The current schema version this build writes.
    public static let currentFormatVersion = 1

    public init(
        formatVersion: Int = ProcessTraceDocument.currentFormatVersion,
        generator: String,
        exportedAt: Date,
        source: Source,
        startDate: Date,
        endDate: Date,
        resolutionSeconds: Double,
        processes: [ProcessTraceSeries]
    ) {
        self.formatVersion = formatVersion
        self.generator = generator
        self.exportedAt = exportedAt
        self.source = source
        self.startDate = startDate
        self.endDate = endDate
        self.resolutionSeconds = resolutionSeconds
        self.processes = processes
    }

    /// The covered window as a range (clamped so `lowerBound <= upperBound`).
    public var timeRange: ClosedRange<Date> {
        let lo = min(startDate, endDate)
        let hi = max(startDate, endDate)
        return lo...hi
    }

    /// Total number of stored points across every series.
    public var totalPointCount: Int {
        processes.reduce(0) { $0 + $1.points.count }
    }

    /// Minimal, non-identifying provenance. Deliberately excludes anything that
    /// names a person or account; the hardware model and OS version are the kind
    /// of context a recipient needs to reason about a report, nothing more.
    public struct Source: Codable, Sendable, Equatable {
        /// OS marketing description, e.g. "macOS 15.5".
        public var osVersion: String
        /// Hardware model identifier, e.g. "MacBookPro18,3". Optional.
        public var machineModel: String?
        /// An optional friendly label the exporter chose to attach (off by
        /// default for privacy).
        public var hostLabel: String?

        public init(osVersion: String, machineModel: String? = nil, hostLabel: String? = nil) {
            self.osVersion = osVersion
            self.machineModel = machineModel
            self.hostLabel = hostLabel
        }
    }
}

/// One process's exported series: a stable identity, the metadata a recipient
/// needs to recognise it (even though the process does not exist on their Mac),
/// and the recorded points.
public struct ProcessTraceSeries: Codable, Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var startTime: Date
    /// Display name captured at export time.
    public var name: String
    public var executablePath: String?
    public var bundleID: String?
    /// Code-signing Team Identifier, when known.
    public var teamID: String?
    /// CPU architecture string (e.g. "arm64", "x86_64"), when known.
    public var architecture: String?
    /// Whether the process was running translated under Rosetta, when known.
    public var isTranslated: Bool?
    /// The recorded points, oldest first.
    public var points: [ProcessTracePoint]

    public init(
        pid: Int32,
        startTime: Date,
        name: String,
        executablePath: String? = nil,
        bundleID: String? = nil,
        teamID: String? = nil,
        architecture: String? = nil,
        isTranslated: Bool? = nil,
        points: [ProcessTracePoint]
    ) {
        self.pid = pid
        self.startTime = startTime
        self.name = name
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.teamID = teamID
        self.architecture = architecture
        self.isTranslated = isTranslated
        self.points = points
    }

    /// Stable, unique string id (a reused PID with a new start time is a
    /// distinct process, so both are folded in).
    public var id: String { "\(pid)/\(startTime.timeIntervalSince1970.bitPattern)" }

    /// The identity this series belongs to.
    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: startTime)
    }
}

/// One recorded point. Field names are abbreviated to keep the pre-compression
/// JSON compact; the values mirror `ProcessHistoryPoint`.
public struct ProcessTracePoint: Codable, Sendable, Equatable {
    /// Timestamp as seconds since the Unix epoch.
    public var t: Double
    /// Physical memory footprint, bytes.
    public var footprint: UInt64
    /// CPU usage, percent of one core.
    public var cpu: Double
    /// Open file-descriptor count.
    public var fd: Int
    /// Cumulative bytes read since the process started.
    public var diskRead: UInt64
    /// Cumulative bytes written since the process started.
    public var diskWritten: UInt64
    /// Instantaneous network throughput, bytes/second (download + upload).
    public var net: Double

    public init(
        t: Double,
        footprint: UInt64,
        cpu: Double,
        fd: Int,
        diskRead: UInt64,
        diskWritten: UInt64,
        net: Double
    ) {
        self.t = t
        self.footprint = footprint
        self.cpu = cpu
        self.fd = fd
        self.diskRead = diskRead
        self.diskWritten = diskWritten
        self.net = net
    }

    private enum CodingKeys: String, CodingKey {
        case t
        case footprint = "f"
        case cpu = "c"
        case fd
        case diskRead = "dr"
        case diskWritten = "dw"
        case net = "n"
    }
}

// MARK: - Bridging to the internal point type

extension ProcessTracePoint {
    /// Build a trace point from an internal history point.
    public init(_ point: ProcessHistoryPoint) {
        self.init(
            t: point.date.timeIntervalSince1970,
            footprint: point.footprint,
            cpu: point.cpuPercent,
            fd: point.fdTotal,
            diskRead: point.diskRead,
            diskWritten: point.diskWritten,
            net: point.networkBytesPerSec
        )
    }

    /// Convert back to an internal history point for charting.
    public var historyPoint: ProcessHistoryPoint {
        ProcessHistoryPoint(
            date: Date(timeIntervalSince1970: t),
            footprint: footprint,
            cpuPercent: cpu,
            fdTotal: fd,
            diskRead: diskRead,
            diskWritten: diskWritten,
            networkBytesPerSec: net
        )
    }
}

extension ProcessTraceSeries {
    /// The series' points as internal history points, oldest first.
    public var historyPoints: [ProcessHistoryPoint] {
        points.map(\.historyPoint)
    }
}
