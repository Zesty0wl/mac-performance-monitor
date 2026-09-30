import GRDB
import XCTest

@testable import MacPerfMonitorCore

/// The agent views are a contract: their columns are described to AI agents,
/// so a column that changes without its description changing is a bug.
final class AgentViewsTests: XCTestCase {
    private var url: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-views-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: url)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    func testEveryViewMatchesItsDocumentedColumns() throws {
        try store.databasePool.read { db in
            for view in AgentViews.all {
                let actual = try String.fetchAll(
                    db, sql: "SELECT name FROM pragma_table_info(?)", arguments: [view.name])
                XCTAssertEqual(
                    actual, view.columns.map(\.name),
                    "\(view.name) columns differ from their descriptions")
                XCTAssertFalse(view.columns.contains { $0.detail.isEmpty }, view.name)
                _ = try Row.fetchAll(db, sql: "SELECT * FROM \(view.name) LIMIT 1")
            }
        }
    }

    func testSystemViewUsesTheFinestTierWithoutOverlap() throws {
        let now = Date()
        for step in stride(from: 3 * 3600.0, through: 0, by: -10) {
            var sample = Make.system(timestamp: now.addingTimeInterval(-step), pressurePercent: 20)
            sample.cpuLoad = 0.5
            try store.insert(systemSample: sample)
        }
        try Retention.run(store.databasePool, now: now)
        try store.databasePool.read { db in
            let rawStart = try XCTUnwrap(
                Double.fetchOne(db, sql: "SELECT MIN(timestamp) FROM system_samples"))
            let overlapping =
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM agent_system WHERE resolution_seconds > 1 AND ts >= ?",
                    arguments: [rawStart]) ?? -1
            XCTAssertEqual(
                overlapping, 0, "a summary row repeats a moment the live rows already cover")
            let cpu = try XCTUnwrap(
                Double.fetchOne(db, sql: "SELECT AVG(cpu_percent) FROM agent_system"))
            XCTAssertEqual(cpu, 50, accuracy: 0.5, "CPU is 0 to 100, not a fraction")
            let minutes =
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_system_by_minute") ?? 0
            XCTAssertGreaterThan(minutes, 100)
        }
    }

    func testProcessViewsClassifyAndShareTheMac() throws {
        try store.databasePool.write { db in
            try AgentViews.recordMacFacts(
                db, cpuCores: 10, performanceCores: 6, efficiencyCores: 4, memoryBytes: 18 << 30)
        }
        let now = Date()
        let paths: [(key: String, value: String)] = [
            (
                "Renderer",
                "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
            ),
            ("contactsd", "/System/Library/Frameworks/Contacts.framework/Support/contactsd"),
            ("node", "/opt/homebrew/bin/node"),
        ]
        for step in stride(from: 1800.0, through: 0, by: -5) {
            let time = now.addingTimeInterval(-step)
            let processes = paths.enumerated().map { index, entry -> ProcessSample in
                var process = Make.process(
                    timestamp: time, pid: Int32(100 + index),
                    startTime: now.addingTimeInterval(-4000),
                    name: entry.key, cpu: 50)
                process.executablePath = entry.value
                return process
            }
            try store.insert(Make.system(timestamp: time), processes: processes)
        }
        try Retention.run(store.databasePool, now: now)
        try store.databasePool.read { db in
            let kinds = try Row.fetchAll(
                db, sql: "SELECT name, app, kind FROM agent_processes ORDER BY pid")
            XCTAssertEqual(kinds.map { $0["kind"] as String }, ["app", "macos", "background"])
            XCTAssertEqual(kinds[0]["app"] as String?, "Google Chrome")
            XCTAssertNil(kinds[2]["app"] as String?)
            let share = try XCTUnwrap(
                Double.fetchOne(
                    db,
                    sql:
                        "SELECT AVG(cpu_share_of_mac_percent) FROM agent_process_usage WHERE name = 'node'"
                ))
            XCTAssertEqual(
                share, 5, accuracy: 0.5, "50% of one core on a 10-core Mac is 5% of the Mac")
            let facts = try Row.fetchAll(db, sql: "SELECT fact, value FROM agent_mac ORDER BY fact")
            XCTAssertTrue(
                facts.contains {
                    ($0["fact"] as String) == "cpu_cores" && ($0["value"] as Double) == 10
                })
        }
    }
}
