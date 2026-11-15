import Foundation
import GRDB

/// One row of the leak board: a process whose footprint trends steadily upward,
/// with the `LeakDetector` finding that flagged it (PRD section 8.5).
public struct LeakBoardEntry: Sendable, Identifiable, Equatable {
    public var identity: ProcessIdentity
    public var name: String
    public var executablePath: String?
    public var isTranslated: Bool
    /// The most recent footprint in the analysed window (bytes).
    public var latestFootprint: UInt64
    /// The growth finding that flagged this process.
    public var finding: LeakDetector.Finding
    /// What an interpreter was running (`CommandLabel`), as recorded.
    public var commandLabel: String?

    public var id: ProcessIdentity { identity }

    /// The full name to show, recovering a kernel-truncated `p_comm` from the
    /// executable path just as the live process list does.
    public var displayName: String {
        ProcessSample.resolvedDisplayName(name: name, executablePath: executablePath)
    }

    /// `displayName` with the script an interpreter ran: "python3 · train.py".
    public var labeledName: String {
        ProcessSample.labeledName(displayName, commandLabel: commandLabel)
    }

    public init(
        identity: ProcessIdentity,
        name: String,
        executablePath: String? = nil,
        isTranslated: Bool,
        latestFootprint: UInt64,
        finding: LeakDetector.Finding,
        commandLabel: String? = nil
    ) {
        self.identity = identity
        self.name = name
        self.executablePath = executablePath
        self.isTranslated = isTranslated
        self.latestFootprint = latestFootprint
        self.finding = finding
        self.commandLabel = commandLabel
    }
}

extension SampleStore {
    /// Seconds per fast-path analysis bucket: the raw 2-second series is
    /// averaged into these buckets in SQL before the detector sees it.
    /// Each point uses its bucket's mean timestamp and recorded footprint mean.
    static let leakBucketSeconds = 30.0

    /// How far back the raw fast path looks. Long enough to satisfy the
    /// detector's 20-minute duration floor with margin — so a process that has
    /// raw samples but not yet a full set of minute buckets (the current minute
    /// isn't rolled up) can still be judged — yet short enough that the
    /// per-minute scan touches a bounded slice of the raw tier.
    static let leakRawWindow: TimeInterval = 30 * 60

