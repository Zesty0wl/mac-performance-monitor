import XCTest

@testable import MacPerfMonitorCore

final class GroupMatcherTests: XCTestCase {
    private let glossary = ProcessGlossary(
        version: 1,
        entries: [
            .init(
                match: .init(name: "falcond"), title: "CrowdStrike Falcon", description: "…",
                category: "security", vendor: "CrowdStrike"),
            // Microsoft Defender's daemon: a security tool, but vendor Microsoft —
            // the mixed-vendor case that motivates AND.
            .init(
                match: .init(name: "wdavdaemon"), title: "Microsoft Defender", description: "…",
                category: "security", vendor: "Microsoft"),
            .init(
                match: .init(bundleID: "com.microsoft.Word"), title: "Microsoft Word",
                description: "…", category: "app", vendor: "Microsoft"),
            .init(
                match: .init(bundleIDPrefix: "com.apple."), title: "Apple system process",
                description: "…", category: "system", vendor: "Apple"),
        ])

    private func candidate(
        name: String, bundleID: String? = nil, path: String? = nil, teamID: String? = nil
    ) -> GroupMatcher.Candidate {
        GroupMatcher.Candidate(name: name, bundleID: bundleID, executablePath: path, teamID: teamID)
    }

    private func cond(_ field: GroupCondition.Field, _ value: String) -> GroupRule {
        .condition(GroupCondition(field: field, op: .equals, value: value))
    }

    private func cond(
        _ field: GroupCondition.Field, _ op: GroupCondition.Op, _ value: String
    ) -> GroupRule {
        .condition(GroupCondition(field: field, op: op, value: value))
    }

    private func matches(_ c: GroupMatcher.Candidate, _ rule: GroupRule) -> Bool {
        GroupMatcher.matches(c, rule: rule, glossary: glossary)
    }

    // MARK: - Conditions

    func testTeamIDEquals() {
        let rule = cond(.teamID, "EQHXZ8M8AV")
        XCTAssertTrue(matches(candidate(name: "weird-daemon", teamID: "EQHXZ8M8AV"), rule))
        XCTAssertFalse(matches(candidate(name: "weird-daemon", teamID: "OTHER"), rule))
        XCTAssertFalse(matches(candidate(name: "weird-daemon", teamID: nil), rule))
    }

    /// Every python3 shares a name and a path, so the command label is the
    /// only field that can pick one out by the script it runs.
    func testCommandLabelSinglesOutOneInterpreter() {
        var train = candidate(name: "python3", path: "/usr/bin/python3")
        train.commandLabel = "train.py"
        var serve = candidate(name: "python3", path: "/usr/bin/python3")
        serve.commandLabel = "http.server"
        let plain = candidate(name: "python3", path: "/usr/bin/python3")

        XCTAssertTrue(matches(train, cond(.commandLabel, "TRAIN.PY")))
        XCTAssertFalse(matches(serve, cond(.commandLabel, "train.py")))
        XCTAssertFalse(matches(plain, cond(.commandLabel, "train.py")), "no label, no match")
        XCTAssertTrue(matches(serve, cond(.commandLabel, .startsWith, "http.")))
        // Combined with the name, as a "python3 running train" group would be.
        let rule = GroupRule.all([cond(.name, "python3"), cond(.commandLabel, .contains, "train")])
        XCTAssertTrue(matches(train, rule))
        XCTAssertFalse(matches(serve, rule))
    }

    func testClassificationEqualsViaGlossaryIsCaseInsensitive() {
        XCTAssertTrue(matches(candidate(name: "falcond"), cond(.classification, "security")))
        XCTAssertTrue(matches(candidate(name: "falcond"), cond(.classification, "SECURITY")))
        XCTAssertFalse(
            matches(
                candidate(name: "Microsoft Word", bundleID: "com.microsoft.Word"),
                cond(.classification, "security")))
    }

    func testVendorEquals() {
        XCTAssertTrue(
            matches(
                candidate(name: "Microsoft Word", bundleID: "com.microsoft.Word"),
                cond(.vendor, "Microsoft")))
        XCTAssertFalse(matches(candidate(name: "falcond"), cond(.vendor, "Microsoft")))
    }

    func testBundleIDStartsWithAndContains() {
        XCTAssertTrue(
            matches(
                candidate(name: "Word", bundleID: "com.microsoft.Word"),
                cond(.bundleID, .startsWith, "com.microsoft.")))
        XCTAssertFalse(
            matches(
                candidate(name: "Chrome", bundleID: "com.google.Chrome"),
                cond(.bundleID, .startsWith, "com.microsoft.")))
        XCTAssertTrue(
            matches(
                candidate(name: "wdav", bundleID: "com.microsoft.wdav"),
                cond(.bundleID, .contains, "wdav")))
    }

