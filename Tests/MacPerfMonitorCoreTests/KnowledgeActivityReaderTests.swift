import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class KnowledgeActivityReaderTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var database: DatabaseQueue!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macperfmonitor-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("activity.sqlite")
        database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE ZOBJECT (
                        ZSTREAMNAME TEXT, ZVALUESTRING TEXT, ZSTARTDATE REAL, ZENDDATE REAL
                    )
                    """)
        }
    }

    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func insert(
        _ stream: String = "/app/usage", bundle: String = "com.example.App",
        from: Double, to: Double
    ) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO ZOBJECT VALUES (?, ?, ?, ?)",
                arguments: [
                    stream, bundle, base.addingTimeInterval(from).timeIntervalSinceReferenceDate,
                    base.addingTimeInterval(to).timeIntervalSinceReferenceDate,
                ])
        }
    }

    func testReadsOnlySelectedAppStreamsAndConvertsReferenceDates() throws {
        try insert(from: -10, to: 20)
        try insert(from: 10, to: 30)
        try insert("/app/mediaUsage", from: 50, to: 120)
        try insert(bundle: "com.example.Other", from: 30, to: 90)
        try insert("/app/intents", from: 30, to: 90)
        try insert(from: 150, to: 200)
        try insert(from: 70, to: 60)
        try insert(from: 40, to: 40)

        let intervals = try KnowledgeActivityReader.read(
            bundleID: "com.example.App", within: base...base.addingTimeInterval(100), url: url)

        XCTAssertEqual(
            intervals,
            [
                .init(kind: .appUsage, start: base, end: base.addingTimeInterval(30)),
                .init(
                    kind: .mediaUsage, start: base.addingTimeInterval(50),
                    end: base.addingTimeInterval(100)),
            ])
    }

    func testReadDoesNotChangeDatabaseAndBundleIsBoundAsData() throws {
        try insert(from: 0, to: 60)
        let before = try Data(contentsOf: url)
        let range = base...base.addingTimeInterval(100)

        XCTAssertEqual(
            try KnowledgeActivityReader.read(bundleID: "com.example.App", within: range, url: url)
                .count, 1)
        XCTAssertTrue(
            try KnowledgeActivityReader.read(
                bundleID: "com.example.App' OR 1=1 --", within: range, url: url
            ).isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testMissingFileIsNotCreated() {
        let missing = directory.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(
            try KnowledgeActivityReader.read(
                bundleID: "com.example.App", within: base...base.addingTimeInterval(100),
                url: missing)
        ) { error in
            XCTAssertEqual(error as? KnowledgeActivityReader.ReadError, .notFound)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testUnsupportedSchemaFailsWithoutAttemptingMigration() throws {
        try database.write { db in
            try db.execute(sql: "ALTER TABLE ZOBJECT RENAME COLUMN ZENDDATE TO unsupported")
        }
        XCTAssertThrowsError(
            try KnowledgeActivityReader.read(
                bundleID: "com.example.App", within: base...base.addingTimeInterval(100), url: url)
        ) { error in
            XCTAssertEqual(error as? KnowledgeActivityReader.ReadError, .unsupportedSchema)
        }
    }

    func testReadsCommittedWALRecordsWithoutCheckpointing() throws {
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0")
        }
        try insert(from: 0, to: 60)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let before = try Data(contentsOf: wal)
        let intervals = try KnowledgeActivityReader.read(
            bundleID: "com.example.App", within: base...base.addingTimeInterval(100), url: url)

        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(try Data(contentsOf: wal), before)
    }

    func testRecordLimitDoesNotReturnSilentlyTruncatedHistory() throws {
        try database.write { db in
            try db.execute(
                sql: """
                    WITH RECURSIVE numbers(value) AS (
                        SELECT 1 UNION ALL SELECT value + 1 FROM numbers WHERE value < 20001
                    )
                    INSERT INTO ZOBJECT
                    SELECT '/app/usage', 'com.example.App', ?, ? FROM numbers
                    """,
                arguments: [
                    base.timeIntervalSinceReferenceDate,
                    base.addingTimeInterval(60).timeIntervalSinceReferenceDate,
                ])
        }
        XCTAssertThrowsError(
            try KnowledgeActivityReader.read(
                bundleID: "com.example.App", within: base...base.addingTimeInterval(100), url: url)
        ) { error in
            XCTAssertEqual(error as? KnowledgeActivityReader.ReadError, .tooManyRecords)
        }
    }
}
