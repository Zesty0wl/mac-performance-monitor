import Foundation
import GRDB

/// A selectable window for the History tab's cross-process queries (PRD section
/// 8.5). Each window picks the storage tier that keeps the result bounded and
/// fast: the most recent hour reads raw 2-second samples; longer windows read
/// the downsampled minute or hour aggregates.
public enum HistoryWindow: String, Sendable, CaseIterable, Identifiable {
    case oneHour
    case sixHours
    case oneDay
    case sevenDays

    public var id: String { rawValue }

    /// Span of the window in seconds.
    public var seconds: TimeInterval {
        switch self {
        case .oneHour: return 3600
        case .sixHours: return 6 * 3600
        case .oneDay: return 24 * 3600
        case .sevenDays: return 7 * 86_400
        }
    }

    /// Short label for the window picker.
    public var label: String {
        switch self {
        case .oneHour: return "1 hr"
        case .sixHours: return "6 hr"
        case .oneDay: return "24 hr"
        case .sevenDays: return "7 day"
        }
    }

    /// Which stored tier backs queries for this window. The raw tier only holds
    /// two hours (section 6), so anything longer reads the aggregates.
    public enum Granularity: Sendable, Equatable { case raw, minute, hour }

    public var granularity: Granularity {
        switch self {
        case .oneHour: return .raw
        case .sixHours, .oneDay: return .minute
        case .sevenDays: return .hour
        }
    }
}

/// How to rank the "top consumers over time" leaderboard.
public enum ConsumerMetric: String, Sendable, CaseIterable, Identifiable {
    /// Time-weighted mean footprint across the window.
    case averageFootprint
    /// Highest footprint reached at any point in the window.
    case peakFootprint
    /// Time-weighted mean CPU (percent of one core) across the window.
    case averageCPU
    /// Time-weighted mean energy impact across the window (the Battery tab's
    /// top-energy-users leaderboard). See `EnergyImpact`.
    case averageEnergy
    /// Time-weighted mean network throughput across the window (bytes/second,
    /// download + upload). Only meaningful when per-app network tracking is on.
    case averageNetwork
    /// Mean kernel-attributed disk throughput across the process's observed
    /// portion of the window, derived from cumulative read and write endpoints.
    case averageDisk

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .averageFootprint: return "Average"
        case .peakFootprint: return "Peak"
        case .averageCPU: return "CPU"
        case .averageEnergy: return "Energy"
        case .averageNetwork: return "Network"
        case .averageDisk: return "Disk"
        }
    }

    /// The SELECT alias this metric ranks by, shared by the top-consumer and the
    /// group member-consumer queries.
    var orderColumn: String {
        switch self {
        case .averageFootprint: return "avg_fp"
        case .peakFootprint: return "max_fp"
        case .averageCPU: return "avg_cpu"
        case .averageEnergy: return "avg_energy"
        case .averageNetwork: return "avg_net"
        case .averageDisk: return "avg_disk"
        }
    }
}

/// One row of the "top consumers over time" leaderboard: a process and its
/// footprint/CPU aggregates over the selected window.
public struct ProcessConsumer: Sendable, Identifiable, Equatable {
    public var identity: ProcessIdentity
    public var name: String
    public var executablePath: String?
    public var bundleID: String?
    public var architecture: Architecture
    public var isTranslated: Bool
    /// Time-weighted mean footprint across the window (bytes).
    public var averageFootprint: UInt64
    /// Highest footprint reached in the window (bytes).
    public var peakFootprint: UInt64
    /// Mean CPU percentage across the window.
    public var averageCPU: Double
    /// Mean energy impact across the window (relative; see `EnergyImpact`).
    public var averageEnergy: Double
    /// Mean network throughput across the window (bytes/second, download+upload).
    public var averageNetwork: Double
    /// Mean attributed read + write throughput over the observed window.
    public var averageDisk: Double
    /// Number of underlying samples contributing to the aggregate.
    public var sampleCount: Int

    public var id: ProcessIdentity { identity }

    /// The full name to show, recovering a kernel-truncated `p_comm` from the
    /// executable path just as the live process list does.
    public var displayName: String {
        ProcessSample.resolvedDisplayName(name: name, executablePath: executablePath)
    }

