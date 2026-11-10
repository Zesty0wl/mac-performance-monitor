import AppKit
import XCTest

@testable import MacPerfMonitor

@MainActor
final class WindowPickerTests: XCTestCase {
    private func window(
        _ number: Int, pid: pid_t, _ frame: CGRect, layer: Int = 0, alpha: Double = 1
    ) -> WindowPicker.Window {
        WindowPicker.Window(number: number, ownerPID: pid, frame: frame, layer: layer, alpha: alpha)
    }

    private let big = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let small = CGRect(x: 100, y: 100, width: 200, height: 200)
    private let inside = CGPoint(x: 150, y: 150)

    func testFrontmostWindowUnderThePointWins() {
        let windows = [window(1, pid: 10, small), window(2, pid: 20, big)]
        XCTAssertEqual(WindowPicker.ownerPID(at: inside, in: windows), 10)
        XCTAssertEqual(WindowPicker.ownerPID(at: CGPoint(x: 600, y: 600), in: windows), 20)
        XCTAssertNil(WindowPicker.ownerPID(at: CGPoint(x: 5000, y: 5000), in: windows))
    }

    /// A notification or an overlay floats above an app window; the click was
    /// meant for the app.
    func testAnAppWindowWinsOverSomethingFloatingAboveIt() {
        let windows = [window(1, pid: 99, big, layer: 25), window(2, pid: 20, big)]
        XCTAssertEqual(WindowPicker.ownerPID(at: inside, in: windows), 20)
    }

    /// With no app window there, the menu bar or Dock owner is the answer.
    func testAHigherLayerCountsWhenNoAppWindowIsThere() {
        let menuBar = CGRect(x: 0, y: 0, width: 1000, height: 24)
        let windows = [window(1, pid: 77, menuBar, layer: 24), window(2, pid: 20, small)]
        XCTAssertEqual(WindowPicker.ownerPID(at: CGPoint(x: 500, y: 10), in: windows), 77)
    }

    func testInvisibleAndIgnoredWindowsAreSkipped() {
        let windows = [
            window(1, pid: 5, big, alpha: 0), window(2, pid: 6, big), window(3, pid: 20, big),
        ]
        XCTAssertEqual(WindowPicker.ownerPID(at: inside, in: windows), 6)
        XCTAssertEqual(WindowPicker.ownerPID(at: inside, in: windows, ignoring: [2]), 20)
        XCTAssertNil(WindowPicker.ownerPID(at: inside, in: windows, ignoring: [2, 3]))
    }

    func testAppKitPointsFlipToWindowServerPoints() {
        // 100 pt up from the bottom of a 900 pt display is 800 pt down from its top.
        XCTAssertEqual(
            WindowPicker.windowServerPoint(fromAppKit: CGPoint(x: 40, y: 100), mainHeight: 900),
            CGPoint(x: 40, y: 800))
        // A display above the main one has AppKit y beyond the main height,
        // and so a negative window-server y.
        XCTAssertEqual(
            WindowPicker.windowServerPoint(fromAppKit: CGPoint(x: 0, y: 1000), mainHeight: 900).y,
            -100)
    }

    /// The live window list: readable without any permission, and every
    /// window in it has a real owner and a frame.
    func testLiveWindowListIsReadable() {
        let windows = WindowPicker.onScreenWindows()
        for window in windows {
            XCTAssertGreaterThan(window.ownerPID, 0)
            XCTAssertFalse(window.frame.isNull)
        }
        // A login session with a display always has at least the menu bar.
        if NSScreen.screens.isEmpty == false, !windows.isEmpty {
            XCTAssertTrue(windows.contains { $0.layer != 0 || $0.frame.width > 0 })
        }
    }

    /// The overlay goes up over every display and comes down again on cancel,
    /// reporting no process.
    func testPickerCoversEveryDisplayAndCancelsCleanly() {
        _ = NSApplication.shared
        let controller = WindowPickerController()
        var result: pid_t?? = .none
        let before = NSApp.windows.count
        controller.begin { result = .some($0) }
        XCTAssertTrue(controller.isPicking)
        XCTAssertEqual(NSApp.windows.count - before, NSScreen.screens.count)

        // Escape, delivered to the overlay's content view as the key window would.
        let overlay = NSApp.windows.last
        overlay?.contentView?.cancelOperation(nil)
        XCTAssertFalse(controller.isPicking)
        XCTAssertEqual(result, .some(nil))
    }
}
