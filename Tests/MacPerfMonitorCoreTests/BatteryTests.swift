import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class BatteryTests: XCTestCase {
    func testEnergyRollupsDoNotMixPacksOrOpposingRuntimeStates() throws {
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        var battery = BatterySample(
            timestamp: start, isPresent: true, chargePercent: 50, timeToEmptyMinutes: 120,
            systemPowerWatts: 20, serialNumber: "first")
        try store.insert(systemSample: Make.system(timestamp: start), battery: battery)
        battery.timestamp = start.addingTimeInterval(10)
        battery.serialNumber = "replacement"
        battery.chargePercent = 100
        try store.insert(systemSample: Make.system(timestamp: battery.timestamp), battery: battery)
        battery.timestamp = start.addingTimeInterval(60)
        try store.insert(systemSample: Make.system(timestamp: battery.timestamp), battery: battery)
        battery.timestamp = start.addingTimeInterval(70)
        battery.isOnAC = true
        battery.isCharging = true
        battery.timeToFullMinutes = 30
        try store.insert(systemSample: Make.system(timestamp: battery.timestamp), battery: battery)
        try Retention.run(store.databasePool, now: start.addingTimeInterval(120))
        let history = try store.batteryHistory(.oneDay, now: start.addingTimeInterval(120))
        XCTAssertEqual(history.count, 2)
        XCTAssertNil(history[0].batteryID)
        XCTAssertNil(history[0].values[.charge])
        XCTAssertNil(history[0].values[.runtime])
        XCTAssertEqual(history[0].values[.power], 20)
        XCTAssertNil(history[1].state)
        XCTAssertNil(history[1].values[.runtime])
        XCTAssertNil(history[1].values[.timeToFull])
    }

    func testEnergyRecorderRejectsStaleBatteryAndDoesNotWriteLifetimeWithoutSnapshot() throws {
        let now = Date()
        let stale = BatterySample(
            timestamp: now.addingTimeInterval(-120), isPresent: true, chargePercent: 50,
            cycleCount: 100, healthPercent: 95, serialNumber: "pack")
        try store.insert(systemSample: Make.system(timestamp: now), battery: stale)
        try store.insertChanged(
            Make.system(timestamp: now.addingTimeInterval(5)), processes: [], bucket: 60)
        let history = try store.batteryHistory(.oneHour, now: now.addingTimeInterval(10))
        XCTAssertTrue(history.allSatisfy { $0.values.isEmpty })
        let identifier = try XCTUnwrap(BatteryIdentity.identifier(for: "pack"))
        XCTAssertTrue(try store.batteryDailyHistory(for: identifier).isEmpty)
    }

    func testEnergyHistoryKeepsKnownLegacyChargeWithoutInventingNewMetrics() throws {
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        var system = Make.system(timestamp: start)
        system.batteryPresent = true
        system.batteryCharge = 75
        system.batteryHealthPercent = 94
        system.batteryTemperatureCelsius = 30
        try store.insert(systemSample: system)
        let raw = try XCTUnwrap(try store.batteryHistory(.oneHour, now: start).first)
        XCTAssertEqual(raw.values[.charge], 75)
        XCTAssertEqual(raw.values[.temperature], 30)
        XCTAssertNil(raw.values[.power])
        XCTAssertNil(raw.values[.runtime])
        XCTAssertNil(raw.batteryID)
        XCTAssertNil(raw.state)
        try Retention.run(store.databasePool, now: start.addingTimeInterval(300))
        let minute = try XCTUnwrap(
            try store.batteryHistory(.oneDay, now: start.addingTimeInterval(300)).first)
        XCTAssertEqual(minute.values[.charge], 75)
        XCTAssertNil(minute.minima[.charge])
        XCTAssertNil(minute.maxima[.temperature])
        XCTAssertNil(minute.counts[.temperature])
    }

    func testUpgradeFromVersionTwoPreservesRecordedHistory() throws {
        let directory = tempURL.appendingPathExtension("upgrade")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("history.sqlite")
        let timestamp = Date(timeIntervalSince1970: 1_700_006_400)
        do {
            let pool = try DatabasePool(path: legacyURL.path)
            try MacPerfMonitorDatabase.migrator.migrate(pool, upTo: "v18-swap-activity")
            try pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO system_samples
                        (timestamp, total_ram, free, active, inactive, wired, speculative, compressed,
                         app_memory, cached_files, swap_total, swap_used, pressure_level, pressure_percent,
                         page_ins, page_outs, compressions, decompressions,
                         page_ins_delta, page_outs_delta, compressions_delta, decompressions_delta, cpu_load,
                         battery_present, battery_charge, battery_health, battery_temp)
                        VALUES (?,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,75,94,30)
                        """, arguments: [timestamp.timeIntervalSince1970])
            }
        }

        let migratedStore = try SampleStore(url: legacyURL)
        let latest = try XCTUnwrap(try migratedStore.latestSystemSample())
        XCTAssertNil(latest.aneTimeMillisecondsPerSecond)
        XCTAssertNil(latest.aneSampleIsPartial)
        let history = try migratedStore.batteryHistory(.oneHour, now: timestamp)
        XCTAssertEqual(history.count, 1)
        let point = try XCTUnwrap(history.first)
        XCTAssertEqual(point.date, timestamp)
        XCTAssertEqual(point.values[.charge], 75)
        XCTAssertEqual(point.values[.temperature], 30)
        XCTAssertNil(point.values[.power])
        XCTAssertNil(point.values[.runtime])
        XCTAssertNil(point.batteryID)
        let dailyCount = try migratedStore.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery_daily")
        }
        XCTAssertEqual(dailyCount, 0)
        let sample = BatterySample(
            timestamp: timestamp.addingTimeInterval(5), isPresent: true, chargePercent: 74,
            cycleCount: 100, healthPercent: 94, serialNumber: "upgrade-pack")
        try migratedStore.insert(
            systemSample: Make.system(timestamp: sample.timestamp), battery: sample)
        let identifier = try XCTUnwrap(BatteryIdentity.identifier(for: sample.serialNumber))
        let daily = try migratedStore.batteryDailyHistory(
            for: identifier, through: sample.timestamp)
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily.first?.cycleCount, 100)
    }

    func testEnergyHistoryIncludesOlderWideBucketAcrossPolicyChanges() throws {
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let battery = BatterySample(timestamp: start, isPresent: true, chargePercent: 75)
        try store.insert(systemSample: Make.system(timestamp: start), battery: battery)
        try Retention.run(
            store.databasePool, now: start.addingTimeInterval(600),
            policy: RetentionPolicy(standardResBucket: 300))
        try store.databasePool.write { db in try Retention.setMeta(db, "minute_bucket_seconds", 60)
        }
        let now = start.addingTimeInterval(86_400 + 180)
        let point = try XCTUnwrap(try store.batteryHistory(.oneDay, now: now).first)
        XCTAssertEqual(point.duration, 300)
        XCTAssertEqual(point.values[.charge], 75)
    }

    func testEnergyHistoryPreservesPowerAndRuntimeAcrossAllTiers() throws {
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        for (offset, power, runtime) in [(0.0, 10.0, 120.0), (10, 30, 100)] {
            let date = start.addingTimeInterval(offset)
            let battery = BatterySample(
                timestamp: date, isPresent: true, chargePercent: 50,
                runtimeEstimate: BatteryRuntimeEstimate(
                    minutesRemaining: runtime, fullChargeMinutes: runtime * 2, source: .recentUse),
                powerWatts: power, systemPowerWatts: power + 5,
                voltageMilliVolts: 12_000, temperatureCelsius: 31, cycleCount: 200,
                healthPercent: 95, serialNumber: "pack")
            try store.insert(systemSample: Make.system(timestamp: date), battery: battery)
        }
        let raw = try store.batteryHistory(.oneHour, now: start.addingTimeInterval(20))
        XCTAssertEqual(raw.compactMap { $0.values[.power] }, [15, 35])
        XCTAssertEqual(raw.compactMap { $0.values[.flow] }, [-10, -30])
        XCTAssertEqual(raw.compactMap { $0.values[.runtime] }, [120, 100])
        XCTAssertEqual(raw.first?.estimateSource, .recentUse)
        try Retention.run(store.databasePool, now: start.addingTimeInterval(120))
        let minute = try XCTUnwrap(
            try store.batteryHistory(.oneDay, now: start.addingTimeInterval(120)).first)
        XCTAssertEqual(minute.values[.power], 25)
        XCTAssertEqual(minute.minima[.power], 15)
        XCTAssertEqual(minute.maxima[.power], 35)
        XCTAssertEqual(minute.values[.runtime], 110)
        XCTAssertEqual(minute.counts[.runtime], 2)
        try Retention.run(store.databasePool, now: start.addingTimeInterval(7200))
        let hour = try XCTUnwrap(
            try store.batteryHistory(.sevenDays, now: start.addingTimeInterval(7200)).first)
        XCTAssertEqual(hour.values[.power], 25)
        XCTAssertEqual(hour.values[.runtime], 110)
        XCTAssertEqual(hour.maxima[.power], 35)
        XCTAssertEqual(hour.state, .battery)
        let identifier = try XCTUnwrap(BatteryIdentity.identifier(for: "pack"))
        XCTAssertEqual(try store.batteryDailyHistory(for: identifier).count, 1)
    }

    func testEnergyHistoryLeavesLegacyAndUnavailableReadingsMissing() throws {
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        try store.insert(systemSample: Make.system(timestamp: start))
        let legacy = try XCTUnwrap(try store.batteryHistory(.oneHour, now: start).first)
        XCTAssertTrue(legacy.values.isEmpty)
        let desktop = BatterySample(timestamp: start.addingTimeInterval(10), systemPowerWatts: 20)
        try store.insert(systemSample: Make.system(timestamp: desktop.timestamp), battery: desktop)
        let newest = try XCTUnwrap(try store.batteryHistory(.oneHour, now: desktop.timestamp).last)
        XCTAssertEqual(newest.values[.power], 20)
        XCTAssertNil(newest.values[.charge])
        XCTAssertNil(newest.values[.runtime])
        XCTAssertEqual(newest.state, .noBattery)
        try Retention.run(store.databasePool, now: start.addingTimeInterval(120))
        let minute = try XCTUnwrap(
            try store.batteryHistory(.oneDay, now: start.addingTimeInterval(120)).first)
        XCTAssertEqual(minute.values[.power], 20)
        XCTAssertNil(minute.values[.charge])
    }

    func testRuntimeEstimatorPrefersTheReportedEstimate() throws {
        var estimator = BatteryRuntimeEstimator()
        let sample = BatterySample(
            timestamp: Date(), isPresent: true, chargePercent: 50, timeToEmptyMinutes: 120,
            maxCapacitymAh: 6000, currentCapacitymAh: 3000)
        let estimate = try XCTUnwrap(estimator.update(sample))
        XCTAssertEqual(estimate.source, .macOS)
        XCTAssertEqual(estimate.minutesRemaining, 120)
        XCTAssertEqual(estimate.fullChargeMinutes, 240)
    }

    func testRuntimeEstimatorNeedsSustainedDischargeAndResetsAcrossGapsAndCharging() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var estimator = BatteryRuntimeEstimator()
        var sample = BatterySample(
            timestamp: start, isPresent: true, chargePercent: 50,
            amperageMilliAmps: -1000, voltageMilliVolts: 12_000,
            maxCapacitymAh: 6000, currentCapacitymAh: 3000, serialNumber: "pack")
        for offset in stride(from: 0.0, to: 180, by: 10) {
            sample.timestamp = start.addingTimeInterval(offset)
            XCTAssertNil(estimator.update(sample))
        }
        sample.timestamp = start.addingTimeInterval(180)
        let estimate = try XCTUnwrap(estimator.update(sample))
        XCTAssertEqual(estimate.source, .recentUse)
        XCTAssertEqual(estimate.minutesRemaining, 180, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(estimate.fullChargeMinutes), 360, accuracy: 0.01)
        sample.timestamp = start.addingTimeInterval(300)
        XCTAssertNil(estimator.update(sample))
        sample.isCharging = true
        sample.timeToEmptyMinutes = 120
        XCTAssertNil(estimator.update(sample))
        sample.isCharging = false
        sample.isOnAC = true
        XCTAssertNil(estimator.update(sample))
        XCTAssertNil(estimator.update(nil))
    }

    func testRuntimeEstimatorRejectsUnstableLoadAndBatteryReplacement() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var estimator = BatteryRuntimeEstimator()
        var sample = BatterySample(
            timestamp: start, isPresent: true, chargePercent: 50,
            amperageMilliAmps: -100, voltageMilliVolts: 12_000,
            maxCapacitymAh: 6000, currentCapacitymAh: 3000, serialNumber: "pack")
        for index in 0...30 {
            sample.timestamp = start.addingTimeInterval(Double(index) * 10)
            sample.amperageMilliAmps = index < 25 ? -100 : -8000
            _ = estimator.update(sample)
        }
        sample.timestamp = start.addingTimeInterval(310)
        XCTAssertNil(estimator.update(sample))
        sample.serialNumber = "replacement"
        sample.timestamp = start.addingTimeInterval(320)
        XCTAssertNil(estimator.update(sample))
    }

    func testRuntimeEstimatorRejectsAlternatingLoadAndRecoversAfterItSettles() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var estimator = BatteryRuntimeEstimator()
        var sample = BatterySample(
            timestamp: start, isPresent: true, chargePercent: 50,
            voltageMilliVolts: 12_000, maxCapacitymAh: 6000, currentCapacitymAh: 3000,
            serialNumber: "pack")
        for index in 0...30 {
            sample.timestamp = start.addingTimeInterval(Double(index) * 10)
            sample.amperageMilliAmps = index.isMultiple(of: 2) ? -100 : -1900
            XCTAssertNil(estimator.update(sample))
        }
        for index in 31...60 {
            sample.timestamp = start.addingTimeInterval(Double(index) * 10)
            sample.amperageMilliAmps = -1000
            _ = estimator.update(sample)
        }
        sample.timestamp = start.addingTimeInterval(610)
        let estimate = try XCTUnwrap(estimator.update(sample))
        XCTAssertEqual(estimate.source, .recentUse)
        XCTAssertEqual(estimate.minutesRemaining, 180, accuracy: 0.01)
    }

    func testDailyBatteryHistoryKeepsLatestValidValuesAndSeparatesPacks() throws {
        let day = Date(timeIntervalSince1970: 1_700_006_400)
        var sample = BatterySample(
            timestamp: day, isPresent: true, cycleCount: 100, designCapacitymAh: 6000,
            maxCapacitymAh: 5700, healthPercent: 95, serialNumber: "pack-one")
        try store.recordDailyBattery(sample)
        sample.timestamp = day.addingTimeInterval(3600)
        sample.cycleCount = 101
        sample.healthPercent = nil
        try store.recordDailyBattery(sample)
        sample.timestamp = day.addingTimeInterval(10)
        sample.cycleCount = 99
        try store.recordDailyBattery(sample)
        sample.timestamp = day.addingTimeInterval(7200)
        sample.serialNumber = "pack-two"
        sample.cycleCount = 0
        sample.healthPercent = 100
        try store.recordDailyBattery(sample)

        let firstID = try XCTUnwrap(BatteryIdentity.identifier(for: "pack-one"))
        let secondID = try XCTUnwrap(BatteryIdentity.identifier(for: "pack-two"))
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertFalse(firstID.contains("pack-one"))
        let history = try store.batteryDailyHistory(for: firstID, through: sample.timestamp)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.cycleCount, 101)
        XCTAssertEqual(history.first?.healthPercent, 95)
        XCTAssertEqual(history.first?.fullCapacitymAh, 5700)
        XCTAssertEqual(history.first?.date, day.addingTimeInterval(3600))
        let replacement = try store.batteryDailyHistory(for: secondID, through: sample.timestamp)
        XCTAssertEqual(replacement.first?.cycleCount, 0)
    }

    func testDailyBatteryHistorySurvivesOrdinaryRetentionAndRespectsDates() throws {
        let first = Date(timeIntervalSince1970: 1_650_067_200)
        var sample = BatterySample(
            timestamp: first, isPresent: true, cycleCount: 100, healthPercent: 95,
            serialNumber: "pack")
        try store.recordDailyBattery(sample)
        sample.timestamp = first.addingTimeInterval(400 * 86_400)
        sample.cycleCount = 220
        try store.recordDailyBattery(sample)
        try Retention.run(store.databasePool, now: sample.timestamp)
        let identifier = try XCTUnwrap(BatteryIdentity.identifier(for: "pack"))
        let all = try store.batteryDailyHistory(for: identifier, through: sample.timestamp)
        XCTAssertEqual(all.map(\.cycleCount), [100, 220])
        let recent = try store.batteryDailyHistory(
            for: identifier, since: sample.timestamp.addingTimeInterval(-90 * 86_400),
            through: sample.timestamp)
        XCTAssertEqual(recent.map(\.cycleCount), [220])
        let earlier = try store.batteryDailyHistory(
            for: identifier, through: first.addingTimeInterval(1))
        XCTAssertEqual(earlier.map(\.cycleCount), [100])
    }

    func testDailyBatteryHistoryIgnoresMissingIdentityAndInvalidValues() throws {
        var sample = BatterySample(timestamp: Date(), isPresent: true, cycleCount: 10)
        try store.recordDailyBattery(sample)
        sample.serialNumber = "pack"
        sample.isPresent = false
        try store.recordDailyBattery(sample)
        sample.isPresent = true
        sample.cycleCount = -1
        sample.healthPercent = .nan
        try store.recordDailyBattery(sample)
        let identifier = try XCTUnwrap(BatteryIdentity.identifier(for: "pack"))
        XCTAssertTrue(try store.batteryDailyHistory(for: identifier).isEmpty)
        XCTAssertNil(BatteryIdentity.identifier(for: "  "))
    }

    private var tempURL: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-battery-test-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    // MARK: - BatteryReader

    /// The reader must never crash. Outcomes:
    /// - `nil`: no AppleSmartBattery entry at all
    /// - `isPresent == false`: desktop telemetry-only sample (system watts)
    /// - `isPresent == true`: a self-consistent laptop battery sample
    func testBatteryReaderIsSafeAndConsistent() {
        let sample = BatteryReader().read()
        guard let sample else { return }
        XCTAssertGreaterThanOrEqual(sample.powerWatts, 0)
        XCTAssertGreaterThanOrEqual(sample.systemPowerWatts, 0)
        guard sample.isPresent else { return }
        XCTAssertGreaterThanOrEqual(sample.chargePercent, 0)
        XCTAssertLessThanOrEqual(sample.chargePercent, 100)
        if let health = sample.healthPercent {
            XCTAssertGreaterThanOrEqual(health, 0)
            XCTAssertLessThanOrEqual(health, 100)
        }
    }

    // MARK: - Capacity / health derivation (firmware layouts across the fleet)

    /// Apple silicon, figures at the top level: MaxCapacity is the normalised 0–100
    /// percent, the real mAh sit in NominalChargeCapacity / AppleRaw*. Health must
    /// follow AppleRawMaxCapacity — the raw FCC coconutBattery divides by design —
    /// not the higher NominalChargeCapacity that System Settings smooths to.
    func testCapacityAppleSiliconTopLevel() {
        let out = BatteryReader.capacityReadout(from: [
            "CycleCount": 189,
            "DesignCapacity": 6075,
            "MaxCapacity": 100,  // normalised percent, must not be used as mAh
            "NominalChargeCapacity": 5489,
            "AppleRawMaxCapacity": 5339,
            "AppleRawCurrentCapacity": 3542,
        ])
        XCTAssertEqual(out.cycleCount, 189)
        XCTAssertEqual(out.designCapacitymAh, 6075)
        XCTAssertEqual(out.maxCapacitymAh, 5339)  // AppleRawMaxCapacity preferred (coconut)
        XCTAssertEqual(out.currentCapacitymAh, 3542)
        XCTAssertEqual(try XCTUnwrap(out.healthPercent), 87.9, accuracy: 0.1)
    }

    /// Some Macs expose the detailed figures only inside the nested `BatteryData`
    /// sub-dictionary. The old top-level-only read returned nil health here — this
    /// is the layout behind "not displayed on most MacBooks".
    func testCapacityNestedUnderBatteryData() {
        let out = BatteryReader.capacityReadout(from: [
            "MaxCapacity": 100,
            "BatteryData": [
                "CycleCount": 312,
                "DesignCapacity": 6075,
                "NominalChargeCapacity": 5000,
            ] as [String: Any],
        ])
        XCTAssertEqual(out.cycleCount, 312)
        XCTAssertEqual(out.designCapacitymAh, 6075)
        XCTAssertEqual(out.maxCapacitymAh, 5000)
        XCTAssertEqual(try XCTUnwrap(out.healthPercent), 82.3, accuracy: 0.1)
    }

    /// AppleRawMaxCapacity is the primary (coconut-matching) numerator, used even
    /// when NominalChargeCapacity is absent — the common Apple-silicon case.
    func testCapacityUsesAppleRawMax() {
        let out = BatteryReader.capacityReadout(from: [
            "DesignCapacity": 6000,
            "MaxCapacity": 100,
            "AppleRawMaxCapacity": 5100,
        ])
        XCTAssertEqual(out.maxCapacitymAh, 5100)
        XCTAssertEqual(try XCTUnwrap(out.healthPercent), 85.0, accuracy: 0.1)
    }

    /// Regression guard: the plain `MaxCapacity` is a normalised 0–100 percent on
    /// Apple silicon, never a mAh — so when only it and DesignCapacity are present
    /// (no Nominal/AppleRaw mAh figure), health must be nil, never the bogus ~1.6%
    /// that dividing the normalised 100 by the design capacity would produce.
    func testCapacityRejectsNormalisedMaxAsMilliampHours() {
        let out = BatteryReader.capacityReadout(from: [
            "DesignCapacity": 6075,
            "MaxCapacity": 100,
        ])
        XCTAssertNil(out.maxCapacitymAh)
        XCTAssertNil(out.currentCapacitymAh)
        XCTAssertNil(out.healthPercent)
    }

    /// No capacity keys at all: every derived figure is nil, nothing fabricated.
    func testCapacityMissingEverything() {
        let out = BatteryReader.capacityReadout(from: ["Serial": "ABC123"])
        XCTAssertNil(out.cycleCount)
        XCTAssertNil(out.designCapacitymAh)
        XCTAssertNil(out.maxCapacitymAh)
        XCTAssertNil(out.healthPercent)
    }

    // MARK: - Manufacture date from serial (Apple-silicon scheme)

    /// A fixed "now" so the decade-resolution tests are deterministic.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// ISO week-of-year + year actually decoded out of a Date, for assertions.
    private func isoWeekYear(_ date: Date) -> (week: Int, year: Int) {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return (
            cal.component(.weekOfYear, from: date), cal.component(.yearForWeekOfYear, from: date)
        )
    }

    /// The reference Apple-silicon serial: year digit 2 at index 3, week "47" at
    /// indices 4–5 → ISO week 47 of 2022 (resolved against a 2026 "now").
    func testManufactureDateFromSerialReferenceSample() throws {
        let decoded = try XCTUnwrap(
            BatteryReader.manufactureDate(
                fromSerial: "F8Y2475H3CYQ1LTAP", now: date(2026, 6, 22)))
        let wy = isoWeekYear(decoded)
        XCTAssertEqual(wy.week, 47)
        XCTAssertEqual(wy.year, 2022)
    }

    /// The lone year digit resolves to the latest non-future year ending in it:
    /// digit 2 against a 2026 "now" is 2022, not 2012.
    func testManufactureDateResolvesLatestNonFutureDecade() throws {
        let decoded = try XCTUnwrap(
            BatteryReader.manufactureDate(fromSerial: "XYZ210ABCDEFGHIJK", now: date(2026, 6, 22)))
        XCTAssertEqual(isoWeekYear(decoded).year, 2022)
    }

    /// When the digit's week in the current decade hasn't occurred yet, the real
    /// year is a decade earlier: digit 6, week 50, "now" early in 2026 → 2016.
    func testManufactureDateRollsBackWhenWeekIsFuture() throws {
        let decoded = try XCTUnwrap(
            BatteryReader.manufactureDate(fromSerial: "XYZ650ABCDEFGHIJK", now: date(2026, 2, 1)))
        XCTAssertEqual(isoWeekYear(decoded).year, 2016)
    }

    /// An 18-character serial (this Mac's "F5DH4A000U100000EB") is not the
    /// 17-char scheme, so it must decode to nil rather than a fabricated date.
    func testManufactureDateRejectsWrongLengthSerial() {
        XCTAssertNil(
            BatteryReader.manufactureDate(fromSerial: "F5DH4A000U100000EB", now: date(2026, 6, 22)))
    }

    /// A non-digit in the year/week positions, or an out-of-range week, is junk —
    /// never coerced into a date.
    func testManufactureDateRejectsNonNumericFields() {
        // Letter where the year digit must be.
        XCTAssertNil(
            BatteryReader.manufactureDate(fromSerial: "XYZH47ABCDEFGHIJK", now: date(2026, 6, 22)))
        // Week "99" is out of the 1...53 range.
        XCTAssertNil(
            BatteryReader.manufactureDate(fromSerial: "XYZ299ABCDEFGHIJK", now: date(2026, 6, 22)))
        // Week "00" is invalid.
        XCTAssertNil(
            BatteryReader.manufactureDate(fromSerial: "XYZ200ABCDEFGHIJK", now: date(2026, 6, 22)))
    }

    // MARK: - Manufacturer from serial vendor prefix

    /// The two real reference serials resolve to their known pack assemblers, and
    /// the lookup is case-insensitive on the prefix.
    func testManufacturerFromSerialReferenceSamples() {
        XCTAssertEqual(
            BatteryReader.manufacturer(fromSerial: "F5DH4A000U100000EB"),
            "Huizhou Desay Battery Company")
        XCTAssertEqual(BatteryReader.manufacturer(fromSerial: "F8Y2475H3CYQ1LTAP"), "Sunwoda")
        // Lowercase prefix still matches (serials are uppercased before lookup).
        XCTAssertEqual(
            BatteryReader.manufacturer(fromSerial: "ac000000000000000"), "Amperex Technology Ltd.")
    }

    /// An unknown prefix or a too-short serial returns nil rather than guessing.
    func testManufacturerFromSerialUnknownOrShort() {
        XCTAssertNil(BatteryReader.manufacturer(fromSerial: "ZZ000000000000000"))
        XCTAssertNil(BatteryReader.manufacturer(fromSerial: "F"))
        XCTAssertNil(BatteryReader.manufacturer(fromSerial: ""))
    }

    // MARK: - Manufacture date from battery lifetime age (modern Apple-silicon)

    /// coconutBattery's age path for modern serials that no longer encode a date:
    /// the big-endian uint32 at the head of `BatteryData/LifetimeData/Raw` is the
    /// battery's lifetime age in seconds, and the manufacture date is `now − age`.
    /// This Mac's real blob opens 0x03E739E0 (65,485,280 s ≈ 758 days); against a
    /// 2026-06-22 "now" that resolves to the 2024-05-25 coconutBattery shows.
    func testManufactureDateFromLifetimeRawReproducesCoconut() throws {
        // Real M3 Pro AppleSmartBattery LifetimeData/Raw blob head.
        let raw = Data([0x03, 0xE7, 0x39, 0xE0, 0x00, 0x01, 0x4F, 0xEF])
        let decoded = try XCTUnwrap(
            BatteryReader.manufactureDate(fromLifetimeRaw: raw, now: date(2026, 6, 22)))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: decoded)
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 25)
    }

    /// The age is `now − seconds` exactly: the decoded date must be the lifetime
    /// counter subtracted from "now" to the second.
    func testManufactureDateFromLifetimeRawIsNowMinusAge() throws {
        let now = date(2026, 6, 22)
        let raw = Data([0x00, 0x00, 0x01, 0x00])  // 256 seconds
        let decoded = try XCTUnwrap(BatteryReader.manufactureDate(fromLifetimeRaw: raw, now: now))
        XCTAssertEqual(decoded.timeIntervalSince(now), -256, accuracy: 0.001)
    }

    /// A zeroed counter (age 0) is not a real first-use and must yield nil rather
    /// than today's date.
    func testManufactureDateFromLifetimeRawRejectsZeroAge() {
        XCTAssertNil(
            BatteryReader.manufactureDate(
                fromLifetimeRaw: Data([0x00, 0x00, 0x00, 0x00]), now: date(2026, 6, 22)))
    }

    /// An absurd age (here ~136 years, the full uint32) lands before the Apple-
    /// silicon era and must be rejected, not surfaced as a 19th-century date.
    func testManufactureDateFromLifetimeRawRejectsAbsurdAge() {
        XCTAssertNil(
            BatteryReader.manufactureDate(
                fromLifetimeRaw: Data([0xFF, 0xFF, 0xFF, 0xFF]), now: date(2026, 6, 22)))
    }

    /// A blob shorter than four bytes can't carry the counter and must yield nil.
    func testManufactureDateFromLifetimeRawRejectsShortBlob() {
        XCTAssertNil(
            BatteryReader.manufactureDate(
                fromLifetimeRaw: Data([0x03, 0xE7]), now: date(2026, 6, 22)))
    }

    // MARK: - Electrical detail (cell voltages, adapter spec, charging, gauge chip)

    /// A full on-AC dictionary: per-cell voltages, adapter output (V/A), charging
    /// current and the gauge chip are all extracted, mirroring this Mac's real read.
    func testElectricalDetailOnAC() {
        let detail = BatteryReader.electricalDetail(from: [
            "DeviceName": "bq40z651",
            "BatteryData": ["CellVoltage": [4333, 4334, 4334]] as [String: Any],
            "AdapterDetails": ["AdapterVoltage": 20000, "Current": 4800, "Watts": 96]
                as [String: Any],
            "ChargerData": ["ChargingCurrent": 2100, "ChargingVoltage": 4384] as [String: Any],
        ])
        XCTAssertEqual(detail.cellVoltagesMilliVolts, [4333, 4334, 4334])
        XCTAssertEqual(detail.adapterVoltageMilliVolts, 20000)
        XCTAssertEqual(detail.adapterAmperageMilliAmps, 4800)
        XCTAssertEqual(detail.chargingCurrentMilliAmps, 2100)
        XCTAssertEqual(detail.gasGaugeChip, "bq40z651")
    }

    /// On battery: no adapter dictionary, so the adapter figures are nil while the
    /// cell voltages and gauge chip still read.
    func testElectricalDetailOnBattery() {
        let detail = BatteryReader.electricalDetail(from: [
            "DeviceName": "bq40z651",
            "BatteryData": ["CellVoltage": [3800, 3805]] as [String: Any],
            "ChargerData": ["ChargingCurrent": 0] as [String: Any],
        ])
        XCTAssertEqual(detail.cellVoltagesMilliVolts, [3800, 3805])
        XCTAssertNil(detail.adapterVoltageMilliVolts)
        XCTAssertNil(detail.adapterAmperageMilliAmps)
        XCTAssertEqual(detail.chargingCurrentMilliAmps, 0)  // 0 = not charging, still meaningful
        XCTAssertEqual(detail.gasGaugeChip, "bq40z651")
    }

    /// A cell-voltage array with a zero/garbage entry is dropped wholesale rather
    /// than shown with a bogus 0.00 V cell; missing keys all yield nil.
    func testElectricalDetailRejectsGarbageAndMissing() {
        let bad = BatteryReader.electricalDetail(from: [
            "BatteryData": ["CellVoltage": [4333, 0, 4334]] as [String: Any]
        ])
        XCTAssertNil(bad.cellVoltagesMilliVolts)

        let empty = BatteryReader.electricalDetail(from: ["Serial": "ABC"])
        XCTAssertNil(empty.cellVoltagesMilliVolts)
        XCTAssertNil(empty.adapterVoltageMilliVolts)
        XCTAssertNil(empty.adapterAmperageMilliAmps)
        XCTAssertNil(empty.chargingCurrentMilliAmps)
        XCTAssertNil(empty.gasGaugeChip)
    }

    // MARK: - Temperature decode

    func testBatteryTemperatureDecodesCentiCelsius() {
        // Most controllers report centi-Celsius: 3142 -> 31.42 degrees.
        XCTAssertEqual(BatteryReader.temperatureCelsius(fromCenti: 3142), 31.42, accuracy: 0.001)
    }

    func testBatteryTemperatureKeepsHotCelsiusBelowKelvinFloor() {
        // 10500 centi = 105 degrees Celsius, a genuine (if extreme) reading that
        // the old 100 threshold misread as Kelvin and converted to -168.15. It
        // stays below the 200 Kelvin floor, so it is kept as Celsius.
        XCTAssertEqual(BatteryReader.temperatureCelsius(fromCenti: 10500), 105.0, accuracy: 0.001)
    }

    func testBatteryTemperatureConvertsCentiKelvin() {
        // A centi-Kelvin controller: 30315 -> 303.15 K -> 30.0 degrees Celsius.
        XCTAssertEqual(BatteryReader.temperatureCelsius(fromCenti: 30315), 30.0, accuracy: 0.001)
        // 0 degrees Celsius reported in Kelvin (27315 centi-Kelvin) round-trips.
        XCTAssertEqual(BatteryReader.temperatureCelsius(fromCenti: 27315), 0.0, accuracy: 0.001)
    }

    // MARK: - EnergyImpact

    func testEnergyImpactCombinesCPUAndWakeups() {
        // 50% CPU + 100 wakeups/s at weight 0.1 => 50 + 10 = 60.
        let impact = EnergyImpact.estimate(
            cpuPercent: 50, idleWakeupsPerSec: 100, isTranslated: false)
        XCTAssertEqual(impact, 60, accuracy: 0.001)
    }

    func testEnergyImpactPenalisesRosetta() {
        let native = EnergyImpact.estimate(
            cpuPercent: 50, idleWakeupsPerSec: 0, isTranslated: false)
        let rosetta = EnergyImpact.estimate(
            cpuPercent: 50, idleWakeupsPerSec: 0, isTranslated: true)
        XCTAssertEqual(native, 50, accuracy: 0.001)
        XCTAssertEqual(rosetta, 60, accuracy: 0.001)  // 50 * 1.2
    }

    func testEnergyImpactClampsNegatives() {
        XCTAssertEqual(
            EnergyImpact.estimate(cpuPercent: -5, idleWakeupsPerSec: -10, isTranslated: false),
            0, accuracy: 0.001)
    }

    // MARK: - v4 persistence round-trip

    func testBatteryFieldsRoundTripThroughSystemSamples() throws {
        let now = Date()
        var system = Make.system(timestamp: now)
        system.batteryPresent = true
        system.batteryCharge = 87.5
        system.batteryPowerWatts = 12.3
        system.batteryIsCharging = true
        system.batteryHealthPercent = 92
        system.batteryCycleCount = 231
        system.batteryTemperatureCelsius = 31.4

        try store.insert(systemSample: system)

        let read = try XCTUnwrap(try store.latestSystemSample())
        XCTAssertTrue(read.batteryPresent)
        XCTAssertEqual(read.batteryCharge, 87.5, accuracy: 0.001)
        XCTAssertEqual(read.batteryPowerWatts, 12.3, accuracy: 0.001)
        XCTAssertTrue(read.batteryIsCharging)
        XCTAssertEqual(read.batteryHealthPercent, 92, accuracy: 0.001)
        XCTAssertEqual(read.batteryCycleCount, 231)
        XCTAssertEqual(read.batteryTemperatureCelsius, 31.4, accuracy: 0.001)

        // The chartable battery scalars are also exposed through system history.
        let history = try store.systemHistory(.oneHour, now: now.addingTimeInterval(1))
        let point = try XCTUnwrap(history.last)
        XCTAssertEqual(point.batteryCharge, 87.5, accuracy: 0.001)
        XCTAssertEqual(point.batteryPowerWatts, 12.3, accuracy: 0.001)
        XCTAssertEqual(point.batteryHealthPercent, 92, accuracy: 0.001)
        XCTAssertEqual(point.batteryTemperatureCelsius, 31.4, accuracy: 0.001)
    }

    func testTopConsumersRankByEnergy() throws {
        let now = Date()
        let system = Make.system(timestamp: now)

        var hungry = Make.process(timestamp: now, pid: 100, name: "Hungry")
        hungry.energyImpact = 90
        var idle = Make.process(timestamp: now, pid: 200, name: "Idle")
        idle.energyImpact = 3

        try store.insert(system, processes: [idle, hungry])

        let ranked = try store.topConsumers(
            window: .oneHour, metric: .averageEnergy, limit: 10, now: now.addingTimeInterval(1))
        XCTAssertEqual(ranked.first?.name, "Hungry")
        XCTAssertEqual(ranked.first?.averageEnergy ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(ranked.last?.name, "Idle")
    }
}
