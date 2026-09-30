import XCTest

@testable import MacPerfMonitorCore

/// A program busy for hours (contactsd at 1.6 cores all night, 2026-09-30)
/// must be flagged by the alert and by Ask, across the restarts that make each
/// run look short, without flagging ordinary bursts of work.
final class SustainedCPUTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func series(_ values: [Double], step: TimeInterval = 60) -> [(Date, Double)] {
        values.enumerated().map { (start.addingTimeInterval(Double($0.offset) * step), $0.element) }
    }

    func testSpellNeedsAnHourOfHeavyMostlyBusyWork() {
        let hourAndAHalf = SustainedSpell.current(in: series(Array(repeating: 160, count: 90)))
        XCTAssertEqual(hourAndAHalf?.isSustained, true)
        XCTAssertEqual(hourAndAHalf?.average ?? 0, 160, accuracy: 0.1)

        XCTAssertEqual(
            SustainedSpell.current(in: series(Array(repeating: 300, count: 40)))?.isSustained,
            false,
            "a 40 minute build is not a stuck program")
        XCTAssertEqual(
            SustainedSpell.current(in: series(Array(repeating: 50, count: 180)))?.isSustained,
            false,
            "half a core for hours is too light to flag")
    }

    func testShortDipsKeepTheSpellAndQuietEndsIt() {
        let dips = (0..<120).map { $0 % 20 < 17 ? 150.0 : 0 }
        XCTAssertEqual(SustainedSpell.current(in: series(dips))?.isSustained, true)

        let rested =
            Array(repeating: 150.0, count: 90) + Array(repeating: 0, count: 15)
            + Array(repeating: 150, count: 30)
        let spell = SustainedSpell.current(in: series(rested))
        XCTAssertEqual(spell?.isSustained, false, "15 quiet minutes start a new spell")
        XCTAssertEqual(spell?.duration ?? 0, 29 * 60, accuracy: 1)
    }

    func testALauncherPathIsNotAProgram() {
        XCTAssertEqual(
            SustainedCPU.key(name: "Task Manager", executablePath: "/usr/libexec/xpcproxy"),
            "Task Manager")
        XCTAssertEqual(AskProcessKind.classify(path: "/usr/libexec/xpcproxy").kind, .background)
        XCTAssertEqual(
            SustainedCPU.key(name: "contactsd", executablePath: "/System/x/contactsd"),
            "/System/x/contactsd")
    }

    // MARK: Alert

    private func daemon(
        _ time: Date, run: Int, cpu: Double, name: String = "contactsd"
    )
        -> ProcessSample
    {
        var process = Make.process(
            timestamp: time, pid: Int32(500 + run),
            startTime: start.addingTimeInterval(Double(run) * 1200), name: name, cpu: cpu)
        process.executablePath = "/System/Library/Frameworks/Contacts.framework/Support/\(name)"
        return process
    }

    private func system(_ time: Date) -> SystemSample { Make.system(timestamp: time) }

    func testAlertFollowsADaemonAcrossRestartsAndClearsWhenItSettles() throws {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        var fired: [Alert] = []
        // Restarted every 20 minutes, like a stuck daemon launchd keeps relaunching.
        for step in 0...(80 * 6) {
            let time = start.addingTimeInterval(Double(step) * 10)
            fired += engine.evaluate(
                system: system(time), processes: [daemon(time, run: step / 120, cpu: 160)],
                now: time)
        }
        let alert = try XCTUnwrap(engine.activeAlerts.first { $0.kind == .sustainedProcessCPU })
        XCTAssertEqual(alert.severity, .warning)
        XCTAssertEqual(
            alert.id, "cpu.process./System/Library/Frameworks/Contacts.framework/Support/contactsd")
        XCTAssertTrue(alert.title.contains("contactsd"), alert.title)
        XCTAssertTrue(alert.body.contains("1.6"), alert.body)
        XCTAssertTrue(alert.body.contains("Internet Accounts"), alert.body)
        XCTAssertTrue(fired.contains { $0.kind == .sustainedProcessCPU })
        XCTAssertEqual(AlertIncidentTracker.family(.sustainedProcessCPU), "cpu")

        for step in (80 * 6 + 1)...(110 * 6) {
            let time = start.addingTimeInterval(Double(step) * 10)
            _ = engine.evaluate(
                system: system(time), processes: [daemon(time, run: 99, cpu: 1)], now: time)
        }
        XCTAssertFalse(engine.activeAlerts.contains { $0.kind == .sustainedProcessCPU })
    }

    func testAppsAndKnownJobsAreObservationsFirst() throws {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        for step in 0...(70 * 6) {
            let time = start.addingTimeInterval(Double(step) * 10)
            let app = Make.process(timestamp: time, pid: 900, name: "Renderer", cpu: 120)
            _ = engine.evaluate(
                system: system(time),
                processes: [app, daemon(time, run: 0, cpu: 200, name: "mds_stores")], now: time)
        }
        let incidents = engine.observations.filter {
            $0.condition.alert.kind == .sustainedProcessCPU
        }
        XCTAssertEqual(
            incidents.count, 2, "an app for an hour, and Spotlight indexing, are observations")
        XCTAssertFalse(engine.activeAlerts.contains { $0.kind == .sustainedProcessCPU })
    }

    func testOffWhenDisabledAndOnByDefaultForOldSettings() throws {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        let off = AlertConfig(sustainedProcessCPUEnabled: false)
        for step in 0...(70 * 6) {
            let time = start.addingTimeInterval(Double(step) * 10)
            _ = engine.evaluate(
                system: system(time), processes: [daemon(time, run: 0, cpu: 200)], config: off,
                now: time)
        }
        XCTAssertTrue(engine.activeAlerts.isEmpty)
        let saved = try JSONDecoder().decode(AlertConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(saved.sustainedProcessCPUEnabled)
    }

    // MARK: Ask

    func testAskFindsItInHistoryAndSaysWhatToDo() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sustained-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let store = try SampleStore(url: url)
        let now = Date()
        let first = now.addingTimeInterval(-2 * 3600)
        for step in stride(from: 0.0, through: 2 * 3600, by: 30) {
            let time = first.addingTimeInterval(step)
            var busy = daemon(time, run: Int(step / 1500), cpu: 150)
            busy.startTime = first.addingTimeInterval(Double(Int(step / 1500)) * 1500 + 0.25)
            let light = Make.process(timestamp: time, pid: 77, name: "Light", cpu: 30)
            var sample = Make.system(timestamp: time)
            sample.cpuLoad = 0.3
            try store.insert(sample, processes: [busy, light])
        }
        try Retention.run(store.databasePool, now: now)

        let found = try store.askSustained(end: now)
        XCTAssertEqual(found.map(\.name), ["contactsd"])
        XCTAssertGreaterThan(found.first?.duration ?? 0, 100 * 60)
        XCTAssertEqual(found.first?.average ?? 0, 150, accuracy: 10)

        var input = try store.askInputs(
            area: .processor, start: now.addingTimeInterval(-3600), end: now, now: now)
        input.coreCount = 10
        let brief = AskBriefBuilder.brief(input)
        XCTAssertEqual(brief.status, .unusual)
        XCTAssertTrue(brief.headline.contains("contactsd"), brief.headline)
        XCTAssertEqual(brief.apps.first?.name, "contactsd")
        XCTAssertTrue(brief.notable.contains { $0.contains("1.5 cores") }, "\(brief.notable)")
        XCTAssertTrue(brief.advice.contains { $0.contains("Activity Monitor") }, "\(brief.advice)")
        XCTAssertFalse(brief.advice.contains { $0.contains("settles down on its own") })
        XCTAssertEqual(brief.chart?.processes.first, found.first?.identity)
    }
}
