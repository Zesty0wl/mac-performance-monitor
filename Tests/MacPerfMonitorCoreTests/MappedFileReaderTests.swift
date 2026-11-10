import XCTest

@testable import MacPerfMonitorCore

final class MappedFileReaderTests: XCTestCase {
    func testOwnProcessListsItsExecutableOnceWithASize() throws {
        let files = try XCTUnwrap(MappedFileReader().mappedFiles(getpid()))
        if ProcessInfo.processInfo.environment["MACPERF_PRINT_MAPPED"] != nil {
            for file in files { print("MAPPED", file.mappedBytes, file.path) }
        }
        XCTAssertEqual(Set(files.map(\.path)).count, files.count, "Each file is listed once")
        let executable = try XCTUnwrap(ProcessReader().path(getpid()))
        let mine = try XCTUnwrap(
            files.first {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            })
        XCTAssertGreaterThan(mine.mappedBytes, 0)
    }

    func testAFileMappedByTheTestAppears() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpm-mapped-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 64 * 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let length = 64 * 1024
        let mapping = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0)
        XCTAssertNotEqual(mapping, MAP_FAILED)
        defer { munmap(mapping, length) }

        let files = try XCTUnwrap(MappedFileReader().mappedFiles(getpid()))
        let found = try XCTUnwrap(files.first { $0.name == url.lastPathComponent })
        XCTAssertGreaterThanOrEqual(found.mappedBytes, UInt64(length))
        XCTAssertFalse(found.isLibrary)
    }

    func testUnreadableProcessReturnsNil() {
        XCTAssertNil(MappedFileReader().mappedFiles(-1))
        if geteuid() != 0 { XCTAssertNil(MappedFileReader().mappedFiles(1)) }
    }

    func testLibraryGuess() {
        XCTAssertTrue(MappedFile(path: "/usr/lib/libz.1.dylib", mappedBytes: 1).isLibrary)
        XCTAssertTrue(
            MappedFile(path: "/A.app/Contents/Frameworks/B.framework/Versions/A/B", mappedBytes: 1)
                .isLibrary)
        XCTAssertFalse(MappedFile(path: "/Users/me/data.sqlite", mappedBytes: 1).isLibrary)
        XCTAssertEqual(
            MappedFile(path: "/usr/lib/libz.1.dylib", mappedBytes: 1).name, "libz.1.dylib")
    }
}
