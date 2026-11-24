// SPDX-License-Identifier: MIT
import XCTest

@testable import MacPerfMonitor
@testable import MacPerfMonitorCore

@MainActor
final class MemoryReadoutTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024

    private func system(
        app: UInt64, wired: UInt64, compressed: UInt64 = 0, stored: UInt64?, total: UInt64,
        pressure: Double = 0
    ) -> SystemSample {
        var sample = SystemSample(
            timestamp: Date(), totalRAM: total, free: 0, active: 0, inactive: 0, wired: wired,
            speculative: 0, compressed: compressed, appMemory: app, cachedFiles: 0, swapTotal: 0,
            swapUsed: 0, pressureLevel: .normal, pressurePercent: pressure, pageIns: 0,
            pageOuts: 0, compressions: 0, decompressions: 0)
        sample.compressorStoredBytes = stored
        return sample
    }

    func testRAMShowsUsageByDefaultAndRemembersTheChoice() throws {
        let suite = "MemoryReadoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let configuration = CombinedMenuBarConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.memoryReadout, .usage)
        XCTAssertEqual(configuration.title(for: .pressure), MemoryReadout.usage.title)
        XCTAssertEqual(configuration.title(for: .cpu), MenuBarMetric.cpu.title)

        configuration.memoryReadout = .pressure
        let reloaded = CombinedMenuBarConfiguration(defaults: defaults)
        XCTAssertEqual(reloaded.memoryReadout, .pressure)
        XCTAssertEqual(reloaded.title(for: .pressure), MemoryReadout.pressure.title)
    }

    func testReadoutText() {
        // A 128 GiB Mac with 96 GiB in use and nothing compressed: the pressure
        // index reads 0, memory usage reads what is actually in use.
        let roomy = system(app: 88 * gib, wired: 8 * gib, stored: 0, total: 128 * gib)
        XCTAssertEqual(MemoryReadout.usage.text(for: roomy), "75%")
        XCTAssertEqual(MemoryReadout.pressure.text(for: roomy), "0%")

        // Past installed RAM, usage keeps counting instead of stopping at 100.
        let tight = system(
            app: 8 * gib, wired: 3 * gib, compressed: 4 * gib, stored: 13 * gib, total: 16 * gib,
            pressure: 45)
        XCTAssertEqual(MemoryReadout.usage.text(for: tight), "150%")
        XCTAssertEqual(MemoryReadout.pressure.text(for: tight), "45%")

        // Capped so the menu bar cell keeps its width.
        let extreme = system(
            app: 8 * gib, wired: 3 * gib, compressed: 4 * gib, stored: 200 * gib, total: 16 * gib)
        XCTAssertEqual(MemoryReadout.usage.text(for: extreme), "999%")
    }

    func testMenuBarCellKeepsItsWidthPastOneHundred() {
        let narrow = CombinedMenuBarImage.layout(
            for: .init(metric: .pressure, value: "7%", isAlarm: false))
        let wide = CombinedMenuBarImage.layout(
            for: .init(metric: .pressure, value: "999%", isAlarm: false))
        XCTAssertEqual(narrow.width, wide.width)
    }

    func testPanelChartStretchesPastInstalledRAM() {
        let fits = MenuBarContentView.chartScale(readout: .usage, values: [40, 75])
        XCTAssertEqual(fits.domain, 0...100)
        XCTAssertEqual(fits.ticks, [0, 50, 100])

        let over = MenuBarContentView.chartScale(readout: .usage, values: [90, 130])
        XCTAssertEqual(over.domain, 0...150)
        XCTAssertEqual(over.ticks, [0, 50, 100, 150])

        let far = MenuBarContentView.chartScale(readout: .usage, values: [210])
        XCTAssertEqual(far.domain, 0...250)
        XCTAssertEqual(far.ticks, [0, 100, 250])

        XCTAssertEqual(MenuBarContentView.chartScale(readout: .usage, values: []).domain, 0...100)
        XCTAssertEqual(
            MenuBarContentView.chartScale(readout: .pressure, values: [100]).domain, 0...100)
    }
}
