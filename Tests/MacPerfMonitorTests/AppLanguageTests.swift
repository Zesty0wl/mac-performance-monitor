// SPDX-License-Identifier: MIT
import XCTest

@testable import MacPerfMonitor

final class AppLanguageTests: XCTestCase {
    func testExplicitChineseLanguageKeepsItsScriptAndReviewNotice() {
        XCTAssertEqual(AppLanguage.zhHant.effective, .zhHant)
        XCTAssertTrue(AppLanguage.zhHant.isMachineTranslated)
        XCTAssertEqual(AppLanguage.zhHant.machineTranslationModel, "OpenAI GPT-6.1")
        XCTAssertEqual(AppLanguage.zhHans.effective, .zhHans)
    }

    func testNegotiatedChineseScriptIsPreserved() {
        XCTAssertEqual(
            AppLanguage.resolvedSystemLanguage(preferredLocalizations: ["zh-Hant", "en"]), .zhHant)
        XCTAssertEqual(
            AppLanguage.resolvedSystemLanguage(preferredLocalizations: ["zh-Hans", "en"]), .zhHans)
    }

    func testUnavailableLanguagesFallBackToFirstSupportedLanguage() {
        XCTAssertEqual(AppLanguage.resolvedSystemLanguage(preferredLocalizations: []), .en)
        XCTAssertEqual(
            AppLanguage.resolvedSystemLanguage(preferredLocalizations: ["unsupported"]), .en)
        XCTAssertEqual(
            AppLanguage.resolvedSystemLanguage(preferredLocalizations: ["unsupported", "fr"]), .fr)
        XCTAssertEqual(
            AppLanguage.resolvedSystemLanguage(preferredLocalizations: ["system", "zh-Hant"]),
            .zhHant)
    }
}
