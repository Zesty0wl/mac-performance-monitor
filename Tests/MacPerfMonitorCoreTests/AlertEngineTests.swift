import XCTest

@testable import MacPerfMonitorCore

final class AlertEngineTests: XCTestCase {
    func testAccessoryAlertPreferencesDefaultOffAndSurviveRoundTrip() throws {
        let legacy = try JSONDecoder().decode(
            AlertConfig.self,
            from: Data(#"{"criticalPressureEnabled":false,"leakEnabled":false}"#.utf8))
        XCTAssertFalse(legacy.accessoryBatteryEnabled)
        XCTAssertEqual(legacy.accessoryBatteryThresholdPercent, 20)
        XCTAssertFalse(legacy.criticalPressureEnabled)
        XCTAssertFalse(legacy.leakEnabled)

        var configured = legacy
        configured.accessoryBatteryEnabled = true
        configured.accessoryBatteryThresholdPercent = 15
        let restored = try JSONDecoder().decode(
            AlertConfig.self, from: JSONEncoder().encode(configured))
        XCTAssertEqual(restored, configured)
        XCTAssertFalse(restored.anyEnabled)
    }

    func testAccessoryAlertThresholdIsBoundedWhenLoadingSettings() throws {
        for (saved, expected) in [(-100, 5), (500, 50), (20, 20)] {
            let data = try JSONSerialization.data(
                withJSONObject: ["accessoryBatteryThresholdPercent": saved])
            let config = try JSONDecoder().decode(AlertConfig.self, from: data)
            XCTAssertEqual(config.accessoryBatteryThresholdPercent, expected)
        }
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let gb: UInt64 = 1024 * 1024 * 1024

    private func system(pressure: PressureLevel = .normal, swapUsed: UInt64 = 0) -> SystemSample {
        Make.system(timestamp: now, swapUsed: swapUsed, pressure: pressure)
    }

    func testActiveAlertDetailsPersistAndClearPerProcess() {
        let engine = AlertEngine()
        let config = AlertConfig(processCeilingEnabled: true, processCeilingBytes: gb)
        let first = Make.process(timestamp: now, pid: 100, name: "Alpha", footprint: 2 * gb)
        let second = Make.process(timestamp: now, pid: 200, name: "Beta", footprint: 2 * gb)
        let fired = engine.evaluate(
            system: system(), processes: [first, second], config: config, now: now)
        XCTAssertEqual(Set(engine.activeAlerts.map(\.id)), Set(fired.map(\.id)))
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [first, second], config: config,
                now: now.addingTimeInterval(2)
            ).isEmpty)
        XCTAssertEqual(Set(engine.activeAlerts.compactMap(\.identity)), [first.id, second.id])
        _ = engine.evaluate(
            system: system(), processes: [second], config: config, now: now.addingTimeInterval(4))
        XCTAssertEqual(engine.activeAlerts.map(\.identity), [second.id])
        XCTAssertTrue(engine.activeAlerts[0].body.contains("Beta"))
        XCTAssertEqual(engine.activeAlerts[0].processName, "Beta")
        _ = engine.evaluate(
            system: system(), processes: [], config: config, now: now.addingTimeInterval(6))
        XCTAssertTrue(engine.activeAlerts.isEmpty)
        XCTAssertTrue(engine.activeKinds.isEmpty)
    }

    func testSuppressedRepeatStillHasActiveAlertDetails() {
        let engine = AlertEngine(refireCooldown: 300)
        _ = engine.evaluate(system: system(pressure: .critical), processes: [], now: now)
        _ = engine.evaluate(system: system(), processes: [], now: now.addingTimeInterval(1))
        XCTAssertTrue(engine.activeAlerts.isEmpty)
        XCTAssertTrue(
            engine.evaluate(
                system: system(pressure: .critical), processes: [],
                now: now.addingTimeInterval(2)
            ).isEmpty)
        XCTAssertEqual(engine.activeAlerts.map(\.kind), [.criticalPressure])
        XCTAssertEqual(engine.activeAlerts.first?.date, now.addingTimeInterval(2))
        engine.reset()
        XCTAssertTrue(engine.activeAlerts.isEmpty)
    }

    func testActiveLeakDetailsClearWhenDisabledOrRecovered() {
        let engine = AlertEngine()
        var process = Make.process(
            timestamp: now, pid: 100, startTime: now, name: "Growing", footprint: gb)
        for offset in stride(from: 0.0, through: 400, by: 10) {
            process.timestamp = now.addingTimeInterval(offset)
            process.physFootprint = gb + UInt64(offset) * 20 * 1024 * 1024
            _ = engine.evaluate(
                system: Make.system(timestamp: process.timestamp), processes: [process])
        }
        XCTAssertEqual(engine.activeAlerts.map(\.kind), [.leak])
        XCTAssertEqual(engine.activeAlerts.first?.processName, "Growing")
        for offset in stride(from: 410.0, through: 900, by: 10) {
            process.timestamp = now.addingTimeInterval(offset)
            _ = engine.evaluate(
                system: Make.system(timestamp: process.timestamp), processes: [process])
        }
        XCTAssertTrue(engine.activeAlerts.isEmpty)
        XCTAssertEqual(
            engine.incidentSnapshot.incidents.values.first(where: {
                $0.condition.alert.kind == .leak
            })?.phase, .resolved)
        _ = engine.evaluate(
            system: Make.system(timestamp: process.timestamp), processes: [process],
            config: AlertConfig(leakEnabled: false))
        XCTAssertTrue(engine.activeAlerts.isEmpty)
    }

    // MARK: - Critical pressure

    func testCriticalPressureFiresOnceThenRearmsAfterRecovery() {
        // A cooldown of 0 disables the per-id throttle so the re-arm path can
        // re-fire on the next crossing, which is what this test exercises.
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        let config = AlertConfig(criticalPressureEnabled: true)

        XCTAssertTrue(
            engine.evaluate(system: system(pressure: .normal), processes: [], config: config)
                .isEmpty)

        let first = engine.evaluate(
            system: system(pressure: .critical), processes: [], config: config)
        XCTAssertEqual(first.map(\.kind), [.criticalPressure])

        // Sustained critical must not re-fire every tick.
        XCTAssertTrue(
            engine.evaluate(system: system(pressure: .critical), processes: [], config: config)
                .isEmpty)

        // Drop to normal re-arms; next critical fires again.
        _ = engine.evaluate(system: system(pressure: .normal), processes: [], config: config)
        let second = engine.evaluate(
            system: system(pressure: .critical), processes: [], config: config)
        XCTAssertEqual(second.map(\.kind), [.criticalPressure])
    }

    func testCriticalPressureStaysQuietWhileFlappingToWarning() {
        let engine = AlertEngine()
        let config = AlertConfig(criticalPressureEnabled: true)

        XCTAssertEqual(
            engine.evaluate(system: system(pressure: .critical), processes: [], config: config)
                .count, 1)
        // Falling only to warning does NOT re-arm, so bouncing back to critical
        // stays silent.
        _ = engine.evaluate(system: system(pressure: .warning), processes: [], config: config)
        XCTAssertTrue(
            engine.evaluate(system: system(pressure: .critical), processes: [], config: config)
                .isEmpty)
    }

    func testCriticalPressureSuppressedWhenDisabled() {
        let engine = AlertEngine()
        let config = AlertConfig(criticalPressureEnabled: false)
        XCTAssertTrue(
            engine.evaluate(system: system(pressure: .critical), processes: [], config: config)
                .isEmpty)
    }

    // MARK: - Refire cooldown

    func testSustainedFlapRefiresAtMostOncePerCooldown() {
        let engine = AlertEngine(refireCooldown: 300)
        let config = AlertConfig(criticalPressureEnabled: true)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Step 1: the first critical tick of a sustained crisis fires exactly
        // once and is delivered.
        let first = engine.evaluate(
            system: Make.system(timestamp: t0, pressure: .critical),
            processes: [], config: config, now: t0)
        XCTAssertEqual(first.map(\.kind), [.criticalPressure])

        // Step 2: the crisis keeps flapping (normal to critical) several times
        // WITHIN the cooldown window. Each recovery re-arms the edge trigger,
        // so without the throttle every critical tick here would deliver a
        // fresh alert. All of them are suppressed, and none may advance the
        // cooldown window: recording a delivery time for a suppressed tick
        // would slide the window forward and starve the re-fire step 3 expects.
        for offset in [10.0, 60.0, 180.0, 290.0] {
            _ = engine.evaluate(
                system: Make.system(
                    timestamp: t0.addingTimeInterval(offset - 2), pressure: .normal),
                processes: [], config: config, now: t0.addingTimeInterval(offset - 2))
            let suppressed = engine.evaluate(
                system: Make.system(timestamp: t0.addingTimeInterval(offset), pressure: .critical),
                processes: [], config: config, now: t0.addingTimeInterval(offset))
            XCTAssertEqual(suppressed, [])
        }

        // Step 3: once the cooldown measured from the FIRST delivery (t0) has
        // elapsed, the next flap re-fires exactly once. The last suppressed
        // tick was at t0 + 290, only 13 s before this retry, so a slide-forward
        // bug (recording suppressed ticks) would still suppress it and starve
        // the crisis. The survivor-only implementation fires here.
        _ = engine.evaluate(
            system: Make.system(timestamp: t0.addingTimeInterval(301), pressure: .normal),
            processes: [], config: config, now: t0.addingTimeInterval(301))
        let afterCooldown = engine.evaluate(
            system: Make.system(timestamp: t0.addingTimeInterval(303), pressure: .critical),
            processes: [], config: config, now: t0.addingTimeInterval(303))
        XCTAssertEqual(afterCooldown.map(\.kind), [.criticalPressure])
    }

    // MARK: - Swap

    func testLegacySwapCeilingDoesNotAlertForStableOccupancy() {
        let engine = AlertEngine()
        let config = AlertConfig(swapEnabled: true, swapThresholdBytes: 3 * gb)
        for offset in stride(from: 0.0, through: 1200, by: 10) {
            XCTAssertTrue(
                engine.evaluate(
                    system: Make.system(
                        timestamp: now.addingTimeInterval(offset), swapUsed: 4 * gb),
                    processes: [], config: config
                ).isEmpty)
        }
        XCTAssertTrue(engine.activeKinds.isEmpty)
    }

    // MARK: - Process ceiling

    func testProcessCeilingFiresPerProcessAndRearms() {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        let config = AlertConfig(processCeilingEnabled: true, processCeilingBytes: 1 * gb)

        let a = Make.process(timestamp: now, pid: 100, name: "Alpha", footprint: 2 * gb)
        let aSmall = Make.process(
            timestamp: now, pid: 100, name: "Alpha", footprint: 200 * 1024 * 1024)
        let b = Make.process(timestamp: now, pid: 200, name: "Beta", footprint: 1500 * 1024 * 1024)
        let bUnder = Make.process(
            timestamp: now, pid: 200, name: "Beta", footprint: 100 * 1024 * 1024)

        let first = engine.evaluate(system: system(), processes: [a, bUnder], config: config)
        XCTAssertEqual(first.map(\.kind), [.processCeiling])
        XCTAssertEqual(first.first?.identity?.pid, 100)

        // Alpha still over: no repeat. Beta now crosses: fires for Beta only.
        let second = engine.evaluate(system: system(), processes: [a, b], config: config)
        XCTAssertEqual(second.map(\.identity?.pid), [200])

        // Alpha drops well below: re-arms; climbing back fires again.
        _ = engine.evaluate(system: system(), processes: [aSmall, b], config: config)
        let third = engine.evaluate(system: system(), processes: [a, b], config: config)
        XCTAssertEqual(third.map(\.identity?.pid), [100])
    }

    func testProcessCeilingIgnoresUnreadableFootprints() {
        let engine = AlertEngine()
        let config = AlertConfig(processCeilingEnabled: true, processCeilingBytes: 1 * gb)
        let hidden = Make.process(
            timestamp: now, pid: 100, name: "Hidden", footprint: 5 * gb, readable: false)
        XCTAssertTrue(
            engine.evaluate(system: system(), processes: [hidden], config: config).isEmpty)
    }

    // MARK: - Leaks

    func testLeakBoardFlagsAloneDoNotProveOngoingGrowth() {
        let engine = AlertEngine()
        let config = AlertConfig(leakEnabled: true)
        let a = Make.process(timestamp: now, pid: 100, name: "Leaky", footprint: 1 * gb)
        let b = Make.process(timestamp: now, pid: 200, name: "AlsoLeaky", footprint: 1 * gb)

        let idA = a.id
        let idB = b.id

        let first = engine.evaluate(
            system: system(), processes: [a, b], leakingProcesses: [idA], config: config)
        XCTAssertTrue(first.isEmpty)

        // Same leak set: no repeat. New leaker B joins: fires for B.
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [a, b], leakingProcesses: [idA], config: config
            ).isEmpty)
        let second = engine.evaluate(
            system: system(), processes: [a, b], leakingProcesses: [idA, idB], config: config)
        XCTAssertTrue(second.isEmpty)

