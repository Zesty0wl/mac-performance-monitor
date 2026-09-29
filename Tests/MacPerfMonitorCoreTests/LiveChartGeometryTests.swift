import XCTest

@testable import MacPerfMonitorCore

final class LiveChartGeometryTests: XCTestCase {
    func testOneSecondAdvancesOneHourChartByOneThreeThousandSixHundredth() throws {
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedPoint = latest.addingTimeInterval(-1800)
        let before = try XCTUnwrap(
            LiveChartGeometry.trailingDomain(latest: latest, span: 3600))
        let after = try XCTUnwrap(
            LiveChartGeometry.trailingDomain(
                latest: latest.addingTimeInterval(1), span: 3600))

        XCTAssertEqual(before.upperBound.timeIntervalSince(before.lowerBound), 3600)
        XCTAssertEqual(after.upperBound.timeIntervalSince(after.lowerBound), 3600)
        XCTAssertEqual(
            LiveChartGeometry.normalizedX(fixedPoint, in: before)
                - LiveChartGeometry.normalizedX(fixedPoint, in: after),
            1.0 / 3600.0,
            accuracy: 1e-12)
    }

    func testEveryNewRingSampleMovesExistingPointsLeftByOneSlot() {
        let capacity = 900
        let before = LiveChartGeometry.normalizedSlot(
            index: 49, count: 100, capacity: capacity)
        let afterAppend = LiveChartGeometry.normalizedSlot(
            index: 49, count: 101, capacity: capacity)
        XCTAssertEqual(before - afterAppend, 1.0 / 900.0, accuracy: 1e-12)

        let beforeWrap = LiveChartGeometry.normalizedSlot(
            index: 1, count: capacity, capacity: capacity)
        let afterWrap = LiveChartGeometry.normalizedSlot(
            index: 0, count: capacity, capacity: capacity)
        XCTAssertEqual(beforeWrap - afterWrap, 1.0 / 900.0, accuracy: 1e-12)
    }

    func testNiceCeilingSnapsUpToTheLadder() {
        XCTAssertEqual(LiveChartGeometry.niceCeiling(0), 1)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(-5), 1)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(.nan), 1)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(1), 1)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(1.05), 1.2)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(2.1), 2.5)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(7), 8)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(9.5), 10)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(1_300_000_000), 1_500_000_000)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(0.042), 0.05, accuracy: 1e-12)
        // The data always fills at least ~75% of the plot.
        for v in stride(from: 1.0, through: 1000.0, by: 7.3) {
            let top = LiveChartGeometry.niceCeiling(v)
            XCTAssertGreaterThanOrEqual(top, v)
            XCTAssertGreaterThanOrEqual(v / top, 0.74, "value \(v) top \(top)")
        }
    }

    func testOutlierCeilingIgnoresASingleSpike() {
        // An hour of a process at 20 to 60% CPU with one 352% burst.
        var peaks = (0..<360).map { 20 + Double($0 % 41) }
        peaks[200] = 352
        let fit = LiveChartGeometry.outlierCeiling(peaks: peaks)
        XCTAssertEqual(fit.fullCeiling, 400)
        XCTAssertEqual(fit.ceiling, 100)
        XCTAssertEqual(fit.outlierPeak, 352)
    }

    func testOutlierCeilingKeepsSteadyData() {
        let peaks = (0..<360).map { 20 + Double($0 % 41) }
        let fit = LiveChartGeometry.outlierCeiling(peaks: peaks)
        XCTAssertEqual(fit.ceiling, LiveChartGeometry.niceCeiling(60 * 1.1))
        XCTAssertEqual(fit.ceiling, fit.fullCeiling)
        XCTAssertNil(fit.outlierPeak)
    }

    func testOutlierCeilingKeepsRepeatedBursts() {
        // One sample in twenty is a burst: that is the signal, not an outlier.
        let peaks = (0..<400).map { $0 % 20 == 0 ? 300.0 : 30.0 }
        let fit = LiveChartGeometry.outlierCeiling(peaks: peaks)
        XCTAssertEqual(fit.ceiling, LiveChartGeometry.niceCeiling(330))
        XCTAssertNil(fit.outlierPeak)
    }

    func testOutlierCeilingNeedsEnoughSamples() {
        let fit = LiveChartGeometry.outlierCeiling(peaks: [10, 12, 11, 400])
        XCTAssertEqual(fit.ceiling, LiveChartGeometry.niceCeiling(440))
        XCTAssertNil(fit.outlierPeak)
    }

    func testOutlierCeilingStaysWithinAQuarterOfTheSpike() {
        // Idle noise under one spike is not magnified into a mountain range.
        var peaks = [Double](repeating: 0.3, count: 600)
        peaks[10] = 50
        peaks.append(contentsOf: [Double](repeating: 0, count: 600))
        let fit = LiveChartGeometry.outlierCeiling(peaks: peaks)
        XCTAssertEqual(fit.ceiling, 15)
        XCTAssertEqual(fit.outlierPeak, 50)
    }

    func testNewExtremeDoesNotRescaleExistingValueInFixedDomain() {
        let domain = 0.0...100.0
        let before = LiveChartGeometry.normalizedY(40, in: domain)
        XCTAssertEqual(LiveChartGeometry.normalizedY(200, in: domain), 1)
        let after = LiveChartGeometry.normalizedY(40, in: domain)

        XCTAssertEqual(before, 0.4, accuracy: 1e-12)
        XCTAssertEqual(after, before, accuracy: 1e-12)
    }
}
