import Foundation
import Security
import XCTest

@testable import MacPerfMonitorIPC

final class CodeSigningIdentityTests: XCTestCase {
    /// The ad-hoc helper pin is `cdhash H"<hex>"` built from
    /// `codeDirectoryHash`. Prove that form matches the code it was read from
    /// and nothing else, using two system binaries.
    func testCDHashRequirementMatchesOnlyItsOwnCode() throws {
        let ls = URL(fileURLWithPath: "/bin/ls")
        let cat = URL(fileURLWithPath: "/bin/cat")
        let hash = try XCTUnwrap(codeDirectoryHash(ofCodeAt: ls))
        let hex = hash.map { String(format: "%02x", $0) }.joined()

        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &requirement),
            errSecSuccess)
        let req = try XCTUnwrap(requirement)
        XCTAssertEqual(check(ls, req), errSecSuccess)
        XCTAssertNotEqual(check(cat, req), errSecSuccess)
    }

    func testUnsignedCodeHasNoHash() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsigned-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(codeDirectoryHash(ofCodeAt: file))
    }

    func testNeverRequirementParses() {
        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString("never" as CFString, [], &requirement), errSecSuccess)
    }

    private func check(_ url: URL, _ req: SecRequirement) -> OSStatus {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code
        else { return errSecCSUnsigned }
        return SecStaticCodeCheckValidity(code, [], req)
    }
}
