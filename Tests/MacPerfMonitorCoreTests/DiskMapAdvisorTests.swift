import Darwin
import XCTest

@testable import MacPerfMonitorCore

final class DiskMapAdvisorTests: XCTestCase {
    private let advisor = DiskMapAdvisor(home: "/Users/test")

    private func advice(
        _ path: String, directory: Bool = true, flags: FileNodeFlags = []
    )
        -> DiskMapAdvice
    {
        advisor.advice(forCanonicalPath: path, isDirectory: directory, flags: flags)
    }

    func testExactRules() {
        XCTAssertEqual(advice("/Users/test/Library/Caches").tier, .safeToRemove)
        XCTAssertEqual(advice("/Users/test/Library/Caches").title, "User caches")
        XCTAssertEqual(
            advice("/Users/test/Library/Developer/Xcode/DerivedData").tier, .safeToRemove)
        XCTAssertEqual(advice("/Users/test/Library/Mail").tier, .managedByApp)
        XCTAssertEqual(advice("/private/var/vm").tier, .systemProtected)
        XCTAssertEqual(advice("/Users/test/Downloads").tier, .reviewBeforeRemoving)
        XCTAssertEqual(advice("/Users/test/Downloads").title, "Downloads")
    }

    func testAncestorsInherit() {
        let nested = advice(
            "/Users/test/Library/Caches/com.apple.Safari/Cache.db", directory: false)
        XCTAssertEqual(nested.tier, .safeToRemove)
        XCTAssertEqual(nested.title, "User caches")
        XCTAssertEqual(advice("/System/Library/Frameworks/Foo.framework").tier, .systemProtected)
        XCTAssertEqual(advice("/Users/test/Projects/thing").tier, .reviewBeforeRemoving)
        XCTAssertEqual(advice("/Users/test/Projects/thing").title, "Your files")
    }

    func testAnyDepthAndExtensionRules() {
        XCTAssertEqual(advice("/Users/test/Projects/app/node_modules").tier, .safeToRemove)
        XCTAssertEqual(
            advice("/Users/test/Projects/app/node_modules/left-pad", directory: true).title,
            "Dependencies (node_modules)")
        XCTAssertEqual(
            advice("/Users/test/Pictures/Photos Library.photoslibrary").tier, .managedByApp)
        XCTAssertEqual(
            advice("/Volumes/Ext/Old.photoslibrary/database", directory: false).title,
            "Photos library")
        XCTAssertEqual(advice("/Users/test/VMs/Win.pvm").tier, .managedByApp)
        XCTAssertEqual(
            advice("/Users/test/Downloads/Xcode.dmg", directory: false).title, "Disk image")
        XCTAssertEqual(
            advice("/Users/test/Downloads/Xcode.dmg", directory: false).tier, .reviewBeforeRemoving)
        // A folder named like a file rule is not a file.
        XCTAssertEqual(
            advice("/Users/test/Downloads/Xcode.dmg", directory: true).title, "Downloads")
    }

    func testWildcardFileRules() {
        let docker = advice(
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            directory: false)
        XCTAssertEqual(docker.title, "Docker disk image")
        XCTAssertEqual(docker.tier, .managedByApp)
        XCTAssertNotNil(docker.howToReclaim)
    }

    func testFlagsOverrideRules() {
        XCTAssertEqual(
            advice("/Users/test/Library/Caches/x", flags: [.restricted]).tier, .systemProtected)
        XCTAssertEqual(advice("/Users/test/Downloads/x", flags: [.dataless]).tier, .managedByApp)
        XCTAssertEqual(
            advice("/Users/test/Downloads/x", flags: [.separateVolume]).tier, .systemProtected)
        XCTAssertFalse(advice("/Users/test/Downloads/x", flags: [.immutable]).canTrash)
        XCTAssertTrue(advice("/Users/test/Downloads/x").canTrash)
    }

    func testTrashRefusals() {
        let root = "/System/Volumes/Data"
        for path in [
            "/", "/Users", "/Users/test", "/Users/test/Library", "/Applications", "/Library",
            "/System", "/System/Library", "/usr", "/usr/bin", "/private/var", "/private/var/db/x",
            "/Users/test/.Trash", "/Users/test/.Trash/old", "/Volumes/Ext/.Trashes/501/x", root,
        ] {
            XCTAssertTrue(advisor.isRefusedForTrash(canonicalPath: path, scanRoot: root), path)
        }
        for path in [
            "/Users/test/Downloads/big.zip", "/Users/test/Library/Caches/foo",
            "/usr/local/bin/tool",
            "/opt/homebrew/Cellar/node", "/Applications/Old.app", "/Users/test/Movies/clip.mov",
        ] {
            XCTAssertFalse(advisor.isRefusedForTrash(canonicalPath: path, scanRoot: root), path)
        }
    }

