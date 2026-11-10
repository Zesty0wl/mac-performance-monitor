import CryptoKit
import XCTest

@testable import MacPerfMonitor

final class CodeSignInfoDetailTests: XCTestCase {
    func testSHA256MatchesHashingTheWholeFile() throws {
        let path = "/bin/ls"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(CodeSignInfo.sha256(ofExecutableAt: path), expected)
        XCTAssertEqual(CodeSignInfo.inspect(path: path).sha256, expected)
    }

    func testSHA256OfABundleIsItsExecutables() throws {
        let app = "/System/Applications/Calculator.app"
        let executable = try XCTUnwrap(Bundle(path: app)?.executableURL)
        XCTAssertEqual(
            CodeSignInfo.sha256(ofExecutableAt: app),
            CodeSignInfo.sha256(ofExecutableAt: executable.path))
        XCTAssertNil(CodeSignInfo.sha256(ofExecutableAt: "/no/such/file"))
        XCTAssertNil(
            CodeSignInfo.sha256(ofExecutableAt: "/tmp"), "A plain folder has no executable")
    }

    func testSandboxedAppReportsItsEntitlementsSorted() {
        let info = CodeSignInfo.inspect(path: "/System/Applications/Calculator.app")
        let sandbox = info.entitlements.first { $0.key == "com.apple.security.app-sandbox" }
        XCTAssertEqual(sandbox?.value, "true")
        XCTAssertEqual(info.entitlements.map(\.key), info.entitlements.map(\.key).sorted())
    }

    func testEntitlementValuesAreFlattenedToText() {
        XCTAssertEqual(CodeSignInfo.entitlementText(true), "true")
        XCTAssertEqual(CodeSignInfo.entitlementText(false), "false")
        XCTAssertEqual(CodeSignInfo.entitlementText(NSNumber(value: 1)), "1")
        XCTAssertEqual(CodeSignInfo.entitlementText("group.example"), "group.example")
        XCTAssertEqual(CodeSignInfo.entitlementText(["a", "b"]), "a, b")
        XCTAssertEqual(CodeSignInfo.entitlementText([Any]()), "")
    }
}
