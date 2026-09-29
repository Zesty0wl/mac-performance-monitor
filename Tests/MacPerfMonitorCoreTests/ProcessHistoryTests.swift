import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class ProcessHistoryTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    private let startTime = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-phist-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private func insertTick(
        _ timestamp: Date,
        footprint: UInt64,
        cpu: Double = 0,
        pid: Int32 = 1000,
        startTime: Date? = nil,
        fdTotal: Int32 = 10,
        diskBytesRead: UInt64 = 0,
        diskBytesWritten: UInt64 = 0
    ) throws {
        let snapshot = Sampler.Snapshot(
            system: Make.system(timestamp: timestamp, pressurePercent: 10),
            processes: [
                Make.process(
                    timestamp: timestamp, pid: pid,
                    startTime: startTime ?? self.startTime,
                    footprint: footprint, cpu: cpu,
                    fdTotal: fdTotal,
                    diskBytesRead: diskBytesRead,
                    diskBytesWritten: diskBytesWritten)
            ],
            unreadableProcessCount: 0
        )
        try store.insert(snapshot)
    }

    func testUsageTimelineClipsAndMergesWithoutFillingGapsOrMixingSources() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func interval(
            _ kind: UsageTimeline.Kind, _ start: Double, _ end: Double
        )
            -> UsageTimeline.Interval
        {
            UsageTimeline.Interval(
                kind: kind, start: base.addingTimeInterval(start),
                end: base.addingTimeInterval(end))
        }
        let result = UsageTimeline.normalized(
            [
                interval(.observedRunning, 80, 120),
                interval(.appUsage, 10, 90),
                interval(.observedRunning, -10, 30),
                interval(.observedRunning, 20, 40),
                interval(.observedRunning, 20, 40),
                interval(.observedRunning, 40, 50),
            ], within: base...base.addingTimeInterval(100))

        XCTAssertEqual(
            result,
            [
                interval(.observedRunning, 0, 50),
                interval(.observedRunning, 80, 100),
                interval(.appUsage, 10, 90),
            ])
    }

    func testUsageTimelineRejectsInvalidEmptyAndOutOfRangeIntervals() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let result = UsageTimeline.normalized(
            [
                .init(kind: .observedRunning, start: base, end: base),
                .init(kind: .appUsage, start: base.addingTimeInterval(20), end: base),
                .init(kind: .appUsage, start: base.addingTimeInterval(-20), end: base),
                .init(
                    kind: .mediaUsage, start: base,
                    end: Date(timeIntervalSince1970: .infinity)),
            ], within: base...base.addingTimeInterval(100))

        XCTAssertTrue(result.isEmpty)
    }

    func testUsageTimelineUsesObservationBucketsAndDoesNotBorrowAReusedPID() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        for offset in [10.0, 20, 150] {
            try insertTick(base.addingTimeInterval(offset), footprint: 100)
        }
        try insertTick(
            base.addingTimeInterval(190), footprint: 200,
            startTime: base.addingTimeInterval(180))

        let history = try store.usageTimeline(
            for: ProcessIdentity(pid: 1000, startTime: startTime), window: .oneDay,
            now: base.addingTimeInterval(240))

        XCTAssertEqual(history.bucketSeconds, 60)
        XCTAssertEqual(
            history.intervals,
            [
                .init(kind: .observedRunning, start: base, end: base.addingTimeInterval(60)),
                .init(
                    kind: .observedRunning, start: base.addingTimeInterval(120),
                    end: base.addingTimeInterval(180)),
            ])
    }

    func testUsageTimelineIncludesRolledHistoryAndRawTailWithoutDuplicates() throws {
        let base = Date(timeIntervalSince1970: 1_699_999_200)
        try insertTick(base.addingTimeInterval(30), footprint: 100)
        try insertTick(base.addingTimeInterval(7230), footprint: 200)
        let now = base.addingTimeInterval(10800)
        try Retention.run(store.databasePool, now: now)

        let history = try store.usageTimeline(
            for: ProcessIdentity(pid: 1000, startTime: startTime), window: .sevenDays, now: now)

        XCTAssertEqual(history.bucketSeconds, 3600)
        XCTAssertEqual(
            history.intervals,
            [
                .init(kind: .observedRunning, start: base, end: base.addingTimeInterval(3600)),
                .init(kind: .observedRunning, start: base.addingTimeInterval(7200), end: now),
            ])
    }

    func testUsageTimelineDoesNotExtendBeforeProcessStartOrAfterSnapshot() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        let launched = base.addingTimeInterval(10)
        try insertTick(base.addingTimeInterval(20), footprint: 100, startTime: launched)
        let now = base.addingTimeInterval(30)

        let history = try store.usageTimeline(
            for: ProcessIdentity(pid: 1000, startTime: launched), window: .oneHour, now: now)
        XCTAssertEqual(
            history.intervals,
            [
                .init(kind: .observedRunning, start: launched, end: now)
            ])

        let missing = try store.usageTimeline(
            for: ProcessIdentity(pid: 9999, startTime: launched), window: .oneHour, now: now)
        XCTAssertTrue(missing.intervals.isEmpty)
    }

    func testProcessHistoryReturnsRawSeriesAscendingWithAllFields() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insertTick(base, footprint: 100 * 1024 * 1024, cpu: 5)
        try insertTick(base.addingTimeInterval(2), footprint: 150 * 1024 * 1024, cpu: 12.5)
        try insertTick(base.addingTimeInterval(4), footprint: 200 * 1024 * 1024, cpu: 20)

        let identity = ProcessIdentity(pid: 1000, startTime: startTime)
        let points = try store.processHistory(
            for: identity, window: .oneHour,
            now: base.addingTimeInterval(4))

        XCTAssertEqual(points.count, 3)
        let expectedFootprints: [UInt64] = [
            100 * 1024 * 1024, 150 * 1024 * 1024, 200 * 1024 * 1024,
        ]
        XCTAssertEqual(points.map(\.footprint), expectedFootprints)
        XCTAssertEqual(points.map(\.date), points.map(\.date).sorted())
        XCTAssertEqual(points[1].cpuPercent, 12.5, accuracy: 0.001)
        // Make.process defaults: fd_total 10, disk counters 0.
        XCTAssertEqual(points.first?.fdTotal, 10)
        XCTAssertEqual(points.first?.diskRead, 0)
        XCTAssertEqual(points.first?.diskWritten, 0)
    }

    func testProcessHistoryRespectsRangeWindow() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insertTick(base, footprint: 100 * 1024 * 1024)
        try insertTick(base.addingTimeInterval(2000), footprint: 110 * 1024 * 1024)
        try insertTick(base.addingTimeInterval(3000), footprint: 120 * 1024 * 1024)

        let identity = ProcessIdentity(pid: 1000, startTime: startTime)
        // now = base+4000, one-hour window => since = base+400, excludes base+0.
        let points = try store.processHistory(
            for: identity, window: .oneHour,
            now: base.addingTimeInterval(4000))

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first?.footprint, 110 * 1024 * 1024)
    }

    func testProcessLineageHistoryStitchesRestartsButNotConcurrentInstances() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let oldStart = base.addingTimeInterval(-20)
        let newStart = base.addingTimeInterval(9)

        for (offset, footprint) in [(0.0, 100), (2.0, 110)] {
            let timestamp = base.addingTimeInterval(offset)
            try store.insert(
                Make.system(timestamp: timestamp),
                processes: [
                    Make.process(
                        timestamp: timestamp, pid: 100, startTime: oldStart, name: "Agent",
                        footprint: UInt64(footprint) * 1024 * 1024)
                ])
        }
        for (offset, footprint) in [(10.0, 200), (12.0, 210)] {
            let timestamp = base.addingTimeInterval(offset)
            try store.insert(
                Make.system(timestamp: timestamp),
                processes: [
                    Make.process(
                        timestamp: timestamp, pid: 200, startTime: newStart, name: "Agent",
                        footprint: UInt64(footprint) * 1024 * 1024),
                    Make.process(
                        timestamp: timestamp, pid: 201, startTime: newStart, name: "Agent",
                        footprint: 900 * 1024 * 1024),
                ])
        }

        let selected = ProcessIdentity(pid: 200, startTime: newStart)
        let points = try store.processLineageHistory(
            for: selected, window: .oneHour, now: base.addingTimeInterval(12))

        XCTAssertEqual(
            points.map(\.footprint), [100, 110, 200, 210].map { UInt64($0) * 1024 * 1024 })
        XCTAssertEqual(points.map(\.startsNewRun), [false, false, true, false])

        let exact = try store.processHistory(
            for: selected, window: .oneHour, now: base.addingTimeInterval(12))
        XCTAssertEqual(exact.map(\.footprint), [200, 210].map { UInt64($0) * 1024 * 1024 })
    }

    func testSubsetInsertWritesOnlyGivenProcesses() throws {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let kept = Make.process(
            timestamp: ts, pid: 1000, startTime: startTime,
            footprint: 300 * 1024 * 1024)
        let dropped = Make.process(
            timestamp: ts, pid: 2000, startTime: startTime,
            footprint: 50 * 1024 * 1024)

        try store.insert(Make.system(timestamp: ts), processes: [kept])

        let keptHistory = try store.processHistory(
            for: ProcessIdentity(pid: 1000, startTime: startTime), window: .oneHour, now: ts)
        let droppedHistory = try store.processHistory(
            for: ProcessIdentity(pid: 2000, startTime: startTime), window: .oneHour, now: ts)

        XCTAssertEqual(keptHistory.count, 1)
        XCTAssertTrue(droppedHistory.isEmpty)
        // The system row was still written.
        XCTAssertNotNil(try store.latestSystemSample())
        _ = dropped
    }

    func testProcessHistoriesReturnsEachSelectedSeries() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let other = Date(timeIntervalSince1970: 2_000_000)
        for i in 0..<3 {
            let ts = base.addingTimeInterval(Double(i) * 2)
            let a = Make.process(
                timestamp: ts, pid: 1000, startTime: startTime,
                footprint: UInt64(100 + i) * 1024 * 1024, cpu: Double(i))
            let b = Make.process(
                timestamp: ts, pid: 2000, startTime: other,
                footprint: UInt64(50 + i) * 1024 * 1024, cpu: Double(i) * 2)
            try store.insert(Make.system(timestamp: ts), processes: [a, b])
        }

        let idA = ProcessIdentity(pid: 1000, startTime: startTime)
        let idB = ProcessIdentity(pid: 2000, startTime: other)
        let missing = ProcessIdentity(pid: 9999, startTime: startTime)

        let map = try store.processHistories(
            for: [idA, idB, missing], window: .oneHour,
            now: base.addingTimeInterval(4))

        XCTAssertEqual(map[idA]?.count, 3)
        XCTAssertEqual(map[idB]?.count, 3)
        XCTAssertNil(map[missing], "an identity with no rows is absent from the result")
        let expectedFootprints = [100, 101, 102].map { UInt64($0) * 1024 * 1024 }
        XCTAssertEqual(map[idA]?.map(\.footprint), expectedFootprints)
        XCTAssertEqual(map[idB]?.first?.footprint, 50 * 1024 * 1024)
        // Each series is independent and ascending in time.
        XCTAssertEqual(map[idA]?.map(\.date), map[idA]?.map(\.date).sorted())
    }

    func testProcessHistoriesEmptyInputReturnsEmpty() throws {
        let map = try store.processHistories(for: [], window: .oneHour)
        XCTAssertTrue(map.isEmpty)
    }

    func testProcessHistorySliceEnforcesPointLimitWhileReading() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<3 {
            try insertTick(
                base.addingTimeInterval(Double(index)),
                footprint: UInt64(100 + index) * 1024 * 1024)
        }
        let identity = ProcessIdentity(pid: 1000, startTime: startTime)

        let exact = try store.processHistories(
            for: [identity], granularity: .raw,
            from: base, to: base.addingTimeInterval(1), maximumPointCount: 2)
        XCTAssertEqual(exact[identity]?.count, 2)

        XCTAssertThrowsError(
            try store.processHistories(
                for: [identity], granularity: .raw,
                from: base, to: base.addingTimeInterval(2), maximumPointCount: 2)
        ) { error in
            XCTAssertEqual(error as? ProcessHistoryReadError, .pointLimitExceeded(2))
        }
    }

    func testProcessHistorySliceHonoursCancellation() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insertTick(base, footprint: 100 * 1024 * 1024)
        let identity = ProcessIdentity(pid: 1000, startTime: startTime)

        XCTAssertThrowsError(
            try store.processHistories(
                for: [identity], granularity: .raw,
                from: base, to: base, isCancelled: { true })
        ) { error in
            XCTAssertEqual(error as? ProcessHistoryReadError, .cancelled)
        }
    }

    func testProcessHistoryFeedsLeakDetector() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spacing: TimeInterval = 20
        let count = 70  // ~23 min span — past the 20-minute duration floor
        let baseFootprint: UInt64 = 100 * 1024 * 1024
        let step: UInt64 = 4 * 1024 * 1024

        for i in 0..<count {
            try insertTick(
                base.addingTimeInterval(Double(i) * spacing),
                footprint: baseFootprint + UInt64(i) * step)
        }

        let identity = ProcessIdentity(pid: 1000, startTime: startTime)
        let now = base.addingTimeInterval(Double(count - 1) * spacing)
        let points = try store.processHistory(for: identity, window: .oneHour, now: now)
        XCTAssertEqual(points.count, count)

        let series = points.map { ($0.date, $0.footprint) }
        let finding = LeakDetector.analyze(series: series)
        XCTAssertNotNil(finding, "a steadily rising series should be flagged as a leak")
        XCTAssertGreaterThan(finding?.slopeBytesPerSecond ?? 0, 8 * 1024)
    }

    func testProcessTrendHistoriesReadMinuteThenHourAggregates() throws {
        // A minute-boundary anchor keeps bucket maths predictable.
        let anchor = Date(timeIntervalSince1970: 1_700_000_040)
        // ~40 ticks every 6s across a few minutes; constant footprint so the
        // bucket average equals the input. File descriptors climb (10, 11, ...)
        // and cumulative disk reads climb (0, 1000, 2000, ...) so the tiers can
        // be checked for the per-bucket peak FD and the per-bucket disk maximum.
        let footprint: UInt64 = 200 * 1024 * 1024
        for i in 0..<40 {
            try insertTick(
                anchor.addingTimeInterval(Double(i) * 6), footprint: footprint, cpu: 7,
                fdTotal: Int32(10 + i), diskBytesRead: UInt64(i) * 1_000)
        }
        // Roll raw -> minute, then minute -> hour.
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(600))
        try Retention.run(store.databasePool, now: anchor.addingTimeInterval(7200))

        let identity = ProcessIdentity(pid: 1000, startTime: startTime)
        let now = anchor.addingTimeInterval(7200)

        // 24-hour span reads the minute tier (still within its 7-day retention).
        let day = try store.processHistories(
            for: [identity], window: .oneDay, now: now)
        XCTAssertGreaterThanOrEqual(day[identity]?.count ?? 0, 3, "expected several minute buckets")
        XCTAssertEqual(day[identity]?.first?.footprint, footprint)
        XCTAssertEqual(day[identity]?.first?.cpuPercent ?? 0, 7, accuracy: 0.001)
        // The first minute bucket spans ticks 0...9: peak FD 19, max disk read 9000.
        XCTAssertEqual(day[identity]?.first?.fdTotal, 19)
        XCTAssertEqual(day[identity]?.first?.diskRead, 9_000)
        let dates = day[identity]?.map(\.date) ?? []
        XCTAssertEqual(dates, dates.sorted(), "buckets must be ascending by time")

        // 7-day span reads the hour tier; one hour bucket carries the peak FD
        // (49) and the cumulative-disk maximum (39000) across every minute.
        let week = try store.processHistories(
            for: [identity], window: .sevenDays, now: now)
        XCTAssertGreaterThanOrEqual(
            week[identity]?.count ?? 0, 1, "expected at least one hour bucket")
        XCTAssertEqual(week[identity]?.first?.footprint, footprint)
        XCTAssertEqual(week[identity]?.last?.fdTotal, 49)
        XCTAssertEqual(week[identity]?.last?.diskRead, 39_000)
    }

    func testProcessTrendHistoriesEmptyInputReturnsEmpty() throws {
        let map = try store.processHistories(for: [], window: .oneDay)
        XCTAssertTrue(map.isEmpty)
    }

    func testProcessTrendHistoriesAbsentProcessOmitted() throws {
        let missing = ProcessIdentity(pid: 9999, startTime: startTime)
        let map = try store.processHistories(for: [missing], window: .sevenDays)
        XCTAssertNil(map[missing], "a process with no aggregated rows is absent from the result")
    }
}