    /// Run the leak detector across every process with history in the window,
    /// returning those flagged for sustained growth, most-confident first.
    ///
    /// The scan is two-tier, because it runs about once a minute for the life
    /// of the app and a full-resolution scan of the 2-hour raw tier (~180k
    /// rows at 50 processes) dominated the app's own CPU and heap churn:
    ///  - established leaks read the minute aggregates across the whole window
    ///    (~120 rows per process), and
    ///  - fresh leaks — too young to have enough minute buckets — read only
    ///    the last `leakRawWindow` of raw samples, averaged into 30-second
    ///    buckets in SQL. Both paths use the detector's duration and freshness gates.
    public func leakBoard(
        window: TimeInterval = 2 * 3600,
        config: LeakDetector.Config = .default,
        now: Date = Date(),
        liveIdentities: Set<ProcessIdentity>? = nil
    ) throws -> [LeakBoardEntry] {
        let minuteSince = now.addingTimeInterval(-min(window, 2 * 3600)).timeIntervalSince1970
        let rawSince = now.addingTimeInterval(-Self.leakRawWindow).timeIntervalSince1970

        var minuteConfig = config
        minuteConfig.minimumSamples = Swift.min(config.minimumSamples, 8)
        let end = now.timeIntervalSince1970
        return try databasePool.read { db in
            let minuteStatement = try db.makeStatement(
                sql: """
                    SELECT t.bucket, t.footprint_avg FROM process_minute t
                    WHERE t.process_id = ? AND t.bucket >= ? AND t.bucket + COALESCE(
                        (SELECT bucket_seconds FROM system_minute WHERE bucket = t.bucket), 60) <= ?
                    ORDER BY t.bucket
                    """)
            let rawStatement = try db.makeStatement(
                sql: """
                    SELECT AVG(timestamp), CAST(AVG(phys_footprint) AS INTEGER)
                    FROM process_samples
                    WHERE process_id = ? AND timestamp >= ? AND timestamp <= ? AND footprint_readable = 1
                    GROUP BY CAST(timestamp / \(Self.leakBucketSeconds) AS INTEGER)
                    ORDER BY AVG(timestamp)
                    """)
            let latestStatement = try db.makeStatement(
                sql: """
                    SELECT timestamp, phys_footprint FROM process_samples
                    WHERE process_id = ? AND timestamp <= ? AND footprint_readable = 1
                    ORDER BY timestamp DESC LIMIT 1
                    """)
            let freshnessStatement = try db.makeStatement(
                sql: """
                    SELECT AVG(timestamp) FROM process_samples
                    WHERE process_id = ? AND timestamp >= ? AND timestamp <= ? AND footprint_readable = 1
                    """)
            var entries: [LeakBoardEntry] = []
            func inspect(_ process: Row) throws {
                let id: Int64 = process["id"]
                let minute = try Self.leakSeries(
                    minuteStatement, arguments: [id, minuteSince, end])
                let latestRaw = try Row.fetchOne(latestStatement, arguments: [id, end])
                let latestRawTime: Double? = latestRaw?[0]
                var latest = minute.last?.0.timeIntervalSince1970
                if let latestRawTime, latestRawTime >= rawSince {
                    // Preserve the original last-bucket mean timestamp freshness gate.
                    let tail = max(
                        rawSince,
                        floor(latestRawTime / Self.leakBucketSeconds) * Self.leakBucketSeconds)
                    latest = try Double.fetchOne(freshnessStatement, arguments: [id, tail, end])
                }
                guard let latest, end - latest <= max(120, config.maximumGap) else { return }
                let hasLongCoverage =
                    minute.count >= minuteConfig.minimumSamples
                    && (minute.last?.0.timeIntervalSince(minute.first!.0) ?? 0)
                        >= config.minimumDuration
                let series: [(Date, UInt64)]
                let detectorConfig: LeakDetector.Config
                if hasLongCoverage {
                    series = minute
                    detectorConfig = minuteConfig
                } else {
                    series = try Self.leakSeries(rawStatement, arguments: [id, rawSince, end])
                    detectorConfig = config
                }
                guard let finding = LeakDetector.analyze(series: series, config: detectorConfig),
                    let last = series.last
                else { return }
                let footprint: Int64? = latestRaw?[1]
                entries.append(
                    LeakBoardEntry(
                        identity: ProcessIdentity(
                            pid: process["pid"],
                            startTime: Date(timeIntervalSince1970: process["start_time"])),
                        name: process["name"], executablePath: process["executable_path"],
                        isTranslated: (process["is_translated"] as Int) != 0,
                        latestFootprint: footprint.map(SQLInt.read) ?? last.1,
                        finding: finding, commandLabel: process["command_label"]))
            }
            if let liveIdentities {
                // Indexed identity lookups avoid reading exited processes' series at all.
                let processStatement = try db.makeStatement(
                    sql: "SELECT * FROM processes WHERE pid = ? AND start_time = ?")
                for identity in liveIdentities {
                    if let row = try Row.fetchOne(
                        processStatement,
                        arguments: [identity.pid, identity.startTime.timeIntervalSince1970])
                    {
                        try inspect(row)
                    }
                }
            } else {
                let processes = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT p.* FROM processes p JOIN (
                            SELECT process_id FROM process_minute WHERE bucket >= ? AND bucket <= ?
                            UNION
                            SELECT process_id FROM process_samples WHERE timestamp >= ? AND timestamp <= ?
                                AND footprint_readable = 1
                        ) recent ON recent.process_id = p.id
                        """, arguments: [minuteSince, end, rawSince, end])
                while let row = try processes.next() { try inspect(row) }
            }
            return entries.sorted {
                if $0.finding.confidence != $1.finding.confidence {
                    return $0.finding.confidence > $1.finding.confidence
                }
                if $0.identity.pid != $1.identity.pid { return $0.identity.pid < $1.identity.pid }
                return $0.identity.startTime < $1.identity.startTime
            }
        }
    }

    private static func leakSeries(
        _ statement: Statement, arguments: StatementArguments
    ) throws -> [(Date, UInt64)] {
        var series: [(Date, UInt64)] = []
        let rows = try Row.fetchCursor(statement, arguments: arguments)
        while let row = try rows.next() {
            series.append((Date(timeIntervalSince1970: row[0]), SQLInt.read(row[1])))
        }
        return series
    }
}
