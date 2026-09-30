import XCTest

@testable import MacPerfMonitorCore

/// Area briefs are Ask's knowledge: every status, comparison and phrase the
/// model explains comes from here, so each rule is pinned without a model.
final class AskBriefTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func points(
        minutes: Int = 60, every seconds: Double = 60, end: Date? = nil,
        _ configure: (inout SystemHistoryPoint, Int) -> Void
    ) -> [SystemHistoryPoint] {
        let end = end ?? now
        let count = Int(Double(minutes) * 60 / seconds)
        return (0..<count).map { index in
            var point = SystemHistoryPoint(
                sample: Make.system(
                    timestamp: end.addingTimeInterval(-Double(count - index) * seconds)))
            point.bucketDuration = seconds
            configure(&point, index)
            return point
        }
    }

    /// A week of hourly points before the period, for "normal for this Mac".
    private func baseline(_ configure: (inout SystemHistoryPoint) -> Void) -> [SystemHistoryPoint] {
        points(minutes: 7 * 24 * 60, every: 3600, end: now.addingTimeInterval(-3600)) { point, _ in
            configure(&point)
        }
    }

    private func input(_ area: AskArea, minutes: Double = 60) -> AskBriefInputs {
        AskBriefInputs(area: area, start: now.addingTimeInterval(-minutes * 60), end: now, now: now)
    }

    private let app = ProcessIdentity(
        pid: 42, startTime: Date(timeIntervalSince1970: 1_700_000_000))

    func testBusyProcessorComparesWithThisMacAndNamesTheApp() {
        var input = input(.processor)
        input.points = points { point, _ in point.cpuLoad = 0.9 }
        input.baseline = baseline { $0.cpuLoad = 0.2 }
        input.coreCount = 10
        input.apps = [AskAppUsage(identity: app, name: "Xcode", average: 380)]
        let brief = AskBriefBuilder.brief(input)

        XCTAssertEqual(brief.status, .attention)
        XCTAssertTrue(brief.headline.contains("90%"), brief.headline)
        XCTAssertTrue(brief.headline.contains("far more than usual"), brief.headline)
        XCTAssertEqual(brief.normal, "about 20% busy on average")
        XCTAssertEqual(brief.apps.first?.name, "Xcode")
        XCTAssertEqual(brief.apps.first?.usage, "about 38% of the processor on average")
        XCTAssertEqual(brief.chart?.laneIDs, ["cpu", "process.cpu"])
        XCTAssertEqual(brief.chart?.processes, [app])
        XCTAssertTrue(brief.promptText.contains("\"Xcode\""))
    }

    func testAlwaysBusyMacIsBusyNotWorthALook() {
        var input = input(.processor)
        input.points = points { point, _ in point.cpuLoad = 0.5 }
        input.baseline = baseline { $0.cpuLoad = 0.45 }
        XCTAssertEqual(AskBriefBuilder.brief(input).status, .busy)
    }

    func testMemoryGrowthIsNotableEvenWithLowPressure() {
        var input = input(.memory)
        input.points = points { point, _ in point.pressurePercent = 12 }
        input.growth = [
            AskGrowth(
                identity: app, name: "Task Manager", growthBytes: 466_000_000,
                durationSeconds: 44 * 60)
        ]
        let brief = AskBriefBuilder.brief(input)
        XCTAssertEqual(brief.status, .calm, "445 MB of growth is noted but not alarming")
        XCTAssertTrue(brief.notable.first?.contains("Task Manager") ?? false)
        XCTAssertTrue(
            brief.notable.first?.contains("44 minutes") ?? false, brief.notable.description)
        XCTAssertEqual(brief.chart?.processes.first, app)

        input.growth[0].growthBytes = 900_000_000
        XCTAssertEqual(AskBriefBuilder.brief(input).status, .unusual)
    }

    func testHighPressureAndGrowingSwapNeedAttention() {
        var input = input(.memory)
        input.points = points { point, index in
            point.pressurePercent = 72
            point.swapUsed = UInt64(index) * 50_000_000
        }
        let brief = AskBriefBuilder.brief(input)
        XCTAssertEqual(brief.status, .attention)
        XCTAssertTrue(brief.notable.contains { $0.contains("Swap grew") })
    }

    func testNearlyFullDiskNeedsAttention() {
        var input = input(.storage)
        var live = AskLiveReading(date: now)
        live.bootFreeBytes = 8_000_000_000
        live.bootTotalBytes = 500_000_000_000
        input.live = live
        let brief = AskBriefBuilder.brief(input)
        XCTAssertEqual(brief.status, .attention)
        XCTAssertTrue(brief.headline.hasPrefix("Only"), brief.headline)
    }

    func testFastBatteryDrainIsWorthALookAndEstimatesTimeLeft() {
        var input = input(.energy)
        input.points = points { point, index in point.batteryCharge = 80 - Double(index) / 3 }
        let brief = AskBriefBuilder.brief(input)
        XCTAssertEqual(brief.status, .unusual)
        XCTAssertTrue(brief.facts.contains { $0.contains("an hour") })
        XCTAssertTrue(brief.facts.contains { $0.contains("would last") })
    }

    func testDesktopEnergySaysThereIsNoBattery() {
        var input = input(.energy)
        input.hasBattery = false
        input.apps = [AskAppUsage(identity: app, name: "Safari", average: 30)]
        let brief = AskBriefBuilder.brief(input)
        XCTAssertEqual(brief.chart?.laneIDs, ["process.energyImpact"])
        XCTAssertTrue(brief.gaps.contains { $0.contains("no battery") })
        XCTAssertEqual(brief.apps.first?.usage, "about 100% of the energy used by apps")
    }

    func testSeriousThermalPressureNeedsAttention() {
        var input = input(.heat)
        input.points = points { point, index in
            point.thermalPressure = index > 50 ? .serious : .nominal
        }
        XCTAssertEqual(AskBriefBuilder.brief(input).status, .attention)
    }

    func testNeuralEngineUsesActivityNotPowerAndAdmitsItsLimits() {
        var input = input(.neuralEngine)
        input.points = points { point, _ in
            point.aneTimeMillisecondsPerSecond = 400
            point.anePowerWatts = 0
            point.aneSampleIsPartial = true
        }
        let brief = AskBriefBuilder.brief(input)
        XCTAssertEqual(brief.status, .busy)
        XCTAssertTrue(brief.headline.contains("40%"), brief.headline)
        XCTAssertFalse(
            brief.facts.contains { $0.contains(" W ") }, "zero power is not reported as use")
        XCTAssertTrue(brief.gaps.contains { $0.contains("which app") })
        XCTAssertTrue(brief.gaps.contains { $0.contains("part of the time") })
    }

    func testNetworkWithoutPerAppTrackingSaysSo() {
        var input = input(.network)
        input.points = points { point, _ in point.networkInBytesPerSec = 2_000_000 }
        input.networkTracking = false
        let brief = AskBriefBuilder.brief(input)
        XCTAssertEqual(brief.status, .busy)
        XCTAssertTrue(brief.apps.isEmpty)
        XCTAssertTrue(brief.gaps.contains { $0.contains("turned off") })
    }

    func testNoReadingsIsUnknownNotCalm() {
        var input = input(.processor)
        input.recording = false
        let brief = AskBriefBuilder.brief(input)
        XCTAssertEqual(brief.status, .unknown)
        XCTAssertTrue(brief.gaps.contains { $0.contains("recording is off") })
    }

    func testNamedAppIsDescribedOrReportedMissing() {
        var input = input(.processor)
        input.points = points { point, _ in point.cpuLoad = 0.3 }
        input.coreCount = 10
        input.focusName = "Chrome"
        input.focus = [AskAppUsage(identity: app, name: "Google Chrome", average: 120)]
        let found = AskBriefBuilder.brief(input)
        XCTAssertTrue(
            found.facts.contains("\"Google Chrome\" used about 12% of the processor on average."))
        XCTAssertEqual(found.chart?.processes.first, app)

        input.focus = []
        XCTAssertTrue(
            AskBriefBuilder.brief(input).gaps.contains(
                "No app called \"Chrome\" was recorded in this time."))
    }

    func testOverallNamesTheWorstPartsOrSaysAllIsWell() {
        let calm = AreaBrief(
            area: .processor, start: now, end: now, status: .calm, headline: "Calm.")
        XCTAssertEqual(
            AskBriefBuilder.overall([calm], start: now, end: now).headline,
            "Your Mac is running smoothly.")

        let memory = AreaBrief(
            area: .memory, start: now, end: now, status: .unusual, headline: "Moderate.")
        let overall = AskBriefBuilder.overall([calm, memory], start: now, end: now)
        XCTAssertEqual(overall.status, .unusual)
        XCTAssertEqual(overall.headline, "Worth a look: Memory.")
    }

    func testAdviceIsSafeAndOnlyWhenNeeded() {
        var calm = input(.processor)
        calm.points = points { point, _ in point.cpuLoad = 0.1 }
        XCTAssertEqual(
            AskBriefBuilder.brief(calm).advice, ["Nothing is needed: this part of the Mac is fine."]
        )

        var disk = input(.storage)
        var live = AskLiveReading(date: now)
        live.bootFreeBytes = 8_000_000_000
        live.bootTotalBytes = 500_000_000_000
        disk.live = live
        let storage = AskBriefBuilder.brief(disk)
        XCTAssertTrue(storage.advice.first?.contains("Trash") ?? false)
        XCTAssertTrue(storage.promptText.contains("Things that help:"))

        var memory = input(.memory)
        memory.points = points { point, _ in point.pressurePercent = 12 }
        memory.growth = [
            AskGrowth(
                identity: app, name: "Task Manager", growthBytes: 466_000_000, durationSeconds: 2640
            )
        ]
        XCTAssertEqual(
            AskBriefBuilder.brief(memory).advice.first,
            "Quitting and reopening \"Task Manager\" usually gives its memory back.")
        XCTAssertTrue(
            AskBriefBuilder.brief(memory).promptText.contains("normal amounts, not a problem")
                == false,
            "no app list, so no label")
    }

    func testOnlyAppsAreEverToldToQuit() {
        XCTAssertEqual(
            AskProcessKind.classify(path: "/System/Library/Frameworks/Contacts.framework/contactsd")
                .kind, .system)
        XCTAssertEqual(AskProcessKind.classify(path: "/usr/libexec/trustd").kind, .system)
        let helper = AskProcessKind.classify(
            path:
                "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        )
        XCTAssertEqual(helper.kind, .app)
        XCTAssertEqual(helper.app, "Google Chrome")
        XCTAssertEqual(AskProcessKind.classify(path: "/opt/homebrew/bin/node").kind, .background)

        var busy = input(.processor)
        busy.points = points { point, _ in point.cpuLoad = 0.7 }
        busy.coreCount = 10
        busy.apps = [AskAppUsage(identity: app, name: "contactsd", average: 300, kind: .system)]
        let system = AskBriefBuilder.brief(busy)
        XCTAssertTrue(
            system.advice.first?.contains("part of macOS") ?? false, system.advice.description)
        XCTAssertFalse(system.advice.contains { $0.hasPrefix("Quit") })
        XCTAssertTrue(system.promptText.contains("\"contactsd\" (part of macOS)"))

        busy.apps = [
            AskAppUsage(
                identity: app, name: "Google Chrome Helper (Renderer)", average: 300, kind: .app,
                owner: "Google Chrome")
        ]
        XCTAssertTrue(
            AskBriefBuilder.brief(busy).advice.first?.hasPrefix("Quit \"Google Chrome\"") ?? false)
    }

    func testModeratePressureIsBusyNotWorthALook() {
        var memory = input(.memory)
        memory.points = points { point, _ in point.pressurePercent = 40 }
        XCTAssertEqual(AskBriefBuilder.brief(memory).status, .busy)
        memory.points = points { point, _ in point.pressurePercent = 55 }
        XCTAssertEqual(AskBriefBuilder.brief(memory).status, .unusual)
    }

    func testSmallSharesAreNeverBlamed() {
        var busy = input(.processor)
        busy.points = points { point, _ in point.cpuLoad = 0.8 }
        busy.coreCount = 11
        busy.apps = [
            AskAppUsage(
                identity: app, name: "wdavdaemon_enterprise", average: 22, kind: .app,
                owner: "Microsoft Defender")
        ]
        let brief = AskBriefBuilder.brief(busy)
        XCTAssertEqual(brief.apps.first?.major, false)
        XCTAssertFalse(
            brief.advice.contains { $0.contains("Microsoft Defender") }, brief.advice.description)
        XCTAssertTrue(brief.notable.contains { $0.hasPrefix("No single app stands out") })
        XCTAssertTrue(brief.promptText.contains("a small share, not the cause"))

        let attention = AreaBrief(
            area: .memory, start: now, end: now, status: .attention, headline: "High.")
        XCTAssertEqual(
            AskBriefBuilder.overall([attention], start: now, end: now).headline,
            "Needs attention: Memory.")
        let network = AreaBrief(
            area: .network, start: now, end: now, status: .unusual, headline: "Busy.")
        XCTAssertEqual(
            AskBriefBuilder.overall([attention, network], start: now, end: now).headline,
            "Needs attention: Memory. Worth a look: Network.")
    }

    // MARK: Plans

    func testTimeSpecsResolveToThePastAndClipToRecording() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!

        let afternoon = AskTimeSpec.around(hour: 15, minute: 0, daysAgo: 0)
            .interval(now: morning, calendar: calendar)
        XCTAssertEqual(
            calendar.component(.day, from: afternoon.start), 29, "3pm asked at 10am is yesterday")
        XCTAssertEqual(afternoon.duration, 3600)

        let recent = AskTimeSpec.recent(minutes: 1).interval(now: morning, calendar: calendar)
        XCTAssertEqual(recent.duration, 300, "never shorter than five minutes")

        let today = AskTimeSpec.day(daysAgo: 0).interval(now: morning, calendar: calendar)
        XCTAssertEqual(today.end, morning)
        XCTAssertEqual(calendar.component(.hour, from: today.start), 0)

        let clipped = AskTimeSpec.day(daysAgo: 0).interval(
            now: morning, calendar: calendar, earliest: morning.addingTimeInterval(-3600))
        XCTAssertEqual(clipped.duration, 3600)
    }

    func testPlansKeepThreeDistinctPartsAndFallBackToOverall() {
        let plan = AskPlan(
            areas: [.memory, .memory, .overall, .processor, .storage, .heat], appName: "  Chrome "
        ).resolved()
        XCTAssertEqual(plan.areas, [.memory, .processor, .storage])
        XCTAssertEqual(plan.appName, "Chrome")
        XCTAssertEqual(AskPlan(areas: [], appName: " ").resolved(), AskPlan(areas: [.overall]))
    }
}

