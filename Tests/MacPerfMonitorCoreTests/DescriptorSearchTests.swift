import XCTest

@testable import MacPerfMonitorCore

final class DescriptorSearchTests: XCTestCase {
    private func file(_ path: String) -> OpenFileDescriptor {
        OpenFileDescriptor(fd: 3, kind: .file, detail: path)
    }

    private func socket(_ detail: String) -> OpenFileDescriptor {
        OpenFileDescriptor(fd: 4, kind: .socket, detail: detail)
    }

    func testTextMatchesAnywhereIgnoringCase() {
        let db = file("/Users/me/Library/Application Support/App/Store.sqlite")
        XCTAssertTrue(DescriptorSearch.matches(db, term: "store.SQLITE"))
        XCTAssertTrue(DescriptorSearch.matches(db, term: "  application support "))
        XCTAssertFalse(DescriptorSearch.matches(db, term: "Caches"))
        XCTAssertFalse(DescriptorSearch.matches(db, term: "   "))
    }

    func testDigitsMatchAWholePortOnSockets() {
        let listener = socket("tcp 0.0.0.0:8080 (listening)")
        let web = socket("tcp 10.80.0.2:51234 -> 17.253.144.10:443")
        let v6 = socket("tcp [::1]:80 -> [::1]:52000")
        XCTAssertTrue(DescriptorSearch.matches(listener, term: "8080"))
        XCTAssertFalse(DescriptorSearch.matches(listener, term: "80"), "80 is not port 8080")
        XCTAssertFalse(DescriptorSearch.matches(listener, term: "808"))
        XCTAssertTrue(DescriptorSearch.matches(web, term: "443"))
        XCTAssertTrue(DescriptorSearch.matches(web, term: "51234"))
        XCTAssertFalse(DescriptorSearch.matches(web, term: "80"), "10.80.0.2 is not port 80")
        XCTAssertTrue(DescriptorSearch.matches(v6, term: "80"))
    }

    func testDigitsMatchAsTextInFilePaths() {
        XCTAssertTrue(DescriptorSearch.matches(file("/var/log/app-8080.log"), term: "80"))
    }

    func testAddressesMatchAsText() {
        let web = socket("tcp 10.0.0.2:51234 -> 17.253.144.10:443")
        XCTAssertTrue(DescriptorSearch.matches(web, term: "17.253"))
        XCTAssertTrue(DescriptorSearch.matches(web, term: "TCP"))
    }

    func testMatchesCarryTheProcess() {
        let target = DescriptorSearchTarget(pid: 77, name: "server", uid: 501)
        let found = DescriptorSearch.matches(
            in: [file("/tmp/a.log"), socket("tcp 0.0.0.0:8080 (listening)")], of: target,
            term: "8080")
        XCTAssertEqual(found.map(\.id), ["77:4"])
        XCTAssertEqual(found.first?.processName, "server")
    }

    func testTargetsIncludeThisProcessWithItsOwner() throws {
        let me = try XCTUnwrap(DescriptorSearch.targets().first { $0.pid == getpid() })
        XCTAssertEqual(me.uid, getuid())
        XCTAssertFalse(me.name.isEmpty)
        // launchd is listed even though a normal user cannot read it.
        let launchd = try XCTUnwrap(DescriptorSearch.targets().first { $0.pid == 1 })
        XCTAssertEqual(launchd.name, "launchd")
        if geteuid() != 0 { XCTAssertNil(launchd.uid) }
    }

    /// The real thing, end to end: open a file, then find this process by it.
    func testFindsThisProcessByAFileItHasOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpm-find-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let target = DescriptorSearchTarget(pid: getpid(), name: "xctest", uid: getuid())
        let descriptors = try XCTUnwrap(ProcessReader().openFileDescriptors(getpid()))
        let found = DescriptorSearch.matches(
            in: descriptors, of: target, term: url.lastPathComponent)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.descriptor.kind, .file)
    }

    func testMappedFilesMatchOnPathAndAreMarked() {
        let target = DescriptorSearchTarget(pid: 9, name: "app", uid: 501)
        let files = [
            MappedFile(path: "/usr/lib/libz.1.dylib", mappedBytes: 1),
            MappedFile(path: "/Library/Fonts/8080.ttf", mappedBytes: 1),
        ]
        let found = DescriptorSearch.matches(inMapped: files, of: target, term: "LIBZ")
        XCTAssertEqual(found.map(\.descriptor.detail), ["/usr/lib/libz.1.dylib"])
        XCTAssertEqual(found.first?.isMapped, true)
        XCTAssertEqual(found.first?.id, "9:mapped:/usr/lib/libz.1.dylib")
        // Digits are plain text for a mapped file.
        XCTAssertEqual(DescriptorSearch.matches(inMapped: files, of: target, term: "80").count, 1)
        XCTAssertTrue(DescriptorSearch.matches(inMapped: files, of: target, term: " ").isEmpty)
    }

    /// The same file open and mapped gives two results with different IDs.
    func testOpenAndMappedMatchesOfOneFileAreDistinct() {
        let target = DescriptorSearchTarget(pid: 9, name: "app", uid: 501)
        let open = DescriptorSearch.matches(in: [file("/tmp/a.db")], of: target, term: "a.db")
        let mapped = DescriptorSearch.matches(
            inMapped: [MappedFile(path: "/tmp/a.db", mappedBytes: 1)], of: target, term: "a.db")
        XCTAssertEqual(Set((open + mapped).map(\.id)).count, 2)
    }
}
