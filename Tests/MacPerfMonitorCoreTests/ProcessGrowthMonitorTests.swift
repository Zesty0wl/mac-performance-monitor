import XCTest

@testable import MacPerfMonitorCore

final class ProcessGrowthMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let mib: UInt64 = 1024 * 1024

    func testModestGrowthIsOnlyWatchedAndNeedsNoHistoryDatabase() {
        let monitor = ProcessGrowthMonitor()
        var result = ProcessGrowthMonitor.Result()
        for minute in 0...30 {
            let date = start.addingTimeInterval(Double(minute) * 60)
            result = monitor.evaluate(
                [
                    Make.process(
                        timestamp: date, startTime: start,
                        footprint: (1024 + UInt64(minute) * 4) * mib)
                ], totalRAM: 18 * 1024 * mib, now: date, maximumGap: 120)
        }
        XCTAssertEqual(result.conditions.first?.alert.severity, .watching)
    }

    func testRapidRunawayDoesNotWaitTwentyMinutes() {
        let monitor = ProcessGrowthMonitor()
        var conditions: [AlertCondition] = []
        for offset in stride(from: 0.0, through: 300, by: 10) {
            let date = start.addingTimeInterval(offset)
            let process = Make.process(
                timestamp: date, startTime: start, footprint: (1024 + UInt64(offset) * 20) * mib)
            conditions +=
                monitor.evaluate([process], totalRAM: 18 * 1024 * mib, now: date, maximumGap: 30)
                .conditions
        }
        XCTAssertTrue(conditions.contains { $0.alert.severity == .warning })
    }

    func testExitAndUnreadableSamplesDoNotBecomeFreshGrowth() {
        let monitor = ProcessGrowthMonitor()
        let process = Make.process(timestamp: start, startTime: start, footprint: 4096 * mib)
        _ = monitor.evaluate([process], totalRAM: 18 * 1024 * mib, now: start, maximumGap: 30)
        let stale = monitor.evaluate(
            [process], totalRAM: 18 * 1024 * mib, now: start.addingTimeInterval(300), maximumGap: 30
        )
        XCTAssertEqual(stale.unknown, [process.id])
        XCTAssertTrue(stale.conditions.isEmpty)
        XCTAssertTrue(
            monitor.evaluate(
                [], totalRAM: 18 * 1024 * mib, now: start.addingTimeInterval(301), maximumGap: 30
            ).conditions.isEmpty)
    }

    func testChangingProcessEnumerationCannotGrowPastTheTrackingCap() {
        let monitor = ProcessGrowthMonitor()
        for offset in [0, 1000] {
            let date = start.addingTimeInterval(Double(offset))
            let processes = (0..<4200).map { index in
                Make.process(
                    timestamp: date, pid: Int32(100 + offset + index), startTime: start,
                    footprint: mib)
            }
            let result = monitor.evaluate(
                processes, totalRAM: 18 * 1024 * mib, now: date, maximumGap: 120)
            XCTAssertEqual(monitor.trackedProcessCount, 4096)
            XCTAssertTrue(Set(processes.suffix(104).map(\.id)).isSubset(of: result.unknown))
        }
    }
}
