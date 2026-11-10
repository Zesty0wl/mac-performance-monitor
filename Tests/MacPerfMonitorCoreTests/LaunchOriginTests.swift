import XCTest

@testable import MacPerfMonitorCore

final class LaunchOriginTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpm-launch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ plist: [String: Any], to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url)
    }

    private func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    private func scanFixtures() -> LaunchJobIndex {
        LaunchJobIndex.scan(directories: [
            (path("user/LaunchAgents"), .userAgent), (path("lib/LaunchDaemons"), .daemon),
        ])
    }

    func testFindsJobsByProgramAndByFirstArgument() throws {
        try write(
            ["Label": "com.example.daemon", "Program": "/opt/example/bin/daemon"],
            to: "lib/LaunchDaemons/com.example.daemon.plist")
        try write(
            [
                "Label": "com.example.agent",
                "ProgramArguments": ["/opt/example/bin/agent", "--run"],
            ],
            to: "user/LaunchAgents/com.example.agent.plist")
        let index = scanFixtures()
        XCTAssertEqual(index.count, 2)

        let daemon = try XCTUnwrap(index.job(forExecutable: "/opt/example/bin/daemon"))
        XCTAssertEqual(daemon.label, "com.example.daemon")
        XCTAssertEqual(daemon.domain, .daemon)
        XCTAssertEqual(daemon.plistPath, path("lib/LaunchDaemons/com.example.daemon.plist"))
        XCTAssertEqual(index.job(forExecutable: "/opt/example/bin/agent")?.domain, .userAgent)
    }

    /// Two programs with the same file name are different programs.
    func testAMatchingFileNameElsewhereIsNotAMatch() throws {
        try write(
            ["Label": "com.example.agent", "Program": "/opt/example/bin/agent"],
            to: "user/LaunchAgents/com.example.agent.plist")
        XCTAssertNil(scanFixtures().job(forExecutable: "/opt/other/bin/agent"))
    }

    func testMalformedAndRelativeJobsAreSkipped() throws {
        try write(["Label": "no.program"], to: "lib/LaunchDaemons/a.plist")
        try write(["Label": "relative", "Program": "bin/thing"], to: "lib/LaunchDaemons/b.plist")
        try Data("not a plist".utf8).write(
            to: URL(fileURLWithPath: path("lib/LaunchDaemons/c.plist")))
        try write(["Label": "ignored", "Program": "/x"], to: "lib/LaunchDaemons/notes.txt")
        XCTAssertEqual(scanFixtures().count, 0)
        XCTAssertEqual(
            LaunchJobIndex.scan(directories: [(path("does/not/exist"), .agent)]).count, 0)
    }

    /// An SMAppService daemon: the job file is inside the app and names its
    /// program relative to the bundle.
    func testResolvesAnAppsOwnBundledDaemon() throws {
        let app = path("Apps/Tool.app")
        try write(
            ["Label": "com.example.tool.helper", "BundleProgram": "Contents/MacOS/ToolHelper"],
            to: "Apps/Tool.app/Contents/Library/LaunchDaemons/com.example.tool.helper.plist")
        let origin = LaunchOrigin.resolve(
            executablePath: app + "/Contents/MacOS/ToolHelper", parentPID: 1, parentName: nil,
            index: LaunchJobIndex())
        guard case .job(let job) = origin else { return XCTFail("Expected a job, got \(origin)") }
        XCTAssertEqual(job.domain, .appDaemon)
        XCTAssertEqual(job.label, "com.example.tool.helper")
        // The app's main executable is not what that job runs.
        XCTAssertEqual(
            LaunchOrigin.resolve(
                executablePath: app + "/Contents/MacOS/Tool", parentPID: 1, parentName: nil,
                index: LaunchJobIndex()), .unknown)
    }

    func testXPCServicesNameTheirOwner() {
        let service =
            "/Applications/Safari.app/Contents/XPCServices/com.apple.Safari.History.xpc/Contents/MacOS/com.apple.Safari.History"
        XCTAssertEqual(
            LaunchOrigin.resolve(
                executablePath: service, parentPID: 1, parentName: nil, index: LaunchJobIndex(),
                bundledJobs: { _ in [] }), .xpcService(owner: "/Applications/Safari.app"))
        let framework =
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
        XCTAssertEqual(
            LaunchOrigin.resolve(
                executablePath: framework, parentPID: 1, parentName: nil, index: LaunchJobIndex(),
                bundledJobs: { _ in [] }),
            .xpcService(owner: "/System/Library/Frameworks/WebKit.framework"))
    }

    func testParentIsUsedWhenNoJobNamesTheProgram() {
        XCTAssertEqual(
            LaunchOrigin.resolve(
                executablePath: "/bin/ls", parentPID: 812, parentName: "zsh",
                index: LaunchJobIndex()), .parent(pid: 812, name: "zsh"))
        XCTAssertEqual(
            LaunchOrigin.resolve(
                executablePath: "/bin/ls", parentPID: 812, parentName: nil, index: LaunchJobIndex()),
            .parent(pid: 812, name: "PID 812"))
        XCTAssertEqual(
            LaunchOrigin.resolve(
                executablePath: "/Applications/Notes.app/Contents/MacOS/Notes", parentPID: 1,
                parentName: nil, index: LaunchJobIndex(), bundledJobs: { _ in [] }), .unknown)
        XCTAssertEqual(
            LaunchOrigin.resolve(
                executablePath: nil, parentPID: 1, parentName: nil, index: LaunchJobIndex()),
            .unknown)
    }

    /// A job wins over the parent: launchd's children keep the job that
    /// started them even when something else is listed as responsible.
    func testAJobWinsOverAParent() throws {
        try write(
            ["Label": "com.example.daemon", "Program": "/opt/example/bin/daemon"],
            to: "lib/LaunchDaemons/com.example.daemon.plist")
        let origin = LaunchOrigin.resolve(
            executablePath: "/opt/example/bin/daemon", parentPID: 500, parentName: "sh",
            index: scanFixtures())
        guard case .job = origin else { return XCTFail("Expected a job, got \(origin)") }
    }

    func testCryptexPrefixesAreRemovedBeforeComparing() {
        XCTAssertEqual(
            LaunchJobIndex.normalized(
                "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
            ), "/System/Applications/Safari.app/Contents/MacOS/Safari")
        XCTAssertEqual(LaunchJobIndex.normalized("/usr/libexec/logd"), "/usr/libexec/logd")
    }

    /// The real folders on this Mac: they hold hundreds of jobs, and launchd's
    /// own children are found among them.
    func testRealJobFoldersIdentifyRunningSystemDaemons() async {
        let index = await LaunchJobIndexCache.shared.current()
        XCTAssertGreaterThan(index.count, 100)
        let reader = ProcessReader()
        let matched = reader.listPIDs().compactMap { reader.path($0) }
            .filter { index.job(forExecutable: $0) != nil }
        XCTAssertGreaterThan(matched.count, 20, "Running daemons should match their job files")
    }
}
