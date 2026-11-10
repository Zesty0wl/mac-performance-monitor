import XCTest

@testable import MacPerfMonitorCore

final class ProcessReaderTests: XCTestCase {
    // MARK: - Process start time

    /// The process launch time is read from the kernel as split seconds +
    /// microseconds and must keep its sub-second precision. `ProcessIdentity`
    /// keys a reused PID apart by its start time, and the trace export encodes
    /// `startTime.timeIntervalSince1970.bitPattern`; dropping the microseconds
    /// collapses two distinct processes that reuse a PID within the same second.
    func testStartTimeKeepsMicrosecondPrecision() {
        let wholeSecond = ProcessReader.startDate(seconds: 1_700_000_000, microseconds: 0)
        let later = ProcessReader.startDate(seconds: 1_700_000_000, microseconds: 400_000)

        XCTAssertEqual(wholeSecond.timeIntervalSince1970, 1_700_000_000.0, accuracy: 1e-9)
        XCTAssertEqual(later.timeIntervalSince1970, 1_700_000_000.4, accuracy: 1e-9)
        // Same whole second, different microseconds -> distinct start times, so
        // two same-second PID reuses stay distinct identities.
        XCTAssertNotEqual(wholeSecond, later)
    }

    /// The full microsecond range rounds cleanly into the fractional second.
    func testStartTimeCarriesFullMicrosecondFraction() {
        let t = ProcessReader.startDate(seconds: 1_700_000_000, microseconds: 999_999)
        XCTAssertEqual(t.timeIntervalSince1970, 1_700_000_000.999_999, accuracy: 1e-9)
    }

    // MARK: Scheduling state

    func testOwnProcessReadsAsRunningAtItsNiceValue() throws {
        let info = try XCTUnwrap(ProcessReader().taskAllInfo(getpid()))
        XCTAssertEqual(info.isSuspended, false)
        XCTAssertEqual(info.nice, getpriority(PRIO_PROCESS, 0))
    }

    func testSuspendedAndRenicedChildIsReported() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["100"]
        try task.run()
        defer {
            kill(task.processIdentifier, SIGKILL)
            task.waitUntilExit()
        }
        let pid = task.processIdentifier
        let reader = ProcessReader()

        XCTAssertEqual(kill(pid, SIGSTOP), 0)
        XCTAssertEqual(setpriority(PRIO_PROCESS, id_t(pid), 10), 0)
        // The stop is delivered asynchronously; give the kernel a moment.
        var info = reader.taskAllInfo(pid)
        for _ in 0..<50 where info?.isSuspended != true {
            usleep(20_000)
            info = reader.taskAllInfo(pid)
        }
        XCTAssertEqual(info?.isSuspended, true)
        XCTAssertEqual(info?.nice, 10)

        XCTAssertEqual(kill(pid, SIGCONT), 0)
        for _ in 0..<50 where info?.isSuspended != false {
            usleep(20_000)
            info = reader.taskAllInfo(pid)
        }
        XCTAssertEqual(info?.isSuspended, false)
    }

    /// A helper built before these fields existed sends JSON without them.
    func testTaskInfoFromAnOlderHelperStillDecodes() throws {
        let json = """
            {"name":"sleep","ppid":1,"uid":501,"startTime":0,"residentSize":1,
             "virtualSize":2,"cpuTimeUser":3,"cpuTimeSystem":4,"threadCount":1}
            """
        let info = try JSONDecoder().decode(TaskAllInfo.self, from: Data(json.utf8))
        XCTAssertNil(info.isSuspended)
        XCTAssertNil(info.nice)
        XCTAssertEqual(info.threadCount, 1)
    }
}