/// The ranking reads the real schema, so it runs against a temporary store.
final class AskStoreTests: XCTestCase {
    private var url: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-store-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: url)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    func testAppBusyAllHourOutranksAShortBurstAndNamesMatch() throws {
        let end = Date().addingTimeInterval(-60)
        let start = end.addingTimeInterval(-3600)
        for step in stride(from: 0.0, through: 3600, by: 30) {
            let time = start.addingTimeInterval(step)
            var steady = Make.process(timestamp: time, pid: 100, name: "Steady", cpu: 50)
            steady.startTime = start.addingTimeInterval(-10)
            var processes = [steady]
            if step >= 1800, step < 1920 {
                var burst = Make.process(timestamp: time, pid: 200, name: "Burst", cpu: 100)
                burst.startTime = start.addingTimeInterval(1790)
                processes.append(burst)
            }
            try store.insert(Make.system(timestamp: time), processes: processes)
        }
        let apps = try store.askTopApps(
            area: .processor, start: start, end: end, tier: .raw, limit: 5)
        XCTAssertEqual(apps.map(\.name), ["Steady", "Burst"])
        XCTAssertEqual(apps[0].average, 50, accuracy: 2)
        XCTAssertLessThan(apps[1].average, 10)

        let named = try store.askTopApps(
            area: .processor, start: start, end: end, tier: .raw, limit: 2, nameFilter: "burs")
        XCTAssertEqual(named.map(\.name), ["Burst"])
        let wildcard = try store.askTopApps(
            area: .processor, start: start, end: end, tier: .raw, limit: 2, nameFilter: "%")
        XCTAssertTrue(wildcard.isEmpty, "a % in a question is text, not a pattern")

        let inputs = try store.askInputs(
            area: .processor, start: start, end: end, now: end, appName: "Steady")
        XCTAssertFalse(inputs.points.isEmpty)
        XCTAssertEqual(inputs.focus.first?.name, "Steady")
        XCTAssertNotNil(try store.askEarliestRecord())
    }
}
