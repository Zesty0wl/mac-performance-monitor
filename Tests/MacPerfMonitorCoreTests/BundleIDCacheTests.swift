import XCTest

@testable import MacPerfMonitorCore

final class BundleIDCacheTests: XCTestCase {
    func testNonAppPathReturnsNilWithoutReading() {
        var reads = 0
        var cache = BundleIDCache(readPlist: { _ in
            reads += 1
            return "should.not.run"
        })
        XCTAssertNil(cache.bundleID(fromExecutablePath: "/usr/bin/swift"))
        XCTAssertEqual(reads, 0)
    }

    func testNilPathReturnsNil() {
        var cache = BundleIDCache(readPlist: { _ in "x" })
        XCTAssertNil(cache.bundleID(fromExecutablePath: nil))
    }

    func testReadsPlistOncePerAppBundle() {
        var reads = 0
        var cache = BundleIDCache(readPlist: { appPath in
            reads += 1
            XCTAssertEqual(appPath, "/Applications/Foo.app")
            return "com.example.foo"
        })
        let main = "/Applications/Foo.app/Contents/MacOS/Foo"
        let helper = "/Applications/Foo.app/Contents/MacOS/Foo Helper"
        XCTAssertEqual(cache.bundleID(fromExecutablePath: main), "com.example.foo")
        XCTAssertEqual(cache.bundleID(fromExecutablePath: helper), "com.example.foo")
        XCTAssertEqual(reads, 1)
    }

    func testNegativeResultIsCached() {
        var reads = 0
        var cache = BundleIDCache(readPlist: { _ in
            reads += 1
            return nil
        })
        let path = "/Applications/Bar.app/Contents/MacOS/Bar"
        XCTAssertNil(cache.bundleID(fromExecutablePath: path))
        XCTAssertNil(cache.bundleID(fromExecutablePath: path))
        XCTAssertEqual(reads, 1)
    }

    func testRemoveAllClearsCache() {
        var reads = 0
        var cache = BundleIDCache(readPlist: { _ in
            reads += 1
            return "com.example.baz"
        })
        let path = "/Applications/Baz.app/Contents/MacOS/Baz"
        _ = cache.bundleID(fromExecutablePath: path)
        cache.removeAll()
        _ = cache.bundleID(fromExecutablePath: path)
        XCTAssertEqual(reads, 2)
    }

    func testDefaultReaderLoadsRealInfoPlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleIDCacheTests-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("TestApp.app/Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.test.bundleidcache"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = BundleIDCache()
        let exe = root.appendingPathComponent("TestApp.app/Contents/MacOS/TestApp").path
        XCTAssertEqual(cache.bundleID(fromExecutablePath: exe), "com.test.bundleidcache")
        // Second call must hit cache (still correct).
        XCTAssertEqual(cache.bundleID(fromExecutablePath: exe), "com.test.bundleidcache")
    }

    func testOversizedOrNonRegularInfoPlistIsNotRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleIDCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("Big.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        // Sparse: 100 MiB long, no disk used. Must be refused before allocating.
        let plist = big.appendingPathComponent("Info.plist").path
        XCTAssertTrue(FileManager.default.createFile(atPath: plist, contents: nil))
        XCTAssertEqual(truncate(plist, 100 << 20), 0)
        let bigApp = root.appendingPathComponent("Big.app").path
        XCTAssertNil(BundleIDCache.readInfoPlist(ofAppBundle: bigApp))

        // A FIFO in place of the plist must not block the reader.
        let pipe = root.appendingPathComponent("Pipe.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: pipe, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(pipe.appendingPathComponent("Info.plist").path, 0o600), 0)
        let pipeApp = root.appendingPathComponent("Pipe.app").path
        XCTAssertNil(BundleIDCache.readInfoPlist(ofAppBundle: pipeApp))
    }
}
