import XCTest

@testable import MacPerfMonitorCore

/// The 2.0 migration: one `appMode` setting becomes two independent switches.
/// Getting this wrong would silently change what every existing install does,
/// so each stored shape is pinned here.
final class AppComponentStateTests: XCTestCase {
    func testFreshInstallHasEverythingOn() {
        let state = AppComponentState.resolve(
            menuBarItem: nil, historyLogging: nil, legacyAppMode: nil)
        XCTAssertEqual(state, AppComponentState(menuBarItem: true, historyLogging: true))
    }

    func testLegacyFullModeKeepsLoggingAndTheItem() {
        let state = AppComponentState.resolve(
            menuBarItem: nil, historyLogging: nil, legacyAppMode: "full")
        XCTAssertEqual(state, AppComponentState(menuBarItem: true, historyLogging: true))
    }

    func testLegacyMenuBarOnlyModeTurnsLoggingOffAndKeepsTheItem() {
        let state = AppComponentState.resolve(
            menuBarItem: nil, historyLogging: nil, legacyAppMode: "menuBarOnly")
        XCTAssertEqual(state, AppComponentState(menuBarItem: true, historyLogging: false))
    }

    func testAnUnrecognisedLegacyModeIsTreatedAsLogging() {
        // Anything that is not the no-history value logs, which is the default
        // the old manager itself fell back to.
        let state = AppComponentState.resolve(
            menuBarItem: nil, historyLogging: nil, legacyAppMode: "something-else")
        XCTAssertTrue(state.historyLogging)
    }

    func testExplicitSwitchesWinOverTheLegacyMode() {
        let state = AppComponentState.resolve(
            menuBarItem: false, historyLogging: true, legacyAppMode: "menuBarOnly")
        XCTAssertEqual(state, AppComponentState(menuBarItem: false, historyLogging: true))
    }

    func testExplicitLoggingOffSurvivesALegacyFullMode() {
        let state = AppComponentState.resolve(
            menuBarItem: true, historyLogging: false, legacyAppMode: "full")
        XCTAssertFalse(state.historyLogging)
    }

    func testKeepsRunningWithoutWindows() {
        XCTAssertTrue(
            AppComponentState(menuBarItem: true, historyLogging: false)
                .keepsRunningWithoutWindows)
        XCTAssertTrue(
            AppComponentState(menuBarItem: false, historyLogging: true)
                .keepsRunningWithoutWindows)
        XCTAssertTrue(AppComponentState.default.keepsRunningWithoutWindows)
        XCTAssertFalse(
            AppComponentState(menuBarItem: false, historyLogging: false)
                .keepsRunningWithoutWindows)
    }
}
