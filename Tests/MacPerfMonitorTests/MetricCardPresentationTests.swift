import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class MetricCardPresentationTests: XCTestCase {
    func testNativeANEMenuChartsFitAndUpdateWithoutExtraSampling() async throws {
        _ = NSApplication.shared
        for (name, embedded, appearance) in [
            ("ane-menu-active", false, NSAppearance.Name.aqua),
            ("ane-menu-partial", true, NSAppearance.Name.darkAqua),
            ("ane-menu-helper", false, NSAppearance.Name.darkAqua),
            ("ane-menu-unavailable", true, NSAppearance.Name.aqua),
            ("ane-menu-idle", false, NSAppearance.Name.aqua),
        ] {
            let now = Date()
            let noHelper = name.hasSuffix("helper")
            let unavailable = name.hasSuffix("unavailable")
            let partial = name.hasSuffix("partial")
            let idle = name.hasSuffix("idle")
            let model = SamplerModel(persistenceEnabled: false)
            let clock = MenuClock(source: model.liveTick.eraseToAnyPublisher())
            var gpu = GPUSample(
                utilization: 12, renderUtilization: 10, tilerUtilization: 5,
                inUseMemoryBytes: 2_200_000_000, name: "Apple M3 Pro")
            gpu.sampledAt = now
            gpu.coreCount = 14
            gpu.gpuPowerWatts = 1.2
            gpu.cpuPowerWatts = 3.4
            gpu.dieTemperatureC = 57
            gpu.fanRPM = 2500
            gpu.anePowerRequiresHelper = noHelper
            gpu.aneTimeMillisecondsPerSecond =
                unavailable ? nil : (idle ? 0 : (partial ? 1250 : 720))
            gpu.aneSampleIsPartial = partial
            gpu.anePowerWatts = noHelper || unavailable ? nil : (idle ? 0 : 3.25)
            gpu.anePowerSampledAt = gpu.anePowerWatts == nil ? nil : now
            gpu.anePowerSampleInterval = gpu.anePowerWatts == nil ? nil : 1
            for index in 0..<61 {
                let missing = (24..<28).contains(index) || unavailable
                let time: Double? =
                    index == 60
                    ? gpu.aneTimeMillisecondsPerSecond
                    : (missing ? nil : (idle ? 0 : 420 + 300 * sin(Double(index) / 6)))
                let watts: Double? =
                    index == 60
                    ? gpu.anePowerWatts
                    : (missing || noHelper ? nil : (idle ? 0 : 2 + sin(Double(index) / 7)))
                let sample = aneMenuSample(
                    at: now.addingTimeInterval(Double(index - 60)),
                    time: time, power: watts, partial: partial)
                model.publishForBenchmark(
                    .init(system: sample, processes: [], unreadableProcessCount: 0),
                    table: false, gpu: gpu)
            }
            model.menuLists.update(
                .gpu,
                with: (0..<8).map { index in
                    var process = ProcessSample(
                        timestamp: now, pid: Int32(1000 + index), ppid: 1,
                        name: "GPU client \(index + 1)",
                        physFootprint: 0, residentSize: 0, virtualSize: 0, lifetimeMaxFootprint: 0,
                        cpuPercent: 0, cpuTimeUser: 0, cpuTimeSystem: 0, threadCount: 1,
                        fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0, fdOther: 0,
                        diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false,
                        architecture: .arm64,
                        startTime: now, uid: 501, dataSource: .directUserRead,
                        footprintReadable: true)
                    process.gpuPercent = Double(16 - index)
                    return process
                })
            let width: CGFloat = embedded ? 404 : 300
            let appeared = expectation(description: "ANE menu charts appear")
            let host = NSHostingView(
                rootView: VStack(spacing: 10) {
                    GPUMenuBarContentView(embedded: embedded)
                    if embedded {
                        Divider()
                        Text("Open GPU").font(.caption)
                    }
                }
                .padding(embedded ? 12 : 0)
                .frame(width: width)
                .environmentObject(model)
                .environmentObject(model.menuLists)
                .environmentObject(clock)
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 80, width: width, height: 700),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            clock.open()
            defer {
                clock.close()
                window.close()
            }
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            XCTAssertEqual(size.width, width, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 690)
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let charts = descendants(of: host, type: TrendSurfaceView.self)
            XCTAssertEqual(charts.count, 2)
            let timeChart = try XCTUnwrap(
                charts.first { $0.feed?.model.accessibilityLabel == t("ANE time") })
            let powerChart = try XCTUnwrap(
                charts.first { $0.feed?.model.accessibilityLabel == t("ANE power") })
            for chart in [timeChart, powerChart] {
                XCTAssertEqual(chart.bounds.height, 62, accuracy: 1)
                XCTAssertTrue(chart.scrubbable)
                XCTAssertTrue(host.bounds.contains(chart.convert(chart.bounds, to: host)))
            }
            let timeValues = try XCTUnwrap(timeChart.feed?.model.series.first?.column.values)
            let powerValues = try XCTUnwrap(powerChart.feed?.model.series.first?.column.values)
            XCTAssertEqual(timeValues.contains(where: \.isFinite), !unavailable)
            XCTAssertEqual(powerValues.contains(where: \.isFinite), !unavailable && !noHelper)
            XCTAssertTrue(timeValues.contains(where: \.isNaN))
            XCTAssertTrue(powerValues.contains(where: \.isNaN))
            let scroll = try XCTUnwrap(descendants(of: host, type: NSScrollView.self).first)
            let document = try XCTUnwrap(scroll.documentView)
            for chart in charts {
                let chartFrame = chart.convert(chart.bounds, to: scroll.contentView)
                XCTAssertLessThanOrEqual(chartFrame.maxX, scroll.contentView.bounds.maxX - 2)
            }
            XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
            try captureGPUWindow(window, name: name)
            document.scroll(CGPoint(x: 0, y: document.bounds.height))
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
            document.scroll(.zero)
            let update = aneMenuSample(at: Date(), time: 250, power: noHelper ? nil : 1.5)
            model.publishForBenchmark(
                .init(system: update, processes: [], unreadableProcessCount: 0),
                table: false, gpu: gpu)
            let refreshed = expectation(description: "Existing menu heartbeat refreshes charts")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { refreshed.fulfill() }
            await fulfillment(of: [refreshed], timeout: 3)
            XCTAssertEqual(timeChart.feed?.model.series.first?.column.values.last, 250)
        }
    }

    func testNativeGPUAwakeCardOpensRecordedHistory() async throws {
        _ = NSApplication.shared
        let now = Date()
        let points = (0..<60).map { index -> SystemHistoryPoint in
            var point = SystemHistoryPoint(
                date: now.addingTimeInterval(Double(index - 59) * 15), pressurePercent: 5,
                appMemory: 0, wired: 0, compressed: 0, cachedFiles: 0, swapUsed: 0,
                gpuUtilization: 5)
            if !(20..<24).contains(index) {
                point.gpuActiveResidency = 50 + 30 * sin(Double(index) / 5)
            }
            return point
        }
        var gpu = GPUSample(utilization: 5)
        gpu.activeResidency = 85
        let timeline = GPUTimelineStore()
        timeline.replace(points, span: 1800, live: nil, gpu: gpu)
        let card = try XCTUnwrap(timeline.cardTemplates.first { $0.label == "GPU awake" })
        let host = NSHostingView(rootView: MetricCard(data: card).frame(width: 220, height: 140))
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 820, height: 850),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let cardSurface = try XCTUnwrap(descendants(of: host, type: TrendSurfaceView.self).first)
        let sheet = try await presentCard(cardSurface, in: window)
        let content = try XCTUnwrap(sheet.contentView)
        content.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        let chart = try XCTUnwrap(descendants(of: content, type: TrendSurfaceView.self).first)
        let model = try XCTUnwrap(chart.feed?.model)
        XCTAssertEqual(model.yDomain, 0...100)
        XCTAssertEqual(model.series[0].column.values.filter(\.isFinite).count, 56)
        XCTAssertTrue(model.series[0].column.values.contains(where: \.isNaN))
        XCTAssertGreaterThan(chart.bounds.height, 250)
        XCTAssertTrue(model.showsTimeAxis)
        try captureGPUWindow(sheet, name: "gpu-awake-detail")
    }

    func testANEMenuHistoryKeepsTimeAndPowerIndependentWithRealTimestamps() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(
            _ offset: TimeInterval, time: Double?, power: Double?, partial: Bool = false
        )
            -> SystemSample
        {
            var sample = SystemSample(
                timestamp: now.addingTimeInterval(offset), totalRAM: 0, free: 0, active: 0,
                inactive: 0, wired: 0, speculative: 0, compressed: 0, appMemory: 0,
                cachedFiles: 0, swapTotal: 0, swapUsed: 0, pressureLevel: .normal,
                pressurePercent: 0, pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0)
            sample.aneTimeMillisecondsPerSecond = time
            sample.aneSampleIsPartial = partial
            sample.anePowerWatts = power
            sample.anePowerSampledAt = power == nil ? nil : sample.timestamp
            sample.anePowerSampleInterval = power == nil ? nil : 1
            return sample
        }
        var stalePower = sample(-5, time: 700, power: 3)
        stalePower.anePowerSampledAt = stalePower.timestamp.addingTimeInterval(-10)
        let history = ANEMenuHistory(
            samples: [
                sample(-61, time: 900, power: 9),
                sample(-60, time: 500, power: 1),
                sample(-30, time: nil, power: nil),
                sample(-10, time: 1250, power: 2.5, partial: true),
                stalePower,
                sample(0, time: 0, power: 0),
                sample(1, time: 500, power: 5),
            ], now: now)
        XCTAssertEqual(history.domain, now.addingTimeInterval(-60)...now)
        XCTAssertEqual(
            history.time.map(\.date), [-60.0, -30, -10, -5, 0].map { now.addingTimeInterval($0) })
        XCTAssertEqual(history.power.map(\.date), history.time.map(\.date))
        XCTAssertEqual(history.time[0].value, 500)
        XCTAssertEqual(history.power[0].value, 1)
        XCTAssertTrue(history.time[1].value.isNaN)
        XCTAssertTrue(history.power[1].value.isNaN)
        XCTAssertEqual(history.time[2].value, 1250)
        XCTAssertEqual(history.power[2].value, 2.5)
        XCTAssertTrue(history.power[3].value.isNaN)
        XCTAssertEqual(history.time[3].value, 700)
        XCTAssertEqual(history.time.last?.value, 0)
        XCTAssertEqual(history.power.last?.value, 0)
        XCTAssertTrue(history.hasPartialTime)
        XCTAssertEqual(history.timeChart.xDomain, history.powerChart.xDomain)
        XCTAssertEqual(
            history.timeChart.yFormat(1250), MetricUnit.millisecondsPerSecond.format(1250))
        XCTAssertEqual(history.powerChart.yFormat(2.5), MetricUnit.watts.format(2.5))
        XCTAssertGreaterThan(try XCTUnwrap(history.timeChart.yDomain?.upperBound), 1250)
        XCTAssertEqual(history.timeChart.gapThreshold, 3)
        XCTAssertEqual(history.powerChart.statisticsInterval, 1)
        XCTAssertTrue(history.powerChart.series[0].column.values[3].isNaN)
        XCTAssertTrue(ANEMenuHistory(samples: [], now: now).time.isEmpty)
        XCTAssertFalse(ANEMenuHistory(samples: [], now: now).hasPartialTime)
    }

    func testGPUMenuReservesRoomForCommandsOnSmallerDisplays() {
        XCTAssertEqual(GPUMenuBarContentView.contentHeight(screenHeight: 900, embedded: true), 600)
        XCTAssertEqual(GPUMenuBarContentView.contentHeight(screenHeight: 650, embedded: true), 440)
        XCTAssertEqual(GPUMenuBarContentView.contentHeight(screenHeight: 650, embedded: false), 580)
    }

    func testGPUAwakeCardHasRecordedHistoryAndIsNotGPUUtilization() throws {
        let now = Date()
        let points = [nil, 0.0, 80, 100].enumerated().map { index, awake in
            SystemHistoryPoint(
                date: now.addingTimeInterval(Double(index - 3) * 2), pressurePercent: 5,
                appMemory: 0, wired: 0, compressed: 0, cachedFiles: 0, swapUsed: 0,
                gpuUtilization: 5, gpuActiveResidency: awake,
                gpuActiveSampleCount: awake == nil ? 0 : 1)
        }
        var gpu = GPUSample(utilization: 5)
        gpu.activeResidency = 100
        let store = GPUTimelineStore()
        store.replace(points, span: 1800, live: nil, gpu: gpu)
        let card = try XCTUnwrap(store.cardTemplates.first { $0.label == "GPU awake" }).snapshot
        XCTAssertEqual(card.value, "100%")
        XCTAssertEqual(store.cardFeeds[0].value, "5%")
        let chart = try XCTUnwrap(card.statisticsModel)
        XCTAssertEqual(chart.yDomain, 0...100)
        XCTAssertEqual(chart.statisticsInterval, 15)
        XCTAssertEqual(chart.xDomain, now.addingTimeInterval(-1800)...now)
        XCTAssertTrue(chart.series[0].column.values[0].isNaN)
        XCTAssertEqual(Array(chart.series[0].column.values.dropFirst()), [0, 80, 100])
        XCTAssertEqual(chart.series[0].column.weights.map(Array.init), [0, 1, 1, 1])
        XCTAssertEqual(chart.series[0].column.highs?.last, 100)
        XCTAssertEqual(chart.series[0].column.lows?.last, 100)
        gpu.activeResidency = nil
        store.append(nil, gpu: gpu)
        XCTAssertNil(store.cardFeeds[4].value)
    }

    func testGPUReleasePreviewIncludesBandwidthAndNeuralEngineHistory() async throws {
        _ = NSApplication.shared
        let suite = "gpu-release-preview-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HistoryWindow.thirtyMinutes.rawValue, forKey: "historyRange.gpu")
        let options = ChartBenchmark.Options(arguments: [
            "--scenario", "gpuPage", "--points", "1800", "--interval", "1",
            "--span", "1800", "--width", "1800",
        ])
        let scenario = ChartBenchmark.makeScenario(options)
        let appeared = expectation(description: "The full GPU preview appears")
        let host = NSHostingView(
            rootView: scenario.view.defaultAppStorage(defaults)
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 20, width: 1800, height: 1040),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "GPU preview with sample data"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await fulfillment(of: [appeared], timeout: 5)
        scenario.tick()
        let updated = expectation(description: "The GPU preview receives sample readings")
        DispatchQueue.main.async { updated.fulfill() }
        await fulfillment(of: [updated], timeout: 5)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let charts = descendants(of: host, type: TrendSurfaceView.self)
        for label in [
            t("GPU bandwidth history"), t("Neural Engine activity timeline"),
            t("Neural Engine power timeline"),
        ] {
            let chart = try XCTUnwrap(charts.first { $0.feed?.model.accessibilityLabel == label })
            XCTAssertTrue(
                chart.feed?.model.series.first?.column.values.contains(where: \.isFinite) == true)
        }
        let bandwidth = try XCTUnwrap(
            descendants(of: host, type: GPUBandwidthSurfaceView.self).first)
        XCTAssertTrue(bandwidth.displayedValues.allSatisfy { $0.contains("GB/s") })
        XCTAssertFalse(
            descendants(of: host, type: NSTextField.self).contains {
                $0.stringValue == t("Actual bandwidth may be higher")
            })
        try captureGPUWindow(window, name: "gpu-release")
        let scroll = try XCTUnwrap(descendants(of: host, type: NSScrollView.self).first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 690))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.displayIfNeeded()
        try captureGPUWindow(window, name: "gpu-neural-engine-release")
    }

    func testNativeGPUMemorySheetAndBandwidthPanel() async throws {
        _ = NSApplication.shared
        for (name, width, appearance, available, limited) in [
            ("gpu-memory-bandwidth-light", CGFloat(860), NSAppearance.Name.aqua, true, false),
            ("gpu-memory-bandwidth-dark", CGFloat(1280), NSAppearance.Name.darkAqua, true, false),
            (
                "gpu-memory-bandwidth-unavailable", CGFloat(860), NSAppearance.Name.aqua, false,
                false
            ),
            ("gpu-memory-bandwidth-limits", CGFloat(860), NSAppearance.Name.darkAqua, true, true),
        ] {
            let now = Date()
            let labels = (1...32).map { "\($0)GB/s" }
            let read = try XCTUnwrap(
                GPUBandwidthHistogram(
                    labels: labels,
                    counts: (0..<32).map {
                        limited ? ($0 == 0 ? 100 : 0) : ($0 == 0 ? 60 : ($0 == 12 ? 40 : 0))
                    }))
            let write = try XCTUnwrap(
                GPUBandwidthHistogram(
                    labels: labels, counts: (0..<32).map { $0 == 0 ? 80 : ($0 == 4 ? 20 : 0) }))
            let combined = try XCTUnwrap(
                GPUBandwidthHistogram(
                    labels: labels,
                    counts: (0..<32).map { $0 == 0 ? 40 : ($0 == (limited ? 31 : 20) ? 60 : 0) }))
            var gpu = GPUSample(
                utilization: 15, inUseMemoryBytes: 2_200_000_000, name: "Apple M3 Pro")
            gpu.sampledAt = now
            gpu.performanceStates = [
                GPUPerformanceState(name: "P1", residency: 20),
                GPUPerformanceState(name: "P2", residency: 50),
            ]
            gpu.activeResidency = 70
            if available {
                gpu.bandwidth = GPUBandwidthSample(
                    timestamp: now, interval: 1, read: read, write: write, combined: combined)
            }
            let points = (0..<120).map { index -> SystemHistoryPoint in
                var point = SystemHistoryPoint(
                    date: now.addingTimeInterval(Double(index - 119) * 15), pressurePercent: 10,
                    appMemory: 0, wired: 0, compressed: 0, cachedFiles: 0, swapUsed: 0)
                if index >= 10, !(50..<58).contains(index) {
                    point.gpuMemoryBytes = 2_200_000_000 + sin(Double(index) / 8) * 400_000_000
                    if available {
                        point.gpuTotalBandwidthGBps = 12 + sin(Double(index) / 8) * 7
                        point.gpuReadBandwidthGBps = 7 + sin(Double(index) / 6) * 4
                        point.gpuWriteBandwidthGBps = 3 + cos(Double(index) / 7) * 2
                    }
                }
                return point
            }
            let timeline = GPUTimelineStore()
            timeline.replace(points, span: 1800, live: nil, gpu: gpu)
            let appeared = expectation(description: "GPU memory and bandwidth appear")
            let host = NSHostingView(
                rootView: MainRailLayout {
                    MetricCardsRow(cards: timeline.cardTemplates)
                    GPUBandwidthPanel(timeline: timeline)
                } rail: {
                    GPUClockStatesSection(feed: timeline.statesFeed)
                }
                .padding(20)
                .frame(width: width, height: 760)
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 60, width: width, height: 760),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            defer {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.close()
            }
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 761)
            let surface = try XCTUnwrap(
                descendants(of: host, type: GPUBandwidthSurfaceView.self).first)
            XCTAssertTrue(host.bounds.contains(surface.convert(surface.bounds, to: host)))
            XCTAssertEqual(
                surface.displayedEstimates,
                available
                    ? [combined.estimatedAverage, read.estimatedAverage, write.estimatedAverage]
                    : [nil, nil, nil])
            XCTAssertEqual(surface.displayedValues.count, 3)
            XCTAssertTrue(descendants(of: host, type: NSSegmentedControl.self).isEmpty)
            XCTAssertEqual(descendants(of: host, type: GPUStatesSurfaceView.self).count, 1)
            let bandwidthChart = try XCTUnwrap(
                descendants(of: host, type: TrendSurfaceView.self).first {
                    $0.feed === timeline.bandwidthChartFeed
                })
            XCTAssertTrue(
                host.bounds.contains(bandwidthChart.convert(bandwidthChart.bounds, to: host)))
            XCTAssertTrue(bandwidthChart.scrubbable)
            XCTAssertEqual(bandwidthChart.bounds.height, 170, accuracy: 1)
            XCTAssertEqual(
                timeline.bandwidthChartFeed.model.xDomain, timeline.utilizationFeed.model.xDomain)
            XCTAssertEqual(
                timeline.bandwidthChartFeed.model.series.map(\.name),
                [t("Total"), t("Reads"), t("Writes")])
            for series in timeline.bandwidthChartFeed.model.series {
                XCTAssertTrue(series.column.values.contains(where: \.isNaN))
                XCTAssertEqual(series.column.values.contains(where: \.isFinite), available)
            }
            if available {
                let hiddenLayers = bandwidthChart.layer?.sublayers?.filter(\.isHidden) ?? []
                bandwidthChart.showsHoverPopover = false
                let move = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: .mouseMoved,
                        location: bandwidthChart.convert(
                            CGPoint(
                                x: bandwidthChart.bounds.width * 0.75, y: bandwidthChart.bounds.midY
                            ), to: nil),
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                bandwidthChart.mouseMoved(with: move)
                let overlay = try XCTUnwrap(hiddenLayers.first { !$0.isHidden })
                overlay.displayIfNeeded()
                XCTAssertNotNil(overlay.contents)
                try captureGPUWindow(window, name: name + "-hover")
                bandwidthChart.mouseExited(with: move)
                XCTAssertTrue(overlay.isHidden)
            }
            for field in descendants(of: surface, type: NSTextField.self) {
                XCTAssertTrue(surface.bounds.contains(field.frame))
                let required = try XCTUnwrap(field.cell).cellSize(forBounds: field.bounds)
                XCTAssertLessThanOrEqual(required.height, field.bounds.height + 1)
            }
            try captureGPUWindow(window, name: name)
            let cardSurface = try XCTUnwrap(
                descendants(of: host, type: TrendSurfaceView.self).first {
                    $0.feed === timeline.cardFeeds[3].trend
                })
            let sheet = try await presentCard(cardSurface, in: window)
            let content = try XCTUnwrap(sheet.contentView)
            content.layoutSubtreeIfNeeded()
            sheet.displayIfNeeded()
            let chart = try XCTUnwrap(descendants(of: content, type: TrendSurfaceView.self).first)
            let model = try XCTUnwrap(chart.feed?.model)
            let values = try XCTUnwrap(model.series.first?.column.values)
            XCTAssertGreaterThan(values.filter(\.isFinite).count, 90)
            XCTAssertTrue(values.contains(where: \.isNaN))
            XCTAssertTrue(model.showsTimeAxis)
            XCTAssertEqual(model.statisticsInterval, 15)
            XCTAssertGreaterThan(chart.bounds.height, 250)
            try captureGPUWindow(sheet, name: name + "-memory-detail")
        }
    }

    func testBandwidthChartSharesHistoryRangeAndAppendsWithoutChangingOldReadings() throws {
        let now = Date()
        let points = (0..<3).map { index -> SystemHistoryPoint in
            var point = SystemHistoryPoint(
                date: now.addingTimeInterval(Double(index - 2) * 30), pressurePercent: 10,
                appMemory: 0, wired: 0, compressed: 0, cachedFiles: 0, swapUsed: 0)
            if index > 0 {
                point.gpuReadBandwidthGBps = 2
                point.gpuWriteBandwidthGBps = 3
                point.gpuTotalBandwidthGBps = 8
            }
            return point
        }
        let timeline = GPUTimelineStore()
        for (span, interval) in [
            (300.0, 5.0), (1800, 15), (3600, 30), (21600, 300), (86400, 900), (604800, 7200),
        ] {
            timeline.replace(points, span: span, live: nil, gpu: nil)
            let chart = timeline.bandwidthChartFeed.model
            XCTAssertEqual(chart.xDomain, timeline.utilizationFeed.model.xDomain)
            XCTAssertEqual(chart.xDomain?.lowerBound, now.addingTimeInterval(-span))
            XCTAssertEqual(chart.statisticsInterval, interval)
            XCTAssertEqual(chart.valueUnit, "GB/s")
            XCTAssertEqual(
                chart.statisticsNote,
                t(
                    "Approximate GPU memory bandwidth based on buckets reported by macOS. Actual bandwidth may be higher. Missing readings and older logs are gaps."
                ))
            XCTAssertEqual(chart.accessibilityValue, chart.statisticsNote)
            XCTAssertTrue(chart.showsTimeAxis)
            XCTAssertEqual(chart.series.count, 3)
            XCTAssertEqual(chart.series[0].column.values.last, 8)
            XCTAssertEqual(chart.series[1].column.values.last, 2)
            XCTAssertEqual(chart.series[2].column.values.last, 3)
            for series in chart.series {
                XCTAssertTrue(try XCTUnwrap(series.column.values.first).isNaN)
                XCTAssertEqual(series.column.weights.map(Array.init), [0, 1, 1])
            }
        }
        let frozen = timeline.bandwidthChartFeed.model
        for (series, expected) in zip(frozen.series, [8.0, 2, 3]) {
            let buckets = TrendStatistics.buckets(series, model: frozen)
            let summary = try XCTUnwrap(ChartStatistics.summary(buckets))
            XCTAssertEqual(summary.mean, expected)
            XCTAssertEqual(summary.minimum, expected)
            XCTAssertEqual(summary.maximum, expected)
            XCTAssertEqual(summary.sampleCount, 2)
        }
        let top = try XCTUnwrap(frozen.yDomain?.upperBound)
        var live = aneMenuSample(at: now.addingTimeInterval(2), time: nil, power: nil)
        live.gpuTotalBandwidthGBps = 24
        live.gpuReadBandwidthGBps = 15
        live.gpuWriteBandwidthGBps = 4
        timeline.append(live, gpu: nil)
        let updated = timeline.bandwidthChartFeed.model
        XCTAssertEqual(updated.series[0].column.values.last, 24)
        XCTAssertEqual(Array(updated.series[0].column.values.dropFirst().dropLast()), [8, 8])
        XCTAssertEqual(frozen.series[0].column.values.last, 8)
        XCTAssertGreaterThan(try XCTUnwrap(updated.yDomain?.upperBound), top)
        let expanded = updated.yDomain
        live.timestamp.addTimeInterval(2)
        live.gpuTotalBandwidthGBps = 2
        timeline.append(live, gpu: nil)
        XCTAssertEqual(timeline.bandwidthChartFeed.model.yDomain, expanded)
        let revision = timeline.bandwidthChartFeed.historyRevision
        timeline.replace([SystemHistoryPoint(sample: live)], span: 300, live: nil, gpu: nil)
        XCTAssertEqual(timeline.bandwidthChartFeed.historyRevision, revision + 1)
        XCTAssertLessThan(
            try XCTUnwrap(timeline.bandwidthChartFeed.model.yDomain?.upperBound),
            try XCTUnwrap(expanded?.upperBound))
    }

    func testGPUBandwidthPanelKeepsChannelsSeparateAndClearsStaleReadings() throws {
        let read = try XCTUnwrap(
            GPUBandwidthHistogram(labels: ["1GB/s", "2GB/s", "32GB/s"], counts: [3, 1, 0]))
        let write = try XCTUnwrap(
            GPUBandwidthHistogram(labels: ["1GB/s", "2GB/s", "32GB/s"], counts: [1, 3, 0]))
        let combined = try XCTUnwrap(
            GPUBandwidthHistogram(labels: ["1GB/s", "2GB/s", "32GB/s"], counts: [2, 2, 0]))
        let now = Date()
        let sample = try XCTUnwrap(
            GPUBandwidthSample(
                timestamp: now, interval: 1, read: read, write: write, combined: combined))
        let feed = GPUBandwidthFeed()
        let surface = GPUBandwidthSurfaceView()
        surface.attach(feed)
        XCTAssertEqual(surface.displayedEstimates, [nil, nil, nil])
        feed.publish(sample, at: now)
        XCTAssertEqual(
            surface.displayedEstimates,
            [combined.estimatedAverage, read.estimatedAverage, write.estimatedAverage])
        XCTAssertEqual(
            surface.displayedValues.first,
            t("~%@ GB/s", 1.5.formatted(.number.precision(.fractionLength(0...1)))))
        XCTAssertEqual(surface.displayedNotes, ["", "", ""])
        XCTAssertTrue((surface.accessibilityValue() as? String)?.contains("GB/s") == true)
        feed.publish(GPUBandwidthSample(timestamp: now, interval: 1, read: read), at: now)
        XCTAssertEqual(surface.displayedEstimates, [nil, read.estimatedAverage, nil])
        XCTAssertEqual(surface.displayedValues.first, t("Unavailable"))
        feed.publish(sample, at: now.addingTimeInterval(6))
        XCTAssertEqual(surface.displayedEstimates, [nil, nil, nil])
        XCTAssertEqual(surface.displayedValues, Array(repeating: t("Unavailable"), count: 3))
        surface.detach()
    }

    func testGPUBandwidthReadoutKeepsUnresolvedValuesWithoutRepeatedWarnings() throws {
        let labels = ["1GB/s", "2GB/s", "32GB/s"]
        let low = try XCTUnwrap(GPUBandwidthHistogram(labels: labels, counts: [100, 0, 0]))
        let high = try XCTUnwrap(GPUBandwidthHistogram(labels: labels, counts: [30, 0, 10]))
        let now = Date()
        let feed = GPUBandwidthFeed()
        let surface = GPUBandwidthSurfaceView()
        surface.attach(feed)
        feed.publish(
            GPUBandwidthSample(timestamp: now, interval: 1, read: low, combined: high), at: now)
        XCTAssertEqual(surface.displayedValues[1], t("Below resolution"))
        XCTAssertEqual(surface.displayedNotes[1], t("May include zero traffic"))
        XCTAssertEqual(surface.displayedNotes[0], "")
        XCTAssertEqual(surface.displayedValues[2], t("Unavailable"))
        let accessibility = try XCTUnwrap(surface.accessibilityValue() as? String)
        XCTAssertTrue(accessibility.contains(t("Below resolution")))
        XCTAssertFalse(accessibility.contains(t("Actual bandwidth may be higher")))
        feed.publish(
            GPUBandwidthSample(
                timestamp: now, interval: 1, read: high, write: high, combined: high), at: now)
        XCTAssertEqual(surface.displayedNotes, ["", "", ""])
        XCTAssertTrue(surface.displayedEstimates.allSatisfy { $0?.includesHighestBin == true })
        let timeline = GPUTimelineStore()
        timeline.replace([], span: 1800, live: nil, gpu: nil)
        let caption = try XCTUnwrap(timeline.bandwidthChartFeed.model.statisticsNote)
        XCTAssertEqual(
            caption.components(separatedBy: t("Actual bandwidth may be higher")).count - 1, 1)
    }

    func testGPUMemoryCardCarriesRecordedHistoryIntoItsDetailSnapshot() throws {
        let now = Date()
        let readings: [Double?] = [nil, 1_000_000_000, 3_000_000_000]
        let points = readings.enumerated().map { index, bytes in
            SystemHistoryPoint(
                date: now.addingTimeInterval(Double(index - 2) * 2), pressurePercent: 10,
                appMemory: 0, wired: 0, compressed: 0, cachedFiles: 0, swapUsed: 0,
                gpuMemoryBytes: bytes, gpuMemorySampleCount: bytes == nil ? 0 : 1)
        }
        let timeline = GPUTimelineStore()
        timeline.replace(
            points, span: 1800, live: nil,
            gpu: GPUSample(utilization: 15, inUseMemoryBytes: 3_000_000_000))
        let card = try XCTUnwrap(timeline.cardTemplates.first { $0.label == "GPU memory" })
        let snapshot = card.snapshot
        let model = try XCTUnwrap(snapshot.statisticsModel)
        let column = try XCTUnwrap(model.series.first?.column)
        XCTAssertEqual(snapshot.value, ByteFormat.string(3_000_000_000))
        XCTAssertTrue(try XCTUnwrap(column.values.first).isNaN)
        XCTAssertEqual(Array(column.values.dropFirst()), [1_000_000_000, 3_000_000_000])
        XCTAssertEqual(column.weights.map(Array.init), [0, 1, 1])
        XCTAssertEqual(column.lows?.last, 3_000_000_000)
        XCTAssertEqual(column.highs?.last, 3_000_000_000)
        XCTAssertEqual(model.statisticsInterval, 15)
        XCTAssertEqual(model.xDomain?.lowerBound, now.addingTimeInterval(-1800))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.yDomain?.upperBound), 3_000_000_000)
        timeline.replace([], span: 300, live: nil, gpu: GPUSample(utilization: 0))
        XCTAssertEqual(column.values.last, 3_000_000_000)
        XCTAssertNil(card.snapshot.value)
    }

    func testGPUHeadlineCardsKeepANEMetricsTogetherWithTheirOwnFeeds() {
        let timeline = GPUTimelineStore()
        XCTAssertEqual(
            timeline.cardTemplates.map(\.label),
            ["GPU", "GPU power", "GPU memory", "GPU awake", "ANE time", "ANE power"])
        XCTAssertTrue(timeline.cardTemplates[4].live === timeline.cardFeeds[2])
        XCTAssertTrue(timeline.cardTemplates[5].live === timeline.cardFeeds[5])
        XCTAssertEqual(timeline.cardTemplates[4].unit, .millisecondsPerSecond)
        XCTAssertEqual(timeline.cardTemplates[5].unit, .watts)
    }

    func testClockStatesIncludePoweredOffTimeAndExplainTheSample() {
        let feed = GPUStatesFeed()
        feed.publish(
            [
                GPUPerformanceState(name: "P1", residency: 25),
                GPUPerformanceState(name: "P2", residency: 35),
            ], active: 60)
        let surface = GPUStatesSurfaceView()
        surface.attach(feed)
        let value = surface.accessibilityValue() as? String
        XCTAssertEqual(
            value,
            [
                t("%1$@: %2$@ of the latest sample", "OFF", "40%"),
                t("%1$@: %2$@ of the latest sample", "P1", "25%"),
                t("%1$@: %2$@ of the latest sample", "P2", "35%"),
            ].joined(separator: ", "))
        XCTAssertEqual(
            surface.accessibilityHelp(),
            t(
                "Clock states are GPU speed levels. Percentages show time in each state in the latest sample, not GPU load or history-range averages."
            ))
        feed.publish([], active: nil)
        XCTAssertEqual(surface.accessibilityValue() as? String, "")
    }

    func testNativeClockStateExplanationFitsTheRailAndPopover() async throws {
        _ = NSApplication.shared
        for (name, railWidth, appearance, count) in [
            ("clock-help-compact", CGFloat(260), NSAppearance.Name.aqua, 12),
            ("clock-help-dark", CGFloat(300), NSAppearance.Name.darkAqua, 16),
            ("clock-help-unavailable", CGFloat(260), NSAppearance.Name.aqua, 0),
        ] {
            let feed = GPUStatesFeed()
            feed.publish(
                (0..<count).map {
                    GPUPerformanceState(name: "P\($0 + 1)", residency: 60 / Double(count))
                }, active: count > 0 ? 60 : nil)
            let appeared = expectation(description: "Clock-state help appears")
            let host = NSHostingView(
                rootView: HStack(alignment: .top, spacing: 20) {
                    GPUClockStatesSection(feed: feed).frame(width: railWidth)
                    GPUClockStatesExplanation().frame(width: 328)
                }
                .padding(16)
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: railWidth + 380, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, railWidth + 381)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 600)
            let surface = try XCTUnwrap(
                descendants(of: host, type: GPUStatesSurfaceView.self).first)
            XCTAssertGreaterThanOrEqual(
                surface.bounds.height, GPUStatesSurfaceView.height(forStates: count))
            XCTAssertTrue(host.bounds.contains(surface.convert(surface.bounds, to: host)))
            if let path = ProcessInfo.processInfo.environment["MACPERF_ANE_ARTIFACTS"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let imageURL = directory.appendingPathComponent(name + "-window.png")
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = [
                    "-x", "-o", "-l", String(window.windowNumber), imageURL.path,
                ]
                try capture.run()
                capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0)
                let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: imageURL)))
                let pixels = try XCTUnwrap(image.bitmapData)
                let shades = Set(
                    stride(
                        from: 0, to: image.bytesPerRow * image.pixelsHigh, by: image.samplesPerPixel
                    )
                    .map { pixels[$0] })
                XCTAssertGreaterThan(shades.count, 20)
            }
        }
    }

    func testANEPowerDisplayKeepsHelperStateSeparateFromANETime() {
        let now = Date()
        var gpu = GPUSample(utilization: 8)
        gpu.sampledAt = now
        gpu.aneTimeMillisecondsPerSecond = 750
        gpu.aneSampleIsPartial = false
        gpu.anePowerRequiresHelper = true
        let timeline = GPUTimelineStore()
        timeline.replace([], span: 300, live: nil, gpu: gpu)
        XCTAssertEqual(timeline.cardFeeds[5].value, t("Helper required"))
        XCTAssertEqual(timeline.aneStatusText.text, t("Active"))
        gpu.anePowerRequiresHelper = false
        gpu.anePowerWatts = 3.25
        gpu.anePowerSampledAt = now
        gpu.anePowerSampleInterval = 1.04
        timeline.append(nil, gpu: gpu)
        XCTAssertEqual(timeline.cardFeeds[5].value, MetricUnit.watts.format(3.25))
        XCTAssertEqual(timeline.anePowerStatusText.text, t("powermetrics (root)"))
        XCTAssertEqual(timeline.cardFeeds[2].value, MetricUnit.millisecondsPerSecond.format(750))
        XCTAssertNotNil(timeline.anePowerFeed.model.statisticsInterval)
        gpu.anePowerWatts = 0
        timeline.append(nil, gpu: gpu)
        XCTAssertEqual(timeline.cardFeeds[5].value, MetricUnit.watts.format(0))
        XCTAssertEqual(timeline.aneStatusText.text, t("Active"))
        gpu.anePowerSampledAt = now.addingTimeInterval(-20)
        timeline.append(nil, gpu: gpu)
        XCTAssertNil(timeline.cardFeeds[5].value)
    }

    func testANEActivityPanelRendersActivePartialAndUnavailableStates() async throws {
        _ = NSApplication.shared
        for (name, width, appearance, rate, partial) in [
            ("active", CGFloat(820), NSAppearance.Name.aqua, Double(720), false),
            ("partial", CGFloat(680), NSAppearance.Name.darkAqua, Double(1250), true),
            ("unavailable", CGFloat(680), NSAppearance.Name.aqua, Double.nan, false),
            ("power-active", CGFloat(820), NSAppearance.Name.aqua, Double(720), false),
            ("power-helper", CGFloat(680), NSAppearance.Name.darkAqua, Double(750), false),
            ("power-unavailable", CGFloat(680), NSAppearance.Name.aqua, Double(0), false),
            ("power-wide", CGFloat(1280), NSAppearance.Name.darkAqua, Double(720), false),
        ] {
            let now = Date()
            let points = (0..<120).map { index in
                let missing =
                    index < 12 || (50..<58).contains(index)
                    || (name.contains("unavailable") && index > 95)
                let powerAvailable = !missing && name != "power-helper"
                return SystemHistoryPoint(
                    date: now.addingTimeInterval(Double(index - 119) * 2), pressurePercent: 10,
                    appMemory: 0, wired: 0, compressed: 0, cachedFiles: 0, swapUsed: 0,
                    gpuUtilization: 15, gpuPowerWatts: 1.2,
                    anePowerWatts: powerAvailable
                        ? (index == 119 ? 3.25 : max(0, 2 + 1.5 * sin(Double(index) / 7))) : nil,
                    anePowerSampleCount: powerAvailable ? 1 : 0,
                    aneTimeMillisecondsPerSecond: missing
                        ? nil : (index == 119 ? rate : max(0, 420 + 300 * sin(Double(index) / 7))),
                    aneSampleIsPartial: missing ? nil : partial, aneSampleCount: missing ? 0 : 1)
            }
            var gpu = GPUSample(utilization: 15, name: "Apple M3 Pro")
            gpu.sampledAt = now
            gpu.gpuPowerWatts = 1.2
            gpu.anePowerRequiresHelper = name == "power-helper"
            if !name.contains("unavailable") && name != "power-helper" {
                gpu.anePowerWatts = 3.25
                gpu.anePowerSampledAt = now
                gpu.anePowerSampleInterval = 1.02
            }
            gpu.aneTimeMillisecondsPerSecond = rate.isFinite ? rate : nil
            gpu.aneSampleIsPartial = rate.isFinite ? partial : nil
            let timeline = GPUTimelineStore()
            timeline.replace(points, span: 300, live: nil, gpu: gpu)
            let appeared = expectation(description: "ANE preview appears")
            let host = NSHostingView(
                rootView:
                    VStack(spacing: 16) {
                        MetricCardsRow(cards: timeline.cardTemplates, xDomain: nil, loading: false)
                        if name.hasPrefix("power-") {
                            ANEPowerPanel(timeline: timeline)
                        } else {
                            ANEActivityPanel(timeline: timeline)
                        }
                    }
                    .padding(20)
                    .frame(width: width, height: 620)
                    .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: width, height: 620),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 621)
            let surfaces = descendants(of: host, type: TrendSurfaceView.self)
            let timeCard = try XCTUnwrap(surfaces.first { $0.feed === timeline.cardFeeds[2].trend })
            let powerCard = try XCTUnwrap(
                surfaces.first { $0.feed === timeline.cardFeeds[5].trend })
            let timeFrame = timeCard.convert(timeCard.bounds, to: host)
            let powerFrame = powerCard.convert(powerCard.bounds, to: host)
            XCTAssertEqual(timeFrame.midY, powerFrame.midY, accuracy: 1)
            XCTAssertGreaterThan(powerFrame.minX, timeFrame.maxX)
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let pixels = try XCTUnwrap(image.bitmapData)
            let shades = Set(
                stride(
                    from: 0, to: image.bytesPerRow * image.pixelsHigh,
                    by: image.samplesPerPixel
                ).map { pixels[$0] })
            XCTAssertGreaterThan(shades.count, 20)
            XCTAssertTrue(timeline.aneFeed.model.series[0].column.values.contains(where: \.isNaN))
            XCTAssertTrue(
                timeline.anePowerFeed.model.series[0].column.values.contains(where: \.isNaN))
            if let path = ProcessInfo.processInfo.environment["MACPERF_ANE_ARTIFACTS"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(name + ".png"))
                let presented = expectation(
                    description: "Window compositor presents the ANE preview")
                DispatchQueue.main.async { presented.fulfill() }
                await fulfillment(of: [presented], timeout: 3)
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = [
                    "-x", "-o", "-l", String(window.windowNumber),
                    directory.appendingPathComponent(name + "-window.png").path,
                ]
                try capture.run()
                capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0)
            }
            window.close()
        }
    }

    func testANEActivityUsesTimeAndDistinguishesPartialAndMissingReadings() throws {
        let timeline = GPUTimelineStore()
        var gpu = GPUSample(utilization: 10)
        gpu.anePowerWatts = 0
        timeline.replace([], span: 300, live: nil, gpu: gpu)
        XCTAssertNil(timeline.cardFeeds[2].value)
        XCTAssertEqual(timeline.aneStatusText.text, t("Unavailable"))
        gpu.aneTimeMillisecondsPerSecond = 720
        gpu.aneSampleIsPartial = false
        timeline.append(nil, gpu: gpu)
        XCTAssertEqual(timeline.cardFeeds[2].value, MetricUnit.millisecondsPerSecond.format(720))
        XCTAssertEqual(timeline.aneStatusText.text, t("Active"))
        XCTAssertFalse(try XCTUnwrap(timeline.cardFeeds[2].value).contains("%"))
        XCTAssertNotNil(timeline.aneFeed.model.statisticsInterval)
        gpu.aneSampleIsPartial = true
        timeline.append(nil, gpu: gpu)
        XCTAssertEqual(timeline.aneStatusText.text, t("Partial coverage"))
        XCTAssertEqual(
            timeline.cardFeeds[2].value,
            t("At least %@", MetricUnit.millisecondsPerSecond.format(720)))
        gpu.aneTimeMillisecondsPerSecond = 0
        timeline.append(nil, gpu: gpu)
        XCTAssertEqual(timeline.aneStatusText.text, t("Partial coverage"))
        gpu.aneSampleIsPartial = false
        timeline.append(nil, gpu: gpu)
        XCTAssertEqual(timeline.aneStatusText.text, t("No activity recorded"))
        gpu.aneTimeMillisecondsPerSecond = 1450
        timeline.append(nil, gpu: gpu)
        XCTAssertEqual(timeline.cardFeeds[2].value, MetricUnit.millisecondsPerSecond.format(1450))
    }

    func testFirstCardClickPresentsTheCapturedChartInAFullSizeSheet() async throws {
        _ = NSApplication.shared
        let feed = MetricCardFeed()
        let end = Date(timeIntervalSinceReferenceDate: 120)
        feed.publish(
            value: "25%", tint: .systemGreen,
            column: LiveColumn(times: [0, 30, 60, 90, 120], values: [10, 30, 20, 40, 25]),
            xDomain: end.addingTimeInterval(-120)...end, yDomain: 0...100,
            statisticsInterval: 5, gapThreshold: 45, name: "Pressure")
        let card = MetricCardData(
            label: "Pressure", value: "25%", unit: .percent,
            explanation: MetricExplanation(
                meaning: "Memory pressure describes demand on the memory system.",
                calculation: "The index uses the recorded pressure samples."), live: feed)
        let host = NSHostingView(rootView: MetricCard(data: card).frame(width: 220, height: 140))
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 850),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let surface = try XCTUnwrap(descendants(of: host, type: TrendSurfaceView.self).first)
        XCTAssertNotNil(surface.onActivate)

        let sheet = try await presentCard(surface, in: window)
        let content = try XCTUnwrap(sheet.contentView)
        content.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        XCTAssertGreaterThanOrEqual(content.bounds.width, 700)
        XCTAssertGreaterThanOrEqual(content.bounds.height, 450)
        let chart = try XCTUnwrap(descendants(of: content, type: TrendSurfaceView.self).first)
        let model = try XCTUnwrap(chart.feed?.model)
        XCTAssertFalse(model.bare)
        XCTAssertTrue(model.showsTimeAxis)
        XCTAssertEqual(model.series.first?.column.values.map { $0 }, [10, 30, 20, 40, 25])

        let newEnd = Date(timeIntervalSinceReferenceDate: 150)
        feed.publish(
            value: "65%", tint: .systemGreen,
            column: LiveColumn(times: [30, 60, 90, 120, 150], values: [30, 20, 40, 25, 65]),
            xDomain: newEnd.addingTimeInterval(-120)...newEnd, yDomain: 0...100,
            statisticsInterval: 5, gapThreshold: 45, name: "Pressure")
        XCTAssertEqual(
            chart.feed?.model.series.first?.column.values.map { $0 }, [10, 30, 20, 40, 25])

        let done = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        let dismissed = expectation(description: "Done dismisses the detail sheet")
        let dismissalObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: window, queue: .main
        ) { _ in
            DispatchQueue.main.async { dismissed.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(dismissalObserver) }
        sheet.makeKey()
        if !sheet.performKeyEquivalent(with: done) { sheet.sendEvent(done) }
        await fulfillment(of: [dismissed], timeout: 5)
        XCTAssertNil(window.attachedSheet)

        let reopened = try await presentCard(surface, in: window)
        let reopenedContent = try XCTUnwrap(reopened.contentView)
        reopenedContent.layoutSubtreeIfNeeded()
        let reopenedChart = try XCTUnwrap(
            descendants(of: reopenedContent, type: TrendSurfaceView.self).first)
        XCTAssertGreaterThanOrEqual(reopenedContent.bounds.width, 700)
        XCTAssertEqual(
            reopenedChart.feed?.model.series.first?.column.values.map { $0 }, [30, 20, 40, 25, 65])
        XCTAssertEqual(reopenedChart.feed?.model.xDomain?.upperBound, newEnd)
    }

    private func aneMenuSample(
        at date: Date, time: Double?, power: Double?, partial: Bool = false
    ) -> SystemSample {
        var sample = SystemSample(
            timestamp: date, totalRAM: 0, free: 0, active: 0, inactive: 0, wired: 0,
            speculative: 0, compressed: 0, appMemory: 0, cachedFiles: 0,
            swapTotal: 0, swapUsed: 0, pressureLevel: .normal, pressurePercent: 0,
            pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0)
        sample.aneTimeMillisecondsPerSecond = time
        sample.aneSampleIsPartial = partial
        sample.anePowerWatts = power
        sample.anePowerSampledAt = power == nil ? nil : date
        sample.anePowerSampleInterval = power == nil ? nil : 1
        return sample
    }

    private func captureGPUWindow(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MACPERF_GPU_ARTIFACTS"] else {
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent(name + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), imageURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: imageURL)))
        let pixels = try XCTUnwrap(image.bitmapData)
        let shades = Set(
            stride(from: 0, to: image.bytesPerRow * image.pixelsHigh, by: image.samplesPerPixel).map
            { pixels[$0] })
        XCTAssertGreaterThan(shades.count, 20)
    }

    private func presentCard(
        _ surface: TrendSurfaceView, in window: NSWindow
    ) async throws -> NSWindow {
        let presented = expectation(description: "The card presents its detail sheet")
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willBeginSheetNotification, object: window, queue: .main
        ) { _ in
            DispatchQueue.main.async { presented.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        surface.mouseDown(with: event)
        await fulfillment(of: [presented], timeout: 5)
        return try XCTUnwrap(window.attachedSheet)
    }

    private func descendants<ViewType: NSView>(of view: NSView, type: ViewType.Type) -> [ViewType] {
        var found = (view as? ViewType).map { [$0] } ?? []
        for child in view.subviews { found.append(contentsOf: descendants(of: child, type: type)) }
        return found
    }

}
