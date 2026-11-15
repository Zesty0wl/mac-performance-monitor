import XCTest

@testable import MacPerfMonitorCore

/// Integration tests that run the real sampler against the live system and
/// assert sane bounds rather than exact values.
final class SamplerLiveTests: XCTestCase {
    func testSystemSampleBounds() {
        let sampler = Sampler()
        let snapshot = sampler.tick()

        XCTAssertGreaterThan(snapshot.system.totalRAM, 0)
        XCTAssertGreaterThanOrEqual(snapshot.system.pressurePercent, 0)
        XCTAssertLessThanOrEqual(snapshot.system.pressurePercent, 100)
        // The categories should not individually exceed total RAM.
        XCTAssertLessThanOrEqual(snapshot.system.wired, snapshot.system.totalRAM)
        XCTAssertLessThanOrEqual(snapshot.system.compressed, snapshot.system.totalRAM)
    }

    func testEnumeratesProcessesAndOwnFootprint() {
        let sampler = Sampler()
        let snapshot = sampler.tick()
        XCTAssertFalse(snapshot.processes.isEmpty, "Expected to enumerate at least one process")

        // The test process itself must be readable with a non-zero footprint.
        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let mine = snapshot.processes.first { $0.pid == myPID }
        XCTAssertNotNil(mine, "Expected to find the test process by pid")
        XCTAssertTrue(mine!.footprintReadable)
        XCTAssertGreaterThan(mine!.physFootprint, 0)
    }

    func testCPUPercentComputedOnSecondTick() {
        let sampler = Sampler()
        let t0 = Date()
        _ = sampler.tick(now: t0)
        // Burn a little CPU so a delta exists.
        var acc = 0.0
        for i in 0..<2_000_000 { acc += Double(i).squareRoot() }
        XCTAssertGreaterThan(acc, 0)
        let snapshot = sampler.tick(now: t0.addingTimeInterval(0.2))

        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let mine = snapshot.processes.first { $0.pid == myPID }
        XCTAssertNotNil(mine)
        XCTAssertGreaterThanOrEqual(mine!.cpuPercent, 0)
    }

    func testSystemCPUSampleBounds() {
        let sampler = Sampler()
        // First tick seeds the per-core counters (no delta yet); the second
        // produces real per-core utilisation.
        _ = sampler.tick()
        var acc = 0.0
        for i in 0..<2_000_000 { acc += Double(i).squareRoot() }
        XCTAssertGreaterThan(acc, 0)
        let snapshot = sampler.tick()

        let cpu = snapshot.cpu
        XCTAssertFalse(cpu.cores.isEmpty, "Expected per-core utilisation on the second tick")
        XCTAssertEqual(cpu.cores.count, CPUTopology.current.logicalCores)
        XCTAssertGreaterThanOrEqual(cpu.totalUsage, 0)
        XCTAssertLessThanOrEqual(cpu.totalUsage, 1)
        // System total CPU is mirrored into the persisted SystemSample field.
        XCTAssertEqual(snapshot.system.cpuLoad, cpu.totalUsage, accuracy: 1e-9)
        for core in cpu.cores {
            XCTAssertGreaterThanOrEqual(core.usage, 0)
            XCTAssertLessThanOrEqual(core.usage, 1.0001)
        }
    }

    /// `fdCount` must count *open descriptors*, not the kernel FD-table capacity.
    /// The sizing call it once relied on reports `(fd_nfiles + 20)` entries, where
    /// `fd_nfiles` is a high-water mark that doubles on demand and never shrinks —
    /// the "1620 file descriptors" display bug (docs/fd-count-1620-diagnosis.md).
    /// Open a burst of descriptors (growing the table), close them again, and the
    /// count must fall back to the baseline instead of the inflated plateau.
    func testFDCountCountsOpenDescriptorsNotTableCapacity() throws {
        let reader = ProcessReader()
        let scratch = FDCountScratch()
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)

        let baseline = try XCTUnwrap(reader.fdCount(pid, scratch: scratch))
        XCTAssertGreaterThan(baseline, 0)

        var opened: [Int32] = []
        defer { for fd in opened { close(fd) } }
        for _ in 0..<300 {
            let fd = open("/dev/null", O_RDONLY)
            XCTAssertGreaterThanOrEqual(fd, 0)
            opened.append(fd)
        }

        let during = try XCTUnwrap(reader.fdCount(pid, scratch: scratch))
        XCTAssertGreaterThanOrEqual(during, baseline + 300)

        for fd in opened { close(fd) }
        opened.removeAll()

        // The table capacity is now ≥ (baseline + 300) slots and stays there; the
        // old sizing-call implementation would report that plateau (+20 slop) here.
        let after = try XCTUnwrap(reader.fdCount(pid, scratch: scratch))
        XCTAssertLessThan(after, baseline + 50)
    }

    func testLabelsAnInterpreterByWhatItRuns() throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("label-probe-\(UUID().uuidString.prefix(8)).sh")
        try "sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = [script.path]
        try child.run()
        defer { child.terminate() }
        Thread.sleep(forTimeInterval: 0.2)

        let snapshot = Sampler().tick()
        let row = snapshot.processes.first { $0.pid == child.processIdentifier }
        XCTAssertEqual(row?.commandLabel, script.lastPathComponent)
        // /bin/sh runs as bash on macOS, so check only the label half.
        XCTAssertEqual(row?.labeledName.hasSuffix(" · \(script.lastPathComponent)"), true)
        let own = snapshot.processes.first { $0.pid == getpid() }
        XCTAssertNotNil(own)
        XCTAssertNil(own?.commandLabel, "not an interpreter, so its arguments are never read")
    }

    func testLabelsAPythonPoolWorkerAfterItsParentScript() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("no python3")
        }
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("pool-probe-\(UUID().uuidString.prefix(8)).py")
        try """
        import multiprocessing, time
        def work(_):
            time.sleep(30)
        if __name__ == "__main__":
            multiprocessing.set_start_method("spawn")
            with multiprocessing.Pool(1) as pool:
                pool.map(work, [0])
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [script.path]
        try child.run()
        // The pool's worker and resource tracker are the script's children:
        // stop them as well as the script.
        var children: [pid_t] = []
        defer {
            for pid in children { Darwin.kill(pid, SIGKILL) }
            child.terminate()
        }

        let sampler = Sampler()
        var worker: ProcessSample?
        for _ in 0..<20 where worker?.commandLabel == nil {
            Thread.sleep(forTimeInterval: 0.25)
            let spawned = sampler.tick().processes.filter { $0.ppid == child.processIdentifier }
            children = spawned.map(\.pid)
            worker = spawned.first { $0.commandLabel?.contains("(worker)") == true }
        }
        XCTAssertEqual(worker?.commandLabel, "\(script.lastPathComponent) (worker)")
    }

    func testHasBaselineOnlyAfterAFirstTick() {
        let sampler = Sampler()
        XCTAssertFalse(sampler.hasBaseline, "nothing to difference against before the first tick")
        _ = sampler.tickSystem()
        XCTAssertTrue(sampler.hasBaseline)
        sampler.reset()
        XCTAssertFalse(sampler.hasBaseline, "a reset drops the baseline with the deltas")
    }
}