    // MARK: - Whole-tree analysis

    /// root (/Users/test)
    ///   Library/
    ///     Caches/ a 100, b 50          -> safe, one reclaim item (Caches)
    ///     Mail/ m 30                   -> managed
    ///   Projects/
    ///     app/
    ///       node_modules/ x 40         -> safe, reclaim item
    ///       Thing.app/ (package, application)
    ///         Contents/ icon.png 7, bin 3
    ///     clip.mov 60
    ///   Downloads/ Xcode.dmg 200       -> Downloads folder (review), dmg file (review, own rule)
    private func sampleSnapshot() -> DiskMapSnapshot {
        let b = FileTreeBuilder()
        b.appendRoot(name: "test", fileID: 1, modified: 0, flags: [])
        func e(
            _ name: String, _ bytes: UInt64, dir: Bool = false, flags: FileNodeFlags = [],
            kind: FileKind = .other
        ) -> FileTreeBuilder.Entry {
            FileTreeBuilder.Entry(
                name: ArraySlice(name.utf8), bytes: bytes, count: 1,
                flags: dir ? flags.union(.directory) : flags,
                kind: dir && kind == .other ? .folder : kind)
        }
        let top = b.appendChildren(
            of: 0,
            [e("Library", 0, dir: true), e("Projects", 0, dir: true), e("Downloads", 0, dir: true)])
        let library = top.lowerBound
        let projects = top.lowerBound + 1
        let downloads = top.lowerBound + 2
        let lib = b.appendChildren(
            of: library, [e("Caches", 0, dir: true), e("Mail", 0, dir: true)])
        b.appendChildren(of: lib.lowerBound, [e("a", 100, kind: .cache), e("b", 50, kind: .cache)])
        b.appendChildren(of: lib.lowerBound + 1, [e("m", 30, kind: .data)])
        let proj = b.appendChildren(
            of: projects, [e("app", 0, dir: true), e("clip.mov", 60, kind: .video)])
        let app = b.appendChildren(
            of: proj.lowerBound,
            [
                e("node_modules", 0, dir: true),
                e("Thing.app", 0, dir: true, flags: [.package], kind: .application),
            ])
        b.appendChildren(of: app.lowerBound, [e("x", 40, kind: .code)])
        let contents = b.appendChildren(of: app.lowerBound + 1, [e("Contents", 0, dir: true)])
        b.appendChildren(
            of: contents.lowerBound, [e("icon.png", 7, kind: .image), e("bin", 3, kind: .other)])
        b.appendChildren(of: downloads, [e("Xcode.dmg", 200, kind: .archive)])
        let tree = b.build()
        return DiskMapSnapshot(
            scope: .home, rootPath: "/Users/test", tree: tree,
            reconciliation: DiskMapReconciliation.compute(
                scope: .home, mountPoint: "/", volume: nil, allVolumes: [], usedBefore: nil,
                scannedBytes: tree.bytes[0], sharedBytes: 0, scannedItems: UInt64(tree.count[0]),
                counts: DiskMapScanCounts(), localSnapshotCount: nil),
            scannedAt: Date(), duration: 0, partial: false, smallFileThreshold: 0, revision: 3)
    }

    private func node(_ tree: FileTree, _ name: String) -> Int32 {
        Int32((0..<tree.nodeCount).first { tree.name(of: Int32($0)) == name }!)
    }

