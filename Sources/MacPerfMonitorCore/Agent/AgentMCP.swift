import Foundation

extension AskArea {
    /// Accepts the names people and agents use: "cpu", "neural-engine", "disk".
    public init?(agentName: String) {
        switch agentName.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "overall", "mac", "all": self = .overall
        case "processor", "cpu": self = .processor
        case "memory", "ram": self = .memory
        case "graphics", "gpu": self = .graphics
        case "neural-engine", "neuralengine", "ane", "npu": self = .neuralEngine
        case "network", "net", "internet": self = .network
        case "storage", "disk", "ssd": self = .storage
        case "battery", "energy", "power": self = .energy
        case "heat", "thermal", "temperature", "fan": self = .heat
        default: return nil
        }
    }

    public static let agentNames = [
        "overall", "processor", "memory", "graphics", "neural-engine", "network", "storage",
        "battery", "heat",
    ]
}

/// A period from the options `mpm` and the MCP tools share.
public enum AgentWindow {
    public enum Failure: LocalizedError {
        case badTime(String)
        public var errorDescription: String? {
            switch self {
            case .badTime(let text):
                return
                    "Could not read the time \"\(text)\". Use HH:MM, YYYY-MM-DD HH:MM, ISO 8601 or Unix seconds."
            }
        }
    }

    public static func resolve(
        minutesBack: Int?, from: String?, to: String?, at: String?, now: Date = Date(),
        earliest: Date? = nil
    ) throws -> DateInterval {
        if let at {
            guard let anchor = AgentTime.parse(at, now: now) else { throw Failure.badTime(at) }
            let start = anchor.addingTimeInterval(-1800)
            return DateInterval(
                start: start,
                end: min(now, max(start.addingTimeInterval(300), anchor.addingTimeInterval(1800))))
        }
        if from != nil || to != nil {
            let end =
                try to.map { text -> Date in
                    guard let date = AgentTime.parse(text, now: now) else {
                        throw Failure.badTime(text)
                    }
                    return date
                } ?? now
            let start =
                try from.map { text -> Date in
                    guard let date = AgentTime.parse(text, now: now) else {
                        throw Failure.badTime(text)
                    }
                    return date
                } ?? end.addingTimeInterval(-3600)
            return DateInterval(start: min(start, end.addingTimeInterval(-300)), end: min(end, now))
        }
        return AskTimeSpec.recent(minutes: minutesBack ?? 60).interval(now: now, earliest: earliest)
    }
}

/// The MCP server `mpm mcp` runs: JSON-RPC 2.0, one message per line on
/// stdin/stdout, read-only tools over `AgentStore`. It never writes and never
/// opens anything itself; chart links are returned for the person to open.
public final class AgentMCPServer {
    public static let serverName = "mac-performance-monitor"
    private let store: () throws -> AgentStore
    private lazy var opened: Result<AgentStore, Error> = Result { try store() }
    private let version: String

    public init(version: String, store: @escaping () throws -> AgentStore) {
        self.version = version
        self.store = store
    }

