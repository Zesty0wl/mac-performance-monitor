import Darwin
import XCTest

@testable import MacPerfMonitorCore

final class DiskMapSnapshotCodecTests: XCTestCase {
    private var root: URL!
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskMapCodecTests-\(UUID().uuidString)", isDirectory: true)
        storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        let tree = root.appendingPathComponent("tree/a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 70_000).write(to: tree.appendingPathComponent("big.mov"))
        for i in 0..<30 {
            try Data(repeating: 2, count: 10 + i).write(
                to: tree.appendingPathComponent("s\(i).txt"))
        }
        try Data(repeating: 3, count: 5_000).write(
            to: root.appendingPathComponent("tree/日本語.jpg"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func scan(threshold: UInt64 = 16_384) throws -> DiskMapSnapshot {
        try DiskMapScanner().scanBlocking(
            .folder(root.appendingPathComponent("tree").path),
            options: DiskMapScanOptions(
                smallFileThreshold: threshold, workerCount: 2, previewInterval: 10,
                countLocalSnapshots: false))
    }

    func testRoundTripPreservesEverything() throws {
        let original = try scan()
        let data = try DiskMapSnapshotCodec.encode(original)
        XCTAssertEqual(Array(data.prefix(4)), [0x4D, 0x50, 0x4D, 0x44])
        let decoded = try DiskMapSnapshotCodec.decode(data)

        XCTAssertEqual(decoded.scope, original.scope)
        XCTAssertEqual(decoded.rootPath, original.rootPath)
        XCTAssertEqual(
            decoded.scannedAt.timeIntervalSince1970, original.scannedAt.timeIntervalSince1970,
            accuracy: 0.000_001)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.partial, original.partial)
        XCTAssertEqual(decoded.smallFileThreshold, original.smallFileThreshold)
        XCTAssertEqual(decoded.revision, original.revision)
        XCTAssertEqual(decoded.reconciliation, original.reconciliation)

        let a = original.tree
        let b = decoded.tree
        XCTAssertEqual(b.nodeCount, a.nodeCount)
        XCTAssertEqual(b.parent, a.parent)
        XCTAssertEqual(b.firstChild, a.firstChild)
        XCTAssertEqual(b.childCount, a.childCount)
        XCTAssertEqual(b.bytes, a.bytes)
        XCTAssertEqual(b.shared, a.shared)
        XCTAssertEqual(b.fileID, a.fileID)
        XCTAssertEqual(b.modified, a.modified)
        XCTAssertEqual(b.count, a.count)
        XCTAssertEqual(b.flags, a.flags)
        XCTAssertEqual(b.kind, a.kind)
        XCTAssertEqual(b.nameOffsets, a.nameOffsets)
        XCTAssertEqual(b.nameBytes, a.nameBytes)
        XCTAssertTrue(b.isStructurallyValid)
        XCTAssertTrue(b.flags.contains { $0.contains(.smallFilesFold) }, "the fold survived")
        XCTAssertEqual(decoded.displayPath(of: 1), original.displayPath(of: 1))
    }

    func testHeaderAndPayloadCorruptionIsRejected() throws {
        let data = try DiskMapSnapshotCodec.encode(try scan())

        XCTAssertThrowsError(try DiskMapSnapshotCodec.decode(Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? DiskMapSnapshotError, .notASnapshot)
        }
        var wrongMagic = data
        wrongMagic[0] = 0x58
        XCTAssertThrowsError(try DiskMapSnapshotCodec.decode(wrongMagic)) { error in
            XCTAssertEqual(error as? DiskMapSnapshotError, .notASnapshot)
        }
        var newerVersion = data
        newerVersion[4] = 9
        XCTAssertThrowsError(try DiskMapSnapshotCodec.decode(newerVersion)) { error in
            XCTAssertEqual(error as? DiskMapSnapshotError, .unsupportedVersion(9))
        }
        let truncated = data.prefix(data.count / 2)
        XCTAssertThrowsError(try DiskMapSnapshotCodec.decode(Data(truncated))) { error in
            XCTAssertEqual(error as? DiskMapSnapshotError, .corrupt)
        }
        var badReserved = data
        badReserved[6] = 1
        XCTAssertThrowsError(try DiskMapSnapshotCodec.decode(badReserved)) { error in
            XCTAssertEqual(error as? DiskMapSnapshotError, .corrupt)
        }
    }

    func testStructurallyInvalidTreesNeverComeBack() throws {
        var snapshot = try scan()
        // A parent index pointing forward is the classic corrupt-file shape.
        var parent = snapshot.tree.parent
        parent[1] = Int32(snapshot.tree.nodeCount - 1)
        snapshot = DiskMapSnapshot(
            scope: snapshot.scope, rootPath: snapshot.rootPath,
            tree: FileTree(
                parent: parent, firstChild: snapshot.tree.firstChild,
                childCount: snapshot.tree.childCount, bytes: snapshot.tree.bytes,
                shared: snapshot.tree.shared, fileID: snapshot.tree.fileID,
                modified: snapshot.tree.modified, count: snapshot.tree.count,
                flags: snapshot.tree.flags, kind: snapshot.tree.kind,
                nameOffsets: snapshot.tree.nameOffsets, nameBytes: snapshot.tree.nameBytes),
            reconciliation: snapshot.reconciliation, scannedAt: snapshot.scannedAt,
            duration: snapshot.duration, partial: false, smallFileThreshold: 0, revision: 1)
        let data = try DiskMapSnapshotCodec.encode(snapshot)
        XCTAssertThrowsError(try DiskMapSnapshotCodec.decode(data)) { error in
            XCTAssertEqual(error as? DiskMapSnapshotError, .corrupt)
        }
    }

    func testStoreSavesLoadsAndRollsOver() throws {
        let scope = DiskMapScope.folder(root.appendingPathComponent("tree").path)
        XCTAssertNil(try DiskMapSnapshotStore.load(for: scope, in: storeDirectory))

        let first = try scan(threshold: 0)
        try DiskMapSnapshotStore.save(first, in: storeDirectory)
        let file = DiskMapSnapshotStore.url(for: scope, in: storeDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let permissions =
            try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let loaded = try XCTUnwrap(try DiskMapSnapshotStore.load(for: scope, in: storeDirectory))
        XCTAssertEqual(loaded.tree.nodeCount, first.tree.nodeCount)
        XCTAssertNil(try DiskMapSnapshotStore.load(for: scope, previous: true, in: storeDirectory))

        let second = try scan(threshold: 16_384)
        try DiskMapSnapshotStore.save(second, in: storeDirectory)
        let previous = try XCTUnwrap(
            try DiskMapSnapshotStore.load(for: scope, previous: true, in: storeDirectory))
        XCTAssertEqual(previous.tree.nodeCount, first.tree.nodeCount, "the old scan rolled over")
        let current = try XCTUnwrap(try DiskMapSnapshotStore.load(for: scope, in: storeDirectory))
        XCTAssertEqual(current.tree.nodeCount, second.tree.nodeCount)

        DiskMapSnapshotStore.remove(for: scope, in: storeDirectory)
        XCTAssertNil(try DiskMapSnapshotStore.load(for: scope, in: storeDirectory))
        XCTAssertNil(try DiskMapSnapshotStore.load(for: scope, previous: true, in: storeDirectory))
    }

    func testStoreURLsAreScopedAndSafe() {
        let a = DiskMapSnapshotStore.url(for: .startupDisk, in: storeDirectory)
        let b = DiskMapSnapshotStore.url(for: .folder("/Users/x/Movies"), in: storeDirectory)
        XCTAssertEqual(a.lastPathComponent, "startup.mpmdisk")
        XCTAssertTrue(b.lastPathComponent.hasPrefix("folder-"))
        XCTAssertEqual(b.deletingLastPathComponent(), storeDirectory)
        XCTAssertTrue(
            DiskMapSnapshotStore.url(for: .home, previous: true, in: storeDirectory)
                .lastPathComponent.hasSuffix(".prev.mpmdisk"))
    }

    // MARK: - Item facts

    func testItemFactsReadOneItem() throws {
        let file = root.appendingPathComponent("tree/a/b/big.mov").path
        let facts = try XCTUnwrap(DiskMapItemFacts.read(path: file))
        XCTAssertFalse(facts.isDirectory)
        XCTAssertEqual(facts.logicalBytes, 70_000)
        XCTAssertGreaterThanOrEqual(facts.allocatedBytes, 70_000)
        XCTAssertEqual(facts.linkCount, 1)
        if let privateBytes = facts.privateBytes {
            XCTAssertLessThanOrEqual(privateBytes, facts.allocatedBytes)
        }
        XCTAssertEqual(facts.wouldFreeBytes, facts.privateBytes ?? facts.allocatedBytes)

        let directory = try XCTUnwrap(
            DiskMapItemFacts.read(path: root.appendingPathComponent("tree/a").path))
        XCTAssertTrue(directory.isDirectory)
        XCTAssertNil(DiskMapItemFacts.read(path: root.appendingPathComponent("nope").path))
    }

    func testItemFactsSeeClones() throws {
        let original = root.appendingPathComponent("tree/a/b/big.mov").path
        let clone = root.appendingPathComponent("tree/a/b/clone.mov").path
        guard clonefile(original, clone, 0) == 0 else {
            throw XCTSkip("clonefile unsupported here")
        }
        let facts = try XCTUnwrap(DiskMapItemFacts.read(path: clone))
        XCTAssertTrue(facts.mayShareBlocks)
        XCTAssertGreaterThan(facts.sharedBytes, 0)
        XCTAssertLessThan(facts.wouldFreeBytes, facts.allocatedBytes)
    }
}
