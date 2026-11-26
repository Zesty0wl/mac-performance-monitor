// SPDX-License-Identifier: MIT
import XCTest

@testable import MacPerfMonitor

@MainActor
final class StatusItemClickTests: XCTestCase {
    private func action(
        shown: Bool, onScreen: Bool, clicked: CombinedMenuBarPanel?,
        current: CombinedMenuBarPanel = .metric(.pressure)
    ) -> CombinedStatusItemController.ClickAction {
        CombinedStatusItemController.clickAction(
            popoverShown: shown, popoverOnScreen: onScreen, clicked: clicked, current: current)
    }

    func testClosedPopoverOpens() {
        XCTAssertEqual(action(shown: false, onScreen: false, clicked: .metric(.cpu)), .open)
        XCTAssertEqual(action(shown: false, onScreen: false, clicked: nil), .open)
    }

    func testOpenPopoverSwitchesToTheClickedPanelOrCloses() {
        XCTAssertEqual(
            action(shown: true, onScreen: true, clicked: .metric(.cpu)),
            .switchPanel(.metric(.cpu)))
        XCTAssertEqual(action(shown: true, onScreen: true, clicked: .alerts), .switchPanel(.alerts))
        XCTAssertEqual(action(shown: true, onScreen: true, clicked: .metric(.pressure)), .close)
        XCTAssertEqual(action(shown: true, onScreen: true, clicked: nil), .close)
    }

    /// The stuck state: NSPopover still reports the popover shown, but its window
    /// is off screen. A click used to switch the panel of, or close, a popover
    /// nobody could see, so nothing appeared. It now opens it again, whichever
    /// panel the click landed on.
    func testPopoverReportedOpenButOffScreenReopens() {
        let clicks: [CombinedMenuBarPanel?] = [nil, .metric(.pressure), .metric(.cpu), .alerts]
        for clicked in clicks {
            XCTAssertEqual(action(shown: true, onScreen: false, clicked: clicked), .reopen)
        }
    }
}