    public init(
        identity: ProcessIdentity,
        name: String,
        executablePath: String? = nil,
        bundleID: String?,
        architecture: Architecture,
        isTranslated: Bool,
        averageFootprint: UInt64,
        peakFootprint: UInt64,
        averageCPU: Double,
        averageEnergy: Double = 0,
        averageNetwork: Double = 0,
        averageDisk: Double = 0,
        sampleCount: Int
    ) {
        self.identity = identity
        self.name = name
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.architecture = architecture
        self.isTranslated = isTranslated
        self.averageFootprint = averageFootprint
        self.peakFootprint = peakFootprint
        self.averageCPU = averageCPU
        self.averageEnergy = averageEnergy
        self.averageNetwork = averageNetwork
        self.averageDisk = averageDisk
        self.sampleCount = sampleCount
    }
}

extension SampleStore {
    /// The top memory consumers over a window, ranked by `metric`. Aggregates
    /// each process across the window from the tier that backs the window, then
    /// joins the process dimension for names. Oldest data is summarised; the
    /// result is the leaderboard, descending.
    public func topConsumers(
        window: HistoryWindow,
        metric: ConsumerMetric = .averageFootprint,
        limit: Int = 20,
        now: Date = Date()
    ) throws -> [ProcessConsumer] {
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        let orderColumn = metric.orderColumn
        switch window.granularity {
        case .raw:
            return try rawConsumers(since: since, orderColumn: orderColumn, limit: limit)
        case .minute:
            return try aggregateConsumers(
                table: "process_minute", since: since,
                orderColumn: orderColumn, limit: limit)
        case .hour:
            return try aggregateConsumers(
                table: "process_hour", since: since,
                orderColumn: orderColumn, limit: limit)
        }
    }

    /// The top energy users over the last `seconds`, averaged from the raw tier.
    /// A short window (e.g. 60s) smooths the per-tick energy-impact jitter so the
    /// Battery tab's flow diagram ranks steadily instead of reshuffling every
    /// tick, while staying live. Always reads raw (the window is well inside the
    /// raw retention span).
    public func topEnergyConsumers(
        lastSeconds: TimeInterval, limit: Int = 8, now: Date = Date()
    ) throws -> [ProcessConsumer] {
        let since = now.addingTimeInterval(-lastSeconds).timeIntervalSince1970
        return try rawConsumers(since: since, orderColumn: "avg_energy", limit: limit)
    }

    /// A `column IN (?,?,…)` fragment with one placeholder per id; empty string
    /// when there are no ids (the caller omits the clause entirely).
    static func inClause(_ column: String, count: Int) -> String {
        guard count > 0 else { return "" }
        return " AND \(column) IN (\(Array(repeating: "?", count: count).joined(separator: ",")))"
    }

