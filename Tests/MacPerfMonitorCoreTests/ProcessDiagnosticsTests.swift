import XCTest

@testable import MacPerfMonitorCore

final class ProcessDiagnosticsTests: XCTestCase {
    private func input(
        cpu: Double = 5, footprint: UInt64 = 100_000_000, threads: Int = 4,
        ram: UInt64 = 16 << 30, sample: String? = nil, fds: [OpenFileDescriptor] = [],
        memTrail: [Double] = [], diskRead: [Double] = [], diskWrite: [Double] = [],
        fdTrail: [Double] = [], span: Int = 0, uptime: Double = 0, cpuTrail: [Double] = []
    ) -> ProcessDiagnostics.Input {
        ProcessDiagnostics.Input(
            name: "App", cpuPercent: cpu, footprintBytes: footprint, threadCount: threads,
            systemRAMBytes: ram, uptimeMinutes: uptime, sample: sample.flatMap(SampleDigest.parse),
            fileDescriptors: fds,
            cpuTrail: cpuTrail, memoryTrail: memTrail, diskReadTrail: diskRead,
            diskWriteTrail: diskWrite, fdTrail: fdTrail, spanMinutes: span)
    }

    /// A steadily-rising footprint series in bytes (a real leak).
    private func rising(_ startMB: Double, _ endMB: Double, n: Int = 20) -> [Double] {
        (0..<n).map {
            (startMB + (endMB - startMB) * Double($0) / Double(n - 1)) * 1_048_576
        }
    }
    /// A noisy sawtooth footprint series in bytes (NOT a leak) — e.g. a browser helper.
    private func sawtooth(_ lowMB: Double, _ highMB: Double, n: Int = 20) -> [Double] {
        (0..<n).map { ($0 % 2 == 0 ? lowMB : highMB) * 1_048_576 }
    }

    /// One-thread sample whose main-thread leaf is `mainLeaf`.
    private func sample(mainLeaf: String, binary: String = "App") -> String {
        """
        Process:         App [42]
        Call graph:
            500 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 500 start  (in dyld) + 1  [0x1]
            +   500 -[App run]  (in App) + 1  [0x2]
            +     500 \(mainLeaf)  (in \(binary)) + 1  [0x3]
        """
    }

    private func check(_ checks: [DiagnosticCheck], _ id: String) -> DiagnosticCheck {
        guard let c = checks.first(where: { $0.id == id }) else {
            XCTFail("no check \(id)")
            fatalError()
        }
        return c
    }

    func testStuckInALoopIsCritical() {
        let checks = ProcessDiagnostics.run(
            input(cpu: 180, sample: sample(mainLeaf: "-[Worker grind]")))
        let cpu = check(checks, "cpu-loop")
        XCTAssertEqual(cpu.status, .critical)
        XCTAssertTrue(cpu.summary.contains("-[Worker grind]"), cpu.summary)
        XCTAssertTrue(cpu.summary.lowercased().contains("loop"), cpu.summary)
    }

    func testHungMainThreadIsNotResponding() {
        let checks = ProcessDiagnostics.run(
            input(
                cpu: 0,
                sample: sample(mainLeaf: "__psynch_mutexwait", binary: "libsystem_kernel.dylib")))
        XCTAssertEqual(check(checks, "not-responding").status, .critical)
    }

    func testRunLoopMainThreadIsResponsive() {
        let checks = ProcessDiagnostics.run(
            input(
                cpu: 1, sample: sample(mainLeaf: "mach_msg2_trap", binary: "libsystem_kernel.dylib")
            ))
        XCTAssertEqual(check(checks, "not-responding").status, .ok)
    }

    func testMemoryLeakDetectedOnOldProcess() {
        // An old (>15 min) process with a CONSISTENT rise = a real leak.
        let checks = ProcessDiagnostics.run(
            input(memTrail: rising(100, 300), span: 30, uptime: 60))
        XCTAssertEqual(check(checks, "memory-leak").status, .warning)
        XCTAssertTrue(check(checks, "memory-leak").summary.lowercased().contains("leak"))
    }

