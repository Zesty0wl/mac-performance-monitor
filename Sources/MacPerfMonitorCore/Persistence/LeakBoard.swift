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
        isTranslated: Bool,
        latestFootprint: UInt64,
        finding: LeakDetector.Finding
    ) {
        self.identity = identity
        self.name = name
        self.executablePath = executablePath
        self.isTranslated = isTranslated
        self.latestFootprint = latestFootprint
        self.finding = finding
    }
}

/// Accumulates one process's footprint series as a flat, time-ordered result
/// set is scanned.
private struct SeriesAccumulator {
    var name: String
    var executablePath: String?
    var isTranslated: Bool
    var series: [(Date, UInt64)]
    var latest: UInt64
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

        let (minuteTier, rawTier) = try databasePool.read { db in
            (
                try Self.seriesByIdentity(
                    db,
                    sql: """
                        SELECT p.pid AS pid, p.start_time AS start, p.name AS name, p.is_translated AS translated,
                               p.executable_path AS exec_path,
                               CAST(t.bucket AS REAL) AS ts, t.footprint_avg AS fp
                        FROM process_minute t
                        JOIN processes p ON p.id = t.process_id
                        WHERE t.bucket >= ? AND t.bucket + COALESCE(
                            (SELECT bucket_seconds FROM system_minute WHERE bucket = t.bucket), 60) <= ?
                        ORDER BY ts ASC
                        """, arguments: [minuteSince, now.timeIntervalSince1970]),
                try Self.seriesByIdentity(
                    db,
                    sql: """
                        SELECT p.pid AS pid, p.start_time AS start, p.name AS name, p.is_translated AS translated,
                               p.executable_path AS exec_path,
                               AVG(ps.timestamp) AS ts,
                               CAST(AVG(ps.phys_footprint) AS INTEGER) AS fp
                        FROM process_samples ps
                        JOIN processes p ON p.id = ps.process_id
                        WHERE ps.timestamp >= ? AND ps.timestamp <= ? AND ps.footprint_readable = 1
                        GROUP BY ps.process_id, CAST(ps.timestamp / \(Self.leakBucketSeconds) AS INTEGER)
                        ORDER BY ts ASC
                        """, arguments: [rawSince, now.timeIntervalSince1970])
            )
        }

        // Retained buckets still need sufficient duration and ongoing recent growth.
        var minuteConfig = config
        minuteConfig.minimumSamples = Swift.min(config.minimumSamples, 8)

        var entries: [LeakBoardEntry] = []
        for identity in Set(minuteTier.keys).union(rawTier.keys) {
            guard liveIdentities?.contains(identity) ?? true,
                let latest =
                    (rawTier[identity]?.series.last?.0 ?? minuteTier[identity]?.series.last?.0),
                now.timeIntervalSince(latest) <= max(120, config.maximumGap)
            else { continue }
            // A rejected long trend must not qualify through a shorter window.
            let minute = minuteTier[identity]?.series ?? []
            let hasLongCoverage =
                minute.count >= minuteConfig.minimumSamples
                && (minute.last?.0.timeIntervalSince(minute.first!.0) ?? 0)
                    >= config.minimumDuration
            let finding =
                hasLongCoverage
                ? LeakDetector.analyze(series: minute, config: minuteConfig)
                : rawTier[identity].flatMap {
                    LeakDetector.analyze(series: $0.series, config: config)
                }
            guard let finding, let meta = rawTier[identity] ?? minuteTier[identity] else {
                continue
            }
            entries.append(
                LeakBoardEntry(
                    identity: identity,
                    name: meta.name,
                    executablePath: meta.executablePath,
                    isTranslated: meta.isTranslated,
                    latestFootprint: meta.latest,
                    finding: finding
                ))
        }

        // The bucketed series ends on an averaged value, so replace each
        // flagged entry's "now" figure with its true latest raw sample. Only
        // the flagged few (usually zero) pay this indexed point read.
        for index in entries.indices {
            if let exact = try latestRawFootprint(for: entries[index].identity, through: now) {
                entries[index].latestFootprint = exact
            }
        }
        return entries.sorted { $0.finding.confidence > $1.finding.confidence }
    }

    /// Decode a flat, time-ordered (identity, ts, fp) result set — both tiers'
    /// queries share these column aliases — into per-process series.
    private static func seriesByIdentity(
        _ db: Database, sql: String, arguments: StatementArguments
    ) throws -> [ProcessIdentity: SeriesAccumulator] {
        var acc: [ProcessIdentity: SeriesAccumulator] = [:]
        // Positional decode (both tiers' SELECTs list the same 7 columns in the
        // same order: pid, start, name, translated, exec_path, ts, fp). This scan
        // touches tens of thousands of rows, so reading by index rather than by
        // column name avoids a name lookup per field per row.
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
            let pid: Int32 = row[0]
            let start: Double = row[1]
            let identity = ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: start))
            let ts: Double = row[5]
            let footprint = SQLInt.read(row[6])
            var entry =
                acc[identity]
                ?? SeriesAccumulator(
                    name: row[2], executablePath: row[4],
                    isTranslated: (row[3] as Int) != 0,
                    series: [], latest: 0)
            entry.series.append((Date(timeIntervalSince1970: ts), footprint))
            entry.latest = footprint  // rows are ascending, so the last wins
            acc[identity] = entry
        }
        return acc
    }

    /// The most recent readable raw footprint for one process, or nil when it
    /// has no raw rows.
    private func latestRawFootprint(
        for identity: ProcessIdentity, through date: Date
    ) throws -> UInt64? {
        try databasePool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT ps.phys_footprint AS fp
                    FROM process_samples ps
                    JOIN processes p ON p.id = ps.process_id
                    WHERE p.pid = ? AND p.start_time = ? AND ps.footprint_readable = 1 AND ps.timestamp <= ?
                    ORDER BY ps.timestamp DESC
                    LIMIT 1
                    """,
                arguments: [
                    identity.pid, identity.startTime.timeIntervalSince1970,
                    date.timeIntervalSince1970,
                ]
            ).map { SQLInt.read($0["fp"]) }
        }
    }
}
