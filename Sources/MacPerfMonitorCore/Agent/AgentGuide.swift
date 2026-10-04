import Foundation

/// What an AI agent needs to know to use this Mac's history well: the data
/// dictionary, the rules that stop it drawing wrong conclusions, and example
/// queries (each one executed by the tests). Shared by the prompt Ask copies,
/// `mpm schema`, and the MCP server, so there is one description to keep true.
public enum AgentGuide {
    /// The `mpm` executable inside the installed app.
    public static let mpmPath = "/Applications/Mac Performance Monitor.app/Contents/MacOS/mpm"

    public struct Example: Sendable {
        public let title: String
        public let sql: String
    }

    public static let examples: [Example] = [
        Example(
            title: "Busiest apps over the last hour, as a share of the whole Mac",
            sql: """
                SELECT COALESCE(app, name) AS app_or_process, kind,
                    ROUND(SUM(cpu_share_of_mac_percent * resolution_seconds) / 3600.0, 1) AS avg_share_of_mac_percent,
                    ROUND(MAX(memory_peak_mb)) AS peak_memory_mb
                FROM agent_process_usage
                WHERE ts >= strftime('%s', 'now') - 3600
                GROUP BY COALESCE(app, name), kind
                ORDER BY avg_share_of_mac_percent DESC LIMIT 10
                """),
        Example(
            title: "Minute by minute around 10:00 today (local time)",
            sql: """
                SELECT time_local, ROUND(cpu_percent) AS cpu, ROUND(memory_pressure) AS pressure,
                    ROUND(swap_used_gb, 2) AS swap_gb, ROUND(disk_busy_percent) AS disk_busy, thermal_state
                FROM agent_system_by_minute
                WHERE ts BETWEEN strftime('%s', date('now', 'localtime') || ' 09:30:00', 'utc')
                    AND strftime('%s', date('now', 'localtime') || ' 10:30:00', 'utc')
                ORDER BY ts
                """),
        Example(
            title: "Apps whose memory grew the most in the last 24 hours",
            sql: """
                SELECT COALESCE(app, name) AS app_or_process, process_key,
                    ROUND(MIN(memory_mb)) AS lowest_mb, ROUND(MAX(memory_mb)) AS highest_mb,
                    ROUND(MAX(memory_mb) - MIN(memory_mb)) AS grew_mb
                FROM agent_process_usage
                WHERE ts >= strftime('%s', 'now') - 86400
                GROUP BY process_key
                HAVING grew_mb > 100
                ORDER BY grew_mb DESC LIMIT 10
                """),
        Example(
            title: "When memory pressure was high in the last day",
            sql: """
                SELECT time_local, ROUND(memory_pressure) AS pressure, ROUND(memory_pressure_peak) AS peak,
                    ROUND(swap_used_gb, 2) AS swap_gb
                FROM agent_system_by_minute
                WHERE ts >= strftime('%s', 'now') - 86400 AND memory_pressure_peak >= 50
                ORDER BY ts
                """),
        Example(
            title: "What one app did over the last 6 hours",
            sql: """
                SELECT time_local, ROUND(cpu_share_of_mac_percent, 1) AS share_of_mac, ROUND(memory_mb) AS memory_mb,
                    ROUND(energy_impact, 1) AS energy
                FROM agent_process_usage
                WHERE (app = 'Google Chrome' OR name = 'Google Chrome') AND ts >= strftime('%s', 'now') - 21600
                ORDER BY ts
                """),
        Example(
            title: "Programs that stayed busy for hours in the last day (grouped across restarts)",
            sql: """
                SELECT name, kind, COUNT(DISTINCT process_key) AS runs,
                    ROUND(SUM(cpu_percent_of_one_core * resolution_seconds) / 86400.0) AS avg_percent_of_one_core,
                    ROUND(SUM(CASE WHEN cpu_percent_of_one_core >= 25 THEN resolution_seconds END) / 3600.0, 1) AS busy_hours
                FROM agent_process_usage
                WHERE ts >= strftime('%s', 'now', '-1 day')
                GROUP BY name HAVING busy_hours >= 1
                ORDER BY avg_percent_of_one_core DESC LIMIT 10
                """),
    ]

