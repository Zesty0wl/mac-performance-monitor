import Foundation
import XCTest

@testable import MacPerfMonitor

final class CodeSignInfoTests: XCTestCase {
    /// A signing identifier or path with quotes in it is the binary author's
    /// choice; it must stay one value and never add a key to the rule.
    func testRuleJSONEscapesSignerChosenStrings() throws {
        let info = CodeSignInfo(
            path: "/x/q\".app/Contents/MacOS/b", format: nil,
            signingID: "a\", \"TeamID\" : \"*APPLE*", teamID: nil, cdHash: "00ff",
            cdHashes: [], signingState: .adHoc, authorities: [], isAdHoc: true, isSigned: true,
            validity: .valid, signedTimestamp: nil, flagsDescription: nil,
            designatedRequirement: nil)
        let json = CodesignSheet.appSettingsRuleJSON(info)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        XCTAssertEqual(
            object,
            [
                "CDHash": "00ff", "SigningID": "a\", \"TeamID\" : \"*APPLE*",
                "PathPrefix": "/x/q\".app",
            ])
    }

    func testSigningStateOfRealBinaries() {
        let calculator = "/System/Applications/Calculator.app/Contents/MacOS/Calculator"
        XCTAssertEqual(CodeSignInfo.inspect(path: calculator).signingState, .apple)
    }
}
