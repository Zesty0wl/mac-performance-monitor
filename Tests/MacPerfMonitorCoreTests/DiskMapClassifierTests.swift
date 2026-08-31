import XCTest

@testable import MacPerfMonitorCore

final class DiskMapClassifierTests: XCTestCase {
    private func kind(_ name: String, directory: Bool = false) -> FileKind {
        FileKindClassifier.kind(forName: name, isDirectory: directory)
    }

    func testFileKindsByExtension() {
        XCTAssertEqual(kind("movie.MOV"), .video)
        XCTAssertEqual(kind("IMG_0001.heic"), .image)
        XCTAssertEqual(kind("track.flac"), .audio)
        XCTAssertEqual(kind("Xcode.dmg"), .archive)
        XCTAssertEqual(kind("thesis.pdf"), .document)
        XCTAssertEqual(kind("main.swift"), .code)
        XCTAssertEqual(kind("DSC_0100.raw"), .image)
        XCTAssertEqual(kind("model.gguf"), .data)
        XCTAssertEqual(kind("system.log"), .cache)
        XCTAssertEqual(kind("kernel.kernelcache"), .system)
        XCTAssertEqual(kind("README"), .other)
        XCTAssertEqual(kind(".zshrc"), .other)
        XCTAssertEqual(kind("archive.tar.gz"), .archive)
        XCTAssertEqual(
            kind("weird.verylongextension"), .other)
        XCTAssertEqual(kind("trailingdot."), .other)
        XCTAssertEqual(kind("ünïcödé.jpg"), .image)
    }

    func testPackagesAndFolders() {
        XCTAssertEqual(kind("Safari.app", directory: true), .application)
        XCTAssertEqual(kind("Foo.framework", directory: true), .application)
        XCTAssertEqual(kind("Proj.xcodeproj", directory: true), .code)
        XCTAssertEqual(
            kind("Photos Library.photoslibrary", directory: true), .image)
        XCTAssertEqual(kind("Documents", directory: true), .folder)
        XCTAssertEqual(kind("node_modules", directory: true), .folder)
        XCTAssertEqual(kind("photo.jpg", directory: true), .folder)
        XCTAssertTrue(FileKindClassifier.isPackage(name: "Thing.APP"))
        XCTAssertFalse(FileKindClassifier.isPackage(name: "Thing"))
    }

    func testDisplayOrderCoversEveryNonFolderKind() {
        let ordered = Set(FileKind.displayOrder)
        for kind in FileKind.allCases where kind != .folder {
            XCTAssertTrue(ordered.contains(kind), kind.label)
        }
        XCTAssertFalse(ordered.contains(.folder))
    }

    // MARK: - Firmlinks

    private let map = FirmlinkMap(lines: [
        "/Users\tUsers",
        "/Applications\tApplications",
        "/Library\tLibrary",
        "/System/Library/Caches\tSystem/Library/Caches",
        "/usr/local\tusr/local",
        "/private\tprivate",
        "garbage line without tab",
    ])

    func testCanonicalPaths() {
        XCTAssertEqual(map.canonicalPath("/System/Volumes/Data/Users/neil/x"), "/Users/neil/x")
        XCTAssertEqual(map.canonicalPath("/System/Volumes/Data/Users"), "/Users")
        XCTAssertEqual(map.canonicalPath("/System/Volumes/Data"), "/")
        XCTAssertEqual(
            map.canonicalPath("/System/Volumes/Data/System/Library/Caches/a"),
            "/System/Library/Caches/a")
        XCTAssertEqual(map.canonicalPath("/System/Volumes/Data/usr/local/bin"), "/usr/local/bin")
        XCTAssertEqual(
            map.canonicalPath("/System/Volumes/Data/.Spotlight-V100"),
            "/System/Volumes/Data/.Spotlight-V100")
        XCTAssertEqual(map.canonicalPath("/Users/neil"), "/Users/neil")
        XCTAssertEqual(
            map.canonicalPath("/System/Volumes/DataX/Users"), "/System/Volumes/DataX/Users")
        XCTAssertEqual(
            map.canonicalPath("/System/Volumes/Data/Userspace"), "/System/Volumes/Data/Userspace",
            "prefix matches must stop at a component boundary")
    }

