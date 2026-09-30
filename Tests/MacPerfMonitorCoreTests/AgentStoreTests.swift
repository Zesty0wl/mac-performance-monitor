import GRDB
import XCTest

@testable import MacPerfMonitorCore

/// `mpm` and the MCP server hand this to AI agents, so it must be impossible
/// to write through, and bounded however badly a query is written.
final class AgentStoreTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-store-\(UUID().uuidString).sqlite")
        let writer = try SampleStore(url: url)
        let now = Date()
        for step in stride(from: 1200.0, through: 0, by: -10) {
            var sample = Make.system(timestamp: now.addingTimeInterval(-step), pressurePercent: 20)
            sample.cpuLoad = 0.4
            try writer.insert(
                sample,
                processes: [
                    Make.process(timestamp: now.addingTimeInterval(-step), name: "Xcode", cpu: 80)
                ])
        }
        try writer.databasePool.write {
            try AgentViews.recordMacFacts(
                $0, cpuCores: 8, performanceCores: 4, efficiencyCores: 4, memoryBytes: 1 << 34)
        }
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    func testReadsThroughTheViews() throws {
        let agent = try AgentStore(url: url)
        let table = try agent.query("SELECT ROUND(AVG(cpu_percent)) AS cpu FROM agent_system")
        XCTAssertEqual(table.columns, ["cpu"])
        XCTAssertEqual(table.rows.first?.first, "40")
        XCTAssertEqual(try agent.macFacts()["cpu_cores"], 8)
        XCTAssertEqual(try agent.findProcesses("xco").rows.first?[2], "Xcode")
        XCTAssertTrue(try agent.render(agent.coverage(), "table").contains("live"))
    }

    func testRefusesEveryWayToWrite() throws {
        let agent = try AgentStore(url: url)
        for sql in [
            "DELETE FROM system_samples", "UPDATE meta SET value = 0", "DROP TABLE meta",
            "SELECT 1; DELETE FROM meta", "ATTACH DATABASE '/tmp/x.sqlite' AS x", "VACUUM",
            "PRAGMA journal_mode = DELETE", "INSERT INTO meta VALUES ('a', 1)",
            "WITH x AS (SELECT 1) DELETE FROM meta", "CREATE TABLE t (a)",
        ] {
            XCTAssertThrowsError(try agent.query(sql), sql)
        }
        let rows = try SampleStore(url: url).databasePool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM system_samples")
        }
        XCTAssertEqual(rows, 121, "nothing was changed")
    }

    func testCapsRowsAndStopsRunawayQueries() throws {
        let agent = try AgentStore(url: url)
        let capped = try agent.query("SELECT * FROM agent_system", limit: 5)
        XCTAssertEqual(capped.rows.count, 5)
        XCTAssertTrue(capped.truncated)
        let started = Date()
        XCTAssertThrowsError(
            try agent.query(
                "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT COUNT(*) FROM n",
                timeout: 0.5)
        ) { error in
            guard case AgentStore.Failure.timedOut = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testBuildsTheSameBriefsAsAsk() throws {
        let agent = try AgentStore(url: url)
        let now = Date()
        let briefs = try agent.briefs(
            areas: [.processor],
            interval: DateInterval(start: now.addingTimeInterval(-900), end: now), now: now)
        XCTAssertEqual(briefs.first?.area, .processor)
        XCTAssertTrue(briefs.first?.headline.contains("40%") ?? false, briefs.first?.headline ?? "")
        XCTAssertEqual(briefs.first?.apps.first?.name, "Xcode")
    }
}

extension AgentStore {
    fileprivate func render(_ table: Table, _ format: String) -> String { table.render(as: format) }
}

/// The agent-facing surface: the examples we teach, the MCP protocol, links.
final class AgentSurfaceTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-surface-\(UUID().uuidString).sqlite")
        let writer = try SampleStore(url: url)
        let now = Date()
        for step in stride(from: 1800.0, through: 0, by: -10) {
            var sample = Make.system(timestamp: now.addingTimeInterval(-step), pressurePercent: 30)
            sample.cpuLoad = 0.3
            try writer.insert(
                sample,
                processes: [
                    Make.process(
                        timestamp: now.addingTimeInterval(-step),
                        startTime: Date(timeIntervalSince1970: 1_790_000_000.718),
                        name: "Google Chrome", cpu: 40)
                ])
        }
        try Retention.run(writer.databasePool, now: now)
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    func testEveryTaughtExampleRuns() throws {
        let agent = try AgentStore(url: url)
        for example in AgentGuide.examples {
            XCTAssertNoThrow(try agent.query(example.sql), example.title)
        }
        let busiest = try agent.query(AgentGuide.examples[0].sql)
        XCTAssertEqual(busiest.rows.first?.first, "Google Chrome")
    }

    func testMCPServerSpeaksTheProtocol() throws {
        let server = AgentMCPServer(version: "test") { [url] in try AgentStore(url: url!) }
        func call(_ json: String) throws -> [String: Any] {
            let reply = try XCTUnwrap(server.handle(json))
            return try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        }
        let initialize = try call(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        )
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))

        let tools = try XCTUnwrap(
            (try call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["result"]
                as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(
            tools.compactMap { $0["name"] as? String },
            ["describe_data", "query", "summarize", "find_process", "chart_link"])

        let query = try call(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query","arguments":{"sql":"SELECT COUNT(*) AS n FROM agent_system"}}}"#
        )
        let content = try XCTUnwrap(
            (query["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let count =
            (content.first?["text"] as? String ?? "").split(separator: "\n").last.flatMap {
                Int($0)
            } ?? 0
        XCTAssertGreaterThan(count, 150, "rows from the stitched view")

        let refused = try call(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query","arguments":{"sql":"DELETE FROM meta"}}}"#
        )
        XCTAssertEqual((refused["result"] as? [String: Any])?["isError"] as? Bool, true)

        let summary = try call(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"summarize","arguments":{"part":"cpu","minutes_back":30}}}"#
        )
        let text =
            (((summary["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"]
                as? String) ?? ""
        XCTAssertTrue(text.contains("## Processor"), text)
        XCTAssertTrue(text.contains("macperfmonitor://explorer"), text)

        let unknown = try call(#"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testChartLinksRoundTripAndRejectAnythingElse() throws {
        let now = Date()
        let link = AskChartLink(
            title: "Memory", laneIDs: ["pressure", "process.footprint"],
            start: now.addingTimeInterval(-3600),
            end: now,
            processes: [
                ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 1_790_000_000))
            ])
        let url = try XCTUnwrap(AgentChartURL.url(for: link))
        let parsed = try XCTUnwrap(AgentChartURL.parse(url, now: now))
        XCTAssertEqual(parsed.laneIDs, link.laneIDs)
        XCTAssertEqual(parsed.processes, link.processes)
        XCTAssertEqual(
            parsed.start.timeIntervalSince1970, link.start.timeIntervalSince1970, accuracy: 1)

        for bad in [
            "macperfmonitor://settings?x=1", "https://explorer?charts=cpu&from=1&to=2",
            "macperfmonitor://explorer?charts=cpu;drop&from=1790000000&to=1790003600",
            "macperfmonitor://explorer?charts=cpu&from=1790003600&to=1790000000",
            "macperfmonitor://explorer?charts=cpu&from=1000000001&to=1790000000",
        ] {
            XCTAssertNil(AgentChartURL.parse(URL(string: bad)!, now: now), bad)
        }
    }

    func testLinkProcessesResolveToTheirRecordedRun() throws {
        let store = try SampleStore(url: url)
        let run = try XCTUnwrap(
            try store.databasePool.read { db in
                try Row.fetchOne(db, sql: "SELECT pid, start_time FROM processes LIMIT 1")
            })
        let exact: Double = run["start_time"]
        XCTAssertNotEqual(exact.rounded(.down), exact, "the fixture start time carries a fraction")
        let rounded = ProcessIdentity(
            pid: run["pid"], startTime: Date(timeIntervalSince1970: exact.rounded(.down)))
        let missing = ProcessIdentity(pid: 99_999, startTime: Date(timeIntervalSince1970: exact))
        let resolved = try store.askResolve([rounded, missing])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.startTime.timeIntervalSince1970, exact)
    }

    func testPromptStatesLocalTimeWithItsOffset() {
        let now = Date(timeIntervalSince1970: 1_790_764_640)  // 10:37:20 UTC
        let london = TimeZone(identifier: "Europe/London")!
        XCTAssertEqual(AgentGuide.localNow(now, zone: london), "2026-09-30 11:37 (UTC+01:00)")
    }

    func testTimesAndPartNamesAsAgentsWriteThem() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 11))!
        XCTAssertEqual(
            calendar.component(
                .hour, from: AgentTime.parse("10:15", now: now, calendar: calendar)!), 10)
        XCTAssertEqual(
            calendar.component(.day, from: AgentTime.parse("14:00", now: now, calendar: calendar)!),
            29)
        XCTAssertNotNil(AgentTime.parse("2026-09-29 18:30", now: now, calendar: calendar))
        XCTAssertNotNil(AgentTime.parse("1790000000", now: now))
        XCTAssertNil(AgentTime.parse("teatime", now: now))
        XCTAssertEqual(AskArea(agentName: "cpu"), .processor)
        XCTAssertEqual(AskArea(agentName: "neural-engine"), .neuralEngine)
        XCTAssertEqual(AskArea(agentName: "battery"), .energy)
        XCTAssertNil(AskArea(agentName: "toaster"))
    }
}
