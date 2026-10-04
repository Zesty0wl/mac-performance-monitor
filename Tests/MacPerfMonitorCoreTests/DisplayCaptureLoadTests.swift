// SPDX-License-Identifier: MIT
import XCTest

@testable import MacPerfMonitorCore

final class DisplayCaptureLoadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func process(_ pid: Int32, name: String, cpu: Double) -> ProcessSample {
        ProcessSample(
            timestamp: now, pid: pid, ppid: 1, name: name,
            executablePath: "/test/\(name)",
            physFootprint: 1024, residentSize: 1024, virtualSize: 1024, lifetimeMaxFootprint: 1024,
            cpuPercent: cpu, cpuTimeUser: 0, cpuTimeSystem: 0, threadCount: 4,
            fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0, fdOther: 0,
            diskBytesRead: 0, diskBytesWritten: 0, energyNanojoules: 0, energyImpact: 0,
            isTranslated: false, architecture: .arm64, startTime: now.addingTimeInterval(-3600),
            uid: 501, dataSource: .directUserRead, footprintReadable: true)
    }

    private var busyProcesses: [ProcessSample] {
        [
            process(417, name: "WindowServer", cpu: 93),
            process(748, name: "replayd", cpu: 6),
            process(93408, name: "SkyComputerUseService", cpu: 16),
        ]
    }

    private func point(_ secondsAgo: Double, cpu: Double) -> ProcessHistoryPoint {
        ProcessHistoryPoint(
            date: now.addingTimeInterval(-secondsAgo), footprint: 1024, cpuPercent: cpu,
            fdTotal: 0, diskRead: 0, diskWritten: 0)
    }

    private func history(_ processes: [ProcessSample]) -> [ProcessIdentity: [ProcessHistoryPoint]] {
        Dictionary(
            uniqueKeysWithValues: processes.map { process in
                (process.id, [120, 90, 60, 30, 0].map { point($0, cpu: process.cpuPercent) })
            })
    }

    func testObservedCaptureLoadIsDetectedWithoutTotalCPUOrMemoryPressure() throws {
        let processes = busyProcesses
        let finding = try XCTUnwrap(
            DisplayCaptureLoad.analyze(
                processes: processes, histories: history(processes), now: now))
        XCTAssertEqual(finding.windowServerCPU, 93, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(finding.helperCPU), 16, accuracy: 0.01)
        XCTAssertEqual(finding.replayCPU, 6, accuracy: 0.01)
        XCTAssertEqual(finding.helper?.id, processes[2].id)

        let insights = InsightEngine.insights(
            InsightEngine.Inputs(
                now: now, totalRAM: 128 * 1024 * 1024 * 1024, currentPressure: .normal,
                systemHistory: [], leaks: [], events: [], consumers: [], consumerSeries: [:],
                rosetta: RosettaCost(processCount: 0, totalFootprint: 0), displayCapture: finding))
        let card = try XCTUnwrap(insights.first { $0.kind == .displayCapture })
        XCTAssertEqual(card.identity, processes[2].id)
        XCTAssertEqual(card.severity, .advisory)
        XCTAssertTrue(card.detail.contains("93% of one core over 2 minutes"))
        XCTAssertTrue(card.detail.contains("SkyComputerUseService was busy at the same time"))
        XCTAssertFalse(insights.contains { $0.kind == .allClear })
    }

    /// Any capture source: WindowServer and replayd busy together are enough,
    /// and the card then points at the menu bar's screen recording icon.
    func testDisplayAndReplayLoadWithoutAKnownHelperIsReported() throws {
        let processes = Array(busyProcesses.prefix(2))
        let finding = try XCTUnwrap(
            DisplayCaptureLoad.analyze(
                processes: processes, histories: history(processes), now: now))
        XCTAssertNil(finding.helper)
        XCTAssertNil(finding.helperCPU)
        XCTAssertEqual(finding.windowServerCPU, 93, accuracy: 0.01)
        let insights = InsightEngine.insights(
            InsightEngine.Inputs(
                now: now, totalRAM: 128 * 1024 * 1024 * 1024, currentPressure: .normal,
                systemHistory: [], leaks: [], events: [], consumers: [], consumerSeries: [:],
                rosetta: RosettaCost(processCount: 0, totalFootprint: 0), displayCapture: finding))
        let card = try XCTUnwrap(insights.first { $0.kind == .displayCapture })
        XCTAssertEqual(card.identity, processes[0].id)
        XCTAssertTrue(card.detail.contains("93% of one core over 2 minutes"))
        XCTAssertTrue(card.detail.contains("screen recording icon in the menu bar"))
    }

    func testIdleOrUnrecognisedHelpersAreNotNamedAndHelpersAloneDoNotTrigger() throws {
        var processes = busyProcesses
        processes[2].cpuPercent = 0
        XCTAssertEqual(DisplayCaptureLoad.candidates(from: processes, now: now).count, 2)
        XCTAssertNil(
            try XCTUnwrap(
                DisplayCaptureLoad.analyze(
                    processes: processes, histories: history(processes), now: now)
            ).helper)
        processes[2] = process(42, name: "VideoEditor", cpu: 400)
        XCTAssertNil(
            try XCTUnwrap(
                DisplayCaptureLoad.analyze(
                    processes: processes, histories: history(processes), now: now)
            ).helper)
        XCTAssertTrue(DisplayCaptureLoad.candidates(from: [busyProcesses[2]], now: now).isEmpty)
    }

    func testMissingReplayOrDisplayCoverageDoesNotImplyCaptureLoad() {
        let processes = busyProcesses
        XCTAssertNil(
            DisplayCaptureLoad.analyze(
                processes: [processes[0], processes[2]], histories: history(processes), now: now))
        var trails = history(processes)
        trails.removeValue(forKey: processes[0].id)
        XCTAssertNil(DisplayCaptureLoad.analyze(processes: processes, histories: trails, now: now))
    }

    func testBriefSpikeAndInsufficientHistoryStayQuiet() {
        let processes = busyProcesses
        let trails = Dictionary(
            uniqueKeysWithValues: processes.map { process in
                (
                    process.id,
                    [point(120, cpu: 0), point(60, cpu: 0), point(10, cpu: process.cpuPercent)]
                )
            })
        XCTAssertNil(DisplayCaptureLoad.analyze(processes: processes, histories: trails, now: now))
        let recentOnly = Dictionary(
            uniqueKeysWithValues: processes.map { process in
                (
                    process.id,
                    [point(30, cpu: process.cpuPercent), point(15, cpu: process.cpuPercent)]
                )
            })
        XCTAssertNil(
            DisplayCaptureLoad.analyze(processes: processes, histories: recentOnly, now: now))
    }

    func testHighIndependentAveragesMustOverlapInTime() {
        let processes = busyProcesses
        let trails = [
            processes[0].id: [point(120, cpu: 200), point(60, cpu: 0)],
            processes[1].id: [point(120, cpu: 6), point(60, cpu: 6)],
            processes[2].id: [point(120, cpu: 0), point(60, cpu: 20)],
        ]
        XCTAssertNil(DisplayCaptureLoad.analyze(processes: processes, histories: trails, now: now))
    }

    func testLongSamplingGapAndStaleLiveSnapshotStayUnknown() {
        let processes = busyProcesses
        let trails = Dictionary(
            uniqueKeysWithValues: processes.map { process in
                (
                    process.id,
                    [point(120, cpu: process.cpuPercent), point(110, cpu: process.cpuPercent)]
                )
            })
        XCTAssertNil(DisplayCaptureLoad.analyze(processes: processes, histories: trails, now: now))
        let stale = processes.map { process in
            var stale = process
            stale.timestamp = now.addingTimeInterval(-91)
            return stale
        }
        XCTAssertTrue(DisplayCaptureLoad.candidates(from: stale, now: now).isEmpty)
    }

    func testMinuteCadenceAndUnpersistedLiveReadingAreSupported() throws {
        let processes = busyProcesses
        let trails = Dictionary(
            uniqueKeysWithValues: processes.map { process in
                (
                    process.id,
                    [point(120, cpu: process.cpuPercent), point(60, cpu: process.cpuPercent)]
                )
            })
        XCTAssertNotNil(
            DisplayCaptureLoad.analyze(processes: processes, histories: trails, now: now))
    }

    func testEndingCaptureOrRecoveringDisplayLoadClearsFindingImmediately() {
        let processes = busyProcesses
        let trails = history(processes)
        XCTAssertNil(
            DisplayCaptureLoad.analyze(
                processes: [processes[0], processes[2]], histories: trails, now: now))
        var recovered = processes
        recovered[0].cpuPercent = 20
        recovered[1].cpuPercent = 0
        XCTAssertNil(DisplayCaptureLoad.analyze(processes: recovered, histories: trails, now: now))
    }

    func testReusedPIDDoesNotBorrowPreviousHistory() throws {
        let processes = busyProcesses
        var restarted = processes
        restarted[2].startTime = now.addingTimeInterval(-10)
        XCTAssertNil(
            try XCTUnwrap(
                DisplayCaptureLoad.analyze(
                    processes: restarted, histories: history(processes), now: now)
            ).helper)
        restarted = processes
        restarted[0].startTime = now.addingTimeInterval(-10)
        XCTAssertNil(
            DisplayCaptureLoad.analyze(
                processes: restarted, histories: history(processes), now: now))
    }

    func testDuplicateOrInvalidReadingsDoNotSupplySustainedEvidence() throws {
        let processes = busyProcesses
        var trails = history(processes)
        trails[processes[2].id] = Array(repeating: point(120, cpu: 16), count: 100)
        XCTAssertNil(
            try XCTUnwrap(
                DisplayCaptureLoad.analyze(processes: processes, histories: trails, now: now)
            ).helper)
        trails = history(processes)
        trails[processes[2].id]?[2].cpuPercent = .nan
        XCTAssertNil(
            try XCTUnwrap(
                DisplayCaptureLoad.analyze(processes: processes, histories: trails, now: now)
            ).helper)
        trails = history(processes)
        trails[processes[0].id]?[2].cpuPercent = .nan
        XCTAssertNil(DisplayCaptureLoad.analyze(processes: processes, histories: trails, now: now))
        var future = processes
        future[2].timestamp = now.addingTimeInterval(1)
        XCTAssertEqual(
            DisplayCaptureLoad.candidates(from: future, now: now).map(\.id),
            [processes[0].id, processes[1].id])
        future = processes
        future[0].timestamp = now.addingTimeInterval(1)
        XCTAssertTrue(DisplayCaptureLoad.candidates(from: future, now: now).isEmpty)
    }

    func testTruncatedKernelNameResolvesFromExecutableAndReadsAreBounded() {
        var processes = busyProcesses
        processes[2].name = "SkyComputerUse"
        XCTAssertEqual(
            DisplayCaptureLoad.analyze(
                processes: processes, histories: history(processes), now: now)?.helper?.id,
            processes[2].id)
        processes += (1...20).map { process(Int32($0), name: "SkyComputerUseService", cpu: 10) }
        XCTAssertEqual(DisplayCaptureLoad.candidates(from: processes, now: now).count, 5)
    }
}
