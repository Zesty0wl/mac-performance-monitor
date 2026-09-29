import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class DataExplorerTests: XCTestCase {
    func testExplorerRestoresChosenWindowAndCustomZoom() throws {
        let suite = "MacPerfMonitorTests.ExplorerRange.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_700_000_400)
        let model = DataExplorerModel(now: now, preferences: defaults)
        XCTAssertEqual(model.span, 1800)
        XCTAssertNil(defaults.object(forKey: DataExplorerModel.spanDefaultsKey))

        model.chooseWindow(.sixHours)
        let reopened = DataExplorerModel(now: now, preferences: defaults)
        XCTAssertEqual(reopened.span, 21600)
        XCTAssertEqual(reopened.domain.upperBound, now)
        XCTAssertTrue(reopened.followsLive)

        reopened.zoom(0.3)
        XCTAssertEqual(
            DataExplorerModel(now: now, preferences: defaults).span, 6480, accuracy: 0.001)
        for invalid in [0.0, -1, 19, 90 * 86_400 + 1] {
            defaults.set(invalid, forKey: DataExplorerModel.spanDefaultsKey)
            XCTAssertEqual(DataExplorerModel(now: now, preferences: defaults).span, 1800)
        }
    }

    func testANEExplorerUsesAccountedTimeAndMissingDataGaps() throws {
        let definition = try XCTUnwrap(ExplorerMetrics.all.first { $0.id == "aneTime" })
        XCTAssertEqual(definition.unit.symbol, "ms/s")
        guard case .system(let fields) = definition.source else {
            return XCTFail("Expected machine accounting")
        }
        let field = try XCTUnwrap(fields.first)
        var point = fixture().system[0]
        point.aneTimeMillisecondsPerSecond = nil
        XCTAssertTrue(field.column([point]).values.first?.isNaN == true)
        point.aneTimeMillisecondsPerSecond = 750
        point.aneSampleCount = 2
        let column = field.column([point])
        XCTAssertEqual(column.values.first, 750)
        XCTAssertEqual(column.weights?.first, 1)
        point.bucketDuration = 60
        point.sampleCount = 3
        XCTAssertEqual(field.column([point]).weights?.first, 2)
        let power = try XCTUnwrap(ExplorerMetrics.all.first { $0.id == "power" })
        guard case .system(let powerFields) = power.source else {
            return XCTFail("Expected power history")
        }
        XCTAssertEqual(powerFields.count, 2)
        let anePower = powerFields[1]
        point.anePowerWatts = 2.5
        point.anePowerSampleCount = 2
        XCTAssertEqual(anePower.column([point]).values.first, 2.5)
        XCTAssertEqual(anePower.column([point]).weights?.first, 2)
    }

    func testLatestMetricSelectionWinsBackgroundPreparation() async {
        let model = DataExplorerModel()
        model.seed(fixture(), selected: [], enabled: ExplorerMetrics.defaultIDs)
        let prepared = expectation(description: "Latest chart selection is prepared")
        let subscription = model.$preparing.dropFirst().filter { !$0 }.prefix(1).sink { _ in
            prepared.fulfill()
        }
        model.preset(.memory)
        model.preset(.thermals)
        model.preset(.processor)
        await fulfillment(of: [prepared], timeout: 5)
        XCTAssertEqual(Set(model.lanes.map(\.id)), ["cpu", "load"])
        XCTAssertTrue(model.lanes.allSatisfy { $0.definition.group == .processor })
        withExtendedLifetime(subscription) {}
        model.stop()
    }

    func testCatalogCoversEveryRecordedProcessMetricAndSensorGroup() {
        let definitions = ExplorerMetrics.all
        XCTAssertEqual(Set(definitions.map(\.id)).count, definitions.count)
        let metrics = definitions.compactMap { definition -> ExplorerProcessMetric? in
            if case .process(let metric) = definition.source { return metric }
            return nil
        }
        XCTAssertEqual(Set(metrics), Set(ExplorerProcessMetric.allCases))
        XCTAssertTrue(
            Set([
                "cpu", "pressure", "network", "disk", "iops", "latency", "capacity", "gpu", "power",
                "die",
                "clusterTemp", "enclosure", "peripheralTemp", "fans", "thermalState", "charge",
                "batteryPower", "batteryHealth", "batteryTemp",
            ])
            .isSubset(of: Set(definitions.map(\.id))))
    }

    func testStateChartsAreDiscreteAndAbsentBatteryDataStaysMissing() {
        let data = fixture()
        let model = DataExplorerModel()
        model.seed(
            data, selected: [],
            enabled: ["thermalState", "charge", "batteryPower", "batteryHealth"])
        XCTAssertTrue(
            model.lanes.first(where: { $0.id == "thermalState" })?.feed.model.discrete == true)
        for id in ["charge", "batteryPower", "batteryHealth"] {
            let column = model.lanes.first(where: { $0.id == id })?.feed.model.series.first?.column
            XCTAssertTrue(column?.values.allSatisfy(\.isNaN) == true)
        }
    }

    func testChangingWindowClearsAnOldProcessInspection() {
        let model = DataExplorerModel()
        let date = model.domain.upperBound.addingTimeInterval(-60)
        model.inspect(date)
        XCTAssertEqual(model.observationTime, date)
        model.chooseWindow(.fiveMinutes)
        XCTAssertNil(model.observationTime)
        XCTAssertNil(model.machineRecord)
        XCTAssertNil(model.cursor.date)
    }

    func testUnpinningClearsTheRelatedInspectionWithoutResumingLive() {
        let model = DataExplorerModel()
        model.inspect(model.domain.upperBound.addingTimeInterval(-60))
        model.unpinTime()
        XCTAssertNil(model.observationTime)
        XCTAssertNil(model.cursor.date)
        XCTAssertFalse(model.followsLive)
    }

    func testRecordedTailAppendsWithoutReplacingEarlierObservations() {
        var data = fixture()
        let model = DataExplorerModel()
        let first = data.system[0]
        let last = data.system[data.system.count - 1]
        let selected = data.processes.map(\.process)
        data.system = Array(data.system.dropLast())
        model.seed(data, selected: selected, enabled: ["cpu"])
        var replacement = first
        replacement.cpuLoad = 0.99
        data.system = [replacement, last, last]
        model.mergeRecordedTail(data)
        XCTAssertEqual(model.system.first?.cpuLoad, first.cpuLoad)
        XCTAssertEqual(model.system.count, 721)
        XCTAssertEqual(model.histories.first?.points.count, data.processes.first?.points.count)
        XCTAssertEqual(model.system.last?.date, last.date)
        let frozen = model.system.map(\.date)
        model.mergeRecordedTail(data)
        XCTAssertEqual(model.system.map(\.date), frozen)
        model.chooseWindow(.fiveMinutes)
        model.mergeRecordedTail(
            ExplorerWindowData(domain: model.domain, granularity: .raw, system: [], processes: []))
        XCTAssertTrue(
            model.histories.allSatisfy {
                $0.points.allSatisfy { $0.date >= model.domain.lowerBound }
            })
    }

    func testDiscreteStatesPaintStepsWithoutIntermediateValues() throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 200, height: 100,
                bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let series = TrendSurfaceSeries(
            column: LiveColumn(times: [0, 10], values: [0, 3], durations: [10, 10]), color: .orange)
        TrendRenderer.drawDiscrete(
            series, through: 20, gapThreshold: 15,
            x: { $0 * 10 }, y: { 10 + $0 * 25 }, context: context)
        let pixels = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        for column in [20, 50, 80, 120, 150, 180] {
            let middleInk = (35..<65).contains { row in pixels[row * 800 + column * 4 + 3] > 0 }
            XCTAssertFalse(middleInk)
        }
    }

    func testPinningAnInstantStopsTheLiveWindowFromMoving() {
        let model = DataExplorerModel()
        model.start(sampler: nil, identities: [])
        let time = model.domain.upperBound.addingTimeInterval(-100)
        model.inspect(time)
        let frozen = model.domain
        model.tick()
        XCTAssertFalse(model.followsLive)
        XCTAssertEqual(model.domain, frozen)
        XCTAssertEqual(model.cursor.date, time)
        model.toggleLive()
        XCTAssertTrue(model.followsLive)
        XCTAssertNil(model.cursor.date)
        model.stop()
    }

    func testHistoricalNavigationKeepsItsAnchorAndZoomsAroundCursor() {
        let time = Date(timeIntervalSince1970: 1_700_000_400)
        let model = DataExplorerModel(now: time)
        model.showTime(time)
        XCTAssertEqual(model.domain.lowerBound, time.addingTimeInterval(-900))
        XCTAssertEqual(model.domain.upperBound, time.addingTimeInterval(900))
        model.zoom(0.5)
        XCTAssertEqual(model.span, 900)
        XCTAssertEqual(model.domain.lowerBound, time.addingTimeInterval(-450))
        model.pan(-1)
        XCTAssertEqual(model.domain.upperBound, time.addingTimeInterval(-450))
        XCTAssertFalse(model.followsLive)
    }

    func testPointerZoomKeepsItsTimeAtTheSamePositionAndPreservesThePin() {
        let model = DataExplorerModel(now: Date(timeIntervalSince1970: 1_700_000_400))
        let original = model.domain
        let pointer = original.lowerBound.addingTimeInterval(model.span * 0.25)
        let pinned = original.lowerBound.addingTimeInterval(model.span * 0.6)
        model.cursor.pin(pinned)
        model.zoom(0.5, anchorFraction: 0.25)
        XCTAssertEqual(model.span, 900)
        XCTAssertEqual(model.domain.lowerBound.addingTimeInterval(model.span * 0.25), pointer)
        XCTAssertEqual(model.cursor.date, pinned)
        XCTAssertTrue(model.cursor.pinned)
        XCTAssertFalse(model.followsLive)
        model.zoom(2, anchorFraction: 0.25)
        XCTAssertEqual(model.domain, original)
    }

    func testPointerZoomRespectsLimitsAndRejectsInvalidInput() {
        let model = DataExplorerModel(now: Date(timeIntervalSince1970: 1_700_000_400))
        let original = model.domain
        for factor in [0, -1, Double.nan, Double.infinity] {
            model.zoom(factor, anchorFraction: 0.5)
            XCTAssertEqual(model.domain, original)
        }
        model.zoom(0.5, anchorFraction: .nan)
        XCTAssertEqual(model.domain, original)
        model.zoom(0.00001, anchorFraction: 0.25)
        XCTAssertEqual(model.span, 20)
        model.zoom(1_000_000, anchorFraction: 0.25)
        XCTAssertEqual(model.span, 90 * 86_400)
        XCTAssertLessThanOrEqual(model.domain.upperBound, Date())
    }

    func testAlertInvestigationPinsEvidenceAndRetainsItsValuesWithoutHistory() throws {
        let suite = "MacPerfMonitorTests.ExplorerAlertRange.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_700_000_400)
        let alert = MacPerfMonitorCore.Alert(
            kind: .swap, title: "Swap growth", body: "3 to 4 GiB", date: date,
            evidence: AlertEvidence(
                start: date.addingTimeInterval(-300), end: date, baseline: 3, current: 4))
        let request = try XCTUnwrap(AlertInvestigation(alerts: [alert]))
        let model = DataExplorerModel(preferences: defaults)
        model.chooseWindow(.sixHours)
        model.investigate(request)
        XCTAssertFalse(model.followsLive)
        XCTAssertEqual(model.cursor.date, date)
        XCTAssertEqual(model.selectedLaneID, "swap")
        XCTAssertTrue(model.enabled.contains("swap"))
        XCTAssertEqual(model.alertEvidence.first?.evidence?.current, 4)
        XCTAssertEqual(DataExplorerModel(preferences: defaults).span, 21600)
        model.toggleLive()
        XCTAssertTrue(model.alertEvidence.isEmpty)
    }

    func testWheelZoomImmediatelyUpdatesEveryChartWithoutReplacingSamples() {
        let data = fixture()
        let model = DataExplorerModel()
        model.seed(data, selected: [], enabled: ["cpu", "network"])
        let original = model.lanes.map { Array($0.feed.model.series[0].column.values) }
        let pointer = model.domain.lowerBound.addingTimeInterval(model.span * 0.3)
        for _ in 0..<5 { model.zoom(0.9, anchorFraction: 0.3) }
        XCTAssertEqual(model.span, 3600 * pow(0.9, 5), accuracy: 0.001)
        XCTAssertEqual(
            model.domain.lowerBound.addingTimeInterval(model.span * 0.3).timeIntervalSince(pointer),
            0, accuracy: 0.001)
        XCTAssertTrue(model.lanes.allSatisfy { $0.feed.model.xDomain == model.domain })
        XCTAssertEqual(model.lanes.map { Array($0.feed.model.series[0].column.values) }, original)
        model.stop()
    }

    func testInspectorUsesOnlyCoveredPriorReadings() {
        let series = TrendSurfaceSeries(
            column: LiveColumn(
                times: [0, 10, 20, 100], values: [20, .nan, 30, 80], highs: [20, .nan, 40, 80],
                lows: [20, .nan, 25, 80], durations: [0, 0, 60, 0]), color: .blue)
        func reading(_ time: Double) -> ExplorerReading {
            DataExplorerModel.reading(
                series, at: Date(timeIntervalSinceReferenceDate: time), freshness: 5)
        }
        XCTAssertNil(reading(-1).value)
        XCTAssertEqual(reading(3).value, 20)
        XCTAssertNil(reading(9).value)
        XCTAssertNil(reading(10).value)
        XCTAssertEqual(reading(40).value, 30)
        XCTAssertEqual(reading(40).minimum, 25)
        XCTAssertEqual(reading(40).sourceDuration, 60)
        XCTAssertNil(reading(80).value)
        XCTAssertNil(reading(95).value)
    }

    func testDiskRateResetsAndGapsRemainUnavailable() {
        var sample = process(pid: 1000, at: Date(timeIntervalSinceReferenceDate: 0))
        sample.diskBytesRead = 100
        let first = ExplorerProcessPoint(sample: sample)
        sample.timestamp = Date(timeIntervalSinceReferenceDate: 10)
        sample.diskBytesRead = 300
        let second = ExplorerProcessPoint(sample: sample)
        sample.timestamp = Date(timeIntervalSinceReferenceDate: 20)
        sample.diskBytesRead = 10
        let reset = ExplorerProcessPoint(sample: sample)
        sample.timestamp = Date(timeIntervalSinceReferenceDate: 1000)
        sample.diskBytesRead = 1000
        let gap = ExplorerProcessPoint(sample: sample)
        let values = ExplorerMetrics.processValues([first, second, reset, gap], metric: .diskRead)
        XCTAssertTrue(values[0].isNaN)
        XCTAssertEqual(values[1], 20)
        XCTAssertTrue(values[2].isNaN)
        XCTAssertTrue(values[3].isNaN)
    }

    func testRestartBoundaryCreatesHardGapWithoutDroppingReadings() {
        var sample = process(pid: 1000, at: Date(timeIntervalSinceReferenceDate: 0))
        sample.physFootprint = 100
        sample.diskBytesRead = 100
        let first = ExplorerProcessPoint(sample: sample)
        sample.timestamp = Date(timeIntervalSinceReferenceDate: 2)
        sample.physFootprint = 200
        sample.diskBytesRead = 1_000
        var restarted = ExplorerProcessPoint(sample: sample)
        restarted.startsNewRun = true
        sample.timestamp = Date(timeIntervalSinceReferenceDate: 4)
        sample.physFootprint = 210
        sample.diskBytesRead = 1_200
        let continued = ExplorerProcessPoint(sample: sample)
        let points = [first, restarted, continued]

        let column = ExplorerMetrics.processColumn(points, metric: .footprint)
        XCTAssertEqual(Array(column.values).count, 4)
        XCTAssertEqual(Array(column.values)[0], 100)
        XCTAssertTrue(Array(column.values)[1].isNaN)
        XCTAssertEqual(Array(column.values)[2...], [200, 210])

        let disk = ExplorerMetrics.processValues(points, metric: .diskRead)
        XCTAssertTrue(disk[1].isNaN, "a restart must not become a cross-process rate")
        XCTAssertEqual(disk[2], 100)

        let segments = MetricChart.split(
            [
                MetricSample(date: sample.timestamp.addingTimeInterval(-4), value: 100),
                MetricSample(date: sample.timestamp.addingTimeInterval(-3), value: .nan),
                MetricSample(date: sample.timestamp.addingTimeInterval(-2), value: 200),
            ], gapThreshold: 150)
        XCTAssertEqual(segments.map { $0.map(\.value) }, [[100], [200]])
    }

    func testCSVIncludesRawValuesAndEscapesFormulaLikeProcessNames() {
        var model = TrendModel()
        model.xDomain =
            Date(timeIntervalSinceReferenceDate: 0)...Date(timeIntervalSinceReferenceDate: 1)
        model.series = [
            TrendSurfaceSeries(
                column: LiveColumn(
                    times: [0, 1, 2], values: [10, .nan, 99],
                    highs: [12, .nan, 99], lows: [8, .nan, 99]), color: .blue, name: "=SUM(1,2)")
        ]
        let csv = ExplorerCSV.encode([("CPU", model)])
        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\""))
        XCTAssertTrue(csv.contains(",10.0,8.0,12.0,0"))
        XCTAssertFalse(csv.contains("99.0"))
        XCTAssertFalse(csv.contains("nan"))
        XCTAssertEqual(csv.split(separator: "\n").count, 3)
    }

    func testCSVIncludesAnOverlappingSourceInterval() {
        var model = TrendModel()
        model.xDomain =
            Date(timeIntervalSinceReferenceDate: 10)...Date(timeIntervalSinceReferenceDate: 20)
        model.series = [
            TrendSurfaceSeries(
                column: LiveColumn(
                    times: [-60, 0, 60], values: [1, 2, 3],
                    durations: [60, 60, 60]), color: .blue)
        ]
        let csv = ExplorerCSV.encode([("CPU", model)])
        XCTAssertEqual(csv.split(separator: "\n").count, 2)
        XCTAssertTrue(csv.contains(",2.0,,,60.0"))
    }

    func testExitedProcessCanBeExportedWithItsRecordedIdentity() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_400)
        let sample = process(pid: 1234, at: date)
        let recorded = ExplorerProcess(sample: sample)
        let points = [
            ProcessHistoryPoint(
                date: date, footprint: 1234, cpuPercent: 25,
                fdTotal: 10, diskRead: 20, diskWritten: 30)
        ]
        let series = TraceExportBuilder.makeSeries(from: recorded, points: points)
        XCTAssertEqual(series.identity, sample.id)
        XCTAssertEqual(series.name, recorded.name)
        XCTAssertEqual(series.points.first?.footprint, 1234)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(UUID().uuidString).mpmtrace")
        defer { try? FileManager.default.removeItem(at: destination) }
        let exported = expectation(description: "Recorded process trace is written")
        var result: Result<Void, Error>?
        TraceFileExporter.write(
            histories: [sample.id: points], orderedIdentities: [sample.id], samples: [:],
            recorded: [sample.id: recorded], window: date...date.addingTimeInterval(1),
            resolutionSeconds: 1,
            exportedAt: date, destination: destination, operation: TraceExportOperation()
        ) { output in
            result = output
            exported.fulfill()
        }
        await fulfillment(of: [exported], timeout: 5)
        try XCTUnwrap(result).get()
        let decoded = try ProcessTraceCodec.decode(Data(contentsOf: destination))
        XCTAssertEqual(decoded.processes.first?.identity, sample.id)
        XCTAssertEqual(decoded.processes.first?.name, recorded.name)
        XCTAssertEqual(decoded.processes.first?.points.first?.footprint, 1234)
    }

    func testCursorStepsToActualLoadedObservationTimes() {
        let data = fixture()
        let model = DataExplorerModel()
        model.seed(data, selected: [], enabled: ["cpu"])
        model.cursor.pin(data.domain.lowerBound.addingTimeInterval(502))
        model.stepCursor(-1)
        XCTAssertEqual(model.cursor.date, data.domain.lowerBound.addingTimeInterval(500))
        model.stepCursor(1)
        XCTAssertEqual(model.cursor.date, data.domain.lowerBound.addingTimeInterval(505))
    }

    func testExplorerBuildsMachineChartsBeforeSelectingProcesses() {
        let model = DataExplorerModel()
        let data = fixture()
        model.seed(data, selected: [], enabled: ExplorerMetrics.defaultIDs)
        XCTAssertTrue(
            model.lanes.contains { $0.id == "cpu" && !$0.feed.model.series[0].column.isEmpty })
        XCTAssertEqual(model.lanes.first(where: { $0.id == "cpu" })?.feed.model.yDomain, 0...100)
        XCTAssertEqual(model.lanes.first(where: { $0.id == "die" })?.feed.model.series.count, 2)
    }

    func testSharedCursorMovesNativeChartOverlays() async throws {
        let data = fixture()
        let model = DataExplorerModel()
        model.seed(data, selected: [], enabled: ["cpu", "network"])
        let root = VStack {
            ForEach(model.lanes) { lane in
                ExplorerTrendChart(feed: lane.feed, cursor: model.cursor).frame(height: 150)
            }
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 600, height: 310),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let surfaces = descendants(host)
        XCTAssertEqual(surfaces.count, 2)
        let surface = try XCTUnwrap(surfaces.first)
        let time = data.domain.lowerBound.addingTimeInterval(500)
        surface.onTimeHover?(time)
        XCTAssertEqual(model.cursor.date, time)
        surface.onTimePin?(time)
        surfaces.last?.onTimeHover?(nil)
        XCTAssertTrue(model.cursor.pinned)
        XCTAssertEqual(model.cursor.date, time)
    }

    func testNativeExplorerScreenshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MACPERF_EXPLORER_ARTIFACTS"]
        else { return }
        _ = NSApplication.shared
        let data = fixture()
        let model = DataExplorerModel()
        model.seed(
            data, selected: data.processes.map(\.process), enabled: ExplorerMetrics.defaultIDs)
        model.cursor.pin(data.domain.lowerBound.addingTimeInterval(1800))
        let selection = MonitorSelection()
        for process in data.processes { selection.add(process.process.id) }
        for (width, height, appearance) in [
            (1440.0, 940.0, NSAppearance.Name.darkAqua), (860, 640, .aqua),
        ] {
            let content = DataExplorerView(explorer: model, onImport: { _ in })
                .environmentObject(selection).environmentObject(AppState())
                .frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: width, height: height),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            func display(_ layer: CALayer) {
                layer.displayIfNeeded()
                for child in layer.sublayers ?? [] { display(child) }
            }
            if let layer = host.layer { display(layer) }
            CATransaction.flush()
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let bytes = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("explorer-\(Int(width)).png"))
            XCTAssertFalse(descendants(host).isEmpty)
        }
    }

    private func fixture() -> ExplorerWindowData {
        let end = Date(timeIntervalSince1970: 1_788_950_400)
        let start = end.addingTimeInterval(-3600)
        let machine = stride(from: 0.0, through: 3600, by: 5).map { offset in
            let wave = abs(sin(offset / 200))
            return SystemHistoryPoint(
                date: start.addingTimeInterval(offset), pressurePercent: 15 + wave * 30,
                appMemory: UInt64(4_000_000_000 + wave * 2_000_000_000), wired: 2_000_000_000,
                compressed: 1_000_000_000, cachedFiles: 3_000_000_000, swapUsed: 2_000_000_000,
                cpuLoad: 0.15 + wave * 0.4, networkInBytesPerSec: wave * 1_000_000,
                networkOutBytesPerSec: wave * 100_000, diskReadBytesPerSec: wave * 30_000_000,
                diskWriteBytesPerSec: wave * 5_000_000, gpuUtilization: wave * 40,
                cpuDieC: 55 + wave * 20,
                gpuDieC: (1500...1700).contains(offset) ? nil : 45 + wave * 10)
        }
        let processes = [1000, 2000].map { pid -> ExplorerProcessHistory in
            let sample = process(pid: Int32(pid), at: start)
            let points = stride(from: 0.0, through: 3600, by: 10).map { offset in
                var point = sample
                point.timestamp = start.addingTimeInterval(offset)
                point.cpuPercent = 10 + abs(sin(offset / Double(pid / 10))) * 50
                return ExplorerProcessPoint(sample: point)
            }
            return ExplorerProcessHistory(process: ExplorerProcess(sample: sample), points: points)
        }
        return ExplorerWindowData(
            domain: start...end, granularity: .raw, system: machine, processes: processes)
    }

    private func process(pid: Int32, at date: Date) -> ProcessSample {
        ProcessSample(
            timestamp: date, pid: pid, ppid: 1,
            name: pid == 1000 ? "Build service" : "Browser renderer",
            physFootprint: 250_000_000, residentSize: 300_000_000, virtualSize: 1_000_000_000,
            lifetimeMaxFootprint: 400_000_000, cpuPercent: 20, cpuTimeUser: 0, cpuTimeSystem: 0,
            threadCount: 8, fdTotal: 20, fdVnode: 10, fdSocket: 5, fdPipe: 3, fdOther: 2,
            diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false, architecture: .arm64,
            startTime: date, uid: 501, dataSource: .directUserRead, footprintReadable: true)
    }

    private func descendants(_ view: NSView) -> [TrendSurfaceView] {
        var result = (view as? TrendSurfaceView).map { [$0] } ?? []
        for child in view.subviews { result += descendants(child) }
        return result
    }
}
