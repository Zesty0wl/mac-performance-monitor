import XCTest

@testable import MacPerfMonitorCore

/// Parser tests for the memory inspector. Fixtures are REAL output captured from
/// `/usr/bin/{footprint,heap,leaks}` on macOS 26.5.1, so the parsers are pinned
/// to the actual tool format rather than a guessed one.
final class MemoryInspectionTests: XCTestCase {

    // MARK: footprint

    private let footprintOutput = """
        ==================================================================
        MacPerfMonitor [14047]: 64-bit    Footprint: 195 MB (16384 bytes per page)
        ==================================================================

          Dirty      Clean  Reclaimable    Regions    Category
            ---        ---          ---        ---    ---
          90 MB        0 B          0 B         44    Owned physical footprint (unmapped) (graphics)
          58 MB        0 B          0 B         88    MALLOC_SMALL
          17 MB        0 B          0 B         28    IOSurface
        6592 KB        0 B          0 B         89    IOAccelerator (graphics)
        3013 KB      16 KB          0 B       1001    __DATA
           304 KB        0 B          0 B          1    MALLOC_TINY
        """

    func testParseFootprintTotalAndRegions() {
        guard let snap = MemoryInspection.parseFootprint(footprintOutput) else {
            return XCTFail("expected a footprint snapshot")
        }
        XCTAssertEqual(snap.totalBytes, 195 * 1024 * 1024)
        XCTAssertEqual(snap.regions.count, 6)
        // Sorted by dirty bytes descending, so the 90 MB graphics region is first.
        XCTAssertEqual(
            snap.regions.first?.category, "Owned physical footprint (unmapped) (graphics)")
        XCTAssertEqual(snap.regions.first?.dirtyBytes, 90 * 1024 * 1024)
        XCTAssertEqual(snap.regions.first?.regionCount, 44)

        let malloc = snap.regions.first { $0.category == "MALLOC_SMALL" }
        XCTAssertEqual(malloc?.dirtyBytes, 58 * 1024 * 1024)
        XCTAssertEqual(malloc?.regionCount, 88)

        // A row with a non-zero clean column parses all three sizes.
        let data = snap.regions.first { $0.category == "__DATA" }
        XCTAssertEqual(data?.dirtyBytes, 3013 * 1024)
        XCTAssertEqual(data?.cleanBytes, 16 * 1024)
        XCTAssertEqual(data?.reclaimableBytes, 0)
    }

    func testParseFootprintIgnoresHeaderAndSeparatorRows() {
        let snap = MemoryInspection.parseFootprint(footprintOutput)
        // "Dirty Clean Reclaimable Regions Category" and the "---" rule must not
        // become regions.
        XCTAssertFalse(snap?.regions.contains { $0.category.contains("Category") } ?? true)
        XCTAssertFalse(snap?.regions.contains { $0.category == "---" } ?? true)
    }

    func testParseFootprintReturnsNilOnPrivilegeError() {
        let err = """
            footprint: Unable to find pid for process matching '613'
            footprint: Unable to find any processes matching the supplied process names or pids (try as root?)
            """
        XCTAssertNil(MemoryInspection.parseFootprint(err))
    }

    // MARK: heap

    private let heapOutput = """
        Process:         MacPerfMonitor [14047]
        Path:            /Applications/Mac Performance Monitor.app/Contents/MacOS/MacPerfMonitor
        Physical footprint:         289.4M
        Physical footprint (peak):  295.1M
        ----

        Process 14047: 6 zones
        Found:  1643 ObjC classes  2656 Swift classes  219 C++ classes  269 CFTypes

        ------------------------------------------------------------------------
        All zones: 202503 nodes (47995927 bytes)

           COUNT      BYTES       AVG   CLASS_NAME                        TYPE    BINARY
           =====      =====       ===   ==========                        ====    ======
           73126   25846913     353.5   non-object
            6014     316480      52.6   CFString                          ObjC    CoreFoundation
            5800     185600      32.0   Class.data (class_rw_t)           C       libobjc.A.dylib
            5540     892512     161.1   Closure context                   Swift   <unknown>
            2663     213040      80.0   LocalizedTextStorage              Swift   SwiftUICore
        """

    func testParseHeapTotals() {
        guard let snap = MemoryInspection.parseHeap(heapOutput) else {
            return XCTFail("expected a heap snapshot")
        }
        XCTAssertEqual(snap.totalNodes, 202503)
        XCTAssertEqual(snap.totalBytes, 47_995_927)
    }

    func testParseHeapClassRows() {
        guard let snap = MemoryInspection.parseHeap(heapOutput) else {
            return XCTFail("expected a heap snapshot")
        }
        // Sorted by bytes descending: non-object (25.8M) leads.
        XCTAssertEqual(snap.classes.first?.className, "non-object")
        XCTAssertEqual(snap.classes.first?.instanceCount, 73126)
        XCTAssertEqual(snap.classes.first?.type, "")  // non-object has no type/binary
        XCTAssertEqual(snap.classes.first?.binary, "")

        let cfString = snap.classes.first { $0.className == "CFString" }
        XCTAssertEqual(cfString?.instanceCount, 6014)
        XCTAssertEqual(cfString?.totalBytes, 316480)
        XCTAssertEqual(cfString?.type, "ObjC")
        XCTAssertEqual(cfString?.binary, "CoreFoundation")
    }

