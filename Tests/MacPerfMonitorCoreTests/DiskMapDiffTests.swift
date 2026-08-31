import XCTest

@testable import MacPerfMonitorCore

final class DiskMapDiffTests: XCTestCase {
    private let mb: UInt64 = 1024 * 1024

    /// Builds root/{Docs/{a,b}, Media/{clip}, extras...} with the given sizes.
    private func snapshot(
        docsA: UInt64, docsB: UInt64, clip: UInt64, extra: [(String, UInt64)] = [],
        mediaPresent: Bool = true, at date: Date
    ) -> DiskMapSnapshot {
        let b = FileTreeBuilder()
        b.appendRoot(name: "root", fileID: 1, modified: 0, flags: [])
        func e(_ name: String, _ bytes: UInt64, dir: Bool = false) -> FileTreeBuilder.Entry {
            FileTreeBuilder.Entry(
                name: ArraySlice(name.utf8), bytes: bytes, count: 1,
                flags: dir ? [.directory] : [], kind: dir ? .folder : .other)
        }
        var top = [e("Docs", 0, dir: true)]
        if mediaPresent { top.append(e("Media", 0, dir: true)) }
        for (name, bytes) in extra { top.append(e(name, bytes)) }
        let range = b.appendChildren(of: 0, top)
        b.appendChildren(of: range.lowerBound, [e("a", docsA), e("b", docsB)])
        if mediaPresent {
            let media = range.lowerBound + 1
            let sub = b.appendChildren(of: media, [e("Raw", 0, dir: true), e("clip", clip)])
            b.appendChildren(of: sub.lowerBound, [e("r1", 20 * mb), e("r2", 20 * mb)])
        }
        let tree = b.build()
        return DiskMapSnapshot(
            scope: .folder("/x"), rootPath: "/x", tree: tree,
            reconciliation: DiskMapReconciliation.compute(
                scope: .folder("/x"), mountPoint: "/", volume: nil, allVolumes: [], usedBefore: nil,
                scannedBytes: tree.bytes[0], sharedBytes: 0, scannedItems: 0,
                counts: DiskMapScanCounts(), localSnapshotCount: nil),
            scannedAt: date, duration: 0, partial: false, smallFileThreshold: 0, revision: 1)
    }

    func testGrowthShrinkageNewAndGone() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        let previous = snapshot(docsA: 100 * mb, docsB: 50 * mb, clip: 500 * mb, at: earlier)
        let current = snapshot(
            docsA: 400 * mb, docsB: 50 * mb, clip: 300 * mb, extra: [("new.iso", 1_000 * mb)],
            at: later)
        let diff = DiskMapDiff.compute(current: current, previous: previous)

        XCTAssertEqual(diff.previousScannedAt, earlier)
        XCTAssertEqual(diff.currentScannedAt, later)
        XCTAssertEqual(diff.totalBefore, 690 * mb)
        XCTAssertEqual(diff.totalAfter, 1_790 * mb)
        XCTAssertEqual(diff.totalDelta, Int64(1_100 * mb))

        let grownPaths = diff.grown.map(\.relativePath)
        XCTAssertEqual(grownPaths.first, "", "the root grew the most")
        XCTAssertTrue(grownPaths.contains("new.iso"))
        XCTAssertTrue(grownPaths.contains("Docs"))
        XCTAssertTrue(grownPaths.contains("Docs/a"))
        XCTAssertFalse(grownPaths.contains("Docs/b"), "unchanged files are not listed")
        let newISO = diff.grown.first { $0.relativePath == "new.iso" }!
        XCTAssertTrue(newISO.isNew)
        XCTAssertEqual(newISO.delta, Int64(1_000 * mb))
        XCTAssertNotNil(newISO.node)
        let docs = diff.grown.first { $0.relativePath == "Docs" }!
        XCTAssertTrue(docs.isDirectory)
        XCTAssertEqual(docs.before, 150 * mb)
        XCTAssertEqual(docs.after, 450 * mb)

        let shrunkPaths = diff.shrunk.map(\.relativePath)
        XCTAssertEqual(
            shrunkPaths, ["Media", "Media/clip"], "largest shrink first, sub-folder unchanged")
        XCTAssertEqual(diff.shrunk[1].delta, -Int64(200 * mb))
    }

    func testGoneItemsListOnlyTheTopMostPath() {
        let previous = snapshot(docsA: 100 * mb, docsB: 50 * mb, clip: 500 * mb, at: Date())
        let current = snapshot(
            docsA: 100 * mb, docsB: 50 * mb, clip: 0, mediaPresent: false, at: Date())
        let diff = DiskMapDiff.compute(current: current, previous: previous)
        let gone = diff.shrunk.filter(\.isGone)
        XCTAssertEqual(gone.map(\.relativePath), ["Media"], "Media/Raw and Media/clip went with it")
        XCTAssertEqual(gone.first?.before, 540 * mb)
        XCTAssertNil(gone.first?.node)
        XCTAssertTrue(diff.grown.isEmpty)
    }

    func testThresholdAndLimit() {
        let previous = snapshot(docsA: 100 * mb, docsB: 50 * mb, clip: 500 * mb, at: Date())
        let current = snapshot(docsA: 100 * mb + 5 * mb, docsB: 50 * mb, clip: 500 * mb, at: Date())
        let quiet = DiskMapDiff.compute(current: current, previous: previous)
        XCTAssertTrue(quiet.grown.isEmpty, "a 5 MB move is below the 10 MB default")
        let sensitive = DiskMapDiff.compute(current: current, previous: previous, minimumDelta: mb)
        XCTAssertEqual(sensitive.grown.map(\.relativePath), ["", "Docs", "Docs/a"])
        let capped = DiskMapDiff.compute(
            current: current, previous: previous, minimumDelta: mb, limit: 1)
        XCTAssertEqual(capped.grown.count, 1)
    }

    func testIdenticalScansHaveNoEntries() {
        let a = snapshot(docsA: 100 * mb, docsB: 50 * mb, clip: 500 * mb, at: Date())
        let diff = DiskMapDiff.compute(current: a, previous: a)
        XCTAssertTrue(diff.grown.isEmpty)
        XCTAssertTrue(diff.shrunk.isEmpty)
        XCTAssertEqual(diff.totalDelta, 0)
    }

    func testIndexSkipsSmallFilesFoldsAndTrashedItems() {
        var current = snapshot(docsA: 100 * mb, docsB: 50 * mb, clip: 500 * mb, at: Date())
        let clip = Int32(
            (0..<current.tree.nodeCount).first { current.tree.name(of: Int32($0)) == "clip" }!)
        current.tree.markTrashed(clip)
        let index = DiskMapDiff.index(current.tree, minimumBytes: 30 * mb)
        XCTAssertNil(index["Media/clip"], "trashed items are not compared")
        XCTAssertNil(index["Media/Raw/r1"], "below the threshold")
        XCTAssertNotNil(index["Media/Raw"])
        XCTAssertEqual(index["Media"]?.bytes, 40 * mb, "the trashed clip left the folder total")
    }
}
