import Foundation
import GRDB

extension SampleStore {
    /// The system history a set of briefs shares: the period itself and the
    /// week before it. Read once per request, not once per area.
    public func askHistory(start: Date, end: Date) throws -> AskHistory {
        let tier = try askTier(start: start, end: end)
        return AskHistory(
            points: try systemHistory(from: start, to: end, granularity: tier)
                .filter {
                    $0.date >= start.addingTimeInterval(-$0.bucketDuration) && $0.date <= end
                },
            baseline: try systemHistory(
                from: start.addingTimeInterval(-7 * 86400), to: start, granularity: .hour),
            tier: tier)
    }

    /// Reads everything one area's brief needs from recorded history. Fixed,
    /// bounded queries only; nothing here is driven by model output except the
    /// optional app name, which is matched as plain text. Ranking apps is the
    /// costly part (hundreds of thousands of rows an hour on a busy Mac), so
    /// callers that only need a status, like the start page, skip it.
    public func askInputs(
        area: AskArea, start: Date, end: Date, now: Date, appName: String? = nil,
        history: AskHistory? = nil, includeApps: Bool = true
    ) throws -> AskBriefInputs {
        var input = AskBriefInputs(area: area, start: start, end: end, now: now)
        let history = try history ?? askHistory(start: start, end: end)
        input.points = history.points
        input.baseline = history.baseline
        if includeApps, area.rankedColumn != nil {
            // Rank from the per-minute tier whenever the period allows: raw
            // process rows are written only on change, so a short-lived
            // process (each compiler run of a build) is under-counted there,
            // while the minute roll-up weights every row by the time it held.
            let tier: HistoryWindow.Granularity =
                history.tier == .hour
                ? .hour : end.timeIntervalSince(start) >= 600 ? .minute : history.tier
            // Fresh recordings have no minute roll-up yet: fall back to raw.
            func rank(limit: Int, name: String? = nil) throws -> [AskAppUsage] {
                let ranked = try askTopApps(
                    area: area, start: start, end: end, tier: tier, limit: limit, nameFilter: name)
                guard ranked.isEmpty, tier == .minute, history.tier == .raw else { return ranked }
                return try askTopApps(
                    area: area, start: start, end: end, tier: .raw, limit: limit, nameFilter: name)
            }
            input.apps = try rank(limit: 10)
            if let appName {
                input.focusName = appName
                input.focus = try rank(limit: 2, name: appName)
            }
        }
        if area == .memory {
            let span = min(2 * 3600, max(1800, end.timeIntervalSince(start)))
            input.growth = try leakBoard(window: span, now: end).map {
                let kind = AskProcessKind.classify(path: $0.executablePath)
                return AskGrowth(
                    identity: $0.identity, name: $0.displayName,
                    growthBytes: $0.finding.totalGrowth,
                    durationSeconds: $0.finding.durationSeconds, kind: kind.kind, owner: kind.app)
            }
        }
        return input
    }