    func testDataVolumePaths() {
        XCTAssertEqual(map.dataVolumePath("/Users/neil"), "/System/Volumes/Data/Users/neil")
        XCTAssertEqual(map.dataVolumePath("/Users"), "/System/Volumes/Data/Users")
        XCTAssertEqual(map.dataVolumePath("/Volumes/Ext"), "/Volumes/Ext")
        XCTAssertEqual(map.dataVolumePath("/Userspace/x"), "/Userspace/x")
    }

    func testSystemMapLoadsWhenPresent() {
        guard FileManager.default.fileExists(atPath: "/usr/share/firmlinks") else { return }
        XCTAssertEqual(FirmlinkMap.system.canonicalPath("/System/Volumes/Data/Users/x"), "/Users/x")
    }

    // MARK: - Scope

    func testScopeResolution() {
        XCTAssertEqual(DiskMapScope.resolved(folder: "/"), .startupDisk)
        XCTAssertEqual(DiskMapScope.resolved(folder: "/System"), .startupDisk)
        XCTAssertEqual(DiskMapScope.resolved(folder: "/System/"), .startupDisk)
        XCTAssertEqual(DiskMapScope.resolved(folder: "/System/Volumes/Data"), .startupDisk)
        XCTAssertEqual(DiskMapScope.resolved(folder: NSHomeDirectory()), .home)
        XCTAssertEqual(DiskMapScope.resolved(folder: "/Volumes/Ext/"), .folder("/Volumes/Ext"))
        XCTAssertEqual(DiskMapScope.resolved(folder: "/tmp/../tmp/a"), .folder("/tmp/a"))
    }

    func testScopeNamesAndIDs() {
        XCTAssertEqual(DiskMapScope.startupDisk.rootName, "Macintosh HD")
        XCTAssertEqual(DiskMapScope.startupDisk.displayRoot, "/")
        XCTAssertEqual(DiskMapScope.startupDisk.id, "startup")
        XCTAssertEqual(DiskMapScope.folder("/Users/neil/Movies").rootName, "Movies")
        XCTAssertEqual(DiskMapScope.volume("/Volumes/Backup").rootName, "Backup")
        XCTAssertEqual(DiskMapScope.volume("/").rootName, "Macintosh HD")
        XCTAssertTrue(DiskMapScope.startupDisk.isWholeVolume)
        XCTAssertFalse(DiskMapScope.home.isWholeVolume)
        let a = DiskMapScope.folder("/Users/neil/Movies").id
        let b = DiskMapScope.folder("/Users/neil/Music").id
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("folder-"))
        XCTAssertFalse(a.contains("/"))
        let long = DiskMapScope.folder(String(repeating: "/abcdefghij", count: 30)).id
        XCTAssertLessThan(long.count, 80)
    }

    func testScopeRoundTripsThroughCodable() throws {
        let scopes: [DiskMapScope] = [.startupDisk, .home, .folder("/a/b"), .volume("/Volumes/X")]
        for scope in scopes {
            let data = try JSONEncoder().encode(scope)
            XCTAssertEqual(try JSONDecoder().decode(DiskMapScope.self, from: data), scope)
        }
    }

    func testStatfsHelpersOnTheRoot() {
        XCTAssertEqual(DiskMapScope.mountPoint(ofPath: "/"), "/")
        XCTAssertNotNil(DiskMapScope.usedInodes(ofPath: "/"))
        XCTAssertNil(DiskMapScope.mountPoint(ofPath: "/definitely/not/here"))
    }

    func testAdaptiveThreshold() {
        XCTAssertEqual(DiskMapScanOptions.adaptiveThreshold(usedInodes: nil), 16_384)
        XCTAssertEqual(DiskMapScanOptions.adaptiveThreshold(usedInodes: 10_000), 0)
        XCTAssertEqual(DiskMapScanOptions.adaptiveThreshold(usedInodes: 3_000_000), 16_384)
        XCTAssertEqual(DiskMapScanOptions.adaptiveThreshold(usedInodes: 12_000_000), 65_536)
    }
}