    public static let rules = [
        "Never write to, copy, move or delete the database or anything in its folder. The app owns it; read it only.",
        "Query the agent_* views, not the raw tables. They stitch history together and use plain units.",
        "Always bound queries in time with ts (Unix seconds). For more than a couple of hours use agent_system_by_minute, not agent_system.",
        "NULL means not measured. Never treat it as zero.",
        "For how much of the Mac an app used, use cpu_share_of_mac_percent. cpu_percent_of_one_core can exceed 100.",
        "An app using a small share is not the cause of a slowdown, however high it ranks. Many small processes can add up.",
        "A program that keeps about a core busy for hours (cpu_percent_of_one_core near or above 100 for most minutes) is almost never normal, even when it has become part of this Mac's usual level: check how many days it has done this. Daemons restart, so group by name, not process_key.",
        "Processes with kind = 'macos' are part of macOS. Never suggest quitting them; say they usually settle, and a restart helps if one stays busy for hours.",
        "Memory pressure under 34 is fine, 34 to 66 means macOS is compressing memory, 67 and over means it is swapping and the Mac slows. High memory use alone is not a problem.",
        "Check agent_coverage before concluding nothing happened: the history may not reach back that far.",
        "Show the numbers behind every conclusion, and say when the data cannot answer the question.",
    ]

    /// The current local time with its UTC offset, e.g. 2026-09-30 11:37 (UTC+01:00):
    /// the same local clock the views' *_local columns use.
    static func localNow(_ now: Date = Date(), zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let offset = zone.secondsFromGMT(for: now)
        let sign = offset < 0 ? "-" : "+"
        return formatter.string(from: now)
            + String(format: " (UTC%@%02d:%02d)", sign, abs(offset) / 3600, abs(offset) % 3600 / 60)
    }