    /// When recording began, across every tier.
    public func askEarliestRecord() throws -> Date? {
        try databasePool.read { db in
            let values = try [
                "SELECT MIN(timestamp) FROM system_samples",
                "SELECT MIN(bucket) FROM system_minute",
                "SELECT MIN(bucket) FROM system_hour",
            ].compactMap { try Double.fetchOne(db, sql: $0) }
            return values.min().map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// The finest tier that holds the whole period, coarsened for long spans so
    /// a week never reads every raw row.
    func askTier(start: Date, end: Date) throws -> HistoryWindow.Granularity {
        var tier = try finestGranularityCovering(from: start, to: end)
        let span = end.timeIntervalSince(start)
        if span > 2 * 86400 {
            tier = .hour
        } else if span > 3 * 3600, tier == .raw {
            tier = .minute
        }
        return tier
    }

    /// Apps ranked by their average use of the area's resource. Processor,
    /// graphics, network and energy average over the whole period, so an app
    /// that ran flat out for two minutes does not outrank one busy all hour.
    /// Memory averages over the time the app was open. Disk is the bytes it
    /// read and wrote, spread over the period.
    func askTopApps(
        area: AskArea, start: Date, end: Date, tier: HistoryWindow.Granularity, limit: Int,
        nameFilter: String? = nil
    ) throws -> [AskAppUsage] {
        guard let column = area.rankedColumn else { return [] }
        let window = max(1, end.timeIntervalSince(start))
        var arguments: [any DatabaseValueConvertible] = []
        let sql: String
        let bucketSeconds: Double = tier == .hour ? 3600 : 60
        switch (tier, column) {
        case (.raw, .disk):
            sql = """
                SELECT s.process_id AS id,
                    ((MAX(s.disk_read) - MIN(s.disk_read)) + (MAX(s.disk_written) - MIN(s.disk_written))) / ? AS score
                FROM process_samples s WHERE s.timestamp >= ? AND s.timestamp <= ?
                GROUP BY s.process_id
                """
            arguments = [window, start.timeIntervalSince1970, end.timeIntervalSince1970]
        case (.raw, .value(let raw, _, let overWindow)):
            let average =
                overWindow
                ? "SUM(v * dt) / ?" : "SUM(v * dt) / SUM(CASE WHEN v IS NOT NULL THEN dt END)"
            sql = """
                SELECT id, \(average) AS score FROM (
                    SELECT process_id AS id, (\(raw)) AS v,
                        COALESCE(LEAD(timestamp) OVER (PARTITION BY process_id ORDER BY timestamp),
                            timestamp + 1) - timestamp AS dt
                    FROM process_samples WHERE timestamp >= ? AND timestamp <= ?
                ) GROUP BY id
                """
            if overWindow { arguments.append(window) }
            arguments += [start.timeIntervalSince1970, end.timeIntervalSince1970]
        case (_, .disk):
            let table = tier == .hour ? "process_hour" : "process_minute"
            sql = """
                SELECT process_id AS id,
                    ((MAX(disk_read_max) - MIN(disk_read_max)) + (MAX(disk_written_max) - MIN(disk_written_max))) / ? AS score
                FROM \(table) WHERE bucket >= ? AND bucket <= ? GROUP BY process_id
                """
            arguments = [window, start.timeIntervalSince1970, end.timeIntervalSince1970]
        case (_, .value(_, let aggregate, let overWindow)):
            let table = tier == .hour ? "process_hour" : "process_minute"
            let average =
                overWindow
                ? "SUM(\(aggregate)) * \(bucketSeconds) / ?"
                : "SUM(\(aggregate) * samples) / SUM(samples)"
            sql = """
                SELECT process_id AS id, \(average) AS score
                FROM \(table) WHERE bucket >= ? AND bucket <= ? GROUP BY process_id
                """
            if overWindow { arguments.append(window) }
            arguments += [start.timeIntervalSince1970, end.timeIntervalSince1970]
        }
        var filter = ""
        if let nameFilter {
            let escaped = nameFilter.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(
                    of: "_", with: "\\_")
            filter =
                " AND (p.name LIKE ? ESCAPE '\\' OR p.executable_path LIKE ? ESCAPE '\\' OR p.bundle_id LIKE ? ESCAPE '\\')"
            arguments += Array(repeating: "%\(escaped)%", count: 3)
        }
        arguments.append(limit)
        // One row per app: a build's dozens of short-lived compiler processes
        // are Xcode's work, and Chrome's helpers are Chrome's. The app's share
        // is the sum of its processes; the busiest one stands for it on charts.
        let who = "COALESCE(\(AgentViews.appName("p.executable_path")), p.name)"
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    WITH named AS (
                        SELECT \(who) AS who, p.pid AS pid, p.start_time AS start, p.name AS name,
                            p.executable_path AS path, ranked.score AS score
                        FROM (\(sql)) ranked JOIN processes p ON p.id = ranked.id
                        WHERE ranked.score IS NOT NULL AND ranked.score > 0\(filter)
                    )
                    SELECT who, pid, start, name, path, MAX(score) AS top, SUM(score) AS score
                    FROM named GROUP BY who ORDER BY score DESC LIMIT ?
                    """, arguments: StatementArguments(arguments)
            ).map { row in
                let path: String? = row["path"]
                let kind = AskProcessKind.classify(path: path)
                let name =
                    kind.app
                    ?? ProcessSample.resolvedDisplayName(name: row["name"], executablePath: path)
                return AskAppUsage(
                    identity: ProcessIdentity(
                        pid: row["pid"], startTime: Date(timeIntervalSince1970: row["start"])),
                    name: name, average: row["score"], kind: kind.kind, owner: kind.app)
            }
        }
    }
}

/// System history shared by the briefs of one request.
public struct AskHistory: Sendable {
    public var points: [SystemHistoryPoint]
    public var baseline: [SystemHistoryPoint]
    public var tier: HistoryWindow.Granularity
}

/// Which stored per-process column ranks the apps for an area.
enum AskRankedColumn {
    /// Raw column expression, aggregate column, and whether the average is over
    /// the whole period (true) or the app's own open time (false).
    case value(raw: String, aggregate: String, overWindow: Bool)
    case disk
}

extension AskArea {
    var rankedColumn: AskRankedColumn? {
        switch self {
        case .overall, .neuralEngine, .heat: return nil
        case .processor: return .value(raw: "cpu_percent", aggregate: "cpu_avg", overWindow: true)
        case .memory:
            // Over the whole period too: an app's memory is the sum of its
            // processes weighted by how long each ran, so a build's hundreds of
            // brief compiler runs do not add up as if they ran at once.
            return .value(
                raw: "CASE WHEN footprint_readable = 1 THEN phys_footprint END",
                aggregate: "footprint_avg",
                overWindow: true)
        case .graphics: return .value(raw: "gpu_percent", aggregate: "gpu_avg", overWindow: true)
        case .network: return .value(raw: "net_total", aggregate: "net_avg", overWindow: true)
        case .energy: return .value(raw: "energy_impact", aggregate: "energy_avg", overWindow: true)
        case .storage: return .disk
        }
    }
}
