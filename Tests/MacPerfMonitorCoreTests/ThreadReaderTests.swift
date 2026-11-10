import XCTest

@testable import MacPerfMonitorCore

final class ThreadReaderTests: XCTestCase {
    private func thread(_ id: UInt64, cpu: UInt64) -> ThreadSnapshot {
        ThreadSnapshot(
            id: id, name: "", userNanos: cpu, systemNanos: 0, state: .waiting,
            currentPriority: 31, basePriority: 31, sleepSeconds: 0)
    }

    func testReadsOwnThreadsWithNamesAndRealCPUTime() throws {
        let stop = NSLock()
        stop.lock()
        let started = expectation(description: "worker started")
        let worker = Thread {
            started.fulfill()
            // Spin until the test has taken its second reading.
            while !stop.try() {}
            stop.unlock()
        }
        worker.name = "mpm-test-spinner"
        worker.start()
        wait(for: [started], timeout: 2)

        let reader = ThreadReader()
        let first = try XCTUnwrap(reader.threads(getpid()))
        let firstAt = Date()
        Thread.sleep(forTimeInterval: 0.3)
        let second = try XCTUnwrap(reader.threads(getpid()))
        let elapsed = Date().timeIntervalSince(firstAt)
        stop.unlock()

        let spinner = try XCTUnwrap(second.first { $0.name == "mpm-test-spinner" })
        XCTAssertGreaterThan(second.count, 1)
        XCTAssertEqual(Set(second.map(\.id)).count, second.count, "IDs are unique")

        // A spinning thread uses about one core. A reading far from 100 would
        // mean the times were in the wrong unit (Mach ticks are 41.7 ns each on
        // Apple silicon, which would read as about 2%).
        let usage = ThreadUsage.cpuPercent(previous: first, current: second, elapsed: elapsed)
        let percent = try XCTUnwrap(usage[spinner.id])
        XCTAssertGreaterThan(percent, 50)
        XCTAssertLessThan(percent, 150)
    }

    func testUnreadableProcessReturnsNil() {
        XCTAssertNil(ThreadReader().threads(-1))
        // launchd belongs to root; a normal user cannot list its threads.
        if geteuid() != 0 { XCTAssertNil(ThreadReader().threads(1)) }
    }

    func testUsageSkipsNewAndReusedThreads() {
        let previous = [thread(1, cpu: 1_000_000_000), thread(2, cpu: 5_000_000_000)]
        let current = [
            thread(1, cpu: 2_000_000_000),  // one second of CPU in two seconds
            thread(2, cpu: 1_000_000_000),  // total went down: a new thread
            thread(3, cpu: 9_000_000_000),  // not seen before
        ]
        let usage = ThreadUsage.cpuPercent(previous: previous, current: current, elapsed: 2)
        XCTAssertEqual(usage, [1: 50])
        XCTAssertTrue(
            ThreadUsage.cpuPercent(previous: previous, current: current, elapsed: 0).isEmpty)
    }

    func testSnapshotRoundTripsAsJSON() throws {
        let original = ThreadSnapshot(
            id: 42, name: "worker", userNanos: 7, systemNanos: 9, state: .running,
            currentPriority: 47, basePriority: 31, sleepSeconds: 3)
        let data = try JSONEncoder().encode([original])
        XCTAssertEqual(try JSONDecoder().decode([ThreadSnapshot].self, from: data), [original])
        XCTAssertEqual(original.cpuNanos, 16)
    }
}
