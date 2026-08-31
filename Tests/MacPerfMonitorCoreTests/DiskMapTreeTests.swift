import XCTest

@testable import MacPerfMonitorCore

final class DiskMapTreeTests: XCTestCase {
    private func entry(
        _ name: String, bytes: UInt64, directory: Bool = false, kind: FileKind = .other,
        shared: UInt64 = 0, count: UInt32 = 1
    ) -> FileTreeBuilder.Entry {
        FileTreeBuilder.Entry(
            name: ArraySlice(name.utf8), bytes: bytes, shared: shared,
            fileID: UInt64(name.hashValue.magnitude),
            modified: 1_700_000_000, count: count, flags: directory ? [.directory] : [],
            kind: directory ? .folder : kind)
    }

    /// root
    ///   a/            (dir)
    ///     a1  100
    ///     a2  200
    ///   b/            (dir)
    ///     b1  1000
    ///   c   50
    private func sampleTree() -> FileTree {
        let builder = FileTreeBuilder()
        builder.appendRoot(name: "root", fileID: 1, modified: 0, flags: [])
        let top = builder.appendChildren(
            of: 0,
            [
                entry("a", bytes: 0, directory: true), entry("b", bytes: 0, directory: true),
                entry("c", bytes: 50),
            ])
        XCTAssertEqual(top, 1..<4)
        builder.appendChildren(of: 1, [entry("a1", bytes: 100), entry("a2", bytes: 200)])
        builder.appendChildren(of: 2, [entry("b1", bytes: 1000, shared: 400)])
        return builder.build()
    }

    func testTotalsAccumulateUpTheChain() {
        let tree = sampleTree()
        XCTAssertEqual(tree.nodeCount, 7)
        XCTAssertEqual(tree.bytes[0], 1350)
        XCTAssertEqual(tree.bytes[1], 300)
        XCTAssertEqual(tree.bytes[2], 1000)
        XCTAssertEqual(tree.shared[0], 400)
        XCTAssertEqual(tree.shared[2], 400)
        // Root count: 3 top-level + 2 under a + 1 under b.
        XCTAssertEqual(tree.count[0], 6)
        XCTAssertEqual(tree.count[1], 3)
        XCTAssertEqual(tree.count[2], 2)
    }

    func testChildrenAreContiguousAndSortable() {
        let tree = sampleTree()
        XCTAssertEqual(tree.children(of: 0), 1..<4)
        XCTAssertEqual(tree.children(of: 1), 4..<6)
        XCTAssertEqual(tree.children(of: 2), 6..<7)
        XCTAssertEqual(tree.children(of: 3), 0..<0)
        XCTAssertEqual(tree.childrenBySize(of: 0), [2, 1, 3])
        XCTAssertTrue(tree.isDirectory(1))
        XCTAssertFalse(tree.isDirectory(3))
    }

    func testNamesPathsAncestryAndDepth() {
        let tree = sampleTree()
        XCTAssertEqual(tree.name(of: 0), "root")
        XCTAssertEqual(tree.name(of: 6), "b1")
        XCTAssertEqual(tree.path(of: 6, rootPath: "/tmp/x"), "/tmp/x/b/b1")
        XCTAssertEqual(tree.path(of: 0, rootPath: "/tmp/x"), "/tmp/x")
        XCTAssertEqual(tree.path(of: 3, rootPath: "/"), "/c")
        XCTAssertEqual(tree.ancestry(of: 6), [0, 2, 6])
        XCTAssertEqual(tree.depth(of: 6), 2)
        XCTAssertEqual(tree.depth(of: 0), 0)
        XCTAssertTrue(tree.node(6, isWithin: 2))
        XCTAssertTrue(tree.node(6, isWithin: 0))
        XCTAssertFalse(tree.node(6, isWithin: 1))
    }

    func testFoldPathIsItsParents() {
        let builder = FileTreeBuilder()
        builder.appendRoot(name: "r", fileID: 1, modified: 0, flags: [])
        builder.appendChildren(of: 0, [entry("d", bytes: 0, directory: true)])
        builder.appendChildren(
            of: 1,
            [
                FileTreeBuilder.Entry(
                    name: [], bytes: 4096, count: 30, flags: [.smallFilesFold], kind: .image)
            ])
        let tree = builder.build()
        XCTAssertEqual(tree.path(of: 2, rootPath: "/r"), "/r/d")
        XCTAssertEqual(tree.name(of: 2), "")
        XCTAssertEqual(tree.count[0], 31)
    }

