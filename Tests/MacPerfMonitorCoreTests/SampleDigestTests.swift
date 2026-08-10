import XCTest

@testable import MacPerfMonitorCore

final class SampleDigestTests: XCTestCase {
    /// A synthetic but format-accurate report: a main thread burning CPU in a parse
    /// loop, plus a network thread parked in select.
    private let busy = """
        Analysis of sampling MyBuggyApp (pid 4242) every 10 milliseconds
        Process:         MyBuggyApp [4242]
        Path:            /Applications/MyBuggyApp.app/Contents/MacOS/MyBuggyApp
        Physical footprint:         512.0M
        ----

        Call graph:
            500 Thread_111   DispatchQueue_1: com.apple.main-thread  (serial)
            + 500 start  (in dyld) + 6992  [0x1]
            +   500 main  (in MyBuggyApp) + 228  [0x2]
            +     500 -[AppDelegate run]  (in MyBuggyApp) + 100  [0x3]
            +       480 -[Parser parseLoop]  (in MyBuggyApp) + 50  [0x4]
            +         480 -[Parser parseObject]  (in MyBuggyApp) + 20  [0x5]
            +       20 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x6]
            500 Thread_222: com.myapp.network
            + 500 thread_start  (in libsystem_pthread.dylib) + 8  [0x7]
            +   500 __select  (in libsystem_kernel.dylib) + 8  [0x8]
        """

    /// Real `sample` output (trimmed) — note the binary name contains parens.
    private let idle = """
        Analysis of sampling Google Chrome Helper (Renderer) (pid 80226) every 1 millisecond
        Process:         Google Chrome Helper (Renderer) [80226]
        Physical footprint:         25.1M
        ----

        Call graph:
            1719 Thread_3723338   DispatchQueue_1: com.apple.main-thread  (serial)
            + 1719 start  (in dyld) + 6992  [0x18ba37e00]
            +   1719 main  (in Google Chrome Helper (Renderer)) + 228  [0x104e6c904]
            +     1719 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x18bdb1c34]
            1719 Thread_3723357: PerfettoTrace
            + 1719 thread_start  (in libsystem_pthread.dylib) + 8  [0x18bdf0c1c]
            +   1719 kevent64  (in libsystem_kernel.dylib) + 8  [0x18bdbdba8]
        """

    /// Real `/usr/bin/sample` output on current macOS (captured byte-exact from
    /// /usr/bin/sample on macOS 26): call-graph frames are indented
    /// "<count> <symbol> (in <binary>) + <offset> [addr]" with NO leading "+"
    /// marker. The only "+" on a frame line is the address offset. A parser that
    /// keys on a leading marker rejects every frame and the digest comes back nil.
    private let realFormat = """
        Analysis of sampling MyBuggyApp (pid 4242) every 10 milliseconds
        Process:         MyBuggyApp [4242]
        Path:            /Applications/MyBuggyApp.app/Contents/MacOS/MyBuggyApp
        Physical footprint:         512.0M
        ----

        Call graph:
            500 Thread_111   DispatchQueue_1: com.apple.main-thread  (serial)
              500 start  (in dyld) + 6992  [0x1]
                500 main  (in MyBuggyApp) + 228  [0x2]
                  500 -[AppDelegate run]  (in MyBuggyApp) + 100  [0x3]
                    480 -[Parser parseLoop]  (in MyBuggyApp) + 50  [0x4]
                      480 -[Parser parseObject]  (in MyBuggyApp) + 20  [0x5]
                    20 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x6]
            500 Thread_222: com.myapp.network
              500 thread_start  (in libsystem_pthread.dylib) + 8  [0x7]
                500 __select  (in libsystem_kernel.dylib) + 8  [0x8]
        """

    func testParsesOnCPUThreadAndHotLeaf() throws {
        let report = try XCTUnwrap(SampleDigest.parse(busy))
        XCTAssertEqual(report.process, "MyBuggyApp [4242]")
        XCTAssertEqual(report.footprint, "512.0M")
        XCTAssertEqual(report.threads.count, 2)
        XCTAssertEqual(report.onCPU.count, 1)

        let main = try XCTUnwrap(report.onCPU.first)
        XCTAssertEqual(main.name, "main thread")
        XCTAssertFalse(main.isWaiting)
        // The dominant (480-sample) branch ends in parseObject, not the 20-sample wait.
        XCTAssertEqual(main.leafSymbol, "-[Parser parseObject]")
        XCTAssertEqual(main.leafBinary, "MyBuggyApp")
        XCTAssertTrue(main.hotPath.contains("-[Parser parseLoop]"))
    }

    func testParsesRealSampleOutput() throws {
        // Real /usr/bin/sample emits no leading "+" on call-graph frames; before
        // the fix this returned nil for every real report, silently disabling the
        // CPU call-graph digest.
        let report = try XCTUnwrap(SampleDigest.parse(realFormat))
        XCTAssertEqual(report.process, "MyBuggyApp [4242]")
        XCTAssertEqual(report.footprint, "512.0M")
        XCTAssertEqual(report.threads.count, 2)
        XCTAssertEqual(report.onCPU.count, 1)

        let main = try XCTUnwrap(report.onCPU.first)
        XCTAssertEqual(main.name, "main thread")
        XCTAssertFalse(main.isWaiting)
        XCTAssertEqual(main.leafSymbol, "-[Parser parseObject]")
        XCTAssertEqual(main.leafBinary, "MyBuggyApp")
        XCTAssertTrue(main.hotPath.contains("-[Parser parseLoop]"))

        let net = try XCTUnwrap(report.threads.first { $0.name == "com.myapp.network" })
        XCTAssertTrue(net.isWaiting)
        XCTAssertEqual(net.leafSymbol, "__select")
    }

    func testClassifiesWaitingThreads() throws {
        let report = try XCTUnwrap(SampleDigest.parse(busy))
        let net = try XCTUnwrap(report.threads.first { $0.name == "com.myapp.network" })
        XCTAssertTrue(net.isWaiting)
        XCTAssertEqual(net.leafSymbol, "__select")
    }

    func testHandlesBinaryNameWithParens() throws {
        let report = try XCTUnwrap(SampleDigest.parse(idle))
        XCTAssertEqual(report.process, "Google Chrome Helper (Renderer) [80226]")
        XCTAssertEqual(report.threads.count, 2)
        // Both threads are parked, so nothing is on-CPU.
        XCTAssertEqual(report.onCPU.count, 0)
        let main = try XCTUnwrap(report.threads.first)
        XCTAssertEqual(main.leafBinary, "libsystem_kernel.dylib")
    }

    func testDigestHighlightsOnCPUWork() throws {
        let digest = try XCTUnwrap(
            SampleDigest.make(from: busy, fallbackName: "MyBuggyApp", pid: 4242))
        XCTAssertTrue(digest.contains("On-CPU threads"))
        XCTAssertTrue(digest.contains("-[Parser parseObject]"))
        XCTAssertTrue(digest.contains("call path:"))
    }

    func testDigestReportsAllIdle() throws {
        let digest = try XCTUnwrap(
            SampleDigest.make(from: idle, fallbackName: "Chrome", pid: 80226))
        XCTAssertTrue(digest.contains("No thread was on-CPU"))
    }

    func testReturnsNilWithoutCallGraph() {
        XCTAssertNil(SampleDigest.parse("sample cannot examine process 42: try as root"))
    }
}
