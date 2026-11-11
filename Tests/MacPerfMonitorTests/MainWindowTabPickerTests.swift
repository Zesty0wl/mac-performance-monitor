import AppKit
import SwiftUI
import XCTest

@testable import MacPerfMonitor

/// The main window's tabs and size limits (#188, #189).
@MainActor
final class MainWindowTabPickerTests: XCTestCase {
    /// At the minimum width the icon picker and the room each side of it
    /// (trailing buttons plus somewhere to grab the window) still fit, so the
    /// window can always be dragged.
    func testIconPickerLeavesRoomToDragAtTheMinimumWidth() throws {
        let picker = try iconPickerWidth()
        XCTAssertLessThanOrEqual(
            picker + 2 * MainWindowSize.sideReserve, MainWindowSize.minimumWidth)
    }

    /// The minimum no longer grows with the longest tab title: it is one
    /// width for every language, small enough for a 1024 pt wide screen.
    func testMinimumWidthFitsSmallScreens() {
        XCTAssertLessThanOrEqual(MainWindowSize.minimumWidth, 1024)
    }

    /// Titles show exactly when the titled picker and its side room fit.
    func testTitlesShowOnlyWhenTheyFit() {
        let threshold = MainWindowSize.labelledWidth
        XCTAssertGreaterThanOrEqual(
            threshold, MainWindowTabPicker.labelledWidth + 2 * MainWindowSize.sideReserve)
        XCTAssertTrue(MainWindowSize.showsTabTitles(windowWidth: threshold))
        XCTAssertFalse(MainWindowSize.showsTabTitles(windowWidth: threshold - 1))
        XCTAssertTrue(
            MainWindowSize.showsTabTitles(windowWidth: MainWindowSize.defaultWidth),
            "the window opens with titles")
    }

    /// Each segment fits its own title instead of the widest one, so the
    /// titled picker is narrower than ten copies of the widest segment.
    func testSegmentsFitTheirOwnTitles() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widths = MainWindowTab.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }
        let equalWidths = CGFloat(widths.count) * (widths.max() ?? 0)
        XCTAssertLessThan(MainWindowTabPicker.labelledWidth, equalWidths + 16 * 10)
    }

    /// Choosing a segment selects that tab, and the icons keep the titles as
    /// tooltips and VoiceOver labels.
    func testSelectingASegmentChangesTheTab() throws {
        let session = MainWindowSession()
        let host = NSHostingView(
            rootView: MainWindowTabPicker(
                selection: Binding(get: { session.tab }, set: { session.tab = $0 }),
                showsTitles: false))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 40)
        host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(segmentedControl(in: host))
        XCTAssertEqual(control.segmentCount, MainWindowTab.allCases.count)
        for (index, tab) in MainWindowTab.allCases.enumerated() {
            XCTAssertEqual(control.toolTip(forSegment: index), tab.title)
            XCTAssertEqual(
                control.image(forSegment: index)?.accessibilityDescription, tab.title)
        }
        let gpu = try XCTUnwrap(MainWindowTab.allCases.firstIndex(of: .gpu))
        control.selectedSegment = gpu
        _ = control.sendAction(control.action, to: control.target)
        XCTAssertEqual(session.tab, .gpu)
    }

    /// The session, not the unmountable content, holds the tab, so a window
    /// that is hidden and shown again keeps it (#189).
    func testSessionStartsOnTheDashboardAndKeepsItsTab() {
        let session = MainWindowSession()
        XCTAssertEqual(session.tab, .dashboard)
        session.tab = .diskUsage
        XCTAssertEqual(session.tab, .diskUsage)
    }

    private func iconPickerWidth() throws -> CGFloat {
        var tab = MainWindowTab.dashboard
        let host = NSHostingView(
            rootView: MainWindowTabPicker(
                selection: Binding(get: { tab }, set: { tab = $0 }), showsTitles: false))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 40)
        host.layoutSubtreeIfNeeded()
        return try XCTUnwrap(segmentedControl(in: host)).fittingSize.width
    }

    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for subview in view.subviews {
            if let control = segmentedControl(in: subview) { return control }
        }
        return nil
    }
}