    func testParseHeapClassNameWithSpaces() {
        let snap = MemoryInspection.parseHeap(heapOutput)
        // "Class.data (class_rw_t)" — a class name containing spaces and parens —
        // must not bleed into the TYPE/BINARY columns.
        let cls = snap?.classes.first { $0.className == "Class.data (class_rw_t)" }
        XCTAssertNotNil(cls)
        XCTAssertEqual(cls?.type, "C")
        XCTAssertEqual(cls?.binary, "libobjc.A.dylib")

        // A class name (LocalizedTextStorage) whose BINARY also contains "Swift"
        // must still resolve type and binary correctly.
        let localized = snap?.classes.first { $0.className == "LocalizedTextStorage" }
        XCTAssertEqual(localized?.type, "Swift")
        XCTAssertEqual(localized?.binary, "SwiftUICore")
    }

    func testParseHeapDoesNotMisparseFoundOrZoneLines() {
        let snap = MemoryInspection.parseHeap(heapOutput)
        // The "Found: 1643 ObjC classes ..." and "Process 14047: 6 zones" lines
        // begin with text, so they must not become census rows.
        XCTAssertEqual(snap?.classes.count, 5)
    }

    // MARK: leaks

    func testParseLeaksNotDebuggable() {
        let output = """
            Process 14047 is not debuggable. Due to security restrictions, leaks can only show or save contents of readonly memory of restricted processes.

            Process:         MacPerfMonitor [14047]
            leaks Report Version: 4.0
            Process 14047: 201626 nodes malloced for 46857 KB
            Process 14047: 0 leaks for 0 total leaked bytes.
            """
        guard let summary = MemoryInspection.parseLeaks(output) else {
            return XCTFail("expected a leaks summary")
        }
        XCTAssertFalse(summary.isDebuggable)
        XCTAssertEqual(summary.totalNodes, 201626)
        XCTAssertEqual(summary.totalBytes, 46857 * 1024)
        XCTAssertEqual(summary.leakCount, 0)
        XCTAssertEqual(summary.leakedBytes, 0)
    }

    func testParseLeaksWithLeaksFound() {
        let output = """
            leaks Report Version: 4.0
            Process 500: 1000 nodes malloced for 200 KB
            Process 500: 3 leaks for 4096 total leaked bytes.
            """
        guard let summary = MemoryInspection.parseLeaks(output) else {
            return XCTFail("expected a leaks summary")
        }
        XCTAssertTrue(summary.isDebuggable)
        XCTAssertEqual(summary.leakCount, 3)
        XCTAssertEqual(summary.leakedBytes, 4096)
    }

    func testParseLeaksReturnsNilOnPrivilegeError() {
        let err = "leaks cannot examine process 613 because you do not have appropriate privileges"
        XCTAssertNil(MemoryInspection.parseLeaks(err))
    }

    // MARK: leaks significance (don't cry wolf on tiny framework leaks)

    func testLeaksSignificanceNoneWhenZero() {
        let s = MemoryInspection.LeaksSummary(
            totalNodes: 1000, totalBytes: 200 * 1024, leakCount: 0, leakedBytes: 0,
            isDebuggable: true)
        XCTAssertEqual(s.significance, .none)
    }

    func testLeaksSignificanceMinorForSmallLeaks() {
        // The reported screenshot case: a couple of small leaks is background
        // noise present in almost every process, not an actionable warning.
        let s = MemoryInspection.LeaksSummary(
            totalNodes: 600_000, totalBytes: 100_000 * 1024, leakCount: 2, leakedBytes: 368,
            isDebuggable: false)
        XCTAssertEqual(s.significance, .minor)
    }

    func testLeaksSignificanceNotableForLargeVolume() {
        let s = MemoryInspection.LeaksSummary(
            totalNodes: 1000, totalBytes: 0, leakCount: 5, leakedBytes: 4 * 1024 * 1024,
            isDebuggable: true)
        XCTAssertEqual(s.significance, .notable)
    }

    func testLeaksSignificanceNotableForManyBlocks() {
        let s = MemoryInspection.LeaksSummary(
            totalNodes: 1000, totalBytes: 0, leakCount: 250, leakedBytes: 5000,
            isDebuggable: true)
        XCTAssertEqual(s.significance, .notable)
    }

