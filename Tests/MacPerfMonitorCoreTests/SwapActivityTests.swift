import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class SwapActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_400)

    func testRatesUseActualElapsedTimeAndRejectResetsAndGaps() throws {
        var tracker = SwapActivityTracker()
        XCTAssertNil(tracker.sample(at: start, pagesIn: 100, pagesOut: 200, pageSize: 16384))
        let next = try XCTUnwrap(
            tracker.sample(
                at: start.addingTimeInterval(2), pagesIn: 120, pagesOut: 210, pageSize: 16384))
        XCTAssertEqual(next.rateIn, 20 * 16384 / 2)
        XCTAssertEqual(next.rateOut, 10 * 16384 / 2)
        XCTAssertNil(
            tracker.sample(
                at: start.addingTimeInterval(3), pagesIn: 0, pagesOut: 0, pageSize: 16384))
        XCTAssertNil(
            tracker.sample(
                at: start.addingTimeInterval(1000), pagesIn: 100, pagesOut: 100, pageSize: 16384))
    }

    func testSwapEvidenceRoundTripsAndRollsUpWithKnownCoverageOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SampleStore(url: root.appendingPathComponent("history.sqlite"))
        for (offset, rate, elapsed) in [(0.0, 100.0, 2.0), (10, 300, 10), (20, -1, 0)] {
            var sample = Make.system(timestamp: start.addingTimeInterval(offset))
            sample.swapSampleValid = rate >= 0
            sample.pressureSampleValid = true
            sample.swapInBytesPerSecond = rate >= 0 ? rate : nil
            sample.swapOutBytesPerSecond = rate >= 0 ? rate * 2 : nil
            sample.memorySampleInterval = rate >= 0 ? elapsed : nil
            sample.memoryPageSize = 16384
            sample.swapInPagesDelta = rate >= 0 ? 42 : nil
            try store.insert(systemSample: sample)
        }
        try store.databasePool.read { db in
            let row = try XCTUnwrap(
                Row.fetchOne(db, sql: "SELECT * FROM system_samples ORDER BY timestamp LIMIT 1"))
            let decoded = SampleStore.decodeSystem(row)
            XCTAssertEqual(decoded.swapInPagesDelta, 42)
            XCTAssertEqual(decoded.swapInBytesPerSecond, 100)
            XCTAssertEqual(decoded.swapSampleValid, true)
        }
        try Retention.run(store.databasePool, now: start.addingTimeInterval(7200))
        try store.databasePool.read { db in
            for table in ["system_minute", "system_hour"] {
                let row = try XCTUnwrap(
                    Row.fetchOne(db, sql: "SELECT * FROM \(table) ORDER BY bucket LIMIT 1"))
                XCTAssertEqual(
                    try XCTUnwrap(row["swap_in_avg"] as Double?), 3200 / 12, accuracy: 0.001)
                XCTAssertEqual(row["swap_activity_seconds"] as Double?, 12)
                XCTAssertEqual(row["swap_out_max"] as Double?, 600)
            }
        }
    }
}
