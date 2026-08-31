import Darwin
import XCTest

@testable import MacPerfMonitorCore

/// A scripted filesystem: the scanner's coordinator logic (accumulation,
/// folding, hard links, boundaries, error taxonomy, cancellation) tested
/// without touching the disk. Paths are keyed exactly as the scanner builds
/// them (`root + "/" + name`).
private final class SyntheticLister: DirectoryLister, @unchecked Sendable {
    struct Item {
        var name: String
        var type: DirectoryEntryType = .regular
        var bytes: UInt64 = 0
        var privateSize: UInt64? = nil
        var fileID: UInt64 = 0
        var linkCount: UInt32 = 1
        var bsdFlags: UInt32 = 0
        var extendedFlags: UInt64 = 0
        var isMountPoint = false
        var modified: UInt32 = 1_700_000_000
        var error: Int32 = 0
    }

    var directories: [String: Result<[Item], DirectoryListingError>] = [:]
    var delay: TimeInterval = 0
    private let lock = NSLock()
    private var listedPaths: [String] = []
    private var nextID: UInt64 = 1000

    var listed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return listedPaths
    }

    func list(path: String) throws -> DirectoryListing {
        lock.lock()
        listedPaths.append(path)
        let scripted = directories[path]
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard let scripted else { throw DirectoryListingError.other(errno: EIO) }
        let items = try scripted.get()
        var listing = DirectoryListing()
        for item in items {
            let id: UInt64
            if item.fileID != 0 {
                id = item.fileID
            } else {
                lock.lock()
                nextID += 1
                id = nextID
                lock.unlock()
            }
            listing.append(name: Array(item.name.utf8)) { offset, count in
                RawDirectoryEntry(
                    nameOffset: offset, nameLength: count, type: item.type, error: item.error,
                    allocated: item.bytes, privateSize: item.privateSize, fileID: id,
                    modified: item.modified, bsdFlags: item.bsdFlags, linkCount: item.linkCount,
                    extendedFlags: item.extendedFlags, isMountPoint: item.isMountPoint)
            }
        }
        return listing
    }
}

private func file(
    _ name: String, _ bytes: UInt64, id: UInt64 = 0, links: UInt32 = 1, flags: UInt32 = 0,
    ext: UInt64 = 0, privateSize: UInt64? = nil
) -> SyntheticLister.Item {
    SyntheticLister.Item(
        name: name, type: .regular, bytes: bytes, privateSize: privateSize, fileID: id,
        linkCount: links, bsdFlags: flags, extendedFlags: ext)
}

private func dir(
    _ name: String, mount: Bool = false, dataless: Bool = false
) -> SyntheticLister.Item {
    SyntheticLister.Item(
        name: name, type: .directory, bsdFlags: dataless ? UInt32(SF_DATALESS) : 0,
        isMountPoint: mount)
}

