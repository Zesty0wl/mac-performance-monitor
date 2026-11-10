import XCTest

@testable import MacPerfMonitorCore

final class ProcessExitTrackerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ pid: Int32, started: TimeInterval = 0) -> ProcessSample {
        ProcessSample(
            timestamp: epoch, pid: pid, ppid: 1, name: "p\(pid)", physFootprint: 0,
            residentSize: 0, virtualSize: 0, lifetimeMaxFootprint: 0, cpuPercent: 0,
            cpuTimeUser: 0, cpuTimeSystem: 0, threadCount: 1, fdTotal: 0, fdVnode: 0,
            fdSocket: 0, fdPipe: 0, fdOther: 0, diskBytesRead: 0, diskBytesWritten: 0,
            isTranslated: false, architecture: .arm64,
            startTime: epoch.addingTimeInterval(started), uid: 501,
            dataSource: .directUserRead, footprintReadable: true)
    }

    func testReportsEachExitOnceWithItsLastSample() {
        var tracker = ProcessExitTracker()
        XCTAssertTrue(tracker.exits(in: [sample(1), sample(2), sample(3)], now: epoch).isEmpty)
        let gone = tracker.exits(in: [sample(1), sample(3)], now: epoch.addingTimeInterval(2))
        XCTAssertEqual(gone.map(\.pid), [2])
        XCTAssertTrue(
            tracker.exits(in: [sample(1), sample(3)], now: epoch.addingTimeInterval(4)).isEmpty)
    }

    /// The same pid with a new start time is a different process: the old one
    /// exited and the number was reused within one interval.
    func testReusedPIDCountsAsAnExit() {
        var tracker = ProcessExitTracker()
        _ = tracker.exits(in: [sample(7, started: 0)], now: epoch)
        let gone = tracker.exits(in: [sample(7, started: 1)], now: epoch.addingTimeInterval(2))
        XCTAssertEqual(gone.map(\.startTime), [epoch])
    }

    func testListsTooFarApartAreNotCompared() {
        var tracker = ProcessExitTracker(maximumGap: 10)
        _ = tracker.exits(in: [sample(1), sample(2)], now: epoch)
        XCTAssertTrue(tracker.exits(in: [sample(1)], now: epoch.addingTimeInterval(11)).isEmpty)
        // The late list still becomes the new baseline.
        XCTAssertEqual(
            tracker.exits(in: [], now: epoch.addingTimeInterval(12)).map(\.pid), [1])
    }

    func testResetAndClockGoingBackwardsReportNothing() {
        var tracker = ProcessExitTracker()
        _ = tracker.exits(in: [sample(1)], now: epoch)
        tracker.reset()
        XCTAssertTrue(tracker.exits(in: [], now: epoch.addingTimeInterval(1)).isEmpty)

        _ = tracker.exits(in: [sample(1)], now: epoch.addingTimeInterval(5))
        XCTAssertTrue(tracker.exits(in: [], now: epoch).isEmpty)
    }
}
