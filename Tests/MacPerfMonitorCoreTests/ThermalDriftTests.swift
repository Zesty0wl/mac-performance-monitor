import XCTest

@testable import MacPerfMonitorCore

final class ThermalDriftTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    /// `count` hours at the given die temperature and fan speed.
    private func hours(_ count: Int, dieC: Double, rpm: Double) -> [FanTempHour] {
        (0..<count).map {
            FanTempHour(
                date: anchor.addingTimeInterval(Double($0) * 3600), fanRPM: rpm, dieC: dieC)
        }
    }

    func testFiresOnClearSameTemperatureIncrease() throws {
        // Baseline: 2000 rpm to hold 60 C. Recent: 2600 rpm for the same 60 C.
        let finding = ThermalDrift.analyze(
            recent: hours(100, dieC: 60, rpm: 2600),
            baseline: hours(100, dieC: 60, rpm: 2000),
            baselineWeeksAgo: 6)
        let unwrapped = try XCTUnwrap(finding)
        XCTAssertEqual(unwrapped.increaseFraction, 0.3, accuracy: 0.01)
        XCTAssertEqual(unwrapped.increaseRPM, 600, accuracy: 1)
        XCTAssertEqual(unwrapped.baselineWeeksAgo, 6)
    }

    func testQuietOnSmallIncrease() {
        XCTAssertNil(
            ThermalDrift.analyze(
                recent: hours(100, dieC: 60, rpm: 2200),
                baseline: hours(100, dieC: 60, rpm: 2000),
                baselineWeeksAgo: 6))
    }

    /// A busier month runs hotter AND faster; matched-band comparison must not
    /// read that as drift. Recent hours are at a higher temperature band whose
    /// baseline rpm was proportionally higher too.
    func testWorkloadShiftIsNotDrift() {
        let baseline = hours(60, dieC: 55, rpm: 1800) + hours(60, dieC: 70, rpm: 3500)
        let recent = hours(30, dieC: 55, rpm: 1800) + hours(90, dieC: 70, rpm: 3500)
        XCTAssertNil(
            ThermalDrift.analyze(recent: recent, baseline: baseline, baselineWeeksAgo: 6))
    }

    func testQuietWithoutEnoughHours() {
        XCTAssertNil(
            ThermalDrift.analyze(
                recent: hours(20, dieC: 60, rpm: 2600),
                baseline: hours(100, dieC: 60, rpm: 2000),
                baselineWeeksAgo: 6))
        XCTAssertNil(
            ThermalDrift.analyze(
                recent: hours(100, dieC: 60, rpm: 2600),
                baseline: hours(20, dieC: 60, rpm: 2000),
                baselineWeeksAgo: 6))
    }

    /// Fans-off baselines carry no airflow information: ratios against near
    /// zero are noise, and MacBook Air has no fans at all.
    func testQuietWhenBaselineFansWereOff() {
        XCTAssertNil(
            ThermalDrift.analyze(
                recent: hours(100, dieC: 45, rpm: 400),
                baseline: hours(100, dieC: 45, rpm: 0),
                baselineWeeksAgo: 6))
    }

    /// Non-overlapping temperature bands (a winter/summer ambient shift) have
    /// nothing to compare and must stay quiet.
    func testQuietWithoutOverlappingBands() {
        XCTAssertNil(
            ThermalDrift.analyze(
                recent: hours(100, dieC: 75, rpm: 4000),
                baseline: hours(100, dieC: 50, rpm: 1500),
                baselineWeeksAgo: 6))
    }

    func testInsightCardIsAdvisoryAndWorded() throws {
        let insights = InsightEngine.insights(
            InsightEngine.Inputs(
                totalRAM: 16 << 30,
                currentPressure: .normal,
                systemHistory: [],
                leaks: [],
                events: [],
                consumers: [],
                consumerSeries: [:],
                rosetta: RosettaCost(processCount: 0, totalFootprint: 0),
                thermalDrift: ThermalDrift.Finding(
                    increaseFraction: 0.3, increaseRPM: 600, baselineWeeksAgo: 6)))
        let card = insights.first { $0.kind == .thermalDrift }
        let unwrapped = try XCTUnwrap(card)
        XCTAssertEqual(unwrapped.severity, .advisory)
        XCTAssertEqual(unwrapped.metricText, "+30%")
        XCTAssertTrue(unwrapped.detail.contains("6 weeks"))
    }

    // MARK: - Store query

    func testFanTempHoursReadsHourTier() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-drift-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
        }
        let store = try SampleStore(url: tempURL)
        for i in 0..<40 {
            var sample = Make.system(
                timestamp: anchor.addingTimeInterval(Double(i) * 6), pressurePercent: 10)
            sample.cpuDieC = 55
            sample.fanRPM = 2000
            try store.insert(systemSample: sample)
        }
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(7200))

        let rows = try store.fanTempHours(
            from: anchor.addingTimeInterval(-3600), to: anchor.addingTimeInterval(7200))
        XCTAssertGreaterThanOrEqual(rows.count, 1)
        XCTAssertEqual(rows[0].dieC, 55, accuracy: 0.001)
        XCTAssertEqual(rows[0].fanRPM, 2000, accuracy: 0.001)
    }
}