final class DiskMapScannerTests: XCTestCase {
    private var root: URL!
    private var rootPath: String { root.path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskMapScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fakeVolume(
        mountPoint: String, used: UInt64, purgeable: UInt64? = nil
    ) -> VolumeInfo {
        VolumeInfo(
            mountPoint: mountPoint, name: "Test", bsdName: "disk9s1", fsTypeName: "apfs",
            volumeUUID: nil, role: .data, isRoot: false, isLocal: true, isReadOnly: false,
            isInternal: true, isEjectable: false, isEncrypted: false, totalBytes: 10_000,
            freeBytes: 10_000 - used, availableBytes: 10_000 - used,
            importantUsageAvailableBytes: purgeable.map { 10_000 - used + $0 },
            purgeableBytes: purgeable, containerBSDName: "disk9", blockSize: 4096,
            spaceUsedBytes: used)
    }

    private func scanner(
        _ lister: SyntheticLister, volumes: @escaping @Sendable () -> [VolumeInfo] = { [] },
        snapshots: @escaping @Sendable (String) -> Int? = { _ in nil }
    ) -> DiskMapScanner {
        DiskMapScanner(volumeSource: volumes, snapshotCounter: snapshots)
    }

    private func options(
        _ lister: SyntheticLister, threshold: UInt64? = 0, workers: Int = 2,
        minimumSmallFilesToFold: Int = 24
    ) -> DiskMapScanOptions {
        DiskMapScanOptions(
            smallFileThreshold: threshold, minimumSmallFilesToFold: minimumSmallFilesToFold,
            workerCount: workers, previewInterval: 10, countLocalSnapshots: false, lister: lister)
    }

    // MARK: - Coordinator logic

    func testNestedTotalsCountsAndPaths() throws {
        let lister = SyntheticLister()
        lister.directories[rootPath] = .success([dir("a"), dir("b"), file("c", 50)])
        lister.directories[rootPath + "/a"] = .success([file("a1", 100), file("a2", 200)])
        lister.directories[rootPath + "/b"] = .success([file("b1", 1000, privateSize: 600)])

        let snapshot = try scanner(lister).scanBlocking(.folder(rootPath), options: options(lister))
        let tree = snapshot.tree
        XCTAssertFalse(snapshot.partial)
        XCTAssertEqual(tree.nodeCount, 7)
        XCTAssertEqual(tree.bytes[0], 1350)
        XCTAssertEqual(tree.shared[0], 400)
        XCTAssertEqual(tree.count[0], 6)
        XCTAssertEqual(snapshot.reconciliation.scannedBytes, 1350)
        XCTAssertEqual(snapshot.reconciliation.sharedBytes, 400)
        XCTAssertEqual(snapshot.reconciliation.scannedItems, 6)
        XCTAssertEqual(snapshot.reconciliation.counts.directories, 3)
        XCTAssertEqual(snapshot.reconciliation.counts.files, 4)
        XCTAssertEqual(snapshot.reconciliation.counts.entries, 6)
        XCTAssertTrue(tree.isStructurallyValid)

        let byName = Dictionary(
            uniqueKeysWithValues: (0..<Int32(tree.nodeCount)).map { (tree.name(of: $0), $0) })
        XCTAssertEqual(tree.bytes[Int(byName["a"]!)], 300)
        XCTAssertEqual(tree.bytes[Int(byName["b"]!)], 1000)
        XCTAssertEqual(snapshot.filesystemPath(of: byName["b1"]!), rootPath + "/b/b1")
        XCTAssertEqual(tree.name(of: 0), (rootPath as NSString).lastPathComponent)
        XCTAssertEqual(Set(lister.listed), [rootPath, rootPath + "/a", rootPath + "/b"])
    }

    func testBoundariesAreNotDescended() throws {
        let lister = SyntheticLister()
        lister.directories[rootPath] = .success([
            dir("vol", mount: true), dir("cloud", dataless: true), dir("ok"),
        ])
        lister.directories[rootPath + "/ok"] = .success([file("f", 10)])

        let snapshot = try scanner(lister).scanBlocking(.folder(rootPath), options: options(lister))
        let counts = snapshot.reconciliation.counts
        XCTAssertEqual(counts.separateVolumes, 1)
        XCTAssertEqual(counts.datalessDirectories, 1)
        XCTAssertEqual(counts.unreadable, 0, "boundaries must never be opened")
        XCTAssertEqual(Set(lister.listed), [rootPath, rootPath + "/ok"])
        let tree = snapshot.tree
        for node in tree.children(of: 0) {
            switch tree.name(of: node) {
            case "vol":
                XCTAssertTrue(tree.flags[Int(node)].contains(.separateVolume))
                XCTAssertTrue(tree.flags[Int(node)].contains(.directory))
            case "cloud":
                XCTAssertTrue(tree.flags[Int(node)].contains(.dataless))
            default: break
            }
        }
        XCTAssertEqual(tree.bytes[0], 10)
    }

    func testListingErrorsAreClassifiedPerDirectory() throws {
        let lister = SyntheticLister()
        lister.directories[rootPath] = .success([dir("tcc"), dir("perm"), dir("gone"), dir("io")])
        lister.directories[rootPath + "/tcc"] = .failure(.notPermitted)
        lister.directories[rootPath + "/perm"] = .failure(.accessDenied)
        lister.directories[rootPath + "/gone"] = .failure(.vanished)
        lister.directories[rootPath + "/io"] = .failure(.other(errno: EIO))

        let snapshot = try scanner(lister).scanBlocking(.folder(rootPath), options: options(lister))
        let counts = snapshot.reconciliation.counts
        XCTAssertEqual(counts.notPermitted, 1)
        XCTAssertEqual(counts.accessDenied, 1)
        XCTAssertEqual(counts.vanished, 1)
        XCTAssertEqual(counts.unreadable, 1)
        XCTAssertEqual(counts.unlistedDirectories, 4)
        let tree = snapshot.tree
        let flagsByName = Dictionary(
            uniqueKeysWithValues: tree.children(of: 0).map {
                (tree.name(of: $0), tree.flags[Int($0)])
            })
        XCTAssertTrue(flagsByName["tcc"]!.contains(.notPermitted))
        XCTAssertTrue(flagsByName["perm"]!.contains(.accessDenied))
        XCTAssertTrue(flagsByName["gone"]!.contains(.unreadable))
        XCTAssertTrue(flagsByName["io"]!.contains(.unreadable))
        XCTAssertFalse(flagsByName["perm"]!.contains(.notPermitted))
    }

    func testDataVaultsDoNotCountAgainstFullDiskAccess() throws {
        let lister = SyntheticLister()
        var vault = dir("Biome")
        vault.bsdFlags = UInt32(UF_DATAVAULT)
        lister.directories[rootPath] = .success([vault, dir("Mail")])
        lister.directories[rootPath + "/Biome"] = .failure(.notPermitted)
        lister.directories[rootPath + "/Mail"] = .failure(.notPermitted)
        let snapshot = try scanner(lister).scanBlocking(.folder(rootPath), options: options(lister))
        let counts = snapshot.reconciliation.counts
        XCTAssertEqual(counts.dataVaults, 1)
        XCTAssertEqual(counts.notPermitted, 1)
        XCTAssertEqual(counts.unlistedDirectories, 2)
        let tree = snapshot.tree
        let vaultNode = tree.children(of: 0).first { tree.name(of: $0) == "Biome" }!
        XCTAssertTrue(tree.flags[Int(vaultNode)].contains(.dataVault))
        XCTAssertFalse(tree.flags[Int(vaultNode)].contains(.notPermitted))
    }

    func testPerEntryErrorsBecomeUnreadableLeaves() throws {
        let lister = SyntheticLister()
        var broken = file("broken", 0)
        broken.error = EIO
        lister.directories[rootPath] = .success([broken, file("fine", 8)])
        let snapshot = try scanner(lister).scanBlocking(.folder(rootPath), options: options(lister))
        XCTAssertEqual(snapshot.reconciliation.counts.entryErrors, 1)
        XCTAssertEqual(snapshot.tree.bytes[0], 8)
        let broke = snapshot.tree.children(of: 0).first { snapshot.tree.name(of: $0) == "broken" }!
        XCTAssertTrue(snapshot.tree.flags[Int(broke)].contains(.unreadable))
    }

    func testHardLinksAreCountedOnce() throws {
        let lister = SyntheticLister()
        lister.directories[rootPath] = .success([
            dir("x"), dir("y"), file("solo", 4096, id: 9, links: 1),
        ])
        lister.directories[rootPath + "/x"] = .success([file("f1", 4096, id: 7, links: 2)])
        lister.directories[rootPath + "/y"] = .success([file("f2", 4096, id: 7, links: 2)])

        let snapshot = try scanner(lister).scanBlocking(
            .folder(rootPath), options: options(lister, workers: 1))
        XCTAssertEqual(snapshot.tree.bytes[0], 8192)
        XCTAssertEqual(snapshot.reconciliation.counts.hardLinkDuplicates, 1)
        let dupes = (0..<Int32(snapshot.tree.nodeCount)).filter {
            snapshot.tree.flags[Int($0)].contains(.hardLinkDuplicate)
        }
        XCTAssertEqual(dupes.count, 1)
        XCTAssertEqual(snapshot.tree.bytes[Int(dupes[0])], 0)
    }

    func testSmallFilesFoldPerKindAboveTheMinimum() throws {
        let lister = SyntheticLister()
        var items: [SyntheticLister.Item] = [file("big.mov", 5000)]
        for i in 0..<20 { items.append(file("p\(i).jpg", 10)) }
        for i in 0..<10 { items.append(file("d\(i).txt", 20)) }
        lister.directories[rootPath] = .success(items)

        let folded = try scanner(lister).scanBlocking(
            .folder(rootPath), options: options(lister, threshold: 100))
        let tree = folded.tree
        XCTAssertEqual(tree.childCount[0], 3, "one big file plus one fold per kind")
        XCTAssertEqual(tree.bytes[0], 5400)
        XCTAssertEqual(tree.count[0], 31)
        XCTAssertEqual(folded.reconciliation.counts.foldedFiles, 30)
        XCTAssertEqual(folded.reconciliation.counts.files, 1)
        XCTAssertEqual(folded.smallFileThreshold, 100)
        let folds = tree.children(of: 0).filter { tree.flags[Int($0)].contains(.smallFilesFold) }
        XCTAssertEqual(folds.count, 2)
        let image = folds.first { tree.kind[Int($0)] == .image }!
        XCTAssertEqual(tree.bytes[Int(image)], 200)
        XCTAssertEqual(tree.count[Int(image)], 20)
        XCTAssertEqual(tree.name(of: image), "")
        let document = folds.first { tree.kind[Int($0)] == .document }!
        XCTAssertEqual(tree.bytes[Int(document)], 200)
        XCTAssertEqual(tree.count[Int(document)], 10)
        // Kinds order: image before document.
        XCTAssertLessThan(image, document)

        let unfolded = try scanner(lister).scanBlocking(
            .folder(rootPath), options: options(lister, threshold: 0))
        XCTAssertEqual(unfolded.tree.childCount[0], 31)
        XCTAssertEqual(unfolded.tree.bytes[0], 5400)

        let fewSmall = try scanner(lister).scanBlocking(
            .folder(rootPath), options: options(lister, threshold: 100, minimumSmallFilesToFold: 40)
        )
        XCTAssertEqual(fewSmall.tree.childCount[0], 31, "below the minimum nothing folds")
        XCTAssertEqual(fewSmall.reconciliation.counts.foldedFiles, 0)
    }

    func testPackagesSymlinksAndFlags() throws {
        let lister = SyntheticLister()
        var link = SyntheticLister.Item(name: "alias", type: .symlink, bytes: 0)
        link.linkCount = 1
        let socket = SyntheticLister.Item(name: "sock", type: .other)
        lister.directories[rootPath] = .success([
            dir("Foo.app"), link, socket, file(".hidden", 1),
            file("locked", 2, flags: UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE)),
            file("clone", 3, ext: UInt64(EF_MAY_SHARE_BLOCKS), privateSize: 0),
            file("evicted", 0, flags: UInt32(SF_DATALESS)),
        ])
        lister.directories[rootPath + "/Foo.app"] = .success([file("bin", 9)])
        let snapshot = try scanner(lister).scanBlocking(.folder(rootPath), options: options(lister))
        let tree = snapshot.tree
        let byName = Dictionary(
            uniqueKeysWithValues: tree.children(of: 0).map { (tree.name(of: $0), $0) })
        XCTAssertTrue(tree.flags[Int(byName["Foo.app"]!)].contains(.package))
        XCTAssertEqual(tree.kind[Int(byName["Foo.app"]!)], .application)
        XCTAssertEqual(tree.bytes[Int(byName["Foo.app"]!)], 9, "packages are still scanned")
        XCTAssertTrue(tree.flags[Int(byName["alias"]!)].contains(.symlink))
        XCTAssertEqual(tree.bytes[Int(byName["alias"]!)], 0)
        XCTAssertEqual(tree.bytes[Int(byName["sock"]!)], 0)
        XCTAssertTrue(tree.flags[Int(byName[".hidden"]!)].contains(.hidden))
        XCTAssertTrue(tree.flags[Int(byName["locked"]!)].contains(.restricted))
        XCTAssertTrue(tree.flags[Int(byName["locked"]!)].contains(.immutable))
        XCTAssertTrue(tree.flags[Int(byName["clone"]!)].contains(.mayShareBlocks))
        XCTAssertEqual(tree.shared[Int(byName["clone"]!)], 3)
        XCTAssertTrue(tree.flags[Int(byName["evicted"]!)].contains(.dataless))
        let counts = snapshot.reconciliation.counts
        XCTAssertEqual(counts.symlinks, 1)
        XCTAssertEqual(counts.sharedBlockFiles, 1)
        XCTAssertEqual(counts.datalessFiles, 1)
        XCTAssertEqual(tree.bytes[0], 15)
    }