    func testMarkTrashedReHomesBytes() {
        var tree = sampleTree()
        let removed = tree.markTrashed(2)
        XCTAssertEqual(removed, 1000)
        XCTAssertTrue(tree.flags[2].contains(.trashed))
        XCTAssertEqual(tree.bytes[2], 1000, "the node keeps its own figure")
        XCTAssertEqual(tree.bytes[0], 350)
        XCTAssertEqual(tree.shared[0], 0)
        XCTAssertEqual(tree.count[0], 4)
        XCTAssertEqual(tree.markTrashed(2), 0, "idempotent")
        XCTAssertEqual(tree.bytes[0], 350)
    }

    func testStructuralValidation() {
        let good = sampleTree()
        XCTAssertTrue(good.isStructurallyValid)
        XCTAssertTrue(FileTree.empty.isStructurallyValid)

        // Parent pointing forward.
        var parent = good.parent
        parent[1] = 5
        XCTAssertFalse(rebuilt(good, parent: parent).isStructurallyValid)
        // Child range out of bounds.
        var childCount = good.childCount
        childCount[2] = 40
        XCTAssertFalse(rebuilt(good, childCount: childCount).isStructurallyValid)
        // First child not after the parent.
        var firstChild = good.firstChild
        firstChild[1] = 0
        XCTAssertFalse(rebuilt(good, firstChild: firstChild).isStructurallyValid)
        // Name offsets not ending at the buffer end.
        var offsets = good.nameOffsets
        offsets[offsets.count - 1] += 1
        XCTAssertFalse(rebuilt(good, nameOffsets: offsets).isStructurallyValid)
    }

    private func rebuilt(
        _ tree: FileTree, parent: [Int32]? = nil, firstChild: [Int32]? = nil,
        childCount: [Int32]? = nil, nameOffsets: [UInt32]? = nil
    ) -> FileTree {
        FileTree(
            parent: parent ?? tree.parent, firstChild: firstChild ?? tree.firstChild,
            childCount: childCount ?? tree.childCount, bytes: tree.bytes, shared: tree.shared,
            fileID: tree.fileID, modified: tree.modified, count: tree.count, flags: tree.flags,
            kind: tree.kind, nameOffsets: nameOffsets ?? tree.nameOffsets,
            nameBytes: tree.nameBytes)
    }

    func testPreviewPrunesAndAggregates() {
        let builder = FileTreeBuilder()
        builder.appendRoot(name: "r", fileID: 1, modified: 0, flags: [])
        builder.appendChildren(
            of: 0,
            [
                entry("big", bytes: 0, directory: true), entry("mid", bytes: 500),
                entry("tiny1", bytes: 1), entry("tiny2", bytes: 2),
            ])
        builder.appendChildren(of: 1, [entry("x", bytes: 5000), entry("y", bytes: 10)])
        let preview = builder.preview(depthLimit: 3, minimumBytes: 100, maxChildren: 10)
        XCTAssertEqual(preview.bytes, 5513)
        XCTAssertEqual(preview.children.map(\.name), ["big", "mid"])
        XCTAssertEqual(preview.omittedBytes, 3)
        XCTAssertEqual(preview.omittedCount, 2)
        XCTAssertEqual(preview.children[0].children.map(\.name), ["x"])
        XCTAssertEqual(preview.children[0].omittedBytes, 10)

        let capped = builder.preview(depthLimit: 0, minimumBytes: 0, maxChildren: 10)
        XCTAssertTrue(capped.children.isEmpty, "depth 0 keeps only the root")
        XCTAssertEqual(capped.omittedBytes, 0, "nothing was sorted through at depth 0")
    }

    func testEmptyBuilderPreviewDoesNotCrash() {
        let preview = FileTreeBuilder().preview(depthLimit: 2, minimumBytes: 0, maxChildren: 4)
        XCTAssertEqual(preview.bytes, 0)
        XCTAssertTrue(preview.children.isEmpty)
    }
}
