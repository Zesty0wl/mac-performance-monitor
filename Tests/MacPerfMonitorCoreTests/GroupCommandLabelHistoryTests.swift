import GRDB
import XCTest

@testable import MacPerfMonitorCore

/// History membership reads the stored command label, so a group defined by
/// the script an interpreter runs covers its past runs too.
final class GroupCommandLabelHistoryTests: XCTestCase {
    private var url: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("group-label-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: url)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    func testGroupMemberIDsResolvesByCommandLabel() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let runs: [(pid: Int32, label: String)] = [
            (1000, "train.py"), (2000, "http.server"), (3000, "train.py"),
        ]
        var samples: [ProcessSample] = []
        for run in runs {
            var sample = Make.process(timestamp: base, pid: run.pid, name: "python3")
            sample.commandLabel = run.label
            samples.append(sample)
        }
        try store.insert(Make.system(timestamp: base), processes: samples)

        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .commandLabel, value: "train.py")),
            window: .oneHour, glossary: nil, now: base)
        let pids = try store.databasePool.read { database in
            try ids.compactMap { id in
                try Int32.fetchOne(
                    database, sql: "SELECT pid FROM processes WHERE id = ?", arguments: [id])
            }
        }
        XCTAssertEqual(Set(pids), [1000, 3000])
    }
}
