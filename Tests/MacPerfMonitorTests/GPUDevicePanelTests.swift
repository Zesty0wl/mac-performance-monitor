import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

/// The GPU tab's Device panel: what each page says, and that switching pages
/// never changes the panel's height (every page is laid out at once).
@MainActor
final class GPUDevicePanelTests: XCTestCase {
    typealias P = GPUDevicePresentation

    func testCoresClockAndWakeupText() {
        XCTAssertEqual(P.cores(count: 14, clusters: [7, 7]), "14 · 2 × 7")
        XCTAssertEqual(P.cores(count: 18, clusters: [10, 8]), "18 · 10 + 8")
        XCTAssertEqual(P.cores(count: 10, clusters: nil), "10")
        XCTAssertEqual(P.cores(count: nil, clusters: [7, 7]), "--")

        var gpu = GPUSample(utilization: 50)
        XCTAssertEqual(P.clockDetail(gpu), "")
        gpu.maximumClockMHz = 1380
        XCTAssertEqual(P.clockDetail(gpu), t("Maximum %@", P.megahertz(1380)))
        gpu.clockMHz = 690
        XCTAssertEqual(
            P.clockDetail(gpu), t("%1$@%% of the %2$@ maximum", "50", P.megahertz(1380)))

        var diagnostics = GPUDiagnostics()
        XCTAssertEqual(P.wakeups(diagnostics, awake: 100), "--")
        diagnostics.wakeupsPerSecond = 0
        XCTAssertEqual(P.wakeups(diagnostics, awake: 100), t("Busy throughout"))
        XCTAssertEqual(P.wakeups(diagnostics, awake: 0), t("GPU off"))
        XCTAssertEqual(P.wakeups(diagnostics, awake: 50), P.rate(0))
        diagnostics.wakeupsPerSecond = 99.4
        XCTAssertEqual(P.wakeups(diagnostics, awake: 60), P.rate(99.4))
        XCTAssertEqual(P.milliseconds(nil), "--")
    }

    func testRowsForControllerEnginesSwitchesAndMemory() throws {
        var diagnostics = GPUDiagnostics()
        diagnostics.controllerStates = [
            .init(name: "PERF", residency: 60), .init(name: "CLTMLIMI", residency: 30),
            .init(name: "FAST_DIE", residency: 6), .init(name: "IDLE_OFF", residency: 3),
            .init(name: "STANDBY", residency: 1),
        ]
        let controller = P.controllerRows(diagnostics)
        XCTAssertEqual(
            controller.map(\.label),
            [t("Following demand"), t("Thermal limit"), "FAST_DIE", t("Idle, powered off")])
        XCTAssertEqual(controller[1].color, .systemOrange)

        diagnostics.lostPerformance = [.init(name: "GPU3_TH", residency: 4)]
        XCTAssertEqual(P.lostRows(diagnostics).map(\.label), [t("%@ thermal", "GPU3")])

        diagnostics.engines = [
            .compute: GPUEngineActivity(
                submissionsPerSecond: 300,
                contextSwitches: GPUContextSwitches(buckets: [
                    .init(upperBoundMicroseconds: 100, count: 40)
                ]),
                contextSwitchesPerSecond: 40),
            .fragment: GPUEngineActivity(submissionsPerSecond: 100),
        ]
        let engines = P.engineRows(diagnostics)
        XCTAssertEqual(engines.map(\.label), [t("Compute"), t("Fragment")])
        XCTAssertEqual(engines[0].fraction, 0.75, accuracy: 0.0001)
        let switches = P.switchRows(diagnostics)
        XCTAssertEqual(switches.count, 1)
        XCTAssertEqual(switches[0].value, t("%1$@ · 95%% under %2$@ µs", P.rate(40), "100"))

        var gpu = GPUSample(utilization: 10, inUseMemoryBytes: 9_000_000_000)
        XCTAssertTrue(P.memoryRows(gpu).isEmpty)
        gpu.memoryLimit = GPUMemoryLimit(bytes: 10_000_000_000, isCustom: false)
        XCTAssertEqual(try XCTUnwrap(P.memoryRows(gpu).first).fraction, 0.9, accuracy: 0.0001)
        XCTAssertEqual(P.memoryRows(gpu).first?.color, .systemOrange)
        XCTAssertEqual(P.headroom(gpu), 1_000_000_000)
        gpu.inUseMemoryBytes = 12_000_000_000
        XCTAssertEqual(P.headroom(gpu), 0)
    }

    func testHealthSummary() {
        XCTAssertEqual(P.healthSummary(nil, recoveries: nil).text, "")
        XCTAssertEqual(
            P.healthSummary(nil, recoveries: 0).text, t("No GPU recoveries since the Mac started"))
        var health = GPUHealthCounters()
        health.restarts = 0
        XCTAssertEqual(
            P.healthSummary(health, recoveries: 0).text, t("No GPU faults since the Mac started"))
        XCTAssertEqual(
            P.healthSummary(health, recoveries: 2).text, t("GPU faults since the Mac started"))
        health.killedWork[.compute] = 1
        XCTAssertEqual(P.healthSummary(health, recoveries: 0).color, .systemOrange)
    }

