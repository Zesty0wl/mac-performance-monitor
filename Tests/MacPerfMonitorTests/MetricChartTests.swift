import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class MetricChartTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testNativeModelPreservesGapsHighsAndTrailingWindow() throws {
        var samples = (0..<20).map {
            MetricSample(date: start.addingTimeInterval(Double($0)), value: 2)
        }
        samples[0].high = 4
        samples[5].value = .nan
        samples += [
            MetricSample(date: start.addingTimeInterval(1000), value: 3),
            MetricSample(date: start.addingTimeInterval(1001), value: 3),
            MetricSample(date: start.addingTimeInterval(1002), value: .nan),
        ]
        let chart = MetricChart(
            samples: samples, minTop: 5, windowSeconds: 1800, accessibilityTitle: "CPU",
            rasterizesDrawing: true, yFormat: { String(format: "%.0f", $0) })
        let model = chart.surfaceModel
        XCTAssertEqual(model.series.map { $0.column.count }, [5, 14, 2])
        XCTAssertEqual(Array(try XCTUnwrap(model.series.first?.column.highs)), [4, 2, 2, 2, 2])
        XCTAssertTrue(model.series.allSatisfy { $0.column.values.allSatisfy(\.isFinite) })
        XCTAssertNil(model.series.last?.column.highs)
        XCTAssertEqual(
            model.series.last?.column.times.last, start.timeIntervalSinceReferenceDate + 1001)
        XCTAssertEqual(model.xDomain?.upperBound, samples.last?.date)
        XCTAssertEqual(model.xDomain?.lowerBound, start.addingTimeInterval(1002 - 1800))
        XCTAssertEqual(model.yDomain, 0...5)
        XCTAssertEqual(model.gapThreshold, .infinity)
        XCTAssertEqual(model.leftGutter, 52)
        XCTAssertTrue(model.showsTimeAxis)
        XCTAssertTrue(model.plotBorder)
        XCTAssertNil(model.statisticsInterval)
        XCTAssertEqual(model.accessibilityLabel, t("CPU"))
        XCTAssertEqual(
            model.accessibilityValue,
            t("Currently %1$@. Peak %2$@ over the shown window.", "3", "3"))
    }

    func testEmptyAndFlatModelsKeepSensibleAxes() {
        for samples in [[], [MetricSample(date: start, value: .nan)]] {
            let chart = MetricChart(samples: samples, minTop: 5, yFormat: { String($0) })
            XCTAssertTrue(chart.surfaceModel.series.isEmpty)
            XCTAssertEqual(chart.surfaceModel.yDomain, 0...5)
            XCTAssertEqual(chart.surfaceModel.accessibilityValue, t("No data yet."))
        }
        let flat = MetricChart(
            samples: [MetricSample(date: start, value: 0)], minTop: 10,
            yFormat: { String($0) })
        XCTAssertEqual(flat.surfaceModel.yDomain, 0...10)
        XCTAssertEqual(flat.surfaceModel.series.first?.column.values.first, 0)
        XCTAssertFalse(flat.rasterizesDrawing, "existing callers keep their original renderer")
        var bitmap = flat
        bitmap.rasterizesDrawing = true
        XCTAssertNotEqual(flat, bitmap)
    }

    func testBitmapSurfaceRendersUnlimitedGapsAndHover() async throws {
        _ = NSApplication.shared
        let samples = (0..<1800).map {
            MetricSample(
                date: start.addingTimeInterval(Double($0)), value: 2 + sin(Double($0) / 20))
        }
        let host = NSHostingView(
            rootView: MetricChart(
                samples: samples, minTop: 5, rasterizesDrawing: true,
                yFormat: { String(format: "%.1f", $0) }
            ).frame(width: 328, height: 120))
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 328, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let surface = try XCTUnwrap(chartSurface(in: host))
        XCTAssertTrue(surface.rasterizesDrawing)
        XCTAssertTrue(surface.scrubbable)
        XCTAssertEqual(surface.bounds.size, CGSize(width: 328, height: 120))
        let image = try XCTUnwrap(
            ChartBitmap().render(size: surface.bounds.size, scale: surface.deviceScale) {
                surface.painter.draw(surface.contentLayer, in: $0)
            })
        XCTAssertEqual(image.width, Int(328 * window.backingScaleFactor))
        XCTAssertEqual(image.height, Int(120 * window.backingScaleFactor))
        let hidden = surface.layer?.sublayers?.filter(\.isHidden) ?? []
        surface.showsHoverPopover = false
        let move = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: surface.convert(CGPoint(x: 250, y: 60), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        surface.mouseMoved(with: move)
        let overlay = try XCTUnwrap(hidden.first { !$0.isHidden })
        XCTAssertNotNil(
            ChartBitmap().render(size: overlay.bounds.size, scale: surface.deviceScale) {
                surface.painter.draw(overlay, in: $0)
            })
        surface.mouseExited(with: move)
        XCTAssertTrue(overlay.isHidden)
    }

    private func chartSurface(in view: NSView) -> TrendSurfaceView? {
        (view as? TrendSurfaceView)
            ?? view.subviews.lazy.compactMap { self.chartSurface(in: $0) }.first
    }
}