    func testPathStartsWith() {
        XCTAssertTrue(
            matches(
                candidate(name: "falcond", path: "/Library/CS/falcond"),
                cond(.path, .startsWith, "/Library/CS/")))
        XCTAssertFalse(
            matches(
                candidate(name: "falcond", path: "/usr/bin/falcond"),
                cond(.path, .startsWith, "/Library/CS/")))
    }

    func testNameContainsMatchesDeTruncatedName() {
        // Kernel name truncates; the de-truncated display name comes from the path.
        let c = candidate(
            name: "com.apple.WebK", path: "/System/.../com.apple.WebKit.GPU")
        XCTAssertTrue(matches(c, cond(.name, .contains, "WebKit")))
    }

    // MARK: - Boolean combinators

    func testAnyIsOr() {
        let rule = GroupRule.any([cond(.classification, "security"), cond(.teamID, "UBF8T346G9")])
        XCTAssertTrue(matches(candidate(name: "falcond"), rule))  // security
        XCTAssertTrue(matches(candidate(name: "x", teamID: "UBF8T346G9"), rule))  // team
        XCTAssertFalse(matches(candidate(name: "Chrome", teamID: "EQHXZ8M8AV"), rule))
    }

    func testAllIsAnd_MicrosoftAndSecurityIsolatesDefenderFromOffice() {
        let rule = GroupRule.all([cond(.vendor, "Microsoft"), cond(.classification, "security")])
        // Defender daemon is Microsoft AND security → matches.
        XCTAssertTrue(matches(candidate(name: "wdavdaemon"), rule))
        // Word is Microsoft but "app" → does not match.
        XCTAssertFalse(
            matches(candidate(name: "Microsoft Word", bundleID: "com.microsoft.Word"), rule))
    }

    func testNotNegates() {
        // security AND NOT name contains "helper"
        let rule = GroupRule.all([
            cond(.classification, "security"),
            .not(cond(.name, .contains, "helper")),
        ])
        XCTAssertTrue(matches(candidate(name: "falcond"), rule))
        XCTAssertFalse(matches(candidate(name: "falcond helper"), rule))
    }

    func testNestedTree() {
        // (vendor Microsoft AND classification security) OR teamID CrowdStrike
        let rule = GroupRule.any([
            .all([cond(.vendor, "Microsoft"), cond(.classification, "security")]),
            cond(.teamID, "X9E956P446"),
        ])
        XCTAssertTrue(matches(candidate(name: "wdavdaemon"), rule))  // MS + security
        XCTAssertTrue(matches(candidate(name: "x", teamID: "X9E956P446"), rule))  // team
        XCTAssertFalse(
            matches(candidate(name: "Microsoft Word", bundleID: "com.microsoft.Word"), rule))
    }

    // MARK: - Empty / safety

    func testEmptyTreesMatchNothing() {
        XCTAssertFalse(matches(candidate(name: "falcond"), .any([])))
        XCTAssertFalse(matches(candidate(name: "falcond"), .all([])))
        XCTAssertFalse(matches(candidate(name: "falcond"), cond(.teamID, "")))
        // NOT of an empty tree must not become "match everything".
        XCTAssertFalse(matches(candidate(name: "falcond"), .not(.any([]))))
    }

    func testGlossaryPredicateWithoutGlossaryFailsGracefully() {
        XCTAssertFalse(
            GroupMatcher.matches(
                candidate(name: "falcond"), rule: cond(.classification, "security"), glossary: nil))
    }

    // MARK: - condition(for:) precedence (the "Add to group" default)

    func testConditionForPrecedence() {
        XCTAssertEqual(
            GroupMatcher.condition(
                for: candidate(name: "x", bundleID: "com.x", path: "/x", teamID: "AAA")),
            cond(.teamID, "AAA"))
        XCTAssertEqual(
            GroupMatcher.condition(for: candidate(name: "x", bundleID: "com.x", path: "/x")),
            cond(.bundleID, "com.x"))
        XCTAssertEqual(
            GroupMatcher.condition(for: candidate(name: "x", path: "/x")),
            cond(.path, .startsWith, "/x"))
        XCTAssertEqual(
            GroupMatcher.condition(for: candidate(name: "x")),
            cond(.name, "x"))
    }
}
