import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class ThermalEventsTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    private let startTime = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-tevents-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private func insertTick(_ timestamp: Date, state: ThermalPressureState?) throws {
        let burner = Make.process(
            timestamp: timestamp, pid: 1000, startTime: startTime, name: "Burner", cpu: 312)
        let idle = Make.process(
            timestamp: timestamp, pid: 2000, startTime: startTime, name: "Idle", cpu: 2)
        var system = Make.system(timestamp: timestamp, pressurePercent: 10)
        system.thermalPressure = state
        try store.insert(
            Sampler.Snapshot(system: system, processes: [burner, idle], unreadableProcessCount: 0))
    }

    /// Events are recorded on each upward step into a throttling state,
    /// attributed to the top CPU process, most recent first.
    func testThermalEventsRecordThrottleStepsWithTopCPUProcess() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insertTick(base, state: .nominal)
        try insertTick(base.addingTimeInterval(2), state: .fair)  // not throttling: no event
        try insertTick(base.addingTimeInterval(4), state: .serious)  // event
        try insertTick(base.addingTimeInterval(6), state: .serious)  // no step
        try insertTick(base.addingTimeInterval(8), state: .critical)  // event

        let events = try store.thermalEvents(now: base.addingTimeInterval(8))

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].date, base.addingTimeInterval(8))
        XCTAssertEqual(events[0].state, .critical)
        XCTAssertEqual(events[0].dominantName, "Burner")
        XCTAssertEqual(events[0].dominantCPUPercent, 312, accuracy: 0.001)
        XCTAssertEqual(events[1].state, .serious)
    }

    /// A recovery followed by a new climb is a fresh event; ticks with no
    /// recorded state (older builds) neither step nor reset the tracker.
    func testRecoveryRearmsAndNilStatesAreSkipped() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insertTick(base, state: .serious)  // first sample: no previous, no event
        try insertTick(base.addingTimeInterval(2), state: .nominal)
        try insertTick(base.addingTimeInterval(4), state: nil)
        try insertTick(base.addingTimeInterval(6), state: .serious)  // event

        let events = try store.thermalEvents(now: base.addingTimeInterval(6))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].date, base.addingTimeInterval(6))
    }

    func testNoEventsWhenNeverThrottling() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insertTick(base, state: .nominal)
        try insertTick(base.addingTimeInterval(2), state: .fair)
        try insertTick(base.addingTimeInterval(4), state: .nominal)
        XCTAssertTrue(try store.thermalEvents(now: base.addingTimeInterval(4)).isEmpty)
    }
}

// MARK: - Sustained thermal alert

final class ThermalAlertTests: XCTestCase {
    private func system(_ state: ThermalPressureState?, at date: Date) -> SystemSample {
        var sample = Make.system(timestamp: date, pressurePercent: 10)
        sample.thermalPressure = state
        return sample
    }

    private func burner(at date: Date) -> ProcessSample {
        Make.process(timestamp: date, pid: 42, name: "Burner", cpu: 250)
    }

    func testThermalAlertFiresOnlyAfterSustainedThrottlingThenRearms() {
        let engine = AlertEngine(refireCooldown: 0)
        let config = AlertConfig(thermalEnabled: true)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Serious, but not yet sustained: no alert, though the kind is not
        // active either (armed until fired).
        var fired = engine.evaluate(
            system: system(.serious, at: base), processes: [burner(at: base)], config: config,
            now: base)
        XCTAssertTrue(fired.isEmpty)

        // Still serious 30 s later: fires once, naming the top CPU process.
        let sustained = base.addingTimeInterval(30)
        fired = engine.evaluate(
            system: system(.serious, at: sustained), processes: [burner(at: sustained)],
            config: config, now: sustained)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .thermalThrottle)
        XCTAssertEqual(fired[0].id, "thermal.throttle")
        XCTAssertTrue(fired[0].body.contains("Burner"))
        XCTAssertNotNil(fired[0].identity)
        XCTAssertTrue(engine.activeKinds.contains(.thermalThrottle))

        // Continuing to throttle does not re-fire.
        let later = sustained.addingTimeInterval(10)
        fired = engine.evaluate(
            system: system(.critical, at: later), processes: [burner(at: later)], config: config,
            now: later)
        XCTAssertTrue(fired.isEmpty)

        // Recovery clears the active kind and re-arms; a new sustained spell
        // fires again.
        let recovered = later.addingTimeInterval(10)
        _ = engine.evaluate(
            system: system(.nominal, at: recovered), processes: [], config: config, now: recovered)
        XCTAssertFalse(engine.activeKinds.contains(.thermalThrottle))
        let again = recovered.addingTimeInterval(10)
        _ = engine.evaluate(
            system: system(.serious, at: again), processes: [], config: config, now: again)
        let againSustained = again.addingTimeInterval(30)
        fired = engine.evaluate(
            system: system(.serious, at: againSustained), processes: [], config: config,
            now: againSustained)
        XCTAssertEqual(fired.count, 1)
    }

    /// A brief excursion into serious never alerts, and fair never counts as
    /// throttling at all.
    func testBriefOrFairThrottlingStaysQuiet() {
        let engine = AlertEngine(refireCooldown: 0)
        let config = AlertConfig(thermalEnabled: true)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        _ = engine.evaluate(
            system: system(.serious, at: base), processes: [], config: config, now: base)
        // Back to nominal before the sustain window elapses.
        let recovered = base.addingTimeInterval(10)
        var fired = engine.evaluate(
            system: system(.nominal, at: recovered), processes: [], config: config, now: recovered)
        XCTAssertTrue(fired.isEmpty)

        // Fair for minutes: still quiet.
        var t = recovered
        for _ in 0..<10 {
            t = t.addingTimeInterval(30)
            fired = engine.evaluate(
                system: system(.fair, at: t), processes: [], config: config, now: t)
            XCTAssertTrue(fired.isEmpty)
        }
        XCTAssertFalse(engine.activeKinds.contains(.thermalThrottle))
    }

    func testThermalAlertDisabledByDefault() {
        let engine = AlertEngine(refireCooldown: 0)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = engine.evaluate(system: system(.critical, at: base), processes: [], now: base)
        let sustained = base.addingTimeInterval(60)
        let fired = engine.evaluate(
            system: system(.critical, at: sustained), processes: [], now: sustained)
        XCTAssertTrue(fired.isEmpty)
        XCTAssertFalse(engine.activeKinds.contains(.thermalThrottle))
    }
}