    /// Every view and column with its meaning, as Markdown.
    public static var dictionary: String {
        AgentViews.all.map { view in
            "### \(view.name)\n\(view.purpose)\n\n"
                + view.columns.map { "- `\($0.name)`: \($0.detail)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Model, chip and memory, from the system, for the prompt's "This Mac".
    public static func macDescription() -> String {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        let info = ProcessInfo.processInfo
        var lines = [
            "- Chip: \(sysctl("machdep.cpu.brand_string") ?? "Apple silicon"), model \(sysctl("hw.model") ?? "unknown")",
            "- Cores: \(info.processorCount) (\(sysctlInt("hw.perflevel0.logicalcpu") ?? 0) performance, \(sysctlInt("hw.perflevel1.logicalcpu") ?? 0) efficiency)",
            "- Memory: \(info.physicalMemory / 1_073_741_824) GB",
            "- macOS \(info.operatingSystemVersion.majorVersion).\(info.operatingSystemVersion.minorVersion).\(info.operatingSystemVersion.patchVersion)",
        ]
        lines.append("- Now: \(localNow()), time zone \(TimeZone.current.identifier)")
        return lines.joined(separator: "\n")
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    /// The prompt Ask copies for Claude Code, Codex or another agent. `context`
    /// is an Ask question and the facts behind its answer, when there is one.
    public static func prompt(databasePath: String, coverage: String?, context: String?) -> String {
        """
        # Help me investigate my Mac

        I use Mac Performance Monitor, a macOS app that records this Mac's performance history \
        in a local SQLite database. Please use that history to investigate, check your conclusions \
        against the data, and explain what you find in plain English.

        ## This Mac
        \(macDescription())

        \(coverage.map { "History available:\n\($0)\n" } ?? "")
        ## Reading the data

        Prefer the app's own command-line tool. It is read-only, stops long queries, and knows the data:

        ```sh
        MPM="\(mpmPath)"
        "$MPM" schema                      # every view and column, with units
        "$MPM" sql "SELECT ..."            # read-only SQL (add --format csv or json)
        "$MPM" brief processor --last 60   # the app's own judged summary of one part
        "$MPM" brief overall --at 10:00    # around a time today
        "$MPM" find "Chrome"               # recorded runs of an app
        "$MPM" link processor --last 60    # a link that opens the matching charts in the app
        ```

        Parts for `brief` and `link`: overall, processor, memory, graphics, neural-engine, network, \
        storage, battery, heat. Time options: `--last MINUTES`, `--at HH:MM`, or `--from` and `--to` \
        (HH:MM, YYYY-MM-DD HH:MM, or Unix seconds). `--app NAME` adds one app's use.

        If you use sqlite3 instead, open the database read-only only:

        ```sh
        sqlite3 -readonly "file:\(databasePath)?mode=ro"
        ```

        ## Rules
        \(rules.map { "- \($0)" }.joined(separator: "\n"))

        ## Views (version \(AgentViews.version))
        \(dictionary)

        ## Example queries
        \(examples.map { "\($0.title):\n```sql\n\($0.sql)\n```" }.joined(separator: "\n\n"))

        ## What I want to know
        \(context ?? "Start by summarising how this Mac has been doing over the last hour (`\"$MPM\" brief overall --last 60`), then ask me what to look into.")

        When you find something, show the numbers you used and give me a link from `mpm link` \
        so I can see it on a chart in the app.
        """
    }
}

/// Times as agents and people write them.
public enum AgentTime {
    /// "10:30" (today, or yesterday if that is still to come), "2026-09-30 10:30",
    /// ISO 8601, or Unix seconds.
    public static func parse(
        _ text: String, now: Date = Date(), calendar: Calendar = .current
    ) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        let clock = trimmed.split(separator: ":").compactMap { Int($0) }
        if trimmed.count <= 5, clock.count == 2, (0...23).contains(clock[0]),
            (0...59).contains(clock[1])
        {
            guard
                var date = calendar.date(
                    bySettingHour: clock[0], minute: clock[1], second: 0, of: now)
            else {
                return nil
            }
            if date > now { date = calendar.date(byAdding: .day, value: -1, to: date) ?? date }
            return date
        }
        for format in [
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return try? Date(trimmed, strategy: .iso8601)
    }
}

/// `macperfmonitor://explorer?charts=cpu,process.cpu&from=…&to=…&processes=pid:start`
/// opens the main window's Explorer on those charts. Built and parsed in one
/// place so `mpm link`, the MCP server and the app agree.
public enum AgentChartURL {
    public static let scheme = "macperfmonitor"

    public static func url(for link: AskChartLink) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "explorer"
        components.queryItems = [
            URLQueryItem(name: "charts", value: link.laneIDs.joined(separator: ",")),
            URLQueryItem(name: "from", value: String(Int(link.start.timeIntervalSince1970))),
            URLQueryItem(name: "to", value: String(Int(link.end.timeIntervalSince1970))),
        ]
        if !link.processes.isEmpty {
            components.queryItems?.append(
                URLQueryItem(
                    name: "processes",
                    value: link.processes.map {
                        "\($0.pid):\(Int($0.startTime.timeIntervalSince1970))"
                    }
                    .joined(separator: ",")))
        }
        return components.url
    }

    /// A link from outside the app is untrusted: only chart names, a bounded
    /// time range and a few process identities are accepted, and it can only
    /// open Explorer.
    public static func parse(_ url: URL, now: Date = Date()) -> AskChartLink? {
        guard url.scheme == scheme, url.host == "explorer",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let charts = (value("charts") ?? "").split(separator: ",").map(String.init)
            .filter { $0.range(of: "^[A-Za-z0-9.]{1,40}$", options: .regularExpression) != nil }
        guard !charts.isEmpty, charts.count <= 12,
            let from = value("from").flatMap(Double.init),
            let to = value("to").flatMap(Double.init),
            to > from, to - from <= 90 * 86400, from > 1_000_000_000,
            to <= now.timeIntervalSince1970 + 300
        else { return nil }
        let processes = (value("processes") ?? "").split(separator: ",").prefix(4).compactMap {
            pair -> ProcessIdentity? in
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let pid = Int32(parts[0]), let start = Double(parts[1]) else {
                return nil
            }
            return ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: start))
        }
        return AskChartLink(
            title: charts.joined(separator: ", "), laneIDs: charts,
            start: Date(timeIntervalSince1970: from),
            end: Date(timeIntervalSince1970: to), processes: processes)
    }
}
