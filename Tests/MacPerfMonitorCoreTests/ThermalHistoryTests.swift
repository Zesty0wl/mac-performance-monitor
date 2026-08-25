import XCTest

@testable import MacPerfMonitorCore

/// The v14 thermal columns round-trip through the store and keep their peaks
/// through every tier: raw rows, the minute and hour rollups, and the chart
/// downsampler. Max preservation is the design invariant: thermal history
/// exists to answer "how hot did it get", and any tier that averages a spike
/// away breaks the feature.
final class ThermalHistoryTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-thermal-test-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private func thermalSample(
        at date: Date, cpu: Double? = nil, gpu: Double? = nil, ssd: Double? = nil,
        fan: Double? = nil, pressure: ThermalPressureState? = nil
    ) -> SystemSample {
        var sample = Make.system(timestamp: date, pressurePercent: 10)
        sample.cpuDieC = cpu
        sample.gpuDieC = gpu
        sample.ssdTemperatureC = ssd
        sample.fanRPM = fan
        sample.thermalPressure = pressure
        return sample
    }

    // MARK: - Raw round trip

    func testThermalFiguresRoundTrip() throws {
        let now = Date()
        var sampled = thermalSample(
            at: now.addingTimeInterval(-2), cpu: 53.2, gpu: 41.0, ssd: 29.5, fan: 2317,
            pressure: .serious)
        sampled.gpuUtilization = 83
        sampled.gpuPowerWatts = 3.5
        sampled.anePowerWatts = 0.25
        let unsampled = Make.system(timestamp: now, pressurePercent: 10)
        try store.insert(systemSample: sampled)
        try store.insert(systemSample: unsampled)

        let history = try store.systemHistory(.fiveMinutes, now: now)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].cpuDieC ?? -1, 53.2, accuracy: 0.001)
        XCTAssertEqual(history[0].gpuDieC ?? -1, 41.0, accuracy: 0.001)
        XCTAssertEqual(history[0].ssdTemperatureC ?? -1, 29.5, accuracy: 0.001)
        XCTAssertEqual(history[0].fanRPM ?? -1, 2317, accuracy: 0.001)
        XCTAssertEqual(history[0].thermalPressure, .serious)
        // A tick that did not read the SMC stays distinct from a measured 0.
        XCTAssertNil(history[1].cpuDieC)
        XCTAssertNil(history[1].fanRPM)
        XCTAssertNil(history[1].thermalPressure)
    }

    /// `decodeSystem` (latest-sample and since-queries) must carry the thermal
    /// fields, and the GPU fields it previously dropped on read.
    func testLatestSystemSampleDecodesThermalAndGPU() throws {
        let now = Date()
        var sample = thermalSample(at: now, cpu: 47.0, fan: 0, pressure: .nominal)
        sample.gpuUtilization = 61
        sample.gpuPowerWatts = 2.75
        sample.anePowerWatts = 0.5
        try store.insert(systemSample: sample)

        let latest = try XCTUnwrap(store.latestSystemSample())
        XCTAssertEqual(latest.cpuDieC ?? -1, 47.0, accuracy: 0.001)
        XCTAssertEqual(latest.fanRPM ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(latest.thermalPressure, .nominal)
        XCTAssertEqual(latest.gpuUtilization ?? -1, 61, accuracy: 0.001)
        XCTAssertEqual(latest.gpuPowerWatts ?? -1, 2.75, accuracy: 0.001)
        XCTAssertEqual(latest.anePowerWatts ?? -1, 0.5, accuracy: 0.001)
    }

    // MARK: - Rollups

    func testMinuteRollupKeepsTheSpike() throws {
        // A one-tick 95 degree spike inside a minute of 40 degree samples.
        for i in 0..<10 {
            try store.insert(
                systemSample: thermalSample(
                    at: anchor.addingTimeInterval(Double(i) * 6),
                    cpu: i == 4 ? 95 : 40, gpu: 35, fan: Double(1000 + i * 100),
                    pressure: i == 4 ? .critical : .nominal))
        }
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))

        let points = try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600))
        XCTAssertGreaterThanOrEqual(points.count, 1)
        // The aggregate read serves the bucket max, so the spike survives.
        XCTAssertEqual(points.map { $0.cpuDieC ?? 0 }.max() ?? 0, 95, accuracy: 0.001)
        XCTAssertEqual(points.first?.gpuDieC ?? 0, 35, accuracy: 0.001)
        XCTAssertEqual(points.compactMap(\.thermalPressure).max(), .critical)
    }

    func testHourRollupKeepsTheSpike() throws {
        for i in 0..<40 {
            try store.insert(
                systemSample: thermalSample(
                    at: anchor.addingTimeInterval(Double(i) * 6),
                    cpu: i == 20 ? 88 : 42, pressure: .fair))
        }
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(7200))

        let points = try store.systemHistory(.sevenDays, now: anchor.addingTimeInterval(7200))
        XCTAssertGreaterThanOrEqual(points.count, 1)
        XCTAssertEqual(points.map { $0.cpuDieC ?? 0 }.max() ?? 0, 88, accuracy: 0.001)
        XCTAssertEqual(points.first?.thermalPressure, .fair)
    }

    /// Ticks with no SMC read must not collapse a bucket to null: AVG/MAX skip
    /// nulls, so a bucket with any reading keeps it.
    func testRollupIgnoresUnsampledTicks() throws {
        try store.insert(systemSample: thermalSample(at: anchor, cpu: 50))
        try store.insert(systemSample: thermalSample(at: anchor.addingTimeInterval(6)))
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))

        let points = try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600))
        XCTAssertEqual(points.map { $0.cpuDieC ?? 0 }.max() ?? 0, 50, accuracy: 0.001)
    }

    // MARK: - Chart downsampler

    private func historyPoint(index: Int) -> SystemHistoryPoint {
        SystemHistoryPoint(
            date: anchor.addingTimeInterval(Double(index) * 5), pressurePercent: 10,
            appMemory: 1, wired: 1, compressed: 1, cachedFiles: 1, swapUsed: 0)
    }

    func testChartDownsampleKeepsThermalPeaksAndGPUSeries() {
        let span: TimeInterval = 3600
        var points: [SystemHistoryPoint] = []
        for i in 0..<720 {
            var point = historyPoint(index: i)
            point.gpuUtilization = 50
            point.cpuDieC = i == 360 ? 96 : 40
            point.gpuDieC = 35
            point.fanRPM = Double(i)
            point.thermalPressure = i == 360 ? .serious : .nominal
            points.append(point)
        }
        let thinned = points.chartDownsampled(span: span, to: 100)
        XCTAssertLessThanOrEqual(thinned.count, 102)
        // The one-tick thermal spike survives max-preserving buckets.
        let peaks: [Double] = thinned.compactMap { $0.cpuDieC }
        XCTAssertEqual(peaks.max() ?? 0, 96, accuracy: 0.001)
        let worst: ThermalPressureState? = thinned.compactMap { $0.thermalPressure }.max()
        XCTAssertEqual(worst, ThermalPressureState.serious)
        // The GPU series is carried through instead of being dropped to nil.
        XCTAssertEqual(thinned.compactMap { $0.gpuUtilization }.count, thinned.count)
        // All-nil stays nil: no thermal reading must not become a 0 line.
        let bare = (0..<720).map(historyPoint(index:))
        XCTAssertTrue(bare.chartDownsampled(span: span, to: 100).allSatisfy { $0.cpuDieC == nil })
    }

    func testThermalPressureStateOrderingAndLabels() {
        XCTAssertLessThan(ThermalPressureState.nominal, .fair)
        XCTAssertLessThan(ThermalPressureState.fair, .serious)
        XCTAssertLessThan(ThermalPressureState.serious, .critical)
        XCTAssertFalse(ThermalPressureState.fair.isThrottling)
        XCTAssertTrue(ThermalPressureState.serious.isThrottling)
        let mapped = ThermalPressureState(ProcessInfo.processInfo.thermalState)
        XCTAssertGreaterThanOrEqual(mapped.rawValue, 0)
    }
}