    /// Per-process aggregates from the raw tier. When `processIDs` is non-empty
    /// the result is restricted to that set (reused by the group leaderboards);
    /// otherwise it ranks every process.
    func rawConsumers(
        since: Double, orderColumn: String, limit: Int, processIDs: [Int64] = []
    ) throws -> [ProcessConsumer] {
        var args: [any DatabaseValueConvertible] = [since]
        for id in processIDs { args.append(id) }
        args.append(limit)
        // Raw rows are change-gated (sparse), so a plain AVG() would be a
        // sample-mean biased toward the periods a process changed most. Weight
        // each row by `dt` — how long its value held, i.e. until the process's
        // next row (LEAD). The last row per process has no successor, so it takes
        // a nominal 1 s: this both avoids a zero denominator for a single-row
        // process and, crucially, does NOT extend a dead process's last value
        // across the rest of the window (which would inflate its average). `n`
        // stays the honest raw-row COUNT for the "samples" read-out.
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.pid AS pid, p.start_time AS start, p.name AS name, p.bundle_id AS bundle,
                           p.executable_path AS exec_path,
                           p.architecture AS arch, p.is_translated AS translated,
                           CAST(SUM(s.phys_footprint * s.dt) / SUM(s.dt) AS INTEGER) AS avg_fp,
                           MAX(s.phys_footprint) AS max_fp,
                           SUM(s.cpu_percent * s.dt) / SUM(s.dt) AS avg_cpu,
                           SUM(s.energy_impact * s.dt) / SUM(s.dt) AS avg_energy,
                           SUM(s.net_total * s.dt) / SUM(s.dt) AS avg_net,
                           CASE WHEN MAX(s.timestamp) > MIN(s.timestamp)
                                THEN ((MAX(s.disk_read) - MIN(s.disk_read))
                                    + (MAX(s.disk_written) - MIN(s.disk_written)))
                                    / (MAX(s.timestamp) - MIN(s.timestamp))
                                ELSE 0 END AS avg_disk,
                           COUNT(*) AS n
                    FROM (
                        SELECT process_id, timestamp, phys_footprint, cpu_percent, energy_impact,
                               net_total, disk_read, disk_written,
                               COALESCE(
                                 LEAD(timestamp) OVER (PARTITION BY process_id ORDER BY timestamp),
                                 timestamp + 1) - timestamp AS dt
                        FROM process_samples
                        WHERE timestamp >= ? AND footprint_readable = 1\(Self.inClause("process_id", count: processIDs.count))
                    ) s
                    JOIN processes p ON p.id = s.process_id
                    GROUP BY s.process_id
                    ORDER BY \(orderColumn) DESC
                    LIMIT ?
                    """, arguments: StatementArguments(args)
            ).map(Self.decodeConsumer)
        }
    }

    /// Per-process aggregates recombined from a downsampled tier. `processIDs`
    /// optionally restricts the result to a set (the group leaderboards).
    func aggregateConsumers(
        table: String, since: Double, orderColumn: String, limit: Int, processIDs: [Int64] = []
    ) throws -> [ProcessConsumer] {
        var args: [any DatabaseValueConvertible] = [since]
        for id in processIDs { args.append(id) }
        args.append(limit)
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.pid AS pid, p.start_time AS start, p.name AS name, p.bundle_id AS bundle,
                           p.executable_path AS exec_path,
                           p.architecture AS arch, p.is_translated AS translated,
                           CAST(SUM(t.footprint_avg * t.samples) / SUM(t.samples) AS INTEGER) AS avg_fp,
                           MAX(t.footprint_max) AS max_fp,
                           SUM(t.cpu_avg * t.samples) / SUM(t.samples) AS avg_cpu,
                           SUM(t.energy_avg * t.samples) / SUM(t.samples) AS avg_energy,
                           SUM(t.net_avg * t.samples) / SUM(t.samples) AS avg_net,
                           CASE WHEN MAX(t.bucket) > MIN(t.bucket)
                                THEN ((MAX(t.disk_read_max) - MIN(t.disk_read_max))
                                    + (MAX(t.disk_written_max) - MIN(t.disk_written_max)))
                                    / (MAX(t.bucket) - MIN(t.bucket))
                                ELSE 0 END AS avg_disk,
                           SUM(t.samples) AS n
                    FROM \(table) t
                    JOIN processes p ON p.id = t.process_id
                    WHERE t.bucket >= ?\(Self.inClause("t.process_id", count: processIDs.count))
                    GROUP BY t.process_id
                    ORDER BY \(orderColumn) DESC
                    LIMIT ?
                    """, arguments: StatementArguments(args)
            ).map(Self.decodeConsumer)
        }
    }

    /// Positional decode (raw and aggregate SELECTs list the same 14 columns in
    /// the same order), avoiding a name lookup per field per row.
    private static func decodeConsumer(_ row: Row) -> ProcessConsumer {
        let pid: Int32 = row[0]
        let start: Double = row[1]
        let name: String = row[2]
        let bundle: String? = row[3]
        let execPath: String? = row[4]
        let archRaw: String = row[5]
        let translated: Int = row[6]
        return ProcessConsumer(
            identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: start)),
            name: name,
            executablePath: execPath,
            bundleID: bundle,
            architecture: Architecture(rawValue: archRaw) ?? .unknown,
            isTranslated: translated != 0,
            averageFootprint: SQLInt.read(row[7]),
            peakFootprint: SQLInt.read(row[8]),
            averageCPU: row[9],
            averageEnergy: row[10],
            averageNetwork: row[11],
            averageDisk: row[12],
            sampleCount: row[13]
        )
    }
}
