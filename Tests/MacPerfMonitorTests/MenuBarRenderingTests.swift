import AppKit
import MacPerfMonitorCore
import XCTest

@testable import MacPerfMonitor

@MainActor
final class MenuBarRenderingTests: XCTestCase {
    private var readouts: [CombinedMenuBarReadout] {
        [
            .init(metric: .pressure, value: "42%", isAlarm: false),
            .init(metric: .cpu, value: "15%", isAlarm: false),
            .init(metric: .gpu, value: "8%", isAlarm: false),
            .init(metric: .energy, value: "80%", isAlarm: false),
            .init(metric: .temperature, value: "52\u{00B0}", isAlarm: false),
            .init(
                metric: .network, value: "123K\u{2193}", secondaryValue: "45K\u{2191}",
                isAlarm: false),
            .init(
                metric: .disk, value: "12M\u{2193}", secondaryValue: "2M\u{2191}", isAlarm: false),
        ]
    }

    func testTemplateImagesAndStripHitTargets() throws {
        _ = NSApplication.shared
        let strip = CombinedMenuBarImage.image(readouts: readouts, presentation: .strip)
        try checkImage(strip, name: "strip")
        var hits: [MenuBarMetric] = []
        for x in stride(from: 0.0, to: strip.size.width, by: 0.5) {
            let metric = try XCTUnwrap(
                CombinedMenuBarImage.metric(at: x, readouts: readouts, presentation: .strip))
            if metric != hits.last { hits.append(metric) }
        }
        XCTAssertEqual(hits, readouts.map(\.metric))
        for readout in readouts {
            let image = CombinedMenuBarImage.image(readouts: [readout], presentation: .focus)
            try checkImage(image, name: "focus-\(readout.metric.rawValue)")
            XCTAssertEqual(
                CombinedMenuBarImage.metric(
                    at: image.size.width / 2, readouts: [readout],
                    presentation: .focus),
                readout.metric)
        }
    }

    func testMenuImageWorkloadWhenRequested() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPERF_BENCHMARK_MENU_IMAGES"] == "1")
        _ = NSApplication.shared
        var values = readouts
        let started = ProcessInfo.processInfo.systemUptime
        for tick in 0..<1000 {
            autoreleasepool {
                values[1].value = "\(10 + tick / 5 % 30)%"
                values[4].value = "\(50 + tick / 4 % 10)\u{00B0}"
                values[5].value = "\(100 + tick % 800)K\u{2193}"
                values[6].secondaryValue = "\(1 + tick % 8)M\u{2191}"
                let image = CombinedMenuBarImage.image(readouts: values, presentation: .strip)
                XCTAssertGreaterThan(image.size.width, 100)
            }
        }
        print(
            String(
                format: "[menu-images] 1000 updates: %.3f seconds",
                ProcessInfo.processInfo.systemUptime - started))
    }

    func testUnchangedCellsReuseLayoutAndChangingValuesStayBounded() throws {
        let initial = readouts.map { CombinedMenuBarImage.layout(for: $0) }
        for (index, readout) in readouts.enumerated() {
            XCTAssertTrue(CombinedMenuBarImage.layout(for: readout) === initial[index])
        }
        var values = readouts
        for tick in 0..<100 {
            values[1].value = "\(tick)%"
            let updated = CombinedMenuBarImage.layout(for: values[1])
            XCTAssertFalse(updated === initial[1])
            for index in values.indices where index != 1 {
                XCTAssertTrue(CombinedMenuBarImage.layout(for: values[index]) === initial[index])
            }
        }
        XCTAssertEqual(CombinedMenuBarImage.cachedLayoutCount, MenuBarMetric.allCases.count)
        let directional = try XCTUnwrap(values.last)
        let first = CombinedMenuBarImage.layout(for: directional)
        var changed = directional
        changed.secondaryValue = "123M\u{2191}"
        XCTAssertFalse(CombinedMenuBarImage.layout(for: changed) === first)
        changed.secondaryValue = nil
        XCTAssertFalse(CombinedMenuBarImage.layout(for: changed) === first)
    }

    private func checkImage(_ image: NSImage, name: String) throws {
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.height, 22)
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsHigh, Int(22 * (NSScreen.main?.backingScaleFactor ?? 2)))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        guard let path = ProcessInfo.processInfo.environment["MACPERF_MENU_RENDER_ARTIFACTS"] else {
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    func testReplacingACachedLayoutReleasesTheOldOne() {
        weak var previous: CombinedMenuBarImage.CellLayout?
        autoreleasepool {
            var value = CombinedMenuBarReadout(metric: .cpu, value: "1%", isAlarm: false)
            previous = CombinedMenuBarImage.layout(for: value)
            XCTAssertNotNil(previous)
            value.value = "2%"
            _ = CombinedMenuBarImage.layout(for: value)
        }
        XCTAssertNil(previous)
    }
}
