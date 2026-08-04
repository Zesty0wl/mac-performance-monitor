import XCTest

@testable import MacPerfMonitorCore

final class ByteFormatTests: XCTestCase {
    func testBytesUnit() {
        XCTAssertEqual(ByteFormat.string(512), "512 bytes")
    }

    func testKilobytes() {
        XCTAssertEqual(ByteFormat.string(1536, fractionDigits: 1), "1.5 KB")
    }

    func testGigabytes() {
        // 1.5 GiB
        let value: UInt64 = 1536 * 1024 * 1024
        XCTAssertEqual(ByteFormat.string(value, fractionDigits: 1), "1.5 GB")
    }

    func testPercent() {
        XCTAssertEqual(ByteFormat.percent(0.42), "42%")
    }
}

final class ResolvedDisplayNameTests: XCTestCase {
    func testRecoversKernelTruncatedName() {
        XCTAssertEqual(
            ProcessSample.resolvedDisplayName(
                name: "com.apple.WebK",
                executablePath: "/System/Frameworks/WebKit/com.apple.WebKit.WebContent"),
            "com.apple.WebKit.WebContent")
    }

    func testKeepsNameWhenPathAgrees() {
        XCTAssertEqual(
            ProcessSample.resolvedDisplayName(
                name: "Finder",
                executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            "Finder")
    }

    func testKeepsNameWithoutPath() {
        XCTAssertEqual(
            ProcessSample.resolvedDisplayName(name: "kernel_task", executablePath: nil),
            "kernel_task")
        XCTAssertEqual(
            ProcessSample.resolvedDisplayName(name: "launchd", executablePath: ""), "launchd")
    }

    func testTrustsPathOverTrampolineName() {
        // A history row can pair xpcproxy's name with the exec'd binary's path
        // (the sample straddled the exec); the path names the real program.
        XCTAssertEqual(
            ProcessSample.resolvedDisplayName(
                name: "xpcproxy",
                executablePath: "/Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word"),
            "Microsoft Word")
    }

    func testGenuineTrampolineKeepsItsName() {
        XCTAssertEqual(
            ProcessSample.resolvedDisplayName(
                name: "xpcproxy", executablePath: "/usr/libexec/xpcproxy"),
            "xpcproxy")
    }
}

final class PressureLevelTests: XCTestCase {
    func testRawMapping() {
        XCTAssertEqual(PressureLevel(rawLevel: 1), .normal)
        XCTAssertEqual(PressureLevel(rawLevel: 2), .warning)
        XCTAssertEqual(PressureLevel(rawLevel: 4), .critical)
        XCTAssertEqual(PressureLevel(rawLevel: 99), .normal)
    }

    func testComparable() {
        XCTAssertLessThan(PressureLevel.normal, PressureLevel.warning)
        XCTAssertLessThan(PressureLevel.warning, PressureLevel.critical)
    }
}
