import XCTest

@testable import MacPerfMonitorCore

final class ProcessGlossaryTests: XCTestCase {
    private let g = ProcessGlossary(
        version: 1,
        entries: [
            .init(
                match: .init(name: "WindowServer"), title: "Window Server", description: "…",
                category: "system", vendor: "Apple"),
            .init(
                match: .init(bundleID: "com.google.Chrome"), title: "Google Chrome",
                description: "…", category: "app", vendor: "Google"),
            .init(
                match: .init(bundleIDPrefix: "com.google.Chrome.helper"), title: "Chrome helper",
                description: "…", category: "helper", vendor: "Google"),
            .init(
                match: .init(bundleIDPrefix: "com.apple."), title: "Apple system process",
                description: "…", category: "system", vendor: "Apple"),
            .init(
                match: .init(pathPrefix: "/System/Library/CoreServices/"), title: "Core service",
                description: "…", category: "system"),
            .init(
                match: .init(path: "/usr/bin/log"), title: "Unified logging command",
                description: "…", category: "system"),
            .init(
                match: .init(pathSuffix: "/com.example.agent/Contents/MacOS/agent"),
                title: "Example agent", description: "…", category: "helper"),
            .init(
                match: .init(pathPattern: "/.config/agency/"), title: "Agency service",
                description: "…", category: "developer"),
        ])

    func testExactNameWins() {
        XCTAssertEqual(
            g.lookup(name: "WindowServer", bundleID: nil, path: nil)?.title, "Window Server")
    }

    func testExactBundleIDBeatsPrefix() {
        // com.google.Chrome matches the exact entry, not the helper prefix.
        XCTAssertEqual(
            g.lookup(name: "Google Chrome", bundleID: "com.google.Chrome", path: nil)?.title,
            "Google Chrome")
    }

    func testLongestPrefixWins() {
        // A helper bundle id matches the specific helper prefix, not com.apple. and
        // not the bare com.google.Chrome exact entry.
        XCTAssertEqual(
            g.lookup(
                name: "Google Chrome Helper (Renderer)",
                bundleID: "com.google.Chrome.helper.renderer", path: nil)?.title,
            "Chrome helper")
    }

    func testTruncatedNameResolvesViaPath() {
        // Runtime p_comm is truncated; the full name lives in the executable path.
        let g2 = ProcessGlossary(
            version: 1,
            entries: [
                .init(
                    match: .init(name: "com.apple.WebKit.Networking"),
                    title: "WebKit networking", description: "…", category: "helper")
            ])
        let e = g2.lookup(
            name: "com.apple.WebKi", bundleID: nil,
            path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
                + "com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking")
        XCTAssertEqual(e?.title, "WebKit networking")
    }

    func testApplePrefixCatchAll() {
        XCTAssertEqual(
            g.lookup(name: "someunknownd", bundleID: "com.apple.someunknownd", path: nil)?.title,
            "Apple system process")
    }

