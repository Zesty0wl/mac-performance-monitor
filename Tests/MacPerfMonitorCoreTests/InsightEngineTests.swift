import XCTest

@testable import MacPerfMonitorCore

final class InsightEngineTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let gigabyte: UInt64 = 1024 * 1024 * 1024

    private func identity(pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 1_000_000))
    }

    private func consumer(pid: Int32, name: String) -> ProcessConsumer {
        ProcessConsumer(
            identity: identity(pid: pid),
            name: name,
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            bundleID: "com.test.\(name)",
            architecture: .arm64,
            isTranslated: false,
            averageFootprint: gigabyte,
            peakFootprint: 2 * gigabyte,
            averageCPU: 5,
            sampleCount: 100
        )
    }

    private func leakEntry(
        pid: Int32, name: String, confidence: Double, growth: UInt64
    )
        -> LeakBoardEntry
    {
        LeakBoardEntry(
            identity: identity(pid: pid),
            name: name,
            isTranslated: false,
            latestFootprint: 2 * gigabyte,
            finding: LeakDetector.Finding(
                slopeBytesPerSecond: 100 * 1024,
                rSquared: 0.95,
                durationSeconds: 1800,
                totalGrowth: growth,
                confidence: confidence
            )
        )
    }

    private func historyPoint(
        at date: Date, pressure: Double, swap: UInt64 = 0
    )
        -> SystemHistoryPoint
    {
        SystemHistoryPoint(
            date: date, pressurePercent: pressure,
            appMemory: 4 * gigabyte, wired: 2 * gigabyte, compressed: 0,
            cachedFiles: gigabyte, swapUsed: swap)
    }

    private func inputs(
        currentPressure: PressureLevel = .normal,
        systemHistory: [SystemHistoryPoint] = [],
        leaks: [LeakBoardEntry] = [],
        events: [PressureEvent] = [],
        consumers: [ProcessConsumer] = [],
        consumerSeries: [ProcessIdentity: [(Date, UInt64)]] = [:],
        rosetta: RosettaCost = RosettaCost(processCount: 0, totalFootprint: 0)
    ) -> InsightEngine.Inputs {
        InsightEngine.Inputs(
            now: start.addingTimeInterval(7200),
            totalRAM: 16 * gigabyte,
            currentPressure: currentPressure,
            systemHistory: systemHistory,
            leaks: leaks,
            events: events,
            consumers: consumers,
            consumerSeries: consumerSeries,
            rosetta: rosetta
        )
    }

    func testEmptyInputsProduceSingleAllClear() {
        let insights = InsightEngine.insights(inputs())
        XCTAssertEqual(insights.count, 1)
        XCTAssertEqual(insights[0].kind, .allClear)
        XCTAssertEqual(insights[0].severity, .allClear)
    }

    func testModestGrowthProducesAnAdvisoryWithProcessIdentity() {
        let insights = InsightEngine.insights(
            inputs(leaks: [leakEntry(pid: 42, name: "Leaky", confidence: 0.7, growth: 200_000_000)])
        )
        XCTAssertEqual(insights.count, 1)
        XCTAssertEqual(insights[0].kind, .leak)
        XCTAssertEqual(insights[0].severity, .advisory)
        XCTAssertEqual(insights[0].identity, identity(pid: 42))
        XCTAssertTrue(insights[0].headline.contains("Leaky"))
    }

    func testLargeGrowthDoesNotBecomeCriticalOnFitScoreAlone() {
        let insights = InsightEngine.insights(
            inputs(leaks: [leakEntry(pid: 42, name: "Leaky", confidence: 0.9, growth: gigabyte)])
        )
        XCTAssertEqual(insights[0].severity, .warning)
    }

    func testPressureEventSeverityTracksCurrentLevel() {
        let event = PressureEvent(
            date: start, level: .warning,
            dominantIdentity: identity(pid: 7), dominantName: "Big", dominantFootprint: gigabyte)

        let passed = InsightEngine.insights(inputs(currentPressure: .normal, events: [event]))
        XCTAssertEqual(passed[0].kind, .pressure)
        XCTAssertEqual(passed[0].severity, .advisory)
        XCTAssertTrue(passed[0].detail.contains("back to normal"))

        let ongoing = InsightEngine.insights(inputs(currentPressure: .critical, events: [event]))
        XCTAssertEqual(ongoing[0].severity, .critical)
    }

    func testAttributionNamesTopGrowerBeforeSpike() {
        let event = PressureEvent(
            date: start.addingTimeInterval(900), level: .warning,
            dominantIdentity: nil, dominantName: nil, dominantFootprint: 0)
        let grower = consumer(pid: 9, name: "Hungry")
        // +500 MB across the 15 minutes before the event.
        let series = Make.risingSeries(
            start: start, count: 10, spacing: 100,
            base: gigabyte, stepBytes: 55 * 1024 * 1024)

        let insights = InsightEngine.insights(
            inputs(
                events: [event],
                consumers: [grower],
                consumerSeries: [grower.identity: series]
            ))
        let attribution = insights.first { $0.kind == .attribution }
        XCTAssertNotNil(attribution)
        XCTAssertEqual(attribution?.identity, grower.identity)
        XCTAssertTrue(attribution?.headline.contains("Hungry") ?? false)
    }

    func testStepChangeProducesAdvisoryAndSkipsLeakingProcesses() {
        let jumper = consumer(pid: 11, name: "Jumper")
        var series: [(Date, UInt64)] = []
        for i in 0..<6 { series.append((start.addingTimeInterval(Double(i) * 2), gigabyte)) }
        for i in 6..<12 {
            series.append((start.addingTimeInterval(Double(i) * 2), gigabyte + 500 * 1024 * 1024))
        }

        let flagged = InsightEngine.insights(
            inputs(consumers: [jumper], consumerSeries: [jumper.identity: series]))
        XCTAssertEqual(flagged.first?.kind, .stepChange)
        XCTAssertEqual(flagged.first?.severity, .advisory)

        // The same series is ignored when the process is already on the leak board.
        let suppressed = InsightEngine.insights(
            inputs(
                leaks: [leakEntry(pid: 11, name: "Jumper", confidence: 0.7, growth: 200_000_000)],
                consumers: [jumper],
                consumerSeries: [jumper.identity: series]
            ))
        XCTAssertFalse(suppressed.contains { $0.kind == .stepChange })
    }

    func testSwapGrowthAboveFivePercentOfRAMIsFlagged() {
        let history = [
            historyPoint(at: start, pressure: 10, swap: 0),
            historyPoint(at: start.addingTimeInterval(7200), pressure: 20, swap: gigabyte),
        ]
        let insights = InsightEngine.insights(inputs(systemHistory: history))
        XCTAssertEqual(insights.first?.kind, .swap)
        XCTAssertEqual(insights.first?.severity, .advisory)

        let calm = [
            historyPoint(at: start, pressure: 10, swap: 0),
            historyPoint(at: start.addingTimeInterval(7200), pressure: 20, swap: 100 * 1024 * 1024),
        ]
        XCTAssertEqual(InsightEngine.insights(inputs(systemHistory: calm)).first?.kind, .allClear)
    }

    func testRosettaCostBelowFloorIsIgnored() {
        let small = RosettaCost(processCount: 2, totalFootprint: 100 * 1024 * 1024)
        XCTAssertEqual(InsightEngine.insights(inputs(rosetta: small)).first?.kind, .allClear)

        let big = RosettaCost(processCount: 4, totalFootprint: 2 * gigabyte)
        let insights = InsightEngine.insights(inputs(rosetta: big))
        XCTAssertEqual(insights.first?.kind, .rosetta)
        XCTAssertEqual(insights.first?.severity, .advisory)  // ≥ 5% of 16 GB RAM
    }

    func testRankingPutsHighestSeverityFirst() {
        let history = [
            historyPoint(at: start, pressure: 10, swap: 0),
            historyPoint(at: start.addingTimeInterval(7200), pressure: 20, swap: gigabyte),
        ]
        let insights = InsightEngine.insights(
            inputs(
                systemHistory: history,
                leaks: [leakEntry(pid: 42, name: "Leaky", confidence: 0.9, growth: gigabyte)],
                rosetta: RosettaCost(processCount: 1, totalFootprint: gigabyte)
            ))
        XCTAssertEqual(insights.map(\.kind), [.leak, .swap, .rosetta])
        XCTAssertEqual(
            insights.map(\.severity), insights.map(\.severity).sorted(by: >),
            "insights must be ordered most urgent first")
    }

    // MARK: - CPU

    /// Build Inputs with CPU fields populated; the shared `inputs` helper omits
    /// them. `now` is `start + 7200`, so recent points land near the window end.
    private func cpuInputs(
        systemHistory: [SystemHistoryPoint] = [],
        cpuConsumers: [ProcessConsumer] = []
    ) -> InsightEngine.Inputs {
        InsightEngine.Inputs(
            now: start.addingTimeInterval(7200),
            totalRAM: 16 * gigabyte,
            currentPressure: .normal,
            systemHistory: systemHistory,
            leaks: [], events: [], consumers: [], consumerSeries: [:],
            rosetta: RosettaCost(processCount: 0, totalFootprint: 0),
            cpuConsumers: cpuConsumers
        )
    }

    private func cpuPoint(at date: Date, load: Double) -> SystemHistoryPoint {
        SystemHistoryPoint(
            date: date, pressurePercent: 10, appMemory: gigabyte, wired: gigabyte,
            compressed: 0, cachedFiles: gigabyte, swapUsed: 0, cpuLoad: load)
    }

    func testSustainedHighCPUProducesInsight() {
        let now = start.addingTimeInterval(7200)
        // Ten minutes of ~88% total CPU, every 60s, ending at `now`.
        let history = (0..<10).map {
            cpuPoint(at: now.addingTimeInterval(Double(-($0)) * 60), load: 0.88)
        }
        let insights = InsightEngine.insights(cpuInputs(systemHistory: history))
        let cpu = insights.first { $0.kind == .cpu }
        XCTAssertNotNil(cpu, "sustained high total CPU should produce a CPU insight")
        XCTAssertEqual(cpu?.severity, .advisory)  // average 0.88 < 0.9
    }

    func testBriefCPUSpikeDoesNotProduceSustainedInsight() {
        let now = start.addingTimeInterval(7200)
        // Mostly idle with a single spike — the windowed average stays low.
        var history = (0..<10).map {
            cpuPoint(at: now.addingTimeInterval(Double(-($0)) * 60), load: 0.05)
        }
        history[0] = cpuPoint(at: now, load: 0.99)
        let insights = InsightEngine.insights(cpuInputs(systemHistory: history))
        XCTAssertNil(insights.first { $0.kind == .cpu })
    }

    func testHeavyCPUProcessProducesInsightNamingIt() {
        var heavy = consumer(pid: 99, name: "Encoder")
        heavy.averageCPU = 260  // sustained ~2.6 cores
        let insights = InsightEngine.insights(cpuInputs(cpuConsumers: [heavy]))
        let cpu = insights.first { $0.kind == .cpu }
        XCTAssertEqual(cpu?.identity, identity(pid: 99))
        XCTAssertEqual(cpu?.processName, "Encoder")
    }

    func testModerateCPUProcessProducesNoInsight() {
        var modest = consumer(pid: 99, name: "Editor")
        modest.averageCPU = 30
        let insights = InsightEngine.insights(cpuInputs(cpuConsumers: [modest]))
        XCTAssertNil(insights.first { $0.kind == .cpu })
    }
}