    func testLeaksSignificanceMinorForHighCountWhenNotDebuggable() {
        // The reported Music case: 934 blocks / 64.7 KB on a hardened Apple app
        // (not debuggable). leaks falls back to a conservative scan it can't
        // fully resolve, so it over-reports; a one-shot count here must NEVER be
        // flagged as notable no matter how high, or the inspector cries wolf on
        // core system/Apple apps.
        let s = MemoryInspection.LeaksSummary(
            totalNodes: 1_029_356, totalBytes: 447 * 1024 * 1024, leakCount: 934,
            leakedBytes: 64_700, isDebuggable: false)
        XCTAssertEqual(s.significance, .minor)
    }

    // MARK: privilege detection

    func testIndicatesPrivilegeFailure() {
        XCTAssertTrue(
            MemoryInspection.indicatesPrivilegeFailure(
                "heap[18990]: heap cannot examine process 613 (WindowServer) because you do not have appropriate privileges to examine it; try running with `sudo`."
            ))
        XCTAssertTrue(
            MemoryInspection.indicatesPrivilegeFailure(
                "footprint: Unable to find pid for process matching '613' (try as root?)"))
        XCTAssertFalse(
            MemoryInspection.indicatesPrivilegeFailure(
                "All zones: 202503 nodes (47995927 bytes)"))
    }

    // MARK: byte parsing

    func testParseBytesSpacedAndCompact() {
        XCTAssertEqual(MemoryInspection.parseBytes("90 MB"), 90 * 1024 * 1024)
        XCTAssertEqual(MemoryInspection.parseBytes("0 B"), 0)
        XCTAssertEqual(MemoryInspection.parseBytes("6592 KB"), 6592 * 1024)
        XCTAssertEqual(
            MemoryInspection.parseBytes("121.1M"), UInt64((121.1 * 1024 * 1024).rounded()))
        XCTAssertEqual(
            MemoryInspection.parseBytes("289.4M"), UInt64((289.4 * 1024 * 1024).rounded()))
        XCTAssertNil(MemoryInspection.parseBytes(""))
        XCTAssertNil(MemoryInspection.parseBytes("n/a"))
    }

    func testParseBytesReturnsNilInsteadOfTrappingOnBadValues() {
        // The value is parsed straight from a tool token, so it can be
        // negative, infinite, NaN, or larger than UInt64 can hold. Each of
        // these used to reach `UInt64((value * multiplier).rounded())`, which
        // traps (fatal error) on a non-representable Double; the contract is to
        // return nil. A trap here would abort the whole memory inspector.
        XCTAssertNil(MemoryInspection.parseBytes("-1 B"))
        XCTAssertNil(MemoryInspection.parseBytes("-5 MB"))
        XCTAssertNil(MemoryInspection.parseBytes("inf"))
        XCTAssertNil(MemoryInspection.parseBytes("1e30 B"))
        XCTAssertNil(MemoryInspection.parseBytes("nan"))
        // Normal parsing is unaffected by the safe conversion.
        XCTAssertEqual(MemoryInspection.parseBytes("90 MB"), 90 * 1024 * 1024)
        XCTAssertEqual(MemoryInspection.parseBytes("0 B"), 0)
    }

    // MARK: heap diff (leak-suspect ranking)

    func testDiffHeapRanksGrowthDescending() {
        let baseline = MemoryInspection.HeapSnapshot(
            totalNodes: 100, totalBytes: 1000,
            classes: [
                .init(
                    className: "Node", instanceCount: 10, totalBytes: 320, type: "Swift",
                    binary: "App"),
                .init(
                    className: "Stable", instanceCount: 5, totalBytes: 160, type: "Swift",
                    binary: "App"),
                .init(
                    className: "Shrinking", instanceCount: 8, totalBytes: 256, type: "ObjC",
                    binary: "Foundation"),
            ])
        let current = MemoryInspection.HeapSnapshot(
            totalNodes: 200, totalBytes: 2000,
            classes: [
                .init(
                    className: "Node", instanceCount: 73, totalBytes: 2336, type: "Swift",
                    binary: "App"),
                .init(
                    className: "Stable", instanceCount: 5, totalBytes: 160, type: "Swift",
                    binary: "App"),
                .init(
                    className: "Shrinking", instanceCount: 2, totalBytes: 64, type: "ObjC",
                    binary: "Foundation"),
                .init(
                    className: "BrandNew", instanceCount: 4, totalBytes: 128, type: "C",
                    binary: "libnew"),
            ])

        let deltas = MemoryInspection.diffHeap(baseline: baseline, current: current)
        // Only classes that grew appear: Node (+63) and BrandNew (+4). Stable
        // (unchanged) and Shrinking (-6) are omitted.
        XCTAssertEqual(deltas.map(\.className), ["Node", "BrandNew"])
        XCTAssertEqual(deltas.first?.countDelta, 63)
        XCTAssertEqual(deltas.first?.bytesDelta, 2336 - 320)
        XCTAssertEqual(deltas.last?.className, "BrandNew")
        XCTAssertEqual(deltas.last?.baselineCount, 0)
        XCTAssertEqual(deltas.last?.countDelta, 4)
    }
}
