import Darwin
import XCTest

@testable import MacPerfMonitorCore

/// The listers against a real temp tree: every field cross-checked with
/// `lstat`, the two implementations checked against each other, and the awkward
/// shapes (hard links, sparse files, clones, huge directories, long and
/// non-ASCII names, paths past PATH_MAX, unreadable directories) exercised.
final class DiskMapListerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskMapListerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions on anything the tests locked so removal works,
        // then remove through descriptors: the deep-path fixture is past
        // PATH_MAX and Foundation cannot address it.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                chmod(root.appendingPathComponent(relative).path, 0o755)
            }
        }
        let parentFD = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        if parentFD >= 0 {
            Self.removeTree(named: root.lastPathComponent, in: parentFD)
            close(parentFD)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// `rm -rf` by descriptor so it works at any depth.
    private static func removeTree(named name: String, in parentFD: Int32) {
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd >= 0, let dir = fdopendir(fd) {
            var names: [String] = []
            while let entry = readdir(dir) {
                let child = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
                }
                if child != ".", child != ".." { names.append(child) }
            }
            for child in names {
                if unlinkat(fd, child, 0) != 0 { removeTree(named: child, in: fd) }
            }
            closedir(dir)
        } else if fd >= 0 {
            close(fd)
        }
        unlinkat(parentFD, name, AT_REMOVEDIR)
    }

    /// Build `levels` nested directories of `component` under the root using
    /// `mkdirat`, plus a `leaf` file of `leafBytes`, and return the deepest
    /// directory's URL (which is longer than PATH_MAX).
    private func makeDeepDirectory(levels: Int, component: String, leafBytes: Int) throws -> URL {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var url = root!
        for _ in 0..<levels {
            guard mkdirat(fd, component, 0o755) == 0 else {
                close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY)
            close(fd)
            guard next >= 0 else { throw POSIXError(.EIO) }
            fd = next
            url.appendPathComponent(component)
        }
        let leaf = openat(fd, "leaf", O_CREAT | O_WRONLY, 0o644)
        close(fd)
        guard leaf >= 0 else { throw POSIXError(.EIO) }
        let payload = [UInt8](repeating: 7, count: leafBytes)
        _ = payload.withUnsafeBytes { Darwin.write(leaf, $0.baseAddress, $0.count) }
        close(leaf)
        return url
    }

    private func write(_ name: String, bytes: Int, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func lstatInfo(_ url: URL) -> stat {
        var st = stat()
        XCTAssertEqual(lstat(url.path, &st), 0, url.path)
        return st
    }

    private func listing(
        _ lister: any DirectoryLister, _ url: URL
    ) throws -> [String: RawDirectoryEntry] {
        let result = try lister.list(path: url.path)
        var byName: [String: RawDirectoryEntry] = [:]
        for entry in result.entries {
            byName[result.nameString(of: entry)] = entry
        }
        return byName
    }

    func testBulkFieldsMatchLstat() throws {
        _ = try write("small.txt", bytes: 10)
        _ = try write("big.bin", bytes: 300_000)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: sub)

        let entries = try listing(BulkAttributeLister(), root)
        XCTAssertEqual(Set(entries.keys), ["small.txt", "big.bin", "sub", "link"])

        for (name, entry) in entries {
            let st = lstatInfo(root.appendingPathComponent(name))
            XCTAssertEqual(entry.error, 0, name)
            XCTAssertEqual(entry.fileID, st.st_ino, name)
            XCTAssertEqual(entry.modified, UInt32(st.st_mtimespec.tv_sec), name)
            XCTAssertEqual(entry.bsdFlags, st.st_flags, name)
            XCTAssertEqual(entry.type, DirectoryEntryType(mode: st.st_mode), name)
            XCTAssertFalse(entry.isMountPoint, name)
            if entry.type == .regular {
                XCTAssertEqual(entry.allocated, UInt64(st.st_blocks) * 512, name)
                XCTAssertEqual(entry.linkCount, UInt32(st.st_nlink), name)
                XCTAssertLessThanOrEqual(entry.privateSize, entry.allocated, name)
            }
        }
        XCTAssertGreaterThanOrEqual(entries["big.bin"]!.allocated, 300_000)
        XCTAssertEqual(entries["sub"]!.type, .directory)
        XCTAssertEqual(entries["link"]!.type, .symlink)
    }

    func testReaddirParityWithBulk() throws {
        _ = try write("a.txt", bytes: 5000)
        _ = try write("b.txt", bytes: 70_000)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("s"),
            withDestinationURL: root.appendingPathComponent("a.txt"))

        let bulk = try listing(BulkAttributeLister(), root)
        let readdir = try listing(ReaddirLister(), root)
        XCTAssertEqual(Set(bulk.keys), Set(readdir.keys))
        for (name, b) in bulk {
            let r = try XCTUnwrap(readdir[name])
            XCTAssertEqual(b.type, r.type, name)
            XCTAssertEqual(b.fileID, r.fileID, name)
            XCTAssertEqual(b.modified, r.modified, name)
            XCTAssertEqual(b.bsdFlags, r.bsdFlags, name)
            XCTAssertEqual(b.isMountPoint, r.isMountPoint, name)
            if b.type == .regular {
                XCTAssertEqual(b.allocated, r.allocated, name)
                XCTAssertEqual(b.linkCount, r.linkCount, name)
            }
        }
    }

    func testHardLinksShareFileIDAndReportLinkCount() throws {
        let original = try write("orig", bytes: 20_000)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("copy"))
        for lister in [any DirectoryLister](arrayLiteral: BulkAttributeLister(), ReaddirLister()) {
            let entries = try listing(lister, root)
            XCTAssertEqual(entries["orig"]?.linkCount, 2)
            XCTAssertEqual(entries["copy"]?.linkCount, 2)
            XCTAssertEqual(entries["orig"]?.fileID, entries["copy"]?.fileID)
        }
    }

    func testSparseFileAllocatesLessThanItsLength() throws {
        let url = root.appendingPathComponent("sparse")
        let fd = open(url.path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 50 * 1024 * 1024), 0)
        close(fd)
        let entries = try listing(BulkAttributeLister(), root)
        let sparse = try XCTUnwrap(entries["sparse"])
        XCTAssertLessThan(sparse.allocated, 50 * 1024 * 1024)
    }

    func testClonesCarryTheSharedBlocksFlagAndPrivateSize() throws {
        let original = try write("orig", bytes: 1_000_000)
        let clone = root.appendingPathComponent("clone")
        guard clonefile(original.path, clone.path, 0) == 0 else {
            throw XCTSkip("clonefile unsupported here (errno \(errno))")
        }
        let entries = try listing(BulkAttributeLister(fetchPrivateSize: true), root)
        for name in ["orig", "clone"] {
            let entry = try XCTUnwrap(entries[name])
            XCTAssertNotEqual(entry.extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS), 0, name)
            XCTAssertLessThan(entry.privateSize, entry.allocated, "\(name) shares every block")
        }
        let without = try listing(BulkAttributeLister(fetchPrivateSize: false), root)
        XCTAssertEqual(without["orig"]?.privateSize, without["orig"]?.allocated)
    }

    func testLargeDirectoryNeedsSeveralBulkCalls() throws {
        let big = root.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<5000 {
            try Data().write(to: big.appendingPathComponent("file-\(i)"))
        }
        let bulk = try BulkAttributeLister().list(path: big.path)
        XCTAssertEqual(bulk.entries.count, 5000)
        XCTAssertEqual(Set(bulk.entries.map(bulk.nameString)).count, 5000)
        let readdir = try ReaddirLister().list(path: big.path)
        XCTAssertEqual(readdir.entries.count, 5000)
    }

    func testLongAndNonASCIINamesRoundTrip() throws {
        let longName = String(repeating: "n", count: 250) + ".mov"
        let unicode = "日本語のファイル名 with spaces.jpg"
        _ = try write(longName, bytes: 1)
        _ = try write(unicode, bytes: 1)
        for lister in [any DirectoryLister](arrayLiteral: BulkAttributeLister(), ReaddirLister()) {
            let entries = try listing(lister, root)
            XCTAssertNotNil(entries[longName])
            // The filesystem may normalise Unicode; compare by decomposition-insensitive equality.
            XCTAssertTrue(entries.keys.contains { $0.compare(unicode) == .orderedSame })
        }
    }

    func testPathsDeeperThanPathMaxOpenThroughOpenat() throws {
        let deep = try makeDeepDirectory(
            levels: 7, component: String(repeating: "d", count: 200), leafBytes: 12_345)
        XCTAssertGreaterThan(deep.path.utf8.count, 1024)
        for lister in [any DirectoryLister](arrayLiteral: BulkAttributeLister(), ReaddirLister()) {
            let entries = try listing(lister, deep)
            XCTAssertEqual(entries["leaf"]?.type, .regular)
            XCTAssertGreaterThanOrEqual(entries["leaf"]?.allocated ?? 0, 12_345)
        }
    }

    func testErrorsAreClassified() throws {
        let missing = root.path + "/missing"
        XCTAssertThrowsError(try BulkAttributeLister().list(path: missing)) { error in
            XCTAssertEqual(error as? DirectoryListingError, .vanished)
        }
        let file = try write("plain", bytes: 1)
        XCTAssertThrowsError(try BulkAttributeLister().list(path: file.path)) { error in
            XCTAssertEqual(error as? DirectoryListingError, .vanished, "ENOTDIR maps to vanished")
        }
        guard geteuid() != 0 else { return }
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0)
        XCTAssertThrowsError(try BulkAttributeLister().list(path: locked.path)) { error in
            XCTAssertEqual(error as? DirectoryListingError, .accessDenied)
        }
        XCTAssertThrowsError(try ReaddirLister().list(path: locked.path)) { error in
            XCTAssertEqual(error as? DirectoryListingError, .accessDenied)
        }
    }

    func testMountPointsAreFlaggedNotDescended() throws {
        guard FileManager.default.fileExists(atPath: "/System/Volumes/Data") else {
            throw XCTSkip("no volume group on this machine")
        }
        let entries = try listing(BulkAttributeLister(), URL(fileURLWithPath: "/System/Volumes"))
        XCTAssertEqual(entries["Data"]?.type, .directory)
        XCTAssertEqual(entries["Data"]?.isMountPoint, true)
    }

    func testErrnoMapping() {
        XCTAssertEqual(DirectoryListingError(errno: EPERM), .notPermitted)
        XCTAssertEqual(DirectoryListingError(errno: EACCES), .accessDenied)
        XCTAssertEqual(DirectoryListingError(errno: ENOENT), .vanished)
        XCTAssertEqual(DirectoryListingError(errno: ENOTDIR), .vanished)
        XCTAssertEqual(DirectoryListingError(errno: EDEADLK), .dataless)
        XCTAssertEqual(DirectoryListingError(errno: ENOTSUP), .notSupported)
        XCTAssertEqual(DirectoryListingError(errno: EIO), .other(errno: EIO))
        XCTAssertEqual(DirectoryListingError.notPermitted.nodeFlag, .notPermitted)
        XCTAssertEqual(DirectoryListingError.accessDenied.nodeFlag, .accessDenied)
        XCTAssertEqual(DirectoryListingError.dataless.nodeFlag, .dataless)
        XCTAssertEqual(DirectoryListingError.vanished.nodeFlag, .unreadable)
    }
}
