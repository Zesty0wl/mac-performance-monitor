import XCTest

@testable import MacPerfMonitorCore

final class SwapGrowthTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let gib = 1_073_741_824.0

    func testStableHighSwapAndOvernightOscillationStayQuiet() {
        for baseline in [3.0, 30.0] {
            let detector = SwapGrowthDetector()
            for offset in stride(from: 0.0, through: 3600, by: 10) {
                let sample = Make.system(
                    timestamp: start.addingTimeInterval(offset),
                    swapUsed: UInt64((baseline + 0.3 * sin(offset / 45)) * gib))
                XCTAssertNotEqual(
                    detector.evaluate(sample, maximumGap: 30)?.alert.severity, .warning)
                XCTAssertNotEqual(
                    detector.evaluate(sample, maximumGap: 30)?.alert.severity, .critical)
            }
        }
    }

    func testRapidGrowthIsActionableAndPlateauRecoversAboveTheOldBaseline() {
        let detector = SwapGrowthDetector()
        var warning: AlertCondition?
        for offset in stride(from: 0.0, through: 600, by: 10) {
            let sample = Make.system(
                timestamp: start.addingTimeInterval(offset),
                swapUsed: UInt64((3 + offset / 240) * gib))
            warning = detector.evaluate(sample, maximumGap: 30)
        }
        XCTAssertEqual(warning?.alert.severity, .warning)
        XCTAssertGreaterThan(warning?.alert.evidence?.current ?? 0, 5 * gib)
        var settled: AlertCondition?
        for offset in stride(from: 610.0, through: 1000, by: 10) {
            settled = detector.evaluate(
                Make.system(
                    timestamp: start.addingTimeInterval(offset), swapUsed: UInt64(5.5 * gib)),
                maximumGap: 30)
        }
        XCTAssertNil(settled)
    }

    func testGapDoesNotTurnAnUnobservedIncreaseIntoRapidGrowth() {
        let detector = SwapGrowthDetector()
        _ = detector.evaluate(
            Make.system(timestamp: start, swapUsed: UInt64(3 * gib)), maximumGap: 30)
        XCTAssertNil(
            detector.evaluate(
                Make.system(timestamp: start.addingTimeInterval(3600), swapUsed: UInt64(30 * gib)),
                maximumGap: 30))
    }

    func testMinuteCadenceStillDetectsMeaningfulContinuedGrowth() {
        let detector = SwapGrowthDetector()
        var warnings: [AlertCondition] = []
        for offset in stride(from: 0.0, through: 600, by: 60) {
            let sample = Make.system(
                timestamp: start.addingTimeInterval(offset),
                swapUsed: UInt64((21 + offset / 125) * gib))
            if let condition = detector.evaluate(sample, maximumGap: 120) {
                warnings.append(condition)
            }
        }
        XCTAssertTrue(warnings.contains { $0.alert.severity >= .warning })
    }

    func testPagingCanAlertAtFlatOccupancyOnlyWithSustainedPressure() {
        for pressure in [PressureLevel.normal, .warning] {
            let detector = SwapGrowthDetector()
            var result: AlertCondition?
            for offset in stride(from: 0.0, through: 150, by: 10) {
                var sample = Make.system(
                    timestamp: start.addingTimeInterval(offset), swapUsed: UInt64(30 * gib),
                    pressure: pressure)
                sample.swapInBytesPerSecond = 12 * 1024 * 1024
                sample.swapOutBytesPerSecond = 12 * 1024 * 1024
                result = detector.evaluate(sample, maximumGap: 30)
            }
            XCTAssertEqual(result?.alert.severity, pressure == .warning ? .warning : nil)
        }
    }
}