    func testNoisyMemoryIsNotALeak() {
        // A noisy sawtooth (browser-helper style, 100↔650 MB) must NOT read as a leak
        // — the regression R² gate rejects it (the false positive that prompted this).
        let checks = ProcessDiagnostics.run(
            input(memTrail: sawtooth(100, 650), span: 30, uptime: 60))
        XCTAssertEqual(check(checks, "memory-leak").status, .ok)
    }

    func testYoungProcessRisingIsWarmupNotLeak() {
        // A young (<15 min) process rising consistently = warm-up, not a leak.
        let checks = ProcessDiagnostics.run(
            input(memTrail: rising(100, 300), span: 30, uptime: 5))
        XCTAssertNil(checks.first { $0.id == "memory-leak" }, "leak check should be gated out")
        XCTAssertEqual(check(checks, "memory-warmup").status, .info)
    }

    func testStableMemoryIsNoLeak() {
        let flat = Array(repeating: 100.0 * 1_048_576, count: 20)
        let checks = ProcessDiagnostics.run(input(memTrail: flat, span: 30, uptime: 60))
        XCTAssertEqual(check(checks, "memory-leak").status, .ok)
    }

    func testSustainedHighCPUCaught() {
        // ~45% for the whole window — below the 85% spike threshold but a sustained
        // hog that the recent-median check must flag (the missed case).
        let pinned = Array(repeating: 45.0, count: 20)
        let checks = ProcessDiagnostics.run(input(cpu: 45, span: 30, uptime: 60, cpuTrail: pinned))
        XCTAssertEqual(check(checks, "cpu-sustained").status, .warning)
        XCTAssertEqual(
            check(checks, "cpu-high").status, .ok, "85% spike rule should not fire at 45%")
    }

    func testHighDiskIO() {
        // ~1.5 GB over 1 min ≈ 25 MB/s.
        let checks = ProcessDiagnostics.run(input(diskRead: [0, 1_500_000_000], span: 1))
        XCTAssertEqual(check(checks, "disk-read").status, .warning)
    }

    func testNetworkEndpointsArePortLabelled() {
        let checks = ProcessDiagnostics.run(
            input(fds: [
                OpenFileDescriptor(fd: 5, kind: .socket, detail: "tcp 1.2.3.4:5 -> 10.0.0.5:6379")
            ]))
        XCTAssertTrue(
            check(checks, "network").details.contains { $0.contains("Redis") },
            "\(check(checks, "network").details)")
    }

    func testDataFilesListedNotLibraries() {
        let checks = ProcessDiagnostics.run(
            input(fds: [
                OpenFileDescriptor(fd: 5, kind: .file, detail: "/Users/x/db.sqlite"),
                OpenFileDescriptor(fd: 6, kind: .file, detail: "/usr/lib/libz.dylib"),
            ]))
        let files = check(checks, "fd-many")
        XCTAssertEqual(files.details, ["/Users/x/db.sqlite"])
    }

    func testThreadExplosion() {
        XCTAssertEqual(
            check(ProcessDiagnostics.run(input(threads: 250)), "threads").status, .warning)
    }

    func testOverallVerdictTakesWorstCheck() {
        let r = ProcessProfileReport.make(
            stats: ProcessProfileStats(
                cpuPercent: 180, footprintBytes: 1 << 30, peakFootprintBytes: 1 << 30,
                threadCount: 4),
            systemRAMBytes: 16 << 30, sampleOutput: sample(mainLeaf: "-[Worker grind]"),
            fileDescriptors: [], cpuTrail: [], memoryTrail: [], diskReadTrail: [],
            diskWriteTrail: [], fdTrail: [], spanMinutes: 0)
        XCTAssertEqual(r.overallStatus, .critical)
        XCTAssertTrue(r.headline.lowercased().contains("problem"))
    }

    func testTemplateDoesNotRescanSubstitutedNames() {
        // A binary named after a token used to make the fill loop forever.
        var p = ProbeValues()
        p.strings["sample.hotBinary"] = "{sample.hotBinary}"
        p.numbers["cpu.percent"] = 97
        XCTAssertEqual(
            CheckCatalog.template("{sample.hotBinary} at {cpu.percent|pct} {", p),
            "{sample.hotBinary} at 9700% {")
    }
}
