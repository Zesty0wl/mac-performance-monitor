import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class SystemHistoryTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-hist-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    /// A fixed anchor on a minute boundary keeps bucket maths predictable.
    private let anchor = Date(timeIntervalSince1970: 1_700_000_040)

    private func insert(at date: Date, pressure: Double = 42) throws {
        try store.insert(systemSample: Make.system(timestamp: date, pressurePercent: pressure))
    }

    func testRawRangeReturnsSamplesAscendingAndWindowed() throws {
        // 40 samples every 6s spanning ~3.9 minutes, plus one old sample.
        for i in 0..<40 {
            try insert(at: anchor.addingTimeInterval(Double(i) * 6))
        }
        try insert(at: anchor.addingTimeInterval(-4000))  // older than an hour

        let now = anchor.addingTimeInterval(240)
        let points = try store.systemHistory(.oneHour, now: now)

        XCTAssertEqual(points.count, 40, "the old sample must be excluded by the 1-hour window")
        let dates = points.map(\.date)
        XCTAssertEqual(dates, dates.sorted(), "points must be ascending by time")
        XCTAssertEqual(points.first?.pressurePercent ?? 0, 42, accuracy: 0.001)
    }

    func testShortRawRangesApplyTheirOwnCutoffs() throws {
        let now = anchor.addingTimeInterval(30 * 60)
        try insert(at: now.addingTimeInterval(-31 * 60), pressure: 10)
        try insert(at: now.addingTimeInterval(-20 * 60), pressure: 20)
        try insert(at: now.addingTimeInterval(-4 * 60), pressure: 40)
        try insert(at: now, pressure: 50)

        let fiveMinutes = try store.systemHistory(.fiveMinutes, now: now)
        let thirtyMinutes = try store.systemHistory(.thirtyMinutes, now: now)

        XCTAssertEqual(fiveMinutes.map(\.pressurePercent), [40, 50])
        XCTAssertEqual(thirtyMinutes.map(\.pressurePercent), [20, 40, 50])
        XCTAssertEqual(fiveMinutes.map(\.date), fiveMinutes.map(\.date).sorted())
        XCTAssertEqual(thirtyMinutes.map(\.date), thirtyMinutes.map(\.date).sorted())
    }

    func testDayRangeReadsMinuteAggregates() throws {
        for i in 0..<40 {
            try insert(at: anchor.addingTimeInterval(Double(i) * 6))
        }
        // Roll raw -> minute well after the sampled minutes are complete.
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))

        let points = try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600))
        XCTAssertGreaterThanOrEqual(points.count, 3, "expected several minute buckets")
        let dates = points.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
        // Constant inputs -> the minute average equals the input.
        XCTAssertEqual(points.first?.pressurePercent ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(points.first?.appMemory, 4 * 1024 * 1024 * 1024)
    }

    func testSevenDayRangeReadsHourAggregates() throws {
        for i in 0..<40 {
            try insert(at: anchor.addingTimeInterval(Double(i) * 6))
        }
        // Roll raw -> minute, then minute -> hour an hour+ later.
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(7200))

        let points = try store.systemHistory(.sevenDays, now: anchor.addingTimeInterval(7200))
        XCTAssertGreaterThanOrEqual(points.count, 1, "expected at least one hour bucket")
        XCTAssertEqual(points.first?.pressurePercent ?? 0, 42, accuracy: 0.001)
    }

    func testGranularityMapping() {
        XCTAssertEqual(
            HistoryWindow.allCases,
            [.fiveMinutes, .thirtyMinutes, .oneHour, .sixHours, .oneDay, .sevenDays])
        XCTAssertEqual(HistoryWindow.fiveMinutes.seconds, 5 * 60)
        XCTAssertEqual(HistoryWindow.thirtyMinutes.seconds, 30 * 60)
        XCTAssertEqual(HistoryWindow.fiveMinutes.label, "5 min")
        XCTAssertEqual(HistoryWindow.thirtyMinutes.label, "30 min")
        XCTAssertEqual(HistoryWindow.fiveMinutes.granularity, .raw)
        XCTAssertEqual(HistoryWindow.thirtyMinutes.granularity, .raw)
        XCTAssertEqual(HistoryWindow.oneHour.granularity, .raw)
        XCTAssertEqual(HistoryWindow.sixHours.granularity, .minute)
        XCTAssertEqual(HistoryWindow.oneDay.granularity, .minute)
        XCTAssertEqual(HistoryWindow.sevenDays.granularity, .hour)
    }

    // MARK: - Tiers carry their peaks and run up to the last raw row

    func testMinuteAggregatesCarryTheBucketPeak() throws {
        try insert(at: anchor.addingTimeInterval(6), pressure: 10)
        try insert(at: anchor.addingTimeInterval(12), pressure: 50)
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))

        let points = try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600))
        let minute = try XCTUnwrap(points.first)
        XCTAssertEqual(minute.pressurePercent, 30, accuracy: 0.001, "the line gets the mean")
        XCTAssertEqual(minute.peaks?.pressurePercent ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(minute.effectivePeaks.pressurePercent, 50, accuracy: 0.001)
    }

    func testLongRangesTopUpFromTheRawRowsPastTheWatermark() throws {
        // Two complete minutes, rolled into the minute tier...
        for i in 0..<20 {
            try insert(at: anchor.addingTimeInterval(Double(i) * 6), pressure: 30)
        }
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(120))
        // ...then raw samples retention has not seen yet.
        try insert(at: anchor.addingTimeInterval(130), pressure: 70)
        try insert(at: anchor.addingTimeInterval(140), pressure: 80)

        let points = try store.systemHistory(.sixHours, now: anchor.addingTimeInterval(150))
        let dates = points.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(dates).count, dates.count, "no row is served twice")
        XCTAssertEqual(points.count, 4, "two minute rows, then the two raw rows after them")
        XCTAssertNotNil(points[0].peaks)
        XCTAssertNotNil(points[1].peaks)
        XCTAssertNil(points[2].peaks, "a raw row has no stored peak")
        XCTAssertEqual(points[2].pressurePercent, 70)
        XCTAssertEqual(points[3].pressurePercent, 80)
        XCTAssertEqual(
            points[2].date.timeIntervalSince(points[1].date), 70, accuracy: 0.001,
            "the raw tail starts at the minute watermark, not inside a rolled minute")
    }

    func testRawSamplesAlreadyRolledUpAreNotServedTwice() throws {
        for i in 0..<10 {
            try insert(at: anchor.addingTimeInterval(Double(i) * 6), pressure: 30)
        }
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(60))
        let points = try store.systemHistory(.sixHours, now: anchor.addingTimeInterval(70))
        XCTAssertEqual(points.count, 1, "the minute row stands in for its ten raw samples")
    }

    func testStoredSpacingPerTier() {
        XCTAssertNil(HistoryWindow.oneHour.granularity.storedSpacing)
        XCTAssertEqual(HistoryWindow.sixHours.granularity.storedSpacing, 60)
        XCTAssertEqual(HistoryWindow.oneDay.granularity.storedSpacing, 60)
        XCTAssertEqual(HistoryWindow.sevenDays.granularity.storedSpacing, 3600)
    }
}