    func testPathPrefixMatch() {
        XCTAssertEqual(
            g.lookup(
                name: "Spotlight", bundleID: nil,
                path: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight")?.title,
            "Core service")
    }

    func testExactPathDoesNotMatchSimilarExecutable() {
        XCTAssertEqual(
            g.lookup(name: "log", bundleID: nil, path: "/usr/bin/log")?.title,
            "Unified logging command")
        XCTAssertNil(g.lookup(name: "log", bundleID: nil, path: "/opt/tools/log"))
    }

    func testLongestPathSuffixAndPatternMatch() {
        XCTAssertEqual(
            g.lookup(
                name: "agent", bundleID: nil,
                path: "/Library/SystemExtensions/UUID/com.example.agent/Contents/MacOS/agent")?
                .title,
            "Example agent")
        XCTAssertEqual(
            g.lookup(
                name: "agency", bundleID: nil,
                path: "/Users/test/.config/agency/2026.7.1/agency")?.title,
            "Agency service")
    }

    func testNoMatchReturnsNilThenGenericDerivesAppName() {
        XCTAssertNil(g.lookup(name: "WeirdThing", bundleID: "io.example.weird", path: nil))
        let generic = ProcessGlossary.generic(
            name: "Foo", bundleID: "io.foo.bar",
            path: "/Applications/Foo.app/Contents/MacOS/Foo")
        XCTAssertEqual(generic.title, "Part of Foo")
    }

    /// The shipped seed must decode into the model and answer key lookups.
    func testSeedGlossaryDecodesAndMatches() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repo =
            here
            .deletingLastPathComponent()  // MacPerfMonitorCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = repo.appendingPathComponent("Resources/glossary.json")
        let glossary = try JSONDecoder().decode(ProcessGlossary.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(glossary.entries.count, 20)
        XCTAssertEqual(
            glossary.lookup(name: "WindowServer", bundleID: nil, path: nil)?.vendor, "Apple")
        XCTAssertEqual(
            glossary.lookup(
                name: "Google Chrome Helper (GPU)",
                bundleID: "com.google.Chrome.helper.gpu", path: nil)?.title, "Chrome helper process"
        )
        XCTAssertEqual(
            glossary.lookup(
                name: "Microsoft Word", bundleID: "com.microsoft.Word",
                path: "/Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word")?.title,
            "Microsoft Word")
        XCTAssertEqual(
            glossary.lookup(
                name: "Microsoft Teams WebView Helper",
                bundleID: "com.microsoft.teams2.helper", path: nil)?.title,
            "Microsoft Teams WebView helper")
        XCTAssertEqual(
            glossary.lookup(
                name: "wdavdaemon_enterprise", bundleID: "com.microsoft.wdav",
                path: "/Applications/Microsoft Defender.app/Contents/MacOS/"
                    + "wdavdaemon_enterprise.app/Contents/MacOS/wdavdaemon_enterprise")?.title,
            "Microsoft Defender EDR engine")
        XCTAssertEqual(
            glossary.lookup(
                name: "OneDrive File Provider", bundleID: nil,
                path:
                    "/Applications/OneDrive.app/Contents/PlugIns/OneDrive File Provider.appex/Contents/MacOS/OneDrive File Provider"
            )?.title,
            "OneDrive File Provider")
        XCTAssertEqual(
            glossary.lookup(
                name: "IntuneMdmAgent", bundleID: "com.microsoft.intuneMDMAgent",
                path: "/Library/Intune/Microsoft Intune Agent.app/Contents/MacOS/IntuneMdmAgent")?
                .title,
            "Microsoft Intune management agent")
        XCTAssertEqual(
            glossary.lookup(
                name: "Future Microsoft Helper", bundleID: "com.microsoft.future.helper",
                path: nil)?.title,
            "Microsoft background component")
        XCTAssertEqual(
            glossary.lookup(
                name: "node", bundleID: "com.microsoft.clawpilot.node",
                path:
                    "/Applications/Microsoft Scout.app/Contents/Resources/node/node.app/Contents/MacOS/node"
            )?
            .title,
            "Microsoft Scout Node.js helper")
        XCTAssertEqual(
            glossary.lookup(
                name: "com.microsoft.autoupdate.helper", bundleID: nil,
                path: "/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper")?.title,
            "Microsoft AutoUpdate privileged helper")
        XCTAssertEqual(
            glossary.lookup(
                name: "Microsoft Edge", bundleID: nil,
                path: "/private/var/folders/X/com.microsoft.edgemac.code_sign_clone/"
                    + "code_sign_clone.abc/Microsoft Edge.app.bundle/Contents/MacOS/Microsoft Edge")?
                .title,
            "Microsoft Edge code-signing copy")
        XCTAssertNil(
            glossary.lookup(name: "tracer", bundleID: nil, path: "/opt/example/tracer"),
            "a generic tracer executable must not be labeled as Microsoft Defender")
    }
}