        // A stops leaking then recurs: alerts again.
        _ = engine.evaluate(
            system: system(), processes: [a, b], leakingProcesses: [idB], config: config)
        let third = engine.evaluate(
            system: system(), processes: [a, b], leakingProcesses: [idA, idB], config: config)
        XCTAssertTrue(third.isEmpty)
    }

    // MARK: - Combined / forced-pressure scenario (M7 acceptance)

    func testForcedPressureFiresCriticalAndThresholdAlertsTogether() {
        let engine = AlertEngine()
        let config = AlertConfig(
            criticalPressureEnabled: true,
            swapEnabled: true,
            swapThresholdBytes: 3 * gb,
            processCeilingEnabled: true,
            processCeilingBytes: 4 * gb,
            leakEnabled: true)

        let hog = Make.process(timestamp: now, pid: 100, name: "Hog", footprint: 6 * gb)
        let leaker = Make.process(timestamp: now, pid: 200, name: "Leaker", footprint: 1 * gb)

        let fired = engine.evaluate(
            system: system(pressure: .critical, swapUsed: 5 * gb),
            processes: [hog, leaker],
            leakingProcesses: [leaker.id],
            config: config)

        let kinds = Set(fired.map(\.kind))
        XCTAssertEqual(kinds, [.criticalPressure, .processCeiling])
        XCTAssertEqual(fired.first(where: { $0.kind == .processCeiling })?.identity?.pid, 100)
        XCTAssertFalse(fired.contains { $0.kind == .leak || $0.kind == .swap })
    }

    func testStableIdentifiersForDedup() {
        let pressure = Alert(kind: .criticalPressure, title: "", body: "", date: now)
        XCTAssertEqual(pressure.id, "pressure.critical")
        let id = ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 1_000_000))
        let leak = Alert(kind: .leak, title: "", body: "", identity: id, date: now)
        XCTAssertEqual(
            leak.id, Alert(kind: .leak, title: "updated", body: "", identity: id, date: now).id)
        let reused = ProcessIdentity(pid: 42, startTime: id.startTime.addingTimeInterval(0.001))
        XCTAssertNotEqual(
            leak.id, Alert(kind: .leak, title: "", body: "", identity: reused, date: now).id)
    }

    // MARK: - Sustained high CPU

    private func cpu(_ fraction: Double, offset: Double = 0) -> CPUSample {
        CPUSample(
            timestamp: now.addingTimeInterval(offset), totalUsage: fraction, userFraction: fraction,
            systemFraction: 0,
            idleFraction: 1 - fraction, cores: [], performanceUsage: fraction, efficiencyUsage: 0,
            performanceCoreCount: 8, efficiencyCoreCount: 0,
            loadAverage1: 0, loadAverage5: 0, loadAverage15: 0)
    }

    func testHighCPUFiresOnlyAfterSustainedDurationThenRearms() {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        let config = AlertConfig(highCPUEnabled: true, highCPUThresholdPercent: 85)
        let t0 = now

        // Below the 8 s sustained window: silent, regardless of how many ticks.
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [], config: config, cpu: cpu(0.95), now: t0
            ).isEmpty)
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [], config: config, cpu: cpu(0.95, offset: 4),
                now: t0.addingTimeInterval(4)
            ).isEmpty)
        let fired = engine.evaluate(
            system: system(), processes: [], config: config, cpu: cpu(0.95, offset: 8),
            now: t0.addingTimeInterval(8))
        XCTAssertEqual(fired.map(\.kind), [.highCPU])

        // Sustained high must not re-fire.
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [], config: config, cpu: cpu(0.95, offset: 12),
                now: t0.addingTimeInterval(12)
            ).isEmpty)

        // Fall below the re-arm fraction (85% × 0.8 = 68%), then a fresh sustained
        // spell fires again only after another full window.
        _ = engine.evaluate(
            system: system(), processes: [], config: config, cpu: cpu(0.1, offset: 13),
            now: t0.addingTimeInterval(13))
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [], config: config, cpu: cpu(0.95, offset: 14),
                now: t0.addingTimeInterval(14)
            ).isEmpty)
        _ = engine.evaluate(
            system: system(), processes: [], config: config, cpu: cpu(0.95, offset: 18),
            now: t0.addingTimeInterval(18))
        let second = engine.evaluate(
            system: system(), processes: [], config: config, cpu: cpu(0.95, offset: 22),
            now: t0.addingTimeInterval(22))
        XCTAssertEqual(second.map(\.kind), [.highCPU])
    }

    func testHighCPUBriefSpikesNeverFire() {
        let engine = AlertEngine()
        let config = AlertConfig(highCPUEnabled: true, highCPUThresholdPercent: 85)
        // High for only 2 s at a time, well short of the 8 s window, never fires.
        for i in 0..<10 {
            let base = now.addingTimeInterval(Double(i) * 10)
            _ = engine.evaluate(
                system: system(), processes: [], config: config,
                cpu: cpu(0.95, offset: Double(i) * 10), now: base)
            XCTAssertTrue(
                engine.evaluate(
                    system: system(), processes: [], config: config,
                    cpu: cpu(0.2, offset: Double(i) * 10 + 2),
                    now: base.addingTimeInterval(2)
                ).isEmpty)
        }
    }

    func testHighCPUSuppressedWhenDisabled() {
        let engine = AlertEngine()
        let config = AlertConfig(highCPUEnabled: false)
        for _ in 0..<10 {
            XCTAssertTrue(
                engine.evaluate(system: system(), processes: [], config: config, cpu: cpu(0.99))
                    .isEmpty)
        }
    }

    func testActiveKindsRemainUntilConditionsRecover() {
        let engine = AlertEngine()
        let config = AlertConfig(
            criticalPressureEnabled: true,
            swapEnabled: true,
            swapThresholdBytes: 3 * gb,
            highCPUEnabled: true,
            highCPUThresholdPercent: 85)

        _ = engine.evaluate(
            system: system(pressure: .critical, swapUsed: 4 * gb), processes: [],
            config: config, cpu: cpu(0.95), now: now)
        _ = engine.evaluate(
            system: system(pressure: .critical, swapUsed: 4 * gb), processes: [],
            config: config, cpu: cpu(0.95, offset: 4), now: now.addingTimeInterval(4))
        _ = engine.evaluate(
            system: system(pressure: .critical, swapUsed: 4 * gb), processes: [],
            config: config, cpu: cpu(0.95, offset: 8), now: now.addingTimeInterval(8))
        XCTAssertEqual(engine.activeKinds, [.criticalPressure, .highCPU])

        _ = engine.evaluate(
            system: system(pressure: .warning, swapUsed: 2_600_000_000), processes: [],
            config: config, cpu: cpu(0.8, offset: 9), now: now.addingTimeInterval(9))
        XCTAssertEqual(engine.activeKinds, [.criticalPressure, .highCPU])

        _ = engine.evaluate(
            system: system(pressure: .normal, swapUsed: 1 * gb), processes: [],
            config: config, cpu: cpu(0.1, offset: 10), now: now.addingTimeInterval(10))
        XCTAssertTrue(engine.activeKinds.isEmpty)
    }

    func testAlertConfigSurvivesLegacyDecode() throws {
        // A config persisted before the high-CPU keys existed must still decode,
        // keeping its old choices and defaulting the new fields.
        let legacy = """
            {"criticalPressureEnabled":false,"swapEnabled":true,"swapThresholdBytes":1073741824,
             "processCeilingEnabled":false,"processCeilingBytes":8589934592,"leakEnabled":false}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AlertConfig.self, from: legacy)
        XCTAssertFalse(decoded.criticalPressureEnabled)
        XCTAssertTrue(decoded.swapEnabled)
        XCTAssertFalse(decoded.leakEnabled)
        XCTAssertFalse(decoded.highCPUEnabled)  // defaulted
        XCTAssertEqual(decoded.highCPUThresholdPercent, 85)  // defaulted
    }
}