    func testAnalysisTiersReclaimAndKinds() {
        let snapshot = sampleSnapshot()
        let tree = snapshot.tree
        let analysis = advisor.analyze(snapshot, firmlinks: FirmlinkMap(lines: []))
        XCTAssertEqual(analysis.revision, 3)
        XCTAssertEqual(analysis.tiers.count, tree.nodeCount)

        XCTAssertEqual(analysis.tier(of: node(tree, "Caches")), .safeToRemove)
        XCTAssertEqual(
            analysis.tier(of: node(tree, "a")), .safeToRemove, "files inherit the folder's rule")
        XCTAssertEqual(analysis.tier(of: node(tree, "Mail")), .managedByApp)
        XCTAssertEqual(analysis.tier(of: node(tree, "node_modules")), .safeToRemove)
        XCTAssertEqual(analysis.tier(of: node(tree, "x")), .safeToRemove)
        XCTAssertEqual(analysis.tier(of: node(tree, "clip.mov")), .reviewBeforeRemoving)
        XCTAssertEqual(analysis.tier(of: node(tree, "Xcode.dmg")), .reviewBeforeRemoving)
        XCTAssertEqual(
            advisor.advice(for: node(tree, "Xcode.dmg"), in: analysis, tree: tree).title,
            "Disk image",
            "a file rule beats the inherited folder rule")
        XCTAssertEqual(
            advisor.advice(for: node(tree, "clip.mov"), in: analysis, tree: tree).title,
            "Your files")

        let reclaimTitles = analysis.reclaim.map(\.advice.title)
        XCTAssertTrue(reclaimTitles.contains("User caches"))
        XCTAssertTrue(reclaimTitles.contains("Dependencies (node_modules)"))
        XCTAssertTrue(reclaimTitles.contains("Mail"))
        XCTAssertTrue(reclaimTitles.contains("Downloads"))
        XCTAssertTrue(reclaimTitles.contains("Disk image"))
        XCTAssertFalse(
            analysis.reclaim.contains { $0.node == node(tree, "a") },
            "children of a matched folder are not repeated")
        XCTAssertEqual(analysis.reclaim.first?.bytes, 200, "largest first")
        XCTAssertEqual(analysis.reclaim.first { $0.advice.title == "User caches" }?.bytes, 150)

        let kinds = Dictionary(uniqueKeysWithValues: analysis.kinds.map { ($0.kind, $0) })
        XCTAssertEqual(kinds[.cache]?.bytes, 150)
        XCTAssertEqual(kinds[.cache]?.count, 2)
        XCTAssertEqual(kinds[.application]?.bytes, 10, "package contents roll up")
        XCTAssertEqual(kinds[.application]?.count, 1)
        XCTAssertEqual(kinds[.application]?.topItems, [node(tree, "Thing.app")])
        XCTAssertNil(kinds[.image], "the icon inside the app is not an image item")
        XCTAssertEqual(kinds[.video]?.topItems, [node(tree, "clip.mov")])
        XCTAssertEqual(kinds[.archive]?.bytes, 200)
        XCTAssertEqual(analysis.kinds.first?.kind, .archive, "kinds sorted by bytes")
        XCTAssertEqual(analysis.trashedBytes, 0)
    }

    func testAnalysisCountsTrashedBytesAndSkipsThem() {
        var snapshot = sampleSnapshot()
        let tree = snapshot.tree
        let dmg = node(tree, "Xcode.dmg")
        snapshot.tree.markTrashed(dmg)
        snapshot.revision += 1
        let analysis = advisor.analyze(snapshot, firmlinks: FirmlinkMap(lines: []))
        XCTAssertEqual(analysis.trashedBytes, 200)
        XCTAssertFalse(analysis.reclaim.contains { $0.node == dmg })
        XCTAssertNil(
            Dictionary(uniqueKeysWithValues: analysis.kinds.map { ($0.kind, $0) })[.archive])
    }

    // MARK: - Trash prechecks

    func testTrashPrecheck() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskMapAdvisorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("victim.txt")
        try Data("x".utf8).write(to: file)
        var st = stat()
        XCTAssertEqual(lstat(file.path, &st), 0)

        let live = DiskMapAdvisor(home: NSHomeDirectory())
        XCTAssertEqual(
            DiskMapTrash.precheck(
                path: file.path, canonicalPath: file.path, expectedFileID: st.st_ino,
                advisor: live, scanRoot: "/x"),
            .ok)
        XCTAssertEqual(
            DiskMapTrash.precheck(
                path: file.path, canonicalPath: file.path, expectedFileID: st.st_ino &+ 1,
                advisor: live, scanRoot: "/x"),
            .replaced)
        XCTAssertEqual(
            DiskMapTrash.precheck(
                path: root.appendingPathComponent("gone").path,
                canonicalPath: root.appendingPathComponent("gone").path, expectedFileID: 1,
                advisor: live, scanRoot: "/x"),
            .vanished)
        if case .refused = DiskMapTrash.precheck(
            path: "/System", canonicalPath: "/System", expectedFileID: 0, advisor: live,
            scanRoot: "/x")
        {
        } else {
            XCTFail("the system folder must be refused")
        }
        XCTAssertEqual(
            DiskMapTrash.trash(path: root.appendingPathComponent("nope").path), .alreadyGone)
        // The startup disk is scanned at /System/Volumes/Data, so the path on
        // disk starts with /System/ while the user's path does not; the
        // refusal list must be judged on the latter or everything is refused.
        XCTAssertEqual(
            DiskMapTrash.precheck(
                path: file.path, canonicalPath: "/Users/someone/Downloads/victim.txt",
                expectedFileID: st.st_ino, advisor: live, scanRoot: "/"),
            .ok)
        if case .refused = DiskMapTrash.precheck(
            path: file.path, canonicalPath: "/System/Volumes/Data" + file.path,
            expectedFileID: st.st_ino, advisor: live, scanRoot: "/")
        {
        } else {
            XCTFail("a /System path is refused, which is why the canonical one must be passed")
        }
    }
}