    /// Handles one line; returns the reply line, or nil for a notification.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return encode([
                "jsonrpc": "2.0", "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error"],
            ])
        }
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return reply(
                id,
                [
                    "protocolVersion": requested ?? "2025-06-18",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": Self.serverName, "version": version],
                    "instructions": """
                    Read-only access to this Mac's performance history recorded by Mac Performance Monitor. \
                    Call describe_data first. Prefer summarize for a judged overview of a part of the Mac, \
                    then query for detail. Always bound queries in time.
                    """,
                ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return reply(
                    id,
                    [
                        "content": [["type": "text", "text": try call(name, arguments)]],
                        "isError": false,
                    ])
            } catch {
                return reply(
                    id,
                    [
                        "content": [["type": "text", "text": error.localizedDescription]],
                        "isError": true,
                    ])
            }
        default:
            return encode([
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32601, "message": "Method not found: \(method)"],
            ])
        }
    }

    // MARK: Tools

    private static let timeProperties: [String: Any] = [
        "minutes_back": [
            "type": "integer", "description": "Look back this many minutes from now (default 60).",
        ],
        "from": [
            "type": "string",
            "description":
                "Start: HH:MM (local, today), YYYY-MM-DD HH:MM, ISO 8601 or Unix seconds.",
        ],
        "to": ["type": "string", "description": "End, same formats. Defaults to now."],
        "at": [
            "type": "string", "description": "Half an hour either side of this time, e.g. 10:00.",
        ],
    ]

    static let tools: [[String: Any]] = [
        [
            "name": "describe_data",
            "description":
                "How this Mac's history is stored: the agent_* views and their columns with units, rules for reading them correctly, example queries, what history exists, and the Mac's core counts and memory. Call this first.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "query",
            "description":
                "Run one read-only SQL SELECT against the history. Use the agent_* views and always filter on ts (Unix seconds). Results are capped.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sql": [
                        "type": "string",
                        "description": "A single SELECT, WITH or EXPLAIN statement.",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Most rows to return (default 200, at most 2000).",
                    ],
                    "format": ["type": "string", "enum": ["table", "csv", "json"]],
                ],
                "required": ["sql"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "summarize",
            "description":
                "The app's own judged summary of a part of the Mac over a period: status (calm, busy, worth a look, needs attention), what is normal for this Mac, apps responsible, notable events, what is not known, safe next steps, and a chart link.",
            "inputSchema": [
                "type": "object",
                "properties": timeProperties.merging(
                    [
                        "part": ["type": "string", "enum": AskArea.agentNames],
                        "app": ["type": "string", "description": "Also report this app's use."],
                    ], uniquingKeysWith: { first, _ in first }),
                "required": ["part"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "find_process",
            "description":
                "Find recorded runs of an app or process by name, app, bundle ID or path. Returns process_key values for agent_process_usage.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "chart_link",
            "description":
                "A macperfmonitor:// link that opens the app's Explorer on the charts for a part of the Mac over a period, with its busiest apps selected. Give it to the person to click.",
            "inputSchema": [
                "type": "object",
                "properties": timeProperties.merging(
                    ["part": ["type": "string", "enum": AskArea.agentNames]],
                    uniquingKeysWith: { first, _ in first }),
                "required": ["part"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
    ]

    private func call(_ name: String, _ arguments: [String: Any]) throws -> String {
        let store = try opened.get()
        func window() throws -> DateInterval {
            try AgentWindow.resolve(
                minutesBack: (arguments["minutes_back"] as? NSNumber)?.intValue,
                from: arguments["from"] as? String,
                to: arguments["to"] as? String, at: arguments["at"] as? String,
                earliest: try store.earliestRecord())
        }
        switch name {
        case "describe_data":
            return Self.describe(store)
        case "query":
            guard let sql = arguments["sql"] as? String else { return "Missing sql." }
            let limit = min((arguments["limit"] as? NSNumber)?.intValue ?? 200, 2000)
            return try store.query(sql, limit: limit).render(
                as: arguments["format"] as? String ?? "table")
        case "summarize":
            guard let area = AskArea(agentName: arguments["part"] as? String ?? "") else {
                return "Unknown part. Use one of: \(AskArea.agentNames.joined(separator: ", "))."
            }
            let briefs = try store.briefs(
                areas: [area], interval: try window(), appName: arguments["app"] as? String)
            return Self.render(briefs)
        case "find_process":
            return try store.findProcesses(arguments["name"] as? String ?? "").render(as: "table")
        case "chart_link":
            guard let area = AskArea(agentName: arguments["part"] as? String ?? "") else {
                return "Unknown part. Use one of: \(AskArea.agentNames.joined(separator: ", "))."
            }
            let briefs = try store.briefs(areas: [area], interval: try window())
            let links = briefs.compactMap(\.chart).compactMap(AgentChartURL.url(for:)).map(
                \.absoluteString)
            return links.isEmpty ? "No chart for that part." : links.joined(separator: "\n")
        default:
            return "Unknown tool \(name)."
        }
    }

    public static func describe(_ store: AgentStore) -> String {
        var text =
            "# Mac Performance Monitor history\n\n## This Mac\n\(AgentGuide.macDescription())\n"
        if let facts = try? store.macFacts(), !facts.isEmpty {
            text +=
                facts.sorted { $0.key < $1.key }.map { "- \($0.key): \(Int($0.value))" }.joined(
                    separator: "\n") + "\n"
        }
        if let coverage = try? store.coverage() {
            text += "\n## History available\n\(coverage.render(as: "table"))\n"
        }
        text += "\n## Rules\n" + AgentGuide.rules.map { "- \($0)" }.joined(separator: "\n")
        text += "\n\n## Views (version \(AgentViews.version))\n\(AgentGuide.dictionary)"
        text +=
            "\n\n## Example queries\n"
            + AgentGuide.examples.map { "\($0.title):\n```sql\n\($0.sql)\n```" }.joined(
                separator: "\n\n")
        return text
    }

    /// Briefs as text for an agent: the same facts the model in Ask reads,
    /// plus each chart link.
    public static func render(_ briefs: [AreaBrief]) -> String {
        guard let first = briefs.first else { return "No summary." }
        var text =
            "Period: \(first.start.formatted(date: .abbreviated, time: .shortened)) to "
            + "\(first.end.formatted(date: .omitted, time: .shortened))\n\n"
        text += briefs.map { brief in
            brief.promptText
                + (brief.chart.flatMap(AgentChartURL.url(for:)).map {
                    "\nChart: \($0.absoluteString)"
                } ?? "")
        }.joined(separator: "\n\n")
        return text
    }

    private func reply(_ id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.withoutEscapingSlashes])
        else {
            return
                #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding failed"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
