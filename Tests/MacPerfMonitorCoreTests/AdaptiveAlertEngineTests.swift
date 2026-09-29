import XCTest

@testable import MacPerfMonitorCore

final class AdaptiveAlertEngineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let gib = 1_073_741_824.0

    func testSwapGrowthEscalatesAndStableHighUsageDoesNotAlert() {
        let engine = AlertEngine()
        let config = AlertConfig(swapEnabled: true)
        var notifications: [Alert] = []
        for offset in stride(from: 0.0, through: 1200, by: 10) {
            notifications += engine.evaluate(
                system: Make.system(
                    timestamp: start.addingTimeInterval(offset),
                    swapUsed: UInt64((3 + offset / 240) * gib)), processes: [], config: config)
        }
        XCTAssertGreaterThanOrEqual(notifications.filter { $0.kind == .swap }.count, 2)
        for offset in stride(from: 1210.0, through: 2400, by: 10) {
            _ = engine.evaluate(
                system: Make.system(
                    timestamp: start.addingTimeInterval(offset), swapUsed: UInt64(8 * gib)),
                processes: [], config: config)
        }
        XCTAssertFalse(engine.activeKinds.contains(.swap))
        let stable = AlertEngine()
        for offset in stride(from: 0.0, through: 1200, by: 10) {
            XCTAssertTrue(
                stable.evaluate(
                    system: Make.system(
                        timestamp: start.addingTimeInterval(offset), swapUsed: UInt64(30 * gib)),
                    processes: [], config: config
                ).isEmpty)
        }
    }

    func testMissingSwapReadBecomesUnknownInsteadOfRecovery() {
        let engine = AlertEngine()
        let config = AlertConfig(swapEnabled: true)
        for offset in stride(from: 0.0, through: 400, by: 10) {
            _ = engine.evaluate(
                system: Make.system(
                    timestamp: start.addingTimeInterval(offset),
                    swapUsed: UInt64((3 + offset / 200) * gib)), processes: [], config: config)
        }
        var missing = Make.system(timestamp: start.addingTimeInterval(410), swapUsed: 0)
        missing.swapSampleValid = false
        XCTAssertTrue(engine.evaluate(system: missing, processes: [], config: config).isEmpty)
        XCTAssertEqual(engine.incidentSnapshot.incidents["swap.threshold"]?.phase, .unknown)
    }

    func testStaleLeakBoardIdentityCannotTriggerANotification() {
        let engine = AlertEngine()
        let process = Make.process(timestamp: start, footprint: 1024)
        XCTAssertTrue(
            engine.evaluate(
                system: Make.system(timestamp: start), processes: [process],
                leakingProcesses: [process.id]
            ).isEmpty)
        XCTAssertTrue(engine.activeKinds.isEmpty)
    }

    func testQuietEvaluationObservesGrowthButDoesNotSilenceCriticalPressure() {
        let engine = AlertEngine()
        let config = AlertConfig(swapEnabled: true, observeGrowthOnly: true)
        for offset in stride(from: 0.0, through: 600, by: 10) {
            XCTAssertTrue(
                engine.evaluate(
                    system: Make.system(
                        timestamp: start.addingTimeInterval(offset),
                        swapUsed: UInt64((3 + offset / 200) * gib)), processes: [], config: config
                ).isEmpty)
        }
        XCTAssertTrue(engine.activeAlerts.isEmpty)
        XCTAssertTrue(engine.observations.contains { $0.condition.alert.kind == .swap })
        let critical = engine.evaluate(
            system: Make.system(timestamp: start.addingTimeInterval(601), pressure: .critical),
            processes: [], config: config)
        XCTAssertEqual(critical.map(\.kind), [.criticalPressure])
    }

    func testScanStampedJustAfterTheTickKeepsALeakActive() {
        // The scan runs after the system tick it is evaluated with, so its
        // process samples are a few milliseconds newer than `now`. That must
        // read as fresh evidence, not as unknown.
        let engine = AlertEngine()
        let config = AlertConfig(leakEnabled: true)
        func leaking(_ offset: Double) -> ProcessSample {
            Make.process(
                timestamp: start.addingTimeInterval(offset),
                footprint: UInt64(200 * 1_048_576 + offset * 400 * 1024))
        }
        for offset in stride(from: 0.0, through: 2700, by: 10) {
            _ = engine.evaluate(
                system: Make.system(timestamp: start.addingTimeInterval(offset)),
                processes: [leaking(offset)], config: config)
        }
        let id = Alert(
            kind: .leak, title: "", body: "", identity: leaking(0).id, date: start
        ).id
        XCTAssertEqual(engine.incidentSnapshot.incidents[id]?.phase, .active)
        _ = engine.evaluate(
            system: Make.system(timestamp: start.addingTimeInterval(2710)),
            processes: [leaking(2710.05)], config: config)
        XCTAssertEqual(engine.incidentSnapshot.incidents[id]?.phase, .active)
    }

    func testOlderEvaluationCannotResolveANewerIncident() {
        let engine = AlertEngine()
        _ = engine.evaluate(
            system: Make.system(timestamp: start.addingTimeInterval(10), pressure: .critical),
            processes: [])
        _ = engine.evaluate(system: Make.system(timestamp: start, pressure: .normal), processes: [])
        XCTAssertTrue(engine.activeKinds.contains(.criticalPressure))
    }

    func testCPUGapDoesNotSatisfySustainedTimeAndCriticalPressureRemainsPrompt() {
        let engine = AlertEngine()
        let config = AlertConfig(highCPUEnabled: true)
        func cpu(_ date: Date) -> CPUSample {
            CPUSample(
                timestamp: date, totalUsage: 0.95, userFraction: 0.95, systemFraction: 0,
                idleFraction: 0.05, cores: [], performanceUsage: 0.95, efficiencyUsage: 0,
                performanceCoreCount: 8, efficiencyCoreCount: 0, loadAverage1: 0, loadAverage5: 0,
                loadAverage15: 0)
        }
        _ = engine.evaluate(
            system: Make.system(timestamp: start), processes: [], config: config, cpu: cpu(start))
        let later = start.addingTimeInterval(3600)
        XCTAssertTrue(
            engine.evaluate(
                system: Make.system(timestamp: later), processes: [], config: config,
                cpu: cpu(later)
            ).isEmpty)
        let critical = engine.evaluate(
            system: Make.system(timestamp: later.addingTimeInterval(1), pressure: .critical),
            processes: [], config: config)
        XCTAssertEqual(critical.first?.kind, .criticalPressure)
        XCTAssertEqual(critical.first?.severity, .critical)
    }
}
