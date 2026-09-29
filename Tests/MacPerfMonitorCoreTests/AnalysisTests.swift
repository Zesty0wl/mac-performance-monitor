import XCTest

@testable import MacPerfMonitorCore

final class LeakDetectorTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testFlagsSteadyGrowth() {
        // 16 samples, 90s apart (1350s span), +5 MB each = +75 MB total — past
        // the 20-minute duration floor.
        let series = Make.risingSeries(
            start: start, count: 16, spacing: 90,
            base: 100 * 1024 * 1024, stepBytes: 5 * 1024 * 1024
        )
        let finding = LeakDetector.analyze(series: series)
        XCTAssertNotNil(finding)
        XCTAssertGreaterThan(finding!.rSquared, 0.99)
        XCTAssertGreaterThan(finding!.slopeBytesPerSecond, 8 * 1024)
        XCTAssertEqual(finding!.totalGrowth, 75 * 1024 * 1024)
    }

    func testIgnoresFlatNoisySeries() {
        let series: [(Date, UInt64)] = (0..<40).map { i in
            let noise: UInt64 = (i % 2 == 0) ? 1_000_000 : 0
            return (start.addingTimeInterval(Double(i) * 40), 100 * 1024 * 1024 + noise)
        }
        XCTAssertNil(LeakDetector.analyze(series: series))
    }

    func testIgnoresTooFewSamples() {
        let series = Make.risingSeries(
            start: start, count: 5, spacing: 40,
            base: 100 * 1024 * 1024, stepBytes: 50 * 1024 * 1024
        )
        XCTAssertNil(LeakDetector.analyze(series: series))
    }

    func testIgnoresShortDuration() {
        // 16 samples but only 1s apart = 15s span, far below the 20-minute minimum.
        let series = Make.risingSeries(
            start: start, count: 16, spacing: 1,
            base: 100 * 1024 * 1024, stepBytes: 50 * 1024 * 1024
        )
        XCTAssertNil(LeakDetector.analyze(series: series))
    }

    func testRejectsPlateauSmallRelativeGrowthAndSamplingGaps() {
        let mib: UInt64 = 1024 * 1024
        let plateau = (0...45).map { minute in
            (
                start.addingTimeInterval(Double(minute) * 60),
                1024 * mib + UInt64(min(minute, 30)) * 16 * mib
            )
        }
        XCTAssertNil(LeakDetector.analyze(series: plateau))
        let small = (0...20).map { minute in
            (start.addingTimeInterval(Double(minute) * 60), 4096 * mib + UInt64(minute) * 2 * mib)
        }
        XCTAssertNil(LeakDetector.analyze(series: small))
        let sparse = (0...11).map { index in
            let seconds = index < 6 ? Double(index) * 60 : 3600 + Double(index - 6) * 60
            return (start.addingTimeInterval(seconds), 1024 * mib + UInt64(seconds) * 65536)
        }
        XCTAssertNil(LeakDetector.analyze(series: sparse))
    }

    func testFindsARisingBaselineThroughCyclicReleases() {
        let mib: UInt64 = 1024 * 1024
        let series: [(Date, UInt64)] = (0...60).map { minute in
            let date = start.addingTimeInterval(Double(minute) * 60)
            let baseline = (1024 + UInt64(minute) * 2) * mib
            let cycle = UInt64(minute % 10) * 50 * mib
            return (date, baseline + cycle)
        }
        XCTAssertNotNil(LeakDetector.analyze(series: series))
    }
}

final class ChangeDetectorTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testDetectsStepUp() {
        var series: [(Date, UInt64)] = []
        for i in 0..<5 {
            series.append((start.addingTimeInterval(Double(i) * 2), 100 * 1024 * 1024))
        }
        for i in 5..<10 {
            series.append((start.addingTimeInterval(Double(i) * 2), 500 * 1024 * 1024))
        }
        let change = ChangeDetector.analyze(series: series)
        XCTAssertNotNil(change)
        XCTAssertEqual(change!.deltaBytes, Int64(400 * 1024 * 1024))
    }

    func testIgnoresFlatSeries() {
        let series: [(Date, UInt64)] = (0..<12).map {
            (start.addingTimeInterval(Double($0) * 2), 200 * 1024 * 1024)
        }
        XCTAssertNil(ChangeDetector.analyze(series: series))
    }
}

final class RankingTests: XCTestCase {
    let now = Date()

    func testTopByFootprintExcludesUnreadable() {
        let samples = [
            Make.process(timestamp: now, pid: 1, name: "A", footprint: 300 * 1024 * 1024),
            Make.process(timestamp: now, pid: 2, name: "B", footprint: 900 * 1024 * 1024),
            Make.process(timestamp: now, pid: 3, name: "C", footprint: 0, readable: false),
            Make.process(timestamp: now, pid: 4, name: "D", footprint: 600 * 1024 * 1024),
        ]
        let top = Ranking.topByFootprint(samples, limit: 2)
        XCTAssertEqual(top.map(\.name), ["B", "D"])
    }

    func testRosettaCost() {
        let samples = [
            Make.process(timestamp: now, pid: 1, name: "Native", footprint: 100, translated: false),
            Make.process(
                timestamp: now, pid: 2, name: "Old1", footprint: 200 * 1024 * 1024, translated: true
            ),
            Make.process(
                timestamp: now, pid: 3, name: "Old2", footprint: 300 * 1024 * 1024, translated: true
            ),
        ]
        let cost = RosettaCost.compute(samples)
        XCTAssertEqual(cost.processCount, 2)
        XCTAssertEqual(cost.totalFootprint, 500 * 1024 * 1024)
    }
}

final class PressureCorrelationTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testCrossingsIntoWarning() {
        let samples = [
            Make.system(timestamp: start.addingTimeInterval(0), pressure: .normal),
            Make.system(timestamp: start.addingTimeInterval(2), pressure: .normal),
            Make.system(timestamp: start.addingTimeInterval(4), pressure: .warning),
            Make.system(timestamp: start.addingTimeInterval(6), pressure: .warning),
            Make.system(timestamp: start.addingTimeInterval(8), pressure: .normal),
            Make.system(timestamp: start.addingTimeInterval(10), pressure: .critical),
        ]
        let warnings = PressureCorrelation.crossings(system: samples, threshold: .warning)
        XCTAssertEqual(warnings, [start.addingTimeInterval(4), start.addingTimeInterval(10)])

        let crits = PressureCorrelation.crossings(system: samples, threshold: .critical)
        XCTAssertEqual(crits, [start.addingTimeInterval(10)])
    }

    func testTopGrowers() {
        let id1 = ProcessIdentity(pid: 1, startTime: start)
        let id2 = ProcessIdentity(pid: 2, startTime: start)
        let series: [ProcessIdentity: [(Date, UInt64)]] = [
            id1: [(start, 100), (start.addingTimeInterval(60), 100 + 100 * 1024 * 1024)],
            id2: [(start, 100), (start.addingTimeInterval(60), 100 + 10 * 1024 * 1024)],
        ]
        let window = start...start.addingTimeInterval(60)
        let growers = PressureCorrelation.topGrowers(series: series, window: window, limit: 2)
        XCTAssertEqual(growers.first?.identity, id1)
        XCTAssertEqual(growers.first?.growthBytes, Int64(100 * 1024 * 1024))
    }
}