    // MARK: - Reconciliation

    func testReconciliationReadsTheVolumeAfterTheScan() throws {
        let lister = SyntheticLister()
        lister.directories[rootPath] = .success([file("f", 1350)])
        let mount = try XCTUnwrap(DiskMapScope.mountPoint(ofPath: rootPath))
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() -> Int {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                return count
            }
        }
        let calls = Calls()
        let volumes: @Sendable () -> [VolumeInfo] = { [self] in
            let used: UInt64 = calls.next() == 1 ? 1000 : 1500
            return [fakeVolume(mountPoint: mount, used: used, purgeable: 70)]
        }
        let snapshot = try scanner(lister, volumes: volumes, snapshots: { _ in 3 }).scanBlocking(
            .folder(rootPath), options: options(lister))
        let rec = snapshot.reconciliation
        XCTAssertEqual(rec.volumeMountPoint, mount)
        XCTAssertEqual(rec.usedBytesBeforeScan, 1000)
        XCTAssertEqual(rec.usedBytes, 1500)
        XCTAssertEqual(rec.scannedBytes, 1350)
        XCTAssertEqual(rec.unaccountedBytes, 150)
        XCTAssertEqual(rec.overshootBytes, 0)
        XCTAssertEqual(rec.purgeableBytes, 70)
        XCTAssertTrue(rec.volumeChangedDuringScan)
        XCTAssertNil(rec.localSnapshotCount, "counting was switched off in the options")
        XCTAssertEqual(rec.accountedFraction!, 0.9, accuracy: 0.0001)
    }

    func testReconciliationOvershootAndSystemVolumes() {
        let data = fakeVolume(mountPoint: "/System/Volumes/Data", used: 1000)
        var system = fakeVolume(mountPoint: "/", used: 120)
        system.role = .system
        var vm = fakeVolume(mountPoint: "/System/Volumes/VM", used: 30)
        vm.role = .vm
        var other = fakeVolume(mountPoint: "/Volumes/Ext", used: 5000)
        other.containerBSDName = "disk7"
        other.role = .user
        let rec = DiskMapReconciliation.compute(
            scope: .startupDisk, mountPoint: "/System/Volumes/Data", volume: data,
            allVolumes: [data, system, vm, other], usedBefore: 1000, scannedBytes: 1200,
            sharedBytes: 250, scannedItems: 10, counts: DiskMapScanCounts(), localSnapshotCount: 2)
        XCTAssertEqual(rec.overshootBytes, 200)
        XCTAssertEqual(rec.unaccountedBytes, 0)
        XCTAssertFalse(rec.volumeChangedDuringScan)
        XCTAssertEqual(rec.systemVolumes.map(\.mountPoint), ["/", "/System/Volumes/VM"])
        XCTAssertEqual(rec.systemVolumes.map(\.usedBytes), [120, 30])
        XCTAssertEqual(rec.localSnapshotCount, 2)

        let folderRec = DiskMapReconciliation.compute(
            scope: .folder("/x"), mountPoint: "/System/Volumes/Data", volume: data,
            allVolumes: [data, system], usedBefore: nil, scannedBytes: 10, sharedBytes: 0,
            scannedItems: 1, counts: DiskMapScanCounts(), localSnapshotCount: nil)
        XCTAssertTrue(folderRec.systemVolumes.isEmpty, "system buckets belong to the startup disk")
        XCTAssertNil(folderRec.usedBytesBeforeScan)
    }

    // MARK: - Lifecycle

    func testCancellationYieldsAPartialSnapshot() throws {
        let lister = SyntheticLister()
        lister.delay = 0.002
        var top: [SyntheticLister.Item] = []
        for i in 0..<300 {
            top.append(dir("d\(i)"))
            lister.directories[rootPath + "/d\(i)"] = .success([file("f", 1)])
        }
        lister.directories[rootPath] = .success(top)
        let token = DiskMapCancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { token.cancel() }
        let snapshot = try scanner(lister).scanBlocking(
            .folder(rootPath), options: options(lister, workers: 1), cancellation: token)
        XCTAssertTrue(snapshot.partial)
        XCTAssertTrue(token.isCancelled)
        XCTAssertLessThan(snapshot.reconciliation.counts.directories, 301)
        XCTAssertGreaterThan(snapshot.tree.nodeCount, 1)
        XCTAssertTrue(snapshot.tree.isStructurallyValid)
        XCTAssertEqual(
            snapshot.tree.bytes[0], UInt64(snapshot.reconciliation.counts.directories - 1))
    }

    func testAsyncStreamDeliversProgressThenCompletes() async throws {
        let lister = SyntheticLister()
        lister.delay = 0.002
        var top: [SyntheticLister.Item] = []
        for i in 0..<60 {
            top.append(dir("d\(i)"))
            lister.directories[rootPath + "/d\(i)"] = .success([file("f", 2_000_000)])
        }
        lister.directories[rootPath] = .success(top)
        var options = options(lister, workers: 1)
        options.previewInterval = 0.005

        var progressCount = 0
        var lastPreview: DiskMapPreviewNode?
        var completed: DiskMapSnapshot?
        for await event in scanner(lister).scan(.folder(rootPath), options: options) {
            switch event {
            case .progress(let progress, let preview):
                progressCount += 1
                lastPreview = preview
                XCTAssertNil(progress.expectedEntries, "folder scopes have no inode denominator")
                XCTAssertNil(progress.fraction)
                XCTAssertEqual(progress.scope, .folder(rootPath))
            case .completed(let snapshot):
                completed = snapshot
            case .failed(let error):
                XCTFail("unexpected failure \(error)")
            }
        }
        XCTAssertGreaterThan(progressCount, 0)
        XCTAssertNotNil(lastPreview)
        let snapshot = try XCTUnwrap(completed)
        XCTAssertFalse(snapshot.partial)
        XCTAssertEqual(snapshot.tree.bytes[0], 120_000_000)
        XCTAssertEqual(snapshot.tree.nodeCount, 121)
    }

    func testDroppingTheStreamCancelsTheScan() async throws {
        let lister = SyntheticLister()
        lister.delay = 0.005
        var top: [SyntheticLister.Item] = []
        for i in 0..<400 {
            top.append(dir("d\(i)"))
            lister.directories[rootPath + "/d\(i)"] = .success([file("f", 1)])
        }
        lister.directories[rootPath] = .success(top)
        var options = options(lister, workers: 1)
        options.previewInterval = 0.001
        // The app's model iterates the stream inside a Task and cancels that
        // Task; cancellation reaches the scan through the stream's termination.
        let scanner = scanner(lister)
        let consumer = Task {
            var events = 0
            for await _ in scanner.scan(.folder(rootPath), options: options) { events += 1 }
            return events
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        consumer.cancel()
        _ = await consumer.value
        // The worker notices between directories; the count must plateau far
        // below the full 401.
        try await Task.sleep(nanoseconds: 50_000_000)
        let listedAfterCancel = lister.listed.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThanOrEqual(lister.listed.count, listedAfterCancel + 1)
        XCTAssertLessThan(lister.listed.count, 401)
    }

    func testRootFailures() {
        let missing = root.appendingPathComponent("missing").path
        XCTAssertThrowsError(try DiskMapScanner().scanBlocking(.folder(missing))) { error in
            XCTAssertEqual(error as? DiskMapScanError, .rootNotReadable(missing, .vanished))
        }
        let filePath = root.appendingPathComponent("plain").path
        FileManager.default.createFile(atPath: filePath, contents: Data())
        XCTAssertThrowsError(try DiskMapScanner().scanBlocking(.folder(filePath))) { error in
            XCTAssertEqual(error as? DiskMapScanError, .rootNotADirectory(filePath))
        }
        XCTAssertNotNil(DiskMapScanError.rootNotReadable("/x", .notPermitted).errorDescription)
    }

    // MARK: - Real filesystem

    /// Every byte the scanner reports must match an independent `lstat` walk
    /// with the same rules (allocated size, hard links once, symlinks as they
    /// report), with and without folding.
    func testRealTreeMatchesAnLstatWalk() throws {
        let fm = FileManager.default
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let pics = root.appendingPathComponent("pics", isDirectory: true)
        let nested = pics.appendingPathComponent("2024/trip", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        for i in 0..<40 {
            try Data(repeating: 1, count: 100 + i).write(
                to: docs.appendingPathComponent("n\(i).txt"))
        }
        try Data(repeating: 2, count: 200_000).write(to: docs.appendingPathComponent("big.pdf"))
        try Data(repeating: 3, count: 50_000).write(to: nested.appendingPathComponent("a.jpg"))
        try Data(repeating: 4, count: 30_000).write(to: nested.appendingPathComponent("b.jpg"))
        try fm.linkItem(
            at: nested.appendingPathComponent("a.jpg"),
            to: pics.appendingPathComponent("a-link.jpg"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("shortcut"), withDestinationURL: docs)

        var expectedBytes: UInt64 = 0
        var expectedItems: UInt32 = 0
        var seenInodes = Set<UInt64>()
        let enumerator = fm.enumerator(atPath: rootPath)!
        for case let relative as String in enumerator {
            var st = stat()
            guard lstat(root.appendingPathComponent(relative).path, &st) == 0 else { continue }
            expectedItems += 1
            if st.st_mode & S_IFMT == S_IFREG {
                if st.st_nlink > 1, !seenInodes.insert(st.st_ino).inserted { continue }
                expectedBytes += UInt64(st.st_blocks) * 512
            } else if st.st_mode & S_IFMT == S_IFLNK {
                expectedBytes += UInt64(st.st_blocks) * 512
            }
        }

        let plain = DiskMapScanOptions(
            smallFileThreshold: 0, workerCount: 3, previewInterval: 10, countLocalSnapshots: false)
        let full = try DiskMapScanner().scanBlocking(.folder(rootPath), options: plain)
        XCTAssertEqual(full.tree.bytes[0], expectedBytes)
        XCTAssertEqual(full.tree.count[0], expectedItems)
        XCTAssertEqual(full.tree.nodeCount, Int(expectedItems) + 1)
        XCTAssertEqual(full.reconciliation.counts.hardLinkDuplicates, 1)
        XCTAssertTrue(full.tree.isStructurallyValid)
        XCTAssertNotNil(full.reconciliation.usedBytes, "the temp volume is a real one")

        var folding = plain
        folding.smallFileThreshold = 16_384
        let folded = try DiskMapScanner().scanBlocking(.folder(rootPath), options: folding)
        XCTAssertEqual(folded.tree.bytes[0], expectedBytes, "folding never changes a total")
        XCTAssertEqual(folded.tree.count[0], expectedItems)
        XCTAssertLessThan(folded.tree.nodeCount, full.tree.nodeCount)
        XCTAssertEqual(folded.reconciliation.counts.foldedFiles, 40)
    }

    func testDisplayPathAppliesFirmlinks() throws {
        guard FileManager.default.fileExists(atPath: "/usr/share/firmlinks") else {
            throw XCTSkip("no firmlinks table")
        }
        let builder = FileTreeBuilder()
        builder.appendRoot(name: "Macintosh HD", fileID: 2, modified: 0, flags: [])
        builder.appendChildren(
            of: 0,
            [
                FileTreeBuilder.Entry(
                    name: ArraySlice("Users".utf8), bytes: 0, flags: [.directory], kind: .folder)
            ])
        let snapshot = DiskMapSnapshot(
            scope: .startupDisk, rootPath: "/System/Volumes/Data", tree: builder.build(),
            reconciliation: DiskMapReconciliation.compute(
                scope: .startupDisk, mountPoint: "/System/Volumes/Data", volume: nil,
                allVolumes: [], usedBefore: nil, scannedBytes: 0, sharedBytes: 0, scannedItems: 0,
                counts: DiskMapScanCounts(), localSnapshotCount: nil),
            scannedAt: Date(), duration: 0, partial: false, smallFileThreshold: 0, revision: 1)
        XCTAssertEqual(snapshot.displayPath(of: 1), "/Users")
        XCTAssertEqual(snapshot.filesystemPath(of: 1), "/System/Volumes/Data/Users")
        XCTAssertEqual(snapshot.displayPath(of: 0), "/")
    }
}
