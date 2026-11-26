// SPDX-License-Identifier: MIT
import AppKit
import XCTest

@testable import MacPerfMonitor
@testable import MacPerfMonitorCore

@MainActor
final class LeakMarkerTests: XCTestCase {
    private let room = CombinedMenuBarImage.leakMarkerSize + CombinedMenuBarImage.leakMarkerGap

    private func readout(
        _ metric: MenuBarMetric, _ value: String = "75%", marked: Bool = false
    ) -> CombinedMenuBarReadout {
        CombinedMenuBarReadout(
            metric: metric, value: value, isAlarm: marked, showsLeakMarker: marked)
    }

    func testOnlyRAMCarriesTheMarkerAndOnlyWhileALeakAlertIsActive() {
        XCTAssertTrue(MenuBarMetric.pressure.showsLeakMarker(in: [.leak]))
        XCTAssertTrue(MenuBarMetric.pressure.showsLeakMarker(in: [.leak, .highCPU]))
        // Other memory alarms keep the cell plain: the marker means growth.
        XCTAssertFalse(
            MenuBarMetric.pressure.showsLeakMarker(in: [.criticalPressure, .swap, .processCeiling]))
        XCTAssertFalse(MenuBarMetric.pressure.showsLeakMarker(in: []))
        for metric in MenuBarMetric.allCases where metric != .pressure {
            XCTAssertFalse(metric.showsLeakMarker(in: [.leak]), "\(metric)")
        }
    }

    func testMarkedCellKeepsRoomForTheMarkerOnItsLeft() {
        let plain = CombinedMenuBarImage.layout(for: readout(.pressure)).width
        let marked = CombinedMenuBarImage.layout(for: readout(.pressure, marked: true)).width
        XCTAssertEqual(marked - plain, room)
    }

    func testMarkerSitsInTheRoomLeftOfRAMWhereverRAMIs() throws {
        let readouts = [
            readout(.cpu, "20%"), readout(.pressure, marked: true), readout(.gpu, "5%"),
        ]
        let rects = CombinedMenuBarImage.leakMarkerRects(readouts: readouts, presentation: .strip)
        XCTAssertEqual(rects.count, 1)
        let rect = try XCTUnwrap(rects.first)
        XCTAssertEqual(rect.size, NSSize(width: 12, height: 12))
        XCTAssertEqual(rect.midY, 11, "centred on the 22 point item")
        // Past the CPU cell, and inside the RAM cell, so a click on it opens RAM.
        XCTAssertGreaterThan(rect.minX, CombinedMenuBarImage.layout(for: readouts[0]).width)
        for x in [rect.minX + 0.5, rect.midX, rect.maxX] {
            XCTAssertEqual(
                CombinedMenuBarImage.metric(at: x, readouts: readouts, presentation: .strip),
                .pressure)
        }
    }

    func testFocusPutsTheMarkerAtTheLeftEdge() {
        let marked = [readout(.pressure, marked: true)]
        let rects = CombinedMenuBarImage.leakMarkerRects(readouts: marked, presentation: .focus)
        XCTAssertEqual(rects.map(\.minX), [0])
        let markedWidth = CombinedMenuBarImage.image(readouts: marked, presentation: .focus)
            .size.width
        let plainWidth = CombinedMenuBarImage.image(
            readouts: [readout(.pressure)], presentation: .focus
        ).size.width
        XCTAssertEqual(markedWidth - plainWidth, room)
    }

    func testNoMarkerAndNoRoomWithoutALeakAlert() {
        let readouts = [readout(.pressure), readout(.cpu, "20%")]
        for presentation in MenuBarPresentation.allCases {
            XCTAssertTrue(
                CombinedMenuBarImage.leakMarkerRects(
                    readouts: readouts, presentation: presentation
                ).isEmpty)
        }
    }
}