    /// A tick with fewer clock states, or none, must not shrink the panel.
    func testClockStateBarsNeverShrinkOnceSized() {
        let feed = GPUStatesFeed()
        let full = (1...13).map { GPUPerformanceState(name: "P\($0)", residency: 1) }
        feed.publish(full, active: 50)
        XCTAssertEqual(feed.rowCapacity, 13)
        feed.publish(Array(full.prefix(2)), active: 50)
        feed.publish([], active: nil)
        XCTAssertEqual(feed.rowCapacity, 13)

        _ = NSApplication.shared
        let sized = GPUStatesFeed()
        sized.publish(full, active: 50)
        let host = NSHostingView(rootView: GPUClockStatesSection(feed: sized).frame(width: 268))
        host.layoutSubtreeIfNeeded()
        let before = host.fittingSize.height
        sized.publish([], active: nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, before, accuracy: 0.5)
    }

    /// A native segmented control resized itself to its natural width on
    /// every page change and spilled over the chart beside the rail. The
    /// selector must fit the rail's content width, whatever the page.
    func testPageSelectorStaysInsideTheRail() {
        _ = NSApplication.shared
        let width = MainRailLayout<EmptyView, EmptyView>.railWidth - 32
        for page in GPUDevicePage.allCases {
            let host = NSHostingView(
                rootView: GPUPageSelector(selection: .constant(page)).frame(width: width))
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5, "\(page)")
            XCTAssertTrue(descendants(of: host, type: NSSegmentedControl.self).isEmpty)
        }
    }

    /// The history panel's picker moves beside the title only when the whole
    /// title row fits; at every width the visible picker stays inside the
    /// panel. A fixed 640 pt threshold let six segments overflow between
    /// about 640 and 712 pt.
    func testHistoryPickerNeverOverflowsThePanel() async throws {
        _ = NSApplication.shared
        let timeline = GPUTimelineStore()
        for width in stride(from: CGFloat(560), through: 900, by: 20) {
            let host = NSHostingView(
                rootView: GPUHistoryPanel(
                    timeline: timeline, thermalPoints: [], range: .fiveMinutes
                )
                .frame(width: width))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: width, height: 520),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            // The measurements land over a few layout passes.
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let visible = descendants(of: host, type: NSSegmentedControl.self).filter {
                !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0
                    && $0.window != nil && !$0.frame.isEmpty
            }
            for control in visible {
                let frame = control.convert(control.bounds, to: host)
                guard frame.minY < host.bounds.maxY else { continue }
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "width \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "width \(width)")
            }
        }
    }

    private func descendants<T: NSView>(of view: NSView, type: T.Type) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + descendants(of: $0, type: type) }
    }

    func testBarListFeedSkipsUnchangedRowsAndKeepsItsRowCount() {
        let feed = GPUBarListFeed(rowCount: 2, emptyText: "None")
        var calls = 0
        _ = feed.observe { calls += 1 }
        let row = GPUBarRow(label: "A", fraction: 0.5, value: "50%", color: .systemBlue)
        feed.publish([row, row, row])
        XCTAssertEqual(feed.rows.count, 2)
        feed.publish([row, row, row])
        XCTAssertEqual(calls, 1)
        let surface = GPUBarListSurfaceView()
        surface.attach(feed)
        XCTAssertEqual(surface.displayedText, "A: 50%, A: 50%")
        feed.publish([], emptyText: "Not reported")
        XCTAssertEqual(surface.displayedText, "Not reported")
    }

    /// Every page is laid out at once, so the panel is as tall on the short
    /// Memory page as on the Clock page, and the row never jumps.
    func testSwitchingPagesKeepsThePanelHeight() async throws {
        _ = NSApplication.shared
        let suite = "gpu-device-panel-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let timeline = GPUTimelineStore()
        var gpu = GPUSample(utilization: 40, inUseMemoryBytes: 2_000_000_000, name: "Apple M3 Pro")
        gpu.sampledAt = Date()
        gpu.activeResidency = 90
        gpu.performanceStates = (1...13).map { .init(name: "P\($0)", residency: $0 == 13 ? 90 : 0) }
        gpu.resolveClock(
            table: GPUFrequencyTable(megahertz: (1...13).map { 300 + Double($0) * 80 }),
            helper: nil)
        gpu.memoryLimit = GPUMemoryLimit(bytes: 12_000_000_000, isCustom: true)
        timeline.replace([], span: 1800, live: nil, gpu: gpu)

        var heights: [GPUDevicePage: CGFloat] = [:]
        for page in GPUDevicePage.allCases {
            defaults.set(page.rawValue, forKey: "gpu.devicePage")
            let host = NSHostingView(
                rootView: GPUDevicePanel(timeline: timeline)
                    .frame(width: MainRailLayout<EmptyView, EmptyView>.railWidth)
                    .defaultAppStorage(defaults))
            host.layoutSubtreeIfNeeded()
            heights[page] = host.fittingSize.height
        }
        let clock = try XCTUnwrap(heights[.clock])
        XCTAssertGreaterThan(clock, 300)
        for (page, height) in heights {
            XCTAssertEqual(height, clock, accuracy: 1, "\(page)")
        }
        XCTAssertEqual(timeline.device.clockText.text, P.megahertz(1340))
        XCTAssertEqual(
            timeline.device.limitText.text, t("%@ · custom", ByteFormat.string(12_000_000_000)))
    }
}
