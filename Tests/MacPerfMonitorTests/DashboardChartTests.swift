import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class DashboardChartTests: XCTestCase {
    func testDashboardHistoryRangeDefaultsToThirtyMinutesAndPersists() throws {
        let suite = "MacPerfMonitorTests.HistoryRange.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = StoredHistoryWindow("historyRange.dashboard", store: defaults)
        XCTAssertEqual(preference.wrappedValue, .thirtyMinutes)
        XCTAssertNil(defaults.object(forKey: "historyRange.dashboard"))

        preference.projectedValue.wrappedValue = .sixHours
        let reopened = StoredHistoryWindow(
            "historyRange.dashboard", store: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopened.wrappedValue, .sixHours)
        XCTAssertEqual(defaults.string(forKey: "historyRange.dashboard"), "sixHours")

        reopened.wrappedValue = .fiveMinutes
        XCTAssertEqual(defaults.string(forKey: "historyRange.dashboard"), "fiveMinutes")
        XCTAssertEqual(
            StoredHistoryWindow("historyRange.dashboard", store: defaults).wrappedValue,
            .fiveMinutes)
    }

    func testDashboardHistoryRangesAreIndependentAndRejectUnknownValues() throws {
        let suite = "MacPerfMonitorTests.HistoryRange.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = StoredHistoryWindow("historyRange.dashboard", store: defaults)
        let gpu = StoredHistoryWindow("historyRange.gpu", store: defaults)
        dashboard.wrappedValue = .oneDay
        XCTAssertEqual(gpu.wrappedValue, .thirtyMinutes)
        gpu.wrappedValue = .oneHour
        XCTAssertEqual(dashboard.wrappedValue, .oneDay)

        defaults.set("obsoleteRange", forKey: "historyRange.disk")
        XCTAssertEqual(
            StoredHistoryWindow("historyRange.disk", store: defaults).wrappedValue, .thirtyMinutes)
    }

    func testNativeRangePickerRestoresItsSelectionAndKeepsPreviewOverridesLocal() async throws {
        _ = NSApplication.shared
        let suite = "MacPerfMonitorTests.NativeRange.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState()
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 1100, height: 750),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        func settle() async {
            let rendered = expectation(description: "Range picker renders")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { rendered.fulfill() }
            await fulfillment(of: [rendered], timeout: 3)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func picker(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl,
                control.segmentCount == HistoryWindow.allCases.count
            {
                return control
            }
            return view.subviews.lazy.compactMap { picker(in: $0) }.first
        }

        for reopening in [false, true] {
            host.rootView = AnyView(
                GPUView().environmentObject(state).defaultAppStorage(defaults))
            await settle()
            let control = try XCTUnwrap(picker(in: host))
            XCTAssertEqual(control.selectedSegment, reopening ? 3 : 1)
            if !reopening {
                control.selectedSegment = 3
                XCTAssertTrue(control.sendAction(control.action, to: control.target))
                await settle()
                XCTAssertEqual(defaults.string(forKey: "historyRange.gpu"), "sixHours")
            }
            host.rootView = AnyView(EmptyView())
            await settle()
        }

        defaults.set("oneDay", forKey: "historyRange.dashboard")
        host.rootView = AnyView(
            HistoryRangeProbe(initialRange: .fiveMinutes).defaultAppStorage(defaults))
        await settle()
        let preview = try XCTUnwrap(picker(in: host))
        XCTAssertEqual(preview.selectedSegment, 0)
        preview.selectedSegment = 5
        XCTAssertTrue(preview.sendAction(preview.action, to: preview.target))
        await settle()
        XCTAssertEqual(preview.selectedSegment, 5)
        XCTAssertEqual(defaults.string(forKey: "historyRange.dashboard"), "oneDay")
    }

    private struct HistoryRangeProbe: View {
        @StoredHistoryWindow("historyRange.dashboard") private var range

        init(initialRange: HistoryWindow) {
            _range = StoredHistoryWindow("historyRange.dashboard", initialValue: initialRange)
        }

        var body: some View {
            Picker("Range", selection: $range) {
                ForEach(HistoryWindow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    func testUptimeUsesElapsedTimeSinceBoot() {
        let boot = Date(timeIntervalSince1970: 1_700_000_000)
        for (elapsed, expected) in [
            (0.0, "0m"), (59, "0m"), (60, "1m"), (3599, "59m"),
            (3600, "1h 0m"), (86400, "1d 0h 0m"), (183840, "2d 3h 4m"),
        ] {
            XCTAssertEqual(
                DashboardUptime.value(since: boot, now: boot.addingTimeInterval(elapsed)), expected)
        }
    }

    func testUnavailableOrInvalidBootTimeDoesNotInventUptime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DashboardUptime.value(since: nil, now: now), t("Not reported"))
        XCTAssertEqual(
            DashboardUptime.value(since: now.addingTimeInterval(1), now: now), t("Not reported"))
        XCTAssertEqual(
            DashboardUptime.value(since: Date(timeIntervalSince1970: -.infinity), now: now),
            t("Not reported"))
    }

    func testSystemBootTimeComesFromBeforeTheAppLaunch() throws {
        let beforeRead = Date()
        let boot = try XCTUnwrap(SystemBootTime.read())
        XCTAssertLessThanOrEqual(boot, beforeRead)
        XCTAssertGreaterThan(boot.timeIntervalSince1970, 0)
        XCTAssertEqual(SystemBootTime.read(), boot)
        XCTAssertNotEqual(DashboardUptime.value(since: boot, now: beforeRead), t("Not reported"))
    }

    func testDashboardUptimeFitsCompactAndWideHeaders() async throws {
        let options = ChartBenchmark.Options(arguments: ["--points", "60"])
        let store = ChartBenchmark.ProcessScenarioStore(options: options)
        store.tick()
        for (width, appearance) in [(860.0, NSAppearance.Name.aqua), (1440.0, .darkAqua)] {
            try await capture(
                ChartBenchmark.DashboardPageScenario(store: store, width: width),
                size: CGSize(width: width, height: 1000), name: "dashboard-uptime-\(Int(width))",
                appearance: appearance)
        }
        try await capture(
            DashboardUptime(bootTime: Date().addingTimeInterval(-3_640_440)),
            size: CGSize(width: 220, height: 34), name: "uptime-long-running")
        try await capture(
            DashboardUptime(bootTime: nil), size: CGSize(width: 220, height: 34),
            name: "uptime-unavailable")
    }

    func testStandardIntervalsAreIndependentOfViewSize() async {
        for (span, expected) in [
            (300.0, 5.0), (1800, 15), (3600, 30), (21600, 300), (86400, 900), (604800, 7200),
        ] {
            XCTAssertEqual(ChartStatistics.interval(span: span), expected)
        }
    }

    func testCoarseHistoryDoesNotHideAGapInRawTail() async {
        var stored = point(time: 0, gpu: 60)
        stored.bucketDuration = 3600
        stored.gpuDieAverageC = 50
        stored.gpuDieSampleCount = 100
        let model = TemperatureChart.statisticsModel(
            points: [stored, point(time: 3600, gpu: 45), point(time: 3660, gpu: 46)],
            xDomain: domain(0, 604800))
        let buckets = TrendStatistics.buckets(model.series[1], model: model)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.last?.gapBefore, true)
        XCTAssertNil(ChartStatistics.selection(at: 3630, in: buckets, tolerance: 15))
    }

    func testHistoryReplacementInvalidatesCacheButAnAppendDoesNot() async {
        let feed = TrendFeed()
        let model = fixture(span: 1800)
        feed.publish(model)
        XCTAssertEqual(feed.historyRevision, 0)
        feed.publish(model, replacingHistory: true)
        XCTAssertEqual(feed.historyRevision, 1)
        feed.publish(model)
        XCTAssertEqual(feed.historyRevision, 1)
    }

    func testThermalModelPreservesIndependentMissingReadings() async throws {
        let points = (0..<60).map { offset in
            point(time: Double(offset), gpu: (20..<40).contains(offset) ? nil : 42)
        }
        let model = TemperatureChart.statisticsModel(points: points, xDomain: domain(0, 60))
        let cpu = try XCTUnwrap(model.series.first)
        let gpu = try XCTUnwrap(model.series.last)
        XCTAssertEqual(cpu.column.values.filter(\.isFinite).count, 60)
        XCTAssertEqual(gpu.column.values.filter(\.isFinite).count, 40)
        let buckets = TrendStatistics.buckets(gpu, model: model)
        XCTAssertNil(ChartStatistics.selection(at: 30, in: buckets, tolerance: 30))
        XCTAssertNotNil(ChartStatistics.selection(at: 45, in: buckets, tolerance: 1))
        XCTAssertFalse(TrendStatistics.hasUnknown(gpu.column.lows, column: gpu.column))
        XCTAssertFalse(TrendStatistics.hasUnknown(gpu.column.weights, column: gpu.column))
    }

    func testThermalMeansUseSensorCountsNotDenseSystemCounts() async throws {
        var first = point(time: 0, gpu: 70)
        first.bucketDuration = 60
        first.sampleCount = 60
        first.gpuDieAverageC = 50
        first.gpuDieSampleCount = 2
        var second = point(time: 60, gpu: 40)
        second.bucketDuration = 60
        second.sampleCount = 60
        second.gpuDieAverageC = 30
        second.gpuDieSampleCount = 18
        var model = TemperatureChart.statisticsModel(
            points: [first, second], xDomain: domain(0, 120))
        model.statisticsInterval = 120
        let summary = try XCTUnwrap(
            ChartStatistics.summary(TrendStatistics.buckets(model.series[1], model: model)))
        XCTAssertEqual(summary.mean, 32, accuracy: 0.0001)
        XCTAssertEqual(summary.sampleCount, 20)
        XCTAssertNil(summary.minimum)
        XCTAssertEqual(summary.maximum, 70)
    }

    func testLegacyThermalAverageIsApproximateWithoutInventingMinimum() async throws {
        var legacy = point(time: 0, gpu: 80)
        legacy.bucketDuration = 60
        legacy.gpuDieAverageC = 40
        let model = TemperatureChart.statisticsModel(points: [legacy], xDomain: domain(0, 60))
        let summary = try XCTUnwrap(
            ChartStatistics.summary(TrendStatistics.buckets(model.series[1], model: model)))
        XCTAssertEqual(summary.mean, 40)
        XCTAssertNil(summary.minimum)
        XCTAssertEqual(summary.maximum, 80)
        XCTAssertNil(summary.sampleCount)
        XCTAssertTrue(summary.hasUnknownWeight)
    }

    func testMetricDetailIsAnImmutableSnapshotWithStatistics() async throws {
        let feed = MetricCardFeed()
        let column = LiveColumn(
            times: [0, 1, 2], values: [10, 30, 20], lows: [5, 15, 10], weights: [1, 3, 2])
        feed.publish(
            value: "20%", tint: .systemGreen, column: column, xDomain: domain(0, 3),
            yDomain: 0...100, statisticsInterval: 5, gapThreshold: 15, name: "CPU")
        let card = MetricCardData(label: "CPU", live: feed)
        let snapshot = card.snapshot
        feed.publish(
            value: "90%", tint: .systemRed,
            column: LiveColumn(times: [4, 5], values: [90, 90]),
            xDomain: domain(3, 6), yDomain: 0...100)
        let frozen = try XCTUnwrap(snapshot.statisticsModel)
        XCTAssertEqual(snapshot.value, "20%")
        XCTAssertEqual(Array(frozen.series[0].column.values), [10, 30, 20])
        XCTAssertEqual(Array(try XCTUnwrap(frozen.series[0].column.lows)), [5, 15, 10])
        XCTAssertEqual(frozen.xDomain, domain(0, 3))
        XCTAssertFalse(frozen.bare)
        XCTAssertTrue(frozen.showsTimeAxis)
        XCTAssertNil(snapshot.live)
    }

    func testCardActivationRunsFromNativeChart() async throws {
        let surface = TrendSurfaceView()
        var activations = 0
        surface.onActivate = { activations += 1 }
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        surface.mouseDown(with: event)
        XCTAssertEqual(activations, 1)
    }

    func testAutomaticAxisIncludesStoredPeak() async {
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(
                column: LiveColumn(times: [0, 1], values: [7, 8], highs: [95, 99]), color: .green)
        ]
        XCTAssertGreaterThanOrEqual(TrendSurfaceView.resolvedDomain(model).upperBound, 99)
    }

    func testCompactTimeAxisUsesFewerLabelsWithoutChangingStatistics() async {
        let compact = TrendRenderer.clockStep(span: 1800, width: 210)
        let wide = TrendRenderer.clockStep(span: 1800, width: 900)
        XCTAssertGreaterThan(compact, wide)
        XCTAssertLessThanOrEqual(1800 / compact, 2)
        XCTAssertEqual(fixture(span: 1800).statisticsInterval, 15)
    }

    func testRangePaintUsesTranslucentShadingUnderAnOpaqueAverage() async throws {
        for span in [300.0, 1800, 3600, 21600, 86400, 604800] {
            let model = fixture(span: span)
            let series = model.series[0]
            for width in [256, 960] {
                let context = try bitmap(width: width, height: 160)
                TrendRenderer.drawStatistics(
                    TrendStatistics.buckets(series, model: model), series: series,
                    x: { $0 / span * Double(width) }, y: { 160 - $0 * 1.6 }, context: context)
                let columns = (width / 10)..<(width * 9 / 10)
                XCTAssertEqual(ink(context, columns: columns, rows: 50..<110), columns.count * 60)
                XCTAssertEqual(ink(context, columns: columns, rows: 0..<4), 0)
                XCTAssertEqual(ink(context, columns: columns, rows: 156..<160), 0)
                XCTAssertGreaterThan(alpha(context, column: width / 2, row: 80), 25)
                XCTAssertLessThan(alpha(context, column: width / 2, row: 80), 55)
                XCTAssertGreaterThan(
                    (0..<160).map { alpha(context, column: width / 2, row: $0) }.max() ?? 0, 240)
                try save(context.makeImage(), name: "range-shading-\(Int(span))-\(width)")
            }
        }
    }

    func testLegacyRangeShadesFromRecordedAverageWithoutInventingAMinimum() async throws {
        for span in [21600.0, 86400, 604800] {
            let source = span == 604800 ? 3600.0 : 60.0
            let times = stride(from: 0.0, to: span, by: source).map { $0 }
            var model = fixture(span: span)
            let series = TrendSurfaceSeries(
                column: LiveColumn(
                    times: times[...], values: Array(repeating: 20.0, count: times.count)[...],
                    highs: Array(repeating: 95.0, count: times.count)[...],
                    lows: Array(repeating: .nan, count: times.count)[...],
                    weights: Array(repeating: source, count: times.count)[...],
                    durations: Array(repeating: source, count: times.count)[...]), color: .green)
            model.series = [series]
            let context = try bitmap(width: 300, height: 160)
            TrendRenderer.drawStatistics(
                TrendStatistics.buckets(series, model: model), series: series, layer: .range,
                x: { $0 / span * 300 }, y: { $0 * 1.6 }, context: context)
            let visibleColumns = (30..<270).filter {
                ink(context, columns: $0..<($0 + 1)) > 0
            }
            XCTAssertEqual(visibleColumns.count, 240, "Legacy shading: \(span)")
            XCTAssertEqual(ink(context, columns: 30..<270, rows: 60..<100), 240 * 40)
            XCTAssertEqual(ink(context, columns: 30..<270, rows: 0..<5), 0)
            XCTAssertEqual(ink(context, columns: 30..<270, rows: 155..<160), 0)
            XCTAssertTrue(
                TrendStatistics.buckets(series, model: model).allSatisfy { $0.minimum == nil })
        }
    }

    func testUnknownMinimumUsesRecordedMeanAsTheShadingEdge() async throws {
        let column = LiveColumn(
            times: [0, 10, 20, 30, 40, 50], values: [40, 40, 40, 40, 40, 40],
            highs: [80, 80, 80, 80, 80, 80], lows: [20, 20, .nan, .nan, 20, 20],
            durations: [10, 10, 10, 10, 10, 10])
        let series = TrendSurfaceSeries(column: column, color: .green)
        let buckets = column.statistics(width: 10, range: 0...60, gapThreshold: 15)
        let context = try bitmap(width: 600, height: 160)
        TrendRenderer.drawStatistics(
            buckets, series: series, layer: .range,
            x: { $0 * 10 }, y: { CGFloat($0) }, context: context)
        XCTAssertEqual(ink(context, columns: 220..<380, rows: 0..<30), 0)
        XCTAssertEqual(ink(context, columns: 220..<380, rows: 130..<160), 0)
        XCTAssertGreaterThan(ink(context, columns: 220..<380, rows: 60..<100), 150)
        XCTAssertGreaterThan(
            ink(context, columns: 60..<140, rows: 0..<30)
                + ink(context, columns: 60..<140, rows: 130..<160), 70)
        XCTAssertNil(buckets[2].minimum)
        XCTAssertEqual(buckets[2].mean, 40)
    }

    func testUnsmoothedRangeKeepsABurstAtItsRecordedTime() async throws {
        let times = (0..<60).map(Double.init)
        let values = (0..<60).map { $0 == 5 ? 90.0 : 10.0 }
        let series = TrendSurfaceSeries(
            column: LiveColumn(times: times[...], values: values[...]), color: .green)
        let buckets = TrendRenderer.statisticsBuckets(
            series, interval: 20, secondsPerPoint: 0.1, range: 0...60, gapThreshold: 15)
        XCTAssertEqual(buckets.average.count, 3)
        XCTAssertEqual(buckets.average[0].mean, 14)
        XCTAssertEqual(buckets.range.count, 60)
        XCTAssertEqual(buckets.range[5].firstTime, 5)
        XCTAssertEqual(buckets.range[5].maximum, 90)
        let context = try bitmap(width: 600, height: 100)
        TrendRenderer.drawStatistics(
            buckets.range, series: series, layer: .range,
            x: { $0 * 10 }, y: { 100 - $0 }, context: context)
        XCTAssertGreaterThan(ink(context, columns: 41..<59, rows: 30..<70), 0)
        XCTAssertEqual(ink(context, columns: 90..<190, rows: 30..<70), 0)
    }

    func testRangeResolutionDoesNotChangeAveragesOrDiscardExtrema() async throws {
        let times = (0..<120).map(Double.init)
        let values = (0..<120).map { $0 % 17 == 0 ? 90.0 : 10.0 }
        let series = TrendSurfaceSeries(
            column: LiveColumn(times: times[...], values: values[...]), color: .green)
        let wide = TrendRenderer.statisticsBuckets(
            series, interval: 20, secondsPerPoint: 0.25, range: 0...120, gapThreshold: 15)
        let narrow = TrendRenderer.statisticsBuckets(
            series, interval: 20, secondsPerPoint: 3, range: 0...120, gapThreshold: 15)
        XCTAssertEqual(wide.average, narrow.average)
        XCTAssertGreaterThan(wide.range.count, narrow.range.count)
        let wideRange = try XCTUnwrap(ChartStatistics.summary(wide.range))
        let narrowRange = try XCTUnwrap(ChartStatistics.summary(narrow.range))
        XCTAssertEqual(wideRange.minimum, 10)
        XCTAssertEqual(wideRange.maximum, 90)
        XCTAssertEqual(wideRange, narrowRange)
    }

    func testGPUHoleRemainsBlankInPaintedPixels() async throws {
        let points = (0..<60).map { offset in
            point(time: Double(offset), gpu: (20..<40).contains(offset) ? nil : 42)
        }
        let model = TemperatureChart.statisticsModel(points: points, xDomain: domain(0, 60))
        let series = model.series[1]
        let buckets = TrendRenderer.statisticsBuckets(
            series, interval: try XCTUnwrap(model.statisticsInterval), secondsPerPoint: 0.1,
            range: 0...60, gapThreshold: try XCTUnwrap(model.gapThreshold))
        let context = try bitmap(width: 600, height: 160)
        for layer in [TrendRenderer.StatisticsLayer.range, .average] {
            TrendRenderer.drawStatistics(
                layer == .range ? buckets.range : buckets.average, series: series, layer: layer,
                x: { $0 * 10 }, y: { 160 - $0 * 1.6 }, context: context)
        }
        XCTAssertGreaterThan(ink(context, columns: 0..<180), 0)
        XCTAssertEqual(ink(context, columns: 220..<380), 0)
        XCTAssertGreaterThan(ink(context, columns: 420..<600), 0)
        try save(context.makeImage(), name: "gpu-gap")
    }

    func testNativeChartAndHoverSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["MACPERF_CHART_ARTIFACTS"] != nil else { return }
        for span in [300.0, 1800, 3600, 21600, 86400, 604800] {
            let model = burstFixture(span: span)
            let view = VStack(alignment: .leading, spacing: 12) {
                Text("Processor").font(.headline)
                TrendSnapshotChart(model: model).frame(height: 190)
                TrendStatisticsCaption(model: model)
                TrendStatisticsSummary(model: model)
            }.padding(20)
            try await capture(
                view, size: CGSize(width: 940, height: 350), name: "processor-\(Int(span))")
            if span >= 21600 {
                try await capture(
                    view, size: CGSize(width: 940, height: 350),
                    name: "processor-\(Int(span))-light", appearance: .aqua)
                try await capture(
                    TrendSnapshotChart(model: burstFixture(span: span, legacyBounds: true)),
                    size: CGSize(width: 256, height: 140), name: "legacy-rail-\(Int(span))")
            }
        }
        var compact = fixture(span: 1800)
        compact.series.append(
            TrendSurfaceSeries(
                column: LiveColumn(
                    times: [0, 300, 600, 900, 1200, 1799], values: [40, 45, .nan, 48, 50, 52]),
                color: .red, name: "GPU die"))
        compact.yFormat = { String(format: "%.1f C", $0) }
        try await capture(
            TrendSnapshotChart(model: compact), size: CGSize(width: 256, height: 140),
            name: "rail-chart")
        try await capture(
            TrendHoverView(model: compact, time: 610), size: CGSize(width: 330, height: 310),
            name: "hover-missing-gpu")
        let snapshot = DashboardDetailSnapshot(
            kind: .processor, range: .thirtyMinutes,
            capturedAt: Date(timeIntervalSinceReferenceDate: 1800), dataTimestamp: nil,
            content: .trend(fixture(span: 1800)), facts: [])
        try await capture(
            DashboardDetailSheet(snapshot: snapshot), size: CGSize(width: 860, height: 780),
            name: "processor-detail")
    }

    private func point(time: Double, gpu: Double?) -> SystemHistoryPoint {
        SystemHistoryPoint(
            date: Date(timeIntervalSinceReferenceDate: time), pressurePercent: 12,
            appMemory: 100, wired: 200, compressed: 50, cachedFiles: 100, swapUsed: 0,
            cpuDieC: 72, gpuDieC: gpu)
    }

    private func fixture(span: Double) -> TrendModel {
        let width = ChartStatistics.interval(span: span)
        let times = stride(from: 0.0, to: span, by: width / 10).map { $0 }
        let values = times.enumerated().map { index, _ in index % 10 == 0 ? 95.0 : 12.0 }
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(
                column: LiveColumn(times: times[...], values: values[...]),
                color: .green, name: "Total CPU")
        ]
        model.xDomain = domain(0, span)
        model.yDomain = 0...100
        model.yFormat = { String(format: "%.1f%%", $0) }
        model.statisticsInterval = width
        model.gapThreshold = width
        model.showsTimeAxis = true
        model.plotBorder = true
        return model
    }

    private func burstFixture(span: Double, legacyBounds: Bool = false) -> TrendModel {
        let source = span >= 604800 ? 3600.0 : (span >= 21600 ? 60.0 : 1.0)
        let times = stride(from: 0.0, to: span, by: source).map { $0 }
        var values: [Double] = []
        var lows: [Double] = []
        var highs: [Double] = []
        for (index, time) in times.enumerated() {
            let phase = time / span
            let baseline = 20 + 8 * sin(phase * 4 * .pi) + 3 * sin(phase * 36 * .pi)
            let peak = min(98, baseline + 20 + 48 * abs(sin(Double(index) * 1.7)))
            let missing = (0.46..<0.49).contains(phase)
            let value =
                missing ? Double.nan : (source > 1 ? baseline : (index % 17 == 0 ? peak : baseline))
            values.append(value)
            highs.append(source > 1 ? peak : value)
            lows.append(source > 1 ? (legacyBounds ? .nan : baseline * 0.35) : value)
        }
        var model = fixture(span: span)
        model.series = [
            TrendSurfaceSeries(
                column: LiveColumn(
                    times: times[...], values: values[...], highs: highs[...], lows: lows[...],
                    weights: Array(repeating: source, count: times.count)[...],
                    durations: Array(repeating: source > 1 ? source : 0, count: times.count)[...]),
                color: .green, name: "Total CPU")
        ]
        model.gapThreshold = 15
        return model
    }

    private func domain(_ lower: Double, _ upper: Double) -> ClosedRange<Date> {
        Date(timeIntervalSinceReferenceDate: lower)...Date(timeIntervalSinceReferenceDate: upper)
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func ink(_ context: CGContext, columns: Range<Int>, rows: Range<Int>? = nil) -> Int {
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var count = 0
        for row in rows ?? 0..<context.height {
            for column in columns where pixels[row * context.bytesPerRow + column * 4 + 3] > 20 {
                count += 1
            }
        }
        return count
    }

    private func alpha(_ context: CGContext, column: Int, row: Int) -> UInt8 {
        context.data?.assumingMemoryBound(to: UInt8.self)[
            row * context.bytesPerRow + column * 4 + 3] ?? 0
    }

    private func capture<Content: View>(
        _ content: Content, size: CGSize, name: String,
        appearance: NSAppearance.Name = .darkAqua
    ) async throws {
        _ = NSApplication.shared
        let appeared = expectation(description: "The native preview is mounted")
        let view = NSHostingView(
            rootView:
                content
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
        view.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        defer { window.close() }
        await fulfillment(of: [appeared], timeout: 5)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func displayLayers(_ layer: CALayer) {
            layer.displayIfNeeded()
            for child in layer.sublayers ?? [] { displayLayers(child) }
        }
        if let layer = view.layer { displayLayers(layer) }
        CATransaction.flush()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try save(image.cgImage, name: name)
    }

    private func save(_ image: CGImage?, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MACPERF_CHART_ARTIFACTS"] else {
            return
        }
        let image = try XCTUnwrap(image)
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try XCTUnwrap(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try bytes.write(to: root.appendingPathComponent(name + ".png"))
    }
}
