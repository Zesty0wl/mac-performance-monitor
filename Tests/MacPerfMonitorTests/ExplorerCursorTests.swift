import AppKit
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class ExplorerCursorTests: XCTestCase {
    func testCommandWheelZoomDirectionAndPositionWithoutTakingPageScroll() throws {
        _ = NSApplication.shared
        let surface = TrendSurfaceView()
        surface.frame = CGRect(x: 0, y: 0, width: 500, height: 220)
        let window = NSWindow(
            contentRect: surface.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        let feed = TrendFeed()
        var model = TrendModel()
        model.xDomain =
            Date(timeIntervalSinceReferenceDate: 0)...Date(timeIntervalSinceReferenceDate: 3600)
        feed.publish(model)
        surface.attach(feed)
        surface.layoutSubtreeIfNeeded()
        let plot = TrendChartGeometry(
            leftGutter: model.leftGutter,
            showsTimeAxis: model.showsTimeAxis, plotBorder: model.plotBorder
        ).plotRect(in: surface.bounds.size)
        let pointer = CGPoint(x: plot.minX + plot.width * 0.25, y: plot.midY)
        let fallback = ScrollReceiver()
        surface.nextResponder = fallback
        surface.scrollWheel(with: try scrollEvent(at: pointer, in: surface, delta: 2))
        XCTAssertEqual(fallback.count, 1)
        var zooms: [(Double, Double)] = []
        surface.onTimeZoom = { zooms.append(($0, $1)) }
        surface.scrollWheel(
            with: try scrollEvent(at: pointer, in: surface, delta: 2, modifiers: []))
        XCTAssertTrue(zooms.isEmpty)
        XCTAssertEqual(fallback.count, 2)
        surface.scrollWheel(with: try scrollEvent(at: pointer, in: surface, delta: 2))
        surface.scrollWheel(with: try scrollEvent(at: pointer, in: surface, delta: -2))
        XCTAssertEqual(zooms.count, 2)
        XCTAssertLessThan(try XCTUnwrap(zooms.first).0, 1)
        XCTAssertGreaterThan(try XCTUnwrap(zooms.last).0, 1)
        XCTAssertEqual(try XCTUnwrap(zooms.first).1, 0.25, accuracy: 0.001)
        surface.scrollWheel(
            with: try scrollEvent(at: pointer, in: surface, delta: 0, horizontal: 2))
        surface.scrollWheel(with: try scrollEvent(at: CGPoint(x: 1, y: 1), in: surface, delta: 2))
        XCTAssertEqual(zooms.count, 2)
        XCTAssertEqual(fallback.count, 4)
    }

    func testExplorerWheelZoomRemainsConnectedWhileInspectionIsDisabled() throws {
        _ = NSApplication.shared
        let feed = TrendFeed()
        var model = TrendModel()
        model.xDomain =
            Date(timeIntervalSinceReferenceDate: 0)...Date(timeIntervalSinceReferenceDate: 3600)
        feed.publish(model)
        let cursor = ExplorerCursor()
        var factors: [Double] = []
        let chart = ExplorerTrendChart(
            feed: feed, cursor: cursor, allowsInspection: false,
            onZoom: { factor, _ in factors.append(factor) })
        let host = NSHostingView(rootView: chart.frame(width: 500, height: 220))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 220),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func surface(in view: NSView) -> TrendSurfaceView? {
            if let found = view as? TrendSurfaceView { return found }
            return view.subviews.lazy.compactMap { surface(in: $0) }.first
        }
        let view = try XCTUnwrap(surface(in: host))
        view.onTimePin?(Date(timeIntervalSinceReferenceDate: 100))
        view.onTimeHover?(Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertNil(cursor.date)
        view.scrollWheel(with: try scrollEvent(at: CGPoint(x: 250, y: 100), in: view, delta: 2))
        XCTAssertEqual(factors.count, 1)
        XCTAssertLessThan(try XCTUnwrap(factors.first), 1)
    }

    private func scrollEvent(
        at point: CGPoint, in view: NSView, delta: Int32, horizontal: Int32 = 0,
        modifiers: CGEventFlags = .maskCommand
    ) throws -> NSEvent {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 2, wheel1: delta, wheel2: horizontal, wheel3: 0))
        event.flags = modifiers
        let location = view.convert(point, to: nil)
        event.location = CGPoint(
            x: location.x, y: CGDisplayBounds(CGMainDisplayID()).height - location.y)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private final class ScrollReceiver: NSResponder {
        var count = 0
        override func scrollWheel(with event: NSEvent) { count += 1 }
    }

    func testChartsShareHoverAndPinnedTimeSurvivesMouseExit() {
        let cursor = ExplorerCursor()
        var first: Date?
        var second: Date?
        let token = cursor.observe { first = $0 }
        _ = cursor.observe { second = $0 }
        let date = Date(timeIntervalSince1970: 1000)
        cursor.move(to: date)
        XCTAssertEqual(first, date)
        XCTAssertEqual(second, date)
        cursor.pin(date)
        cursor.move(to: nil)
        cursor.move(to: date.addingTimeInterval(60))
        XCTAssertEqual(cursor.date, date)
        XCTAssertTrue(cursor.pinned)
        cursor.remove(token)
        cursor.clear()
        XCTAssertEqual(first, date)
        XCTAssertNil(second)
        XCTAssertFalse(cursor.pinned)
    }
}
