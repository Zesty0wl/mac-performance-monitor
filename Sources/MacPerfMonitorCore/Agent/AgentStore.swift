import Foundation
import GRDB

/// Read-only access to the app's history for AI agents, used by `mpm` and its
/// MCP server. It never writes: the file is opened read-only, `query_only` is
/// on, and only a single SELECT, WITH or EXPLAIN statement is accepted, which
/// SQLite itself must confirm is read-only. Every query is bounded in rows and
/// time, because a long read holds back the app's own WAL checkpoint.
public final class AgentStore {
    public enum Failure: LocalizedError {
        case noDatabase(String)
        case notReadOnly
        case timedOut(Double)

        public var errorDescription: String? {
            switch self {
            case .noDatabase(let path):
                return
                    "No Mac Performance Monitor history at \(path). Is the app installed and recording?"
            case .notReadOnly:
                return "Only a single read-only SELECT (or WITH, or EXPLAIN) statement is allowed."
            case .timedOut(let seconds):
                return
                    "The query took longer than \(Int(seconds)) seconds and was stopped. Narrow the time range or use agent_system_by_minute."
            }
        }
    }

    public struct Table: Sendable {
        public var columns: [String]
        public var rows: [[String?]]
        public var truncated: Bool
    }

    public let url: URL
    public let pool: DatabasePool
    public let store: SampleStore

    public init(url: URL = MacPerfMonitorDatabase.defaultURL()) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.noDatabase(url.path)
        }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try AgentViews.install(db, temporary: true)
            try db.execute(sql: "PRAGMA query_only = ON")
        }
        self.url = url
        pool = try DatabasePool(path: url.path, configuration: config)
        store = SampleStore(pool: pool)
    }

    // MARK: SQL

    private static let refused = [
        "attach", "detach", "vacuum", "pragma", "load_extension", "reindex", "analyze",
    ]

    /// Runs one read-only statement. Rows are capped at `limit` (at most
    /// 10,000); values come back as text, NULL as nil.
    public func query(_ sql: String, limit: Int = 500, timeout: TimeInterval = 20) throws -> Table {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let lower = trimmed.lowercased()
        guard ["select", "with", "explain"].contains(where: { lower.hasPrefix($0) }),
            !trimmed.contains(";"),
            !Self.refused.contains(where: {
                lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
            })
        else { throw Failure.notReadOnly }
        let cap = min(max(1, limit), 10_000)
        let timer = DispatchWorkItem { [pool] in pool.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        do {
            return try pool.read { db in
                let statement = try db.makeStatement(sql: trimmed)
                guard statement.isReadonly else { throw Failure.notReadOnly }
                let cursor = try Row.fetchCursor(statement)
                var rows: [[String?]] = []
                var truncated = false
                while let row = try cursor.next() {
                    if rows.count == cap {
                        truncated = true
                        break
                    }
                    rows.append(row.databaseValues.map(Self.text))
                }
                return Table(columns: statement.columnNames, rows: rows, truncated: truncated)
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
            throw Failure.timedOut(timeout)
        }
    }

    private static func text(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .null: return nil
        case .int64(let int): return String(int)
        case .double(let double):
            if double.rounded() == double && abs(double) < 1e15 { return String(Int64(double)) }
            // Keep timestamps and large totals whole-number exact; small
            // values keep four significant digits.
            guard abs(double) >= 1000 else { return String(format: "%.4g", double) }
            var text = String(format: "%.3f", double)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text
        case .string(let string): return string
        case .blob(let data): return "<\(data.count) bytes>"
        }
    }

    // MARK: Briefs

    /// The same judged summaries Ask builds, for an agent to start from.
    public func briefs(
        areas: [AskArea], interval: DateInterval, appName: String? = nil, now: Date = Date()
    )
        throws -> [AreaBrief]
    {
        let facts = try macFacts()
        let history = try store.askHistory(start: interval.start, end: interval.end)
        func build(_ area: AskArea) throws -> AreaBrief {
            var input = try store.askInputs(
                area: area, start: interval.start, end: interval.end, now: now, appName: appName,
                history: history)
            input.coreCount = Int(
                facts["cpu_cores"] ?? Double(ProcessInfo.processInfo.activeProcessorCount))
            input.hasBattery = history.points.contains { $0.batteryCharge > 0 }
            return AskBriefBuilder.brief(input)
        }
        guard areas.contains(.overall) else { return try areas.map(build) }
        let parts = try AskArea.parts.map(build)
        let standouts = parts.filter { $0.status >= .busy }.sorted { $0.status > $1.status }.prefix(
            2)
        return [AskBriefBuilder.overall(parts, start: interval.start, end: interval.end)]
            + standouts
    }

    public func earliestRecord() throws -> Date? { try store.askEarliestRecord() }

    /// Recorded runs whose name, app, bundle or path contains `text`.
    public func findProcesses(_ text: String, limit: Int = 20) throws -> Table {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT process_key, pid, name, app, kind, started_local, last_seen_local
                    FROM agent_processes
                    WHERE name LIKE ?1 ESCAPE '\\' OR app LIKE ?1 ESCAPE '\\'
                        OR bundle_id LIKE ?1 ESCAPE '\\' OR executable_path LIKE ?1 ESCAPE '\\'
                    ORDER BY last_seen_ts DESC LIMIT ?2
                    """, arguments: ["%\(escaped)%", min(max(1, limit), 200)])
            let columns = [
                "process_key", "pid", "name", "app", "kind", "started_local", "last_seen_local",
            ]
            return Table(
                columns: columns,
                rows: rows.map { row in columns.map { Self.text(row[$0] as DatabaseValue) } },
                truncated: false)
        }
    }

    public func macFacts() throws -> [String: Double] {
        try pool.read { db in
            Dictionary(
                try Row.fetchAll(db, sql: "SELECT fact, value FROM agent_mac").map {
                    ($0["fact"] as String, $0["value"] as Double)
                }, uniquingKeysWith: { first, _ in first })
        }
    }

    public func coverage() throws -> Table { try query("SELECT * FROM agent_coverage") }
}

extension AgentStore.Table {
    /// Aligned text for a terminal, or CSV/JSON for a program.
    public func render(as format: String) -> String {
        switch format {
        case "csv":
            func csv(_ value: String?) -> String {
                guard let value else { return "" }
                return value.contains(where: { ",\"\n".contains($0) })
                    ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }
            return
                ([columns.map(csv).joined(separator: ",")]
                + rows.map { $0.map(csv).joined(separator: ",") })
                .joined(separator: "\n") + (truncated ? "\n# truncated" : "")
        case "json":
            let objects = rows.map { row in
                Dictionary(uniqueKeysWithValues: zip(columns, row.map { $0 as Any? ?? NSNull() }))
            }
            let payload: [String: Any] = [
                "columns": columns, "rows": objects, "truncated": truncated,
            ]
            let data =
                (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                ?? Data()
            return String(decoding: data, as: UTF8.self)
        default:
            let widths = columns.indices.map { index in
                min(
                    40,
                    max(columns[index].count, rows.map { ($0[index] ?? "NULL").count }.max() ?? 0))
            }
            func line(_ values: [String]) -> String {
                zip(values, widths).map { value, width in
                    let clipped =
                        value.count > width ? String(value.prefix(width - 1)) + "…" : value
                    return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
                }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
            }
            var lines = [line(columns), line(widths.map { String(repeating: "-", count: $0) })]
            lines += rows.map { line($0.map { $0 ?? "NULL" }) }
            if truncated {
                lines.append("(more rows not shown; add a LIMIT or narrow the time range)")
            }
            return lines.joined(separator: "\n")
        }
    }
}
