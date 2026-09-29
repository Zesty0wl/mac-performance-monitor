import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class EnergyChartHoverTests: XCTestCase {
    func testEachEnergyCardOpensItsOwnPopoutWithNativeCharts() async throws {
        _ = NSApplication.shared
        let fixture = energyFixture()
        let history = EnergyHistoryModel(history: fixture.history, daily: fixture.daily)
        let appeared = expectation(description: "The Energy cards appear")
        let host = NSHostingView(
            rootView:
                EnergyMetricCards(history: history, battery: fixture.battery, window: .oneHour)
                .padding(20)
                .frame(width: 860, height: 340)
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 80, width: 860, height: 820),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        await fulfillment(of: [appeared], timeout: 5)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let surfaces = chartSurfaces(in: host)
        XCTAssertEqual(surfaces.count, 6)
        try save(host, name: "energy-cards-dark")
        for (index, kind) in EnergyCardKind.allCases.enumerated() {
            let surface = try XCTUnwrap(surfaces.indices.contains(index) ? surfaces[index] : nil)
            XCTAssertNotNil(surface.onActivate)
            let opened = expectation(description: "The \(kind.rawValue) popout opens")
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willBeginSheetNotification, object: window, queue: .main
            ) { _ in DispatchQueue.main.async { opened.fulfill() } }
            let click = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1))
            surface.mouseDown(with: click)
            await fulfillment(of: [opened], timeout: 5)
            NotificationCenter.default.removeObserver(observer)
            let sheet = try XCTUnwrap(window.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            content.layoutSubtreeIfNeeded()
            sheet.displayIfNeeded()
            XCTAssertGreaterThanOrEqual(content.bounds.width, 700)
            XCTAssertGreaterThanOrEqual(content.bounds.height, 450)
            let detailChart = try XCTUnwrap(chartSurfaces(in: content).first)
            XCTAssertEqual(detailChart.feed?.model.accessibilityLabel, kind.title(fixture.battery))
            XCTAssertTrue(detailChart.scrubbable)
            XCTAssertFalse(detailChart.feed?.model.bare ?? true)
            try save(content, name: "energy-detail-" + kind.rawValue)
            let picker = try XCTUnwrap(rangeControl(in: content))
            picker.selectedSegment = 0
            XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
            let changedRange = expectation(description: "The chart range changes")
            DispatchQueue.main.async { changedRange.fulfill() }
            await fulfillment(of: [changedRange], timeout: 5)
            content.layoutSubtreeIfNeeded()
            let selectedChart = try XCTUnwrap(chartSurfaces(in: content).first)
            let domain = try XCTUnwrap(selectedChart.feed?.model.xDomain)
            let expected = kind.isLifetime ? 30 * 86_400.0 : HistoryWindow.allCases[0].seconds
            XCTAssertEqual(domain.upperBound.timeIntervalSince(domain.lowerBound), expected)
            XCTAssertEqual(domain.upperBound, fixture.battery.timestamp)
            let closed = expectation(description: "The popout closes")
            let closing = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndSheetNotification, object: window, queue: .main
            ) { _ in DispatchQueue.main.async { closed.fulfill() } }
            let done = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: sheet.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            sheet.makeKey()
            if !sheet.performKeyEquivalent(with: done) { sheet.sendEvent(done) }
            await fulfillment(of: [closed], timeout: 5)
            NotificationCenter.default.removeObserver(closing)
        }
    }

    func testNativeEnergyCardsFitCompactAndWideRailLayouts() async throws {
        _ = NSApplication.shared
        let fixture = energyFixture()
        for (name, width, appearance) in [
            ("compact", 860.0, NSAppearance.Name.aqua),
            ("wide", 1440.0, NSAppearance.Name.darkAqua),
        ] {
            let history = EnergyHistoryModel(history: fixture.history, daily: fixture.daily)
            let appeared = expectation(description: "The \(name) Energy cards appear")
            let host = NSHostingView(
                rootView: MainRailLayout {
                    EnergyMetricCards(history: history, battery: fixture.battery, window: .oneHour)
                } rail: {
                    Color.clear.frame(height: 1)
                }
                .padding(20)
                .frame(width: width, height: 400)
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 80, width: width, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let frames = chartSurfaces(in: host).map { $0.convert($0.bounds, to: host) }
            XCTAssertEqual(frames.count, 6)
            for (index, frame) in frames.enumerated() {
                XCTAssertGreaterThan(frame.width, 100)
                XCTAssertGreaterThanOrEqual(frame.minX, 20)
                XCTAssertLessThanOrEqual(frame.maxX, width - 336)
                XCTAssertTrue(host.bounds.contains(frame))
                for other in frames.dropFirst(index + 1) {
                    XCTAssertFalse(frame.intersects(other))
                }
            }
            try save(host, name: "energy-rail-" + name)
        }
    }

    func testNativeEnergyDetailsHandleMissingHistoryAndCharging() async throws {
        _ = NSApplication.shared
        let fixture = energyFixture()
        var charging = fixture.battery
        charging.isCharging = true
        charging.isOnAC = true
        charging.timeToFullMinutes = 45
        charging.runtimeEstimate = nil
        for (name, battery, history) in [
            ("empty", fixture.battery, [BatteryHistoryPoint]()),
            ("charging", charging, [BatteryHistoryPoint(sample: charging)]),
        ] {
            let snapshot = EnergyMetricSnapshot(
                kind: .runtime, battery: battery, history: history, daily: [],
                window: .oneHour, capturedAt: battery.timestamp)
            let appeared = expectation(description: "The runtime detail appears")
            let host = NSHostingView(
                rootView: EnergyMetricDetailSheet(snapshot: snapshot)
                    .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 80, width: 760, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFront(nil)
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertGreaterThanOrEqual(host.fittingSize.width, 700)
            try save(host, name: "energy-runtime-" + name)
            window.close()
        }
    }

    func testEnergyHistoryDoesNotRepublishCachedBatterySamplesAndSeparatesPacks() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var battery = BatterySample(
            timestamp: now, isPresent: true, chargePercent: 75, serialNumber: "first")
        let model = EnergyHistoryModel()
        model.append(battery, range: .oneHour)
        model.append(battery, range: .oneHour)
        XCTAssertEqual(model.history.count, 1)
        battery.timestamp = now.addingTimeInterval(5)
        model.append(battery, range: .oneHour)
        XCTAssertEqual(model.history.count, 2)
        battery.serialNumber = "replacement"
        battery.timestamp = now.addingTimeInterval(10)
        model.append(battery, range: .oneHour)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(
            model.history.first?.batteryID, BatteryIdentity.identifier(for: "replacement"))
    }

    func testForecastIsSeparateAndUnavailableWhileCharging() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var battery = BatterySample(
            timestamp: now, isPresent: true, chargePercent: 50,
            runtimeEstimate: BatteryRuntimeEstimate(
                minutesRemaining: 120, fullChargeMinutes: 240, source: .recentUse),
            serialNumber: "pack")
        let points = [BatteryHistoryPoint(sample: battery)]
        var snapshot = EnergyMetricSnapshot(
            kind: .runtime, battery: battery, history: points, daily: [], window: .oneHour,
            capturedAt: now)
        let forecast = try XCTUnwrap(EnergyChargeForecast.make(snapshot))
        XCTAssertEqual(forecast.end.date.timeIntervalSince(forecast.start.date), 7200)
        XCTAssertEqual(forecast.start.value, 50)
        XCTAssertEqual(forecast.end.value, 0)
        XCTAssertEqual(snapshot.history, points)
        battery.isCharging = true
        snapshot.battery = battery
        XCTAssertNil(EnergyChargeForecast.make(snapshot))
    }

    func testForecastUsesSelectedRangeAndExcludesPreviousBattery() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let battery = BatterySample(
            timestamp: now, isPresent: true, chargePercent: 70,
            runtimeEstimate: BatteryRuntimeEstimate(
                minutesRemaining: 120, fullChargeMinutes: 170, source: .recentUse),
            serialNumber: "current")
        var earlier = battery
        earlier.timestamp = now.addingTimeInterval(-7200)
        earlier.chargePercent = 90
        var otherPack = battery
        otherPack.timestamp = now.addingTimeInterval(-60)
        otherPack.chargePercent = 97
        otherPack.serialNumber = "other"
        let current = BatteryHistoryPoint(sample: battery)
        let history = [
            BatteryHistoryPoint(sample: earlier), BatteryHistoryPoint(sample: otherPack), current,
        ]
        let snapshot = EnergyMetricSnapshot(
            kind: .runtime, battery: battery, history: [current], daily: [], window: .oneHour,
            capturedAt: now)
        let day = try XCTUnwrap(
            EnergyChargeForecast.make(snapshot, history: history, window: .oneDay))
        let values = day.observed.map(\.value).filter(\.isFinite)
        XCTAssertTrue(values.contains(90))
        XCTAssertTrue(values.contains(70))
        XCTAssertFalse(values.contains(97))
        let session = try XCTUnwrap(
            EnergyChargeForecast.make(
                snapshot, history: history, window: .oneDay,
                domain: now.addingTimeInterval(-90)...now))
        XCTAssertEqual(session.observed.map(\.value).filter(\.isFinite), [70])
        XCTAssertEqual(snapshot.history, [current])
        XCTAssertEqual(snapshot.window, .oneHour)
    }

    func testAllSixEnergyCardsHaveDetailsAndAppropriateTimeDomains() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let battery = BatterySample(
            timestamp: now, isPresent: true, chargePercent: 80, powerWatts: 5, systemPowerWatts: 20,
            voltageMilliVolts: 12_000, temperatureCelsius: 30, cycleCount: 200, healthPercent: 95,
            serialNumber: "pack")
        let history = [BatteryHistoryPoint(sample: battery)]
        for kind in EnergyCardKind.allCases {
            let card = EnergyCardMetrics.card(
                kind, battery: battery, history: history, daily: [], window: .oneHour, now: now)
            XCTAssertNotNil(card.explanation)
            XCTAssertNotNil(card.statisticsModel)
            XCTAssertTrue(card.expandedLabels)
            let domain = try XCTUnwrap(card.timeDomain)
            let expected =
                kind == .health ? 90.0 * 86_400 : (kind == .cycles ? 365.0 * 86_400 : 3600)
            XCTAssertEqual(domain.upperBound.timeIntervalSince(domain.lowerBound), expected)
        }
        let power = EnergyCardMetrics.card(
            .power, battery: battery, history: history, daily: [], window: .oneHour, now: now)
        XCTAssertEqual(power.value, MetricUnit.watts.format(20))
        XCTAssertEqual(
            power.statisticsModel?.series.map(\.name), [t("Mac power draw"), t("Battery flow")])
    }

    func testLifetimeChangeRequiresCoverageAndCyclesUseSteps() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let daily = [
            BatteryDailyPoint(
                date: now.addingTimeInterval(-90 * 86_400), healthPercent: 96, cycleCount: 100),
            BatteryDailyPoint(date: now, healthPercent: 95, cycleCount: 110),
        ]
        XCTAssertEqual(
            EnergyCardMetrics.change(daily, days: 90, now: now, value: { $0.healthPercent }), -1)
        XCTAssertNil(
            EnergyCardMetrics.change(
                Array(daily.suffix(1)), days: 90, now: now, value: { $0.healthPercent }))
        XCTAssertTrue(
            EnergyCardMetrics.lifetimeChart(.cycles, daily: daily, range: .year, now: now).discrete)
    }

    func testEnergyCardUnitsFormatDurationsAndCycleCounts() {
        XCTAssertEqual(MetricUnit.minutes.format(125), BatteryFormat.duration(minutes: 125))
        XCTAssertEqual(MetricUnit.minutes.format(0), t("0 min"))
        XCTAssertEqual(MetricUnit.count.format(231), "231")
        XCTAssertEqual(MetricUnit.minutes.format(.nan), t("Not reported"))
        XCTAssertEqual(MetricUnit.count.format(-1), t("Not reported"))
    }

    func testSessionScopeRequiresAnObservedUnplugAndKeepsPackChangesSeparate() throws {
        let now = Date()
        var battery = BatterySample(
            timestamp: now.addingTimeInterval(-20), isPresent: true, chargePercent: 80,
            isOnAC: true, serialNumber: "pack")
        var points = [BatteryHistoryPoint(sample: battery)]
        battery.timestamp = now.addingTimeInterval(-10)
        battery.isOnAC = false
        points.append(BatteryHistoryPoint(sample: battery))
        battery.timestamp = now
        battery.chargePercent = 79
        points.append(BatteryHistoryPoint(sample: battery))
        XCTAssertEqual(EnergyCardMetrics.unpluggedSession(points)?.count, 2)
        XCTAssertNil(EnergyCardMetrics.unpluggedSession(Array(points.suffix(2))))
        let chart = EnergyCardMetrics.sessionChart(
            .charge, history: points, battery: battery, window: .oneHour, now: now,
            domain: now.addingTimeInterval(-10)...now)
        XCTAssertEqual(chart.xDomain?.lowerBound, now.addingTimeInterval(-10))
        battery.serialNumber = "replacement"
        let replaced = EnergyCardMetrics.sessionChart(
            .charge, history: points, battery: battery, window: .oneHour, now: now)
        XCTAssertTrue(replaced.series[0].column.values.allSatisfy(\.isNaN))
    }

    func testYearScaleTicksIncludeTheYear() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let label = TrendChart.clockTickLabel(
            date.timeIntervalSinceReferenceDate, step: 60 * 86_400)
        XCTAssertTrue(label.contains("2023"))
    }

    func testEnergyTimelinesEnableHoverAndKeepTheirUnits() async {
        let points = [point(time: 0), point(time: 30)]
        let charge = BatteryChart(points: points, currentLevel: BatteryLevel(percent: 50)).chart
        let temperature = TemperatureChart(points: points).chart
        let fans = FanChart(points: points).chart
        XCTAssertTrue(charge.scrubbable)
        XCTAssertTrue(temperature.scrubbable)
        XCTAssertTrue(fans.scrubbable)
        XCTAssertEqual(charge.yFormat(50), "50%")
        XCTAssertEqual(temperature.yFormat(65), "65°C")
        XCTAssertEqual(fans.yFormat(2400), "2400 rpm")
        XCTAssertEqual(fans.yFormat(0), "0 rpm")
    }

    func testThermalHoverIncludesBothReadingsAtTheSelectedTime() async throws {
        let chart = TemperatureChart(points: [point(time: 0), point(time: 30)]).chart
        let selected = try XCTUnwrap(chart.nearestPoint(fraction: 1, tMin: 0, span: 30))
        XCTAssertEqual(selected.date, Date(timeIntervalSinceReferenceDate: 30))
        XCTAssertEqual(selected.readings.map(\.name), [t("CPU die"), t("GPU die")])
        XCTAssertEqual(selected.readings.map(\.value), [65, 45])
        XCTAssertEqual(selected.readings.map(\.color), [ThermalStyle.cpu, ThermalStyle.gpu])
    }

    func testThermalHoverDoesNotReuseAnEarlierGPUReading() async throws {
        var missingGPU = point(time: 30)
        missingGPU.gpuDieC = nil
        let chart = TemperatureChart(points: [point(time: 0), missingGPU, point(time: 60)]).chart
        let selected = try XCTUnwrap(chart.nearestPoint(fraction: 0.5, tMin: 0, span: 60))
        XCTAssertEqual(selected.readings[0].value, 65)
        XCTAssertNil(selected.readings[1].value)
    }

    func testChargeHoverUsesTheRecordedSampleTimeAndValue() async throws {
        let chart = BatteryChart(
            points: [point(time: 0), point(time: 30)], currentLevel: BatteryLevel(percent: 50)
        ).chart
        let selected = try XCTUnwrap(chart.nearestPoint(fraction: 0.8, tMin: 0, span: 30))
        XCTAssertEqual(selected.date, Date(timeIntervalSinceReferenceDate: 30))
        XCTAssertEqual(chart.yFormat(selected.value), "50%")
    }

    func testEmptyEnergyChartsDoNotInventHoverReadings() async {
        let charts = [
            BatteryChart(points: [], currentLevel: BatteryLevel(percent: 50)).chart,
            TemperatureChart(points: []).chart,
            FanChart(points: []).chart,
        ]
        for chart in charts {
            XCTAssertNil(chart.nearestPoint(fraction: 0.5, tMin: 0, span: 30))
        }
    }

    func testEnergyCardSparklinesEnableNativeHoverWithUnits() async throws {
        _ = NSApplication.shared
        for (unit, value, expected) in [
            (MetricUnit.percent, 50.0, "50%"), (.watts, 18.25, "18.25 W"), (.celsius, 32, "32°C"),
        ] {
            let appeared = expectation(description: "The card loads its samples")
            let card = MetricCardData(
                label: "Power", value: expected,
                samples: [
                    MetricSample(date: Date(timeIntervalSinceReferenceDate: 0), value: value),
                    MetricSample(date: Date(timeIntervalSinceReferenceDate: 30), value: value),
                ],
                unit: unit)
            let host = NSHostingView(
                rootView: MetricCard(data: card)
                    .frame(width: 220, height: 140)
                    .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await fulfillment(of: [appeared], timeout: 5)
            let surface = try XCTUnwrap(chartSurface(in: host))
            XCTAssertTrue(surface.scrubbable)
            XCTAssertNotNil(surface.onActivate)
            XCTAssertEqual(surface.feed?.model.yFormat(value), expected)
            XCTAssertNil(surface.feed?.model.statisticsInterval)

            let hiddenLayers = surface.layer?.sublayers?.filter(\.isHidden) ?? []
            let location = surface.convert(
                CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
            let move = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 0, pressure: 0))
            surface.mouseMoved(with: move)
            let overlays = hiddenLayers.filter { !$0.isHidden }
            XCTAssertEqual(overlays.count, 1)
            let overlay = try XCTUnwrap(overlays.first)
            overlay.displayIfNeeded()
            XCTAssertNotNil(overlay.contents)
            surface.mouseExited(with: move)
            XCTAssertTrue(overlay.isHidden)
        }
    }

    private func point(time: Double) -> SystemHistoryPoint {
        SystemHistoryPoint(
            date: Date(timeIntervalSinceReferenceDate: time), pressurePercent: 10,
            appMemory: 0, wired: 0, compressed: 0, cachedFiles: 0, swapUsed: 0,
            batteryCharge: 50, cpuDieC: 65, gpuDieC: 45, fanRPM: 2400)
    }

    private func energyFixture() -> (
        battery: BatterySample, history: [BatteryHistoryPoint], daily: [BatteryDailyPoint]
    ) {
        let now = Date()
        var battery = BatterySample(
            timestamp: now, isPresent: true, chargePercent: 70,
            runtimeEstimate: BatteryRuntimeEstimate(
                minutesRemaining: 185, fullChargeMinutes: 264, source: .recentUse),
            powerWatts: 11, systemPowerWatts: 16, amperageMilliAmps: -950,
            voltageMilliVolts: 12_000, temperatureCelsius: 31, cycleCount: 231,
            designCapacitymAh: 6000, maxCapacitymAh: 5520, currentCapacitymAh: 3864,
            healthPercent: 92, serialNumber: "energy-test-pack", adapterWatts: 96)
        let history = (0...360).map { index -> BatteryHistoryPoint in
            var sample = battery
            sample.timestamp = now.addingTimeInterval(Double(index - 360) * 10)
            sample.chargePercent = 78 - Double(index) / 45
            sample.isOnAC = index < 30
            sample.systemPowerWatts = 16 + 4 * sin(Double(index) / 20)
            sample.powerWatts = 11 + 3 * sin(Double(index) / 20)
            sample.temperatureCelsius = 29 + Double(index) / 180
            sample.runtimeEstimate?.minutesRemaining = 240 - Double(index) / 7
            return BatteryHistoryPoint(sample: sample)
        }
        battery.timestamp = now
        let daily = (0...400).map { index -> BatteryDailyPoint in
            let elapsed: TimeInterval = Double(index - 400) * 86_400
            let date = now.addingTimeInterval(elapsed)
            let healthPercent: Double = 100 - Double(index) / 50
            let cycleCount: Int = 31 + index / 2
            let fullCapacitymAh: Int = 6000 - index
            return BatteryDailyPoint(
                date: date, healthPercent: healthPercent, cycleCount: cycleCount,
                fullCapacitymAh: fullCapacitymAh, designCapacitymAh: 6000)
        }
        return (battery, history, daily)
    }

    private func chartSurfaces(in view: NSView) -> [TrendSurfaceView] {
        var surfaces = (view as? TrendSurfaceView).map { [$0] } ?? []
        for child in view.subviews { surfaces += chartSurfaces(in: child) }
        return surfaces
    }

    private func rangeControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for child in view.subviews {
            if let control = rangeControl(in: child) { return control }
        }
        return nil
    }

    private func save(_ view: NSView, name: String) throws {
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let pixels = try XCTUnwrap(image.bitmapData)
        let colors = Set(
            stride(from: 0, to: image.bytesPerRow * image.pixelsHigh, by: image.samplesPerPixel).map
            { pixels[$0] })
        XCTAssertGreaterThan(colors.count, 20)
        if let path = ProcessInfo.processInfo.environment["MACPERF_ENERGY_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private func chartSurface(in view: NSView) -> TrendSurfaceView? {
        if let surface = view as? TrendSurfaceView { return surface }
        for child in view.subviews {
            if let surface = chartSurface(in: child) { return surface }
        }
        return nil
    }
}
