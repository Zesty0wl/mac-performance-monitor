import XCTest

@testable import MacPerfMonitorCore

final class LiveRefreshCadenceTests: XCTestCase {
    func testSubsecondSelectionsSetSubsecondBaseTimer() {
        XCTAssertEqual(LiveRefreshCadence.baseInterval(for: 0.25), 0.25)
        XCTAssertEqual(LiveRefreshCadence.baseInterval(for: 0.5), 0.5)
    }

    func testSlowerSelectionsKeepOneSecondBaseTimer() {
        XCTAssertEqual(LiveRefreshCadence.baseInterval(for: 1), 1)
        XCTAssertEqual(LiveRefreshCadence.baseInterval(for: 10), 1)
        XCTAssertEqual(LiveRefreshCadence.baseInterval(for: 300), 1)
    }

    func testProcessWorkIsFlooredAtOneSecond() {
        XCTAssertEqual(LiveRefreshCadence.processInterval(for: 0.25), 5)
        XCTAssertEqual(LiveRefreshCadence.processInterval(for: 0.5), 5)
        XCTAssertEqual(LiveRefreshCadence.processInterval(for: 1), 5)
        XCTAssertEqual(LiveRefreshCadence.processInterval(for: 10), 10)
    }

    func testGatedCadencesUseExactBaseTickCounts() {
        XCTAssertEqual(LiveRefreshCadence.tickCount(for: 0.25, baseInterval: 0.25), 1)
        XCTAssertEqual(LiveRefreshCadence.tickCount(for: 0.5, baseInterval: 0.25), 2)
        XCTAssertEqual(LiveRefreshCadence.tickCount(for: 1, baseInterval: 0.25), 4)
        XCTAssertEqual(LiveRefreshCadence.tickCount(for: 10, baseInterval: 1), 10)
    }
}
