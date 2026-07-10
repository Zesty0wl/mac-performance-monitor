import XCTest

@testable import MacPerfMonitorCore

final class AlertEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let gb: UInt64 = 1024 * 1024 * 1024

    private func system(pressure: PressureLevel = .normal, swapUsed: UInt64 = 0) -> SystemSample {
        Make.system(timestamp: now, swapUsed: swapUsed, pressure: pressure)
    }

    // MARK: - Critical pressure

    func testCriticalPressureFiresOnceThenRearmsAfterRecovery() {
        let engine = AlertEngine()
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

    // MARK: - Swap

    func testSwapThresholdFiresWithHysteresis() {
        let engine = AlertEngine()
        let config = AlertConfig(swapEnabled: true, swapThresholdBytes: 3 * gb)

        XCTAssertTrue(
            engine.evaluate(system: system(swapUsed: 1 * gb), processes: [], config: config).isEmpty
        )

        let fired = engine.evaluate(system: system(swapUsed: 4 * gb), processes: [], config: config)
        XCTAssertEqual(fired.map(\.kind), [.swap])

        // Still over threshold: no repeat.
        XCTAssertTrue(
            engine.evaluate(system: system(swapUsed: 4 * gb), processes: [], config: config).isEmpty
        )
        // Dropping to just above the 80% re-arm line (2.4 GB) does not re-arm.
        XCTAssertTrue(
            engine.evaluate(system: system(swapUsed: 2_600_000_000), processes: [], config: config)
                .isEmpty)
        // Dropping clearly below re-arms; crossing again fires.
        _ = engine.evaluate(system: system(swapUsed: 1 * gb), processes: [], config: config)
        XCTAssertEqual(
            engine.evaluate(system: system(swapUsed: 4 * gb), processes: [], config: config).map(
                \.kind), [.swap])
    }

    // MARK: - Process ceiling

    func testProcessCeilingFiresPerProcessAndRearms() {
        let engine = AlertEngine()
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

    func testLeakAlertFiresOncePerLeakAndRearms() {
        let engine = AlertEngine()
        let config = AlertConfig(leakEnabled: true)
        let a = Make.process(timestamp: now, pid: 100, name: "Leaky", footprint: 1 * gb)
        let b = Make.process(timestamp: now, pid: 200, name: "AlsoLeaky", footprint: 1 * gb)

        let idA = a.id
        let idB = b.id

        let first = engine.evaluate(
            system: system(), processes: [a, b], leakingProcesses: [idA], config: config)
        XCTAssertEqual(first.map(\.kind), [.leak])
        XCTAssertEqual(first.first?.identity, idA)

        // Same leak set: no repeat. New leaker B joins: fires for B.
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [a, b], leakingProcesses: [idA], config: config
            ).isEmpty)
        let second = engine.evaluate(
            system: system(), processes: [a, b], leakingProcesses: [idA, idB], config: config)
        XCTAssertEqual(second.map(\.identity), [idB])

        // A stops leaking then recurs: alerts again.
        _ = engine.evaluate(
            system: system(), processes: [a, b], leakingProcesses: [idB], config: config)
        let third = engine.evaluate(
            system: system(), processes: [a, b], leakingProcesses: [idA, idB], config: config)
        XCTAssertEqual(third.map(\.identity), [idA])
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
        XCTAssertEqual(kinds, [.criticalPressure, .swap, .processCeiling, .leak])
        XCTAssertEqual(fired.first(where: { $0.kind == .processCeiling })?.identity?.pid, 100)
        XCTAssertEqual(fired.first(where: { $0.kind == .leak })?.identity?.pid, 200)
    }

    func testStableIdentifiersForDedup() {
        let pressure = Alert(kind: .criticalPressure, title: "", body: "", date: now)
        XCTAssertEqual(pressure.id, "pressure.critical")
        let id = ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 1_000_000))
        let leak = Alert(kind: .leak, title: "", body: "", identity: id, date: now)
        XCTAssertEqual(leak.id, "leak.42.1000000")
    }

    // MARK: - Sustained high CPU

    private func cpu(_ fraction: Double) -> CPUSample {
        CPUSample(
            timestamp: now, totalUsage: fraction, userFraction: fraction, systemFraction: 0,
            idleFraction: 1 - fraction, cores: [], performanceUsage: fraction, efficiencyUsage: 0,
            performanceCoreCount: 8, efficiencyCoreCount: 0,
            loadAverage1: 0, loadAverage5: 0, loadAverage15: 0)
    }

    func testHighCPUFiresOnlyAfterSustainedDurationThenRearms() {
        let engine = AlertEngine()
        let config = AlertConfig(highCPUEnabled: true, highCPUThresholdPercent: 85)
        let t0 = now

        // Below the 8 s sustained window: silent, regardless of how many ticks.
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [], config: config, cpu: cpu(0.95), now: t0
            ).isEmpty)
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [], config: config, cpu: cpu(0.95),
                now: t0.addingTimeInterval(4)
            ).isEmpty)
        let fired = engine.evaluate(
            system: system(), processes: [], config: config, cpu: cpu(0.95),
            now: t0.addingTimeInterval(8))
        XCTAssertEqual(fired.map(\.kind), [.highCPU])

        // Sustained high must not re-fire.
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [], config: config, cpu: cpu(0.95),
                now: t0.addingTimeInterval(12)
            ).isEmpty)

        // Fall below the re-arm fraction (85% × 0.8 = 68%), then a fresh sustained
        // spell fires again only after another full window.
        _ = engine.evaluate(
            system: system(), processes: [], config: config, cpu: cpu(0.1),
            now: t0.addingTimeInterval(13))
        XCTAssertTrue(
            engine.evaluate(
                system: system(), processes: [], config: config, cpu: cpu(0.95),
                now: t0.addingTimeInterval(14)
            ).isEmpty)
        let second = engine.evaluate(
            system: system(), processes: [], config: config, cpu: cpu(0.95),
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
                system: system(), processes: [], config: config, cpu: cpu(0.95), now: base)
            XCTAssertTrue(
                engine.evaluate(
                    system: system(), processes: [], config: config, cpu: cpu(0.2),
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
            config: config, cpu: cpu(0.95), now: now.addingTimeInterval(8))
        XCTAssertEqual(engine.activeKinds, [.criticalPressure, .swap, .highCPU])

        _ = engine.evaluate(
            system: system(pressure: .warning, swapUsed: 2_600_000_000), processes: [],
            config: config, cpu: cpu(0.8), now: now.addingTimeInterval(9))
        XCTAssertEqual(engine.activeKinds, [.criticalPressure, .swap, .highCPU])

        _ = engine.evaluate(
            system: system(pressure: .normal, swapUsed: 1 * gb), processes: [],
            config: config, cpu: cpu(0.1), now: now.addingTimeInterval(10))
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
