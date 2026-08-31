import XCTest

@testable import MacPerfMonitorCore

final class TreemapLayoutTests: XCTestCase {
    private let bounds = TreemapRect(x: 10, y: 20, width: 600, height: 400)

    private func assertTiles(
        _ rects: [TreemapRect], weights: [Double], file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let total = weights.reduce(0, +)
        XCTAssertEqual(rects.count, weights.count, file: file, line: line)
        var areaSum = 0.0
        for (rect, weight) in zip(rects, weights) {
            XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - 0.001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.001, file: file, line: line)
            let expected = bounds.area * weight / total
            XCTAssertEqual(
                rect.area, expected, accuracy: max(0.5, expected * 0.002), file: file, line: line)
            areaSum += rect.area
        }
        XCTAssertEqual(areaSum, bounds.area, accuracy: 1, file: file, line: line)
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count where rects[i].area > 0 && rects[j].area > 0 {
                let a = rects[i]
                let b = rects[j]
                let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                XCTAssertFalse(
                    overlapX > 0.01 && overlapY > 0.01, "cells \(i) and \(j) overlap", file: file,
                    line: line)
            }
        }
    }

    func testAreasTileTheBoundsInOrderWithoutOverlap() {
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(weights: weights, in: bounds)
        assertTiles(rects, weights: weights)
        // The first (largest) item sits at the origin corner.
        XCTAssertEqual(rects[0].minX, bounds.minX, accuracy: 0.001)
        XCTAssertEqual(rects[0].minY, bounds.minY, accuracy: 0.001)
    }

    func testEqualWeightsStayNearSquare() {
        let weights = [Double](repeating: 1, count: 16)
        let rects = TreemapLayout.squarify(weights: weights, in: bounds)
        assertTiles(rects, weights: weights)
        for rect in rects {
            let ratio = max(rect.width / rect.height, rect.height / rect.width)
            XCTAssertLessThan(ratio, 2.6)
        }
    }

    func testSingleAndZeroWeights() {
        XCTAssertEqual(TreemapLayout.squarify(weights: [5], in: bounds), [bounds])
        let mixed = TreemapLayout.squarify(weights: [3, 0, 1], in: bounds)
        assertTiles(mixed, weights: [3, 0, 1])
        XCTAssertEqual(mixed[1].area, 0)
        let allZero = TreemapLayout.squarify(weights: [0, 0], in: bounds)
        XCTAssertTrue(allZero.allSatisfy { $0.area == 0 })
        XCTAssertTrue(TreemapLayout.squarify(weights: [], in: bounds).isEmpty)
        let noRoom = TreemapLayout.squarify(weights: [1, 2], in: .zero)
        XCTAssertTrue(noRoom.allSatisfy { $0.area == 0 })
    }

    func testTallBoundsLayRowsAlongTheTop() {
        let tall = TreemapRect(x: 0, y: 0, width: 100, height: 400)
        let rects = TreemapLayout.squarify(weights: [1, 1, 1, 1], in: tall)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, tall.area, accuracy: 0.5)
        XCTAssertEqual(rects[0].minY, 0, accuracy: 0.001)
        XCTAssertEqual(rects[0].width, 100, accuracy: 0.001)
    }

    func testManyWeightsFinishQuickly() {
        var weights: [Double] = []
        var value = 1_000_000.0
        for _ in 0..<2000 {
            weights.append(value)
            value *= 0.997
        }
        let started = Date()
        let rects = TreemapLayout.squarify(weights: weights, in: bounds)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, bounds.area, accuracy: 2)
    }

    // MARK: - Scene

    /// root
    ///   big/            60 (dir)
    ///     b1 40, b2 15, b3 5
    ///   App.app/        30 (package dir)
    ///     Contents/ 30 (dir) -> bin 30
    ///   loose 9
    ///   tiny1 .. tiny40  (1 byte each, folded into aggregate at small sizes)
    private func sampleTree() -> FileTree {
        let builder = FileTreeBuilder()
        builder.appendRoot(name: "root", fileID: 1, modified: 0, flags: [])
        func e(
            _ name: String, _ bytes: UInt64, dir: Bool = false, flags: FileNodeFlags = []
        )
            -> FileTreeBuilder.Entry
        {
            FileTreeBuilder.Entry(
                name: ArraySlice(name.utf8), bytes: bytes, count: 1,
                flags: dir ? flags.union(.directory) : flags, kind: dir ? .folder : .other)
        }
        var top = [
            e("big", 0, dir: true), e("App.app", 0, dir: true, flags: [.package]), e("loose", 9),
        ]
        for i in 0..<40 { top.append(e("tiny\(i)", 1)) }
        builder.appendChildren(of: 0, top)
        builder.appendChildren(of: 1, [e("b1", 40), e("b2", 15), e("b3", 5)])
        builder.appendChildren(of: 2, [e("Contents", 0, dir: true)])
        let contents = builder.childRange(of: 2).lowerBound
        builder.appendChildren(of: contents, [e("bin", 30)])
        return builder.build()
    }

    private func node(_ tree: FileTree, _ name: String) -> Int32 {
        Int32((0..<tree.nodeCount).first { tree.name(of: Int32($0)) == name }!)
    }

    func testSceneSubdividesDirectoriesButNotPackages() {
        let tree = sampleTree()
        let scene = TreemapScene.build(
            tree: tree, root: 0, bounds: TreemapRect(x: 0, y: 0, width: 800, height: 600))
        let byNode = Dictionary(grouping: scene.cells, by: \.node)
        XCTAssertTrue(byNode[1]!.first!.isSubdivided, "big is a plain directory")
        XCTAssertNotNil(byNode[1]!.first!.labelStrip)
        XCTAssertFalse(byNode[2]!.first!.isSubdivided, "packages stay leaves")
        // big's children are drawn inside big's cell.
        let big = byNode[1]!.first!.rect
        for child in scene.children(of: 1) {
            XCTAssertGreaterThanOrEqual(child.rect.minX, big.minX - 0.01)
            XCTAssertLessThanOrEqual(child.rect.maxX, big.maxX + 0.01)
            XCTAssertGreaterThanOrEqual(child.rect.minY, big.minY + 16 - 0.01, "below the strip")
            XCTAssertEqual(child.depth, 1)
        }
        XCTAssertEqual(scene.children(of: 1).count, 3)
        // Parents precede their children in draw order.
        let bigIndex = scene.cells.firstIndex { $0.node == 1 }!
        for child in scene.children(of: 1) {
            XCTAssertGreaterThan(scene.cells.firstIndex(of: child)!, bigIndex)
        }
        // Every cell lies within the bounds.
        for cell in scene.cells {
            XCTAssertGreaterThanOrEqual(cell.rect.minX, -0.01)
            XCTAssertLessThanOrEqual(cell.rect.maxX, 800.01)
            XCTAssertLessThanOrEqual(cell.rect.maxY, 600.01)
        }
    }

    func testTinyChildrenFoldIntoAnExactAggregate() {
        let tree = sampleTree()
        // A small canvas: the 40 one-byte files cannot each get 12 pt² and
        // fold into one aggregate cell carrying their exact bytes and count.
        let scene = TreemapScene.build(
            tree: tree, root: 0, bounds: TreemapRect(x: 0, y: 0, width: 40, height: 30))
        let aggregate = scene.cells.first { $0.isAggregate && $0.parent == 0 }
        XCTAssertNotNil(aggregate)
        XCTAssertEqual(aggregate?.aggregateBytes, 40)
        XCTAssertEqual(aggregate?.aggregateCount, 40)
        XCTAssertFalse(
            scene.cells.contains {
                !$0.isAggregate && tree.name(of: $0.node).hasPrefix("tiny")
            })
    }

    func testDepthLimitAndHitTesting() {
        let tree = sampleTree()
        var options = TreemapSceneOptions()
        options.depthLimit = 1
        let shallow = TreemapScene.build(
            tree: tree, root: 0, bounds: TreemapRect(x: 0, y: 0, width: 800, height: 600),
            options: options)
        XCTAssertTrue(shallow.cells.allSatisfy { $0.depth == 0 && !$0.isSubdivided })

        let scene = TreemapScene.build(
            tree: tree, root: 0, bounds: TreemapRect(x: 0, y: 0, width: 800, height: 600))
        let b1Node = node(tree, "b1")
        let b1 = scene.cell(for: b1Node)!
        let hit = scene.hitTest(x: b1.rect.midX, y: b1.rect.midY)
        XCTAssertEqual(hit?.node, b1Node, "the deepest cell wins")
        let bigStrip = scene.cell(for: 1)!.labelStrip!
        XCTAssertEqual(
            scene.hitTest(x: bigStrip.midX, y: bigStrip.midY)?.node, 1, "the strip is the directory"
        )
        XCTAssertNil(scene.hitTest(x: -5, y: -5))
        XCTAssertNil(scene.hitTest(x: 5000, y: 5))
    }

    func testZoomingIntoADirectoryTilesItsChildren() {
        let tree = sampleTree()
        let scene = TreemapScene.build(
            tree: tree, root: 1, bounds: TreemapRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(scene.root, 1)
        XCTAssertEqual(
            Set(scene.cells.map(\.node)), [node(tree, "b1"), node(tree, "b2"), node(tree, "b3")])
        XCTAssertEqual(
            scene.cells.reduce(0) { $0 + $1.rect.area }, 300 * 200, accuracy: 300 * 200 * 0.02,
            "gutters only")
        XCTAssertEqual(scene.cells[0].node, node(tree, "b1"), "largest first")
    }

    func testEmptyAndInvalidInputs() {
        XCTAssertTrue(
            TreemapScene.build(
                tree: .empty, root: 0, bounds: TreemapRect(x: 0, y: 0, width: 10, height: 10)
            ).cells.isEmpty)
        let tree = sampleTree()
        XCTAssertTrue(
            TreemapScene.build(
                tree: tree, root: 99, bounds: TreemapRect(x: 0, y: 0, width: 10, height: 10)
            ).cells.isEmpty)
        XCTAssertTrue(TreemapScene.build(tree: tree, root: 0, bounds: .zero).cells.isEmpty)
        XCTAssertTrue(
            TreemapScene.build(
                tree: tree, root: 3, bounds: TreemapRect(x: 0, y: 0, width: 10, height: 10)
            ).cells.isEmpty, "a file has nothing to tile")
    }
}
