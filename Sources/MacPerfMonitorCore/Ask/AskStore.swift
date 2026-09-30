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
        // Cheap enough for the overview tiles too, which skip app ranking: a
        // program stuck busy for hours is the thing the tile must not miss.
        if area == .processor || area == .overall {
            input.sustained = try askSustained(end: end)
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

    /// The recorded runs a link from outside the app names. Links carry start
    /// times to the second (agents round them too), while runs are stored to
    /// the microsecond, so each pid:start resolves to that pid's run starting
    /// within a second of it. Unknown runs are dropped.
    public func askResolve(_ identities: [ProcessIdentity]) throws -> [ProcessIdentity] {
        try databasePool.read { db in
            try identities.compactMap { identity in
                let start = identity.startTime.timeIntervalSince1970
                return try Double.fetchOne(
                    db,
                    sql: """
                        SELECT start_time FROM processes
                        WHERE pid = ? AND start_time BETWEEN ? AND ?
                        ORDER BY ABS(start_time - ?) LIMIT 1
                        """, arguments: [identity.pid, start - 1, start + 1, start]
                ).map {
                    ProcessIdentity(pid: identity.pid, startTime: Date(timeIntervalSince1970: $0))
                }
            }
        }
    }

    /// Programs busy for an hour or more when the period ends, busiest first.
    /// Replays each candidate's recorded minutes (up to a day back) through
    /// the same spell rules as the live alert, following it by executable
    /// across restarts.
    public func askSustained(end: Date, limit: Int = 3) throws -> [AskSustained] {
        let key = SustainedCPU.keySQL
        let hourStart = end.addingTimeInterval(-SustainedCPU.minimumSpell).timeIntervalSince1970
        let dayStart = end.addingTimeInterval(-86400).timeIntervalSince1970
        let endTime = end.timeIntervalSince1970
        return try databasePool.read { db in
            let candidates = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(key) AS program, SUM(m.cpu_avg) / 60.0 AS average
                    FROM process_minute m JOIN processes p ON p.id = m.process_id
                    WHERE m.bucket >= ? AND m.bucket < ?
                    GROUP BY program HAVING average >= ?
                    ORDER BY average DESC LIMIT 8
                    """,
                arguments: [hourStart, endTime, SustainedCPU.flagPercent * SustainedCPU.busyShare])
            var found: [AskSustained] = []
            for candidate in candidates {
                let program: String = candidate["program"]
                let runs = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, pid, start_time, name, executable_path FROM processes p
                        WHERE \(key) = ? AND last_seen >= ? AND first_seen < ?
                        """, arguments: [program, dayStart, endTime])
                guard
                    let newest = runs.max(by: { ($0["start_time"] as Double) < $1["start_time"] }),
                    !SustainedCPU.exempt.contains(newest["name"] as String)
                else { continue }
                let ids = runs.map { $0["id"] as Int64 }
                let minutes = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT bucket, SUM(cpu_avg) AS cpu FROM process_minute
                        WHERE process_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                            AND bucket >= ? AND bucket < ?
                        GROUP BY bucket
                        """,
                    arguments: StatementArguments(
                        ids.map { $0 as DatabaseValueConvertible } + [dayStart, endTime]))
                var byMinute: [Int64: Double] = [:]
                for row in minutes { byMinute[Int64((row["bucket"] as Double) / 60)] = row["cpu"] }
                // Every minute of the day, silent ones as zero, so a daemon
                // between runs counts as quiet rather than as a gap.
                let first = Int64(dayStart / 60)
                let last = Int64((endTime - 1) / 60)
                guard first <= last else { continue }
                let series = (first...last).map {
                    (Date(timeIntervalSince1970: Double($0 * 60 + 60)), byMinute[$0] ?? 0)
                }
                guard let spell = SustainedSpell.current(in: series), spell.isSustained,
                    end.timeIntervalSince(spell.lastBusy) <= SustainedCPU.quietGap
                else { continue }
                let path: String? = newest["executable_path"]
                let kind = AskProcessKind.classify(path: path)
                found.append(
                    AskSustained(
                        name: ProcessSample.resolvedDisplayName(
                            name: newest["name"], executablePath: path),
                        identity: ProcessIdentity(
                            pid: newest["pid"],
                            startTime: Date(timeIntervalSince1970: newest["start_time"])),
                        kind: kind.kind, owner: kind.app,
                        since: spell.since, end: spell.last, average: spell.average))
                if found.count == limit { break }
            }
            return found.sorted { $0.average > $1.average }
        }
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
                    SELECT who, pid, start, name, path, total AS score FROM (
                        SELECT *, SUM(score) OVER (PARTITION BY who) AS total,
                            ROW_NUMBER() OVER (PARTITION BY who ORDER BY score DESC, start DESC) AS place
                        FROM named
                    ) WHERE place = 1 ORDER BY total DESC LIMIT ?
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
