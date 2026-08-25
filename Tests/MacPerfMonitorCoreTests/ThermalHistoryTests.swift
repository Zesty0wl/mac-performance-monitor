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

    // MARK: - Per-domain sensor history (v15)

    /// Every sensor group the Hardware charts draw must round-trip, so a
    /// restart resumes the trend instead of starting blank.
    func testSensorDomainsRoundTripAndSeedEveryChart() throws {
        let now = Date()
        var sample = thermalSample(at: now, cpu: 71, gpu: 54, ssd: 35, fan: 2400)
        sample.cpuPCoreDieC = 71
        sample.cpuECoreDieC = 63
        sample.airflowC = 41
        sample.skinC = 47
        sample.wirelessC = 42
        sample.voltageRailC = 66
        sample.otherSensorC = 76
        sample.batteryTemperatureCelsius = 29
        try store.insert(systemSample: sample)

        let history = try store.systemHistory(.fiveMinutes, now: now)
        let point = try XCTUnwrap(history.last)
        // Each group resolves to its recorded series through the same lookup
        // the Hardware overview seeds from.
        let expected: [(String, Double)] = [
            (SMCReader.groupCPUPCores, 71), (SMCReader.groupCPUECores, 63),
            (SMCReader.groupGPU, 54), (SMCReader.groupSSD, 35),
            (SMCReader.groupBattery, 29), (SMCReader.groupAirflow, 41),
            (SMCReader.groupSkin, 47), (SMCReader.groupWireless, 42),
            (SMCReader.groupVoltageRails, 66), (SMCReader.groupOther, 76),
        ]
        for (group, value) in expected {
            let recorded = HardwareFacts.SensorGroup.recordedValue(group, in: point)
            XCTAssertEqual(try XCTUnwrap(recorded, group), value, accuracy: 0.001, group)
        }
        // No group is left without a series, or its chart could never seed.
        for group in HardwareFacts.SensorGroup.displayOrder {
            XCTAssertNotNil(HardwareFacts.SensorGroup.recordedValue(group, in: point), group)
        }
    }

    /// Ticks that never read the SMC stay nil rather than seeding a chart
    /// with zeros, and a battery-less desktop reports no battery series.
    func testUnsampledDomainsStayNil() throws {
        let now = Date()
        try store.insert(systemSample: Make.system(timestamp: now, pressurePercent: 10))
        let point = try XCTUnwrap(try store.systemHistory(.fiveMinutes, now: now).last)
        for group in HardwareFacts.SensorGroup.displayOrder {
            XCTAssertNil(HardwareFacts.SensorGroup.recordedValue(group, in: point), group)
        }
    }

    func testSensorDomainsSurviveBothRollupTiers() throws {
        for i in 0..<40 {
            var sample = thermalSample(at: anchor.addingTimeInterval(Double(i) * 6), cpu: 50)
            sample.cpuPCoreDieC = i == 20 ? 92 : 50
            sample.airflowC = 40
            sample.otherSensorC = 70
            try store.insert(systemSample: sample)
        }
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))
        let minutePoints = try store.systemHistory(.oneDay, now: anchor.addingTimeInterval(600))
        XCTAssertEqual(minutePoints.compactMap(\.cpuPCoreDieC).max() ?? 0, 92, accuracy: 0.001)
        XCTAssertEqual(minutePoints.compactMap(\.airflowC).max() ?? 0, 40, accuracy: 0.001)

        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(7200))
        let hourPoints = try store.systemHistory(.sevenDays, now: anchor.addingTimeInterval(7200))
        XCTAssertEqual(hourPoints.compactMap(\.cpuPCoreDieC).max() ?? 0, 92, accuracy: 0.001)
        XCTAssertEqual(hourPoints.compactMap(\.otherSensorC).max() ?? 0, 70, accuracy: 0.001)
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
