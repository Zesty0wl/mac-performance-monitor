import XCTest

@testable import MacPerfMonitorCore

final class AppGroupingTests: XCTestCase {
    private let mb: UInt64 = 1024 * 1024

    private func sample(
        pid: Int32, name: String, path: String? = nil, coalition: UInt64?,
        responsible: Int32? = nil, footprintMB: UInt64 = 0, cpu: Double = 0,
        threads: Int32 = 1, gpu: Double? = nil, started: TimeInterval = 0,
        readable: Bool = true
    ) -> ProcessSample {
        ProcessSample(
            timestamp: Date(timeIntervalSince1970: 1_000), pid: pid, ppid: 1, name: name,
            executablePath: path, physFootprint: footprintMB * mb, residentSize: 0,
            virtualSize: 0, lifetimeMaxFootprint: 0, cpuPercent: cpu, cpuTimeUser: 0,
            cpuTimeSystem: 0, threadCount: threads, fdTotal: 2, fdVnode: 0, fdSocket: 0,
            fdPipe: 0, fdOther: 0, diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false,
            architecture: .arm64, startTime: Date(timeIntervalSince1970: started), uid: 501,
            dataSource: .directUserRead, footprintReadable: readable, gpuPercent: gpu,
            coalitionID: coalition, responsiblePID: responsible)
    }

    /// Safari's content processes are launchd's children, not Safari's, so
    /// only the shared coalition ties them to it.
    private var safari: [ProcessSample] {
        [
            sample(
                pid: 100, name: "Safari",
                path:
                    "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
                coalition: 7, responsible: 100, footprintMB: 300, cpu: 2, threads: 40,
                started: 10),
            sample(
                pid: 200, name: "com.apple.WebKit", coalition: 7, responsible: 100,
                footprintMB: 900, cpu: 10, threads: 20, gpu: 3, started: 20),
            sample(
                pid: 201, name: "com.apple.WebKit", coalition: 7, responsible: 100,
                footprintMB: 800, cpu: 5, threads: 10, gpu: 1, started: 21),
        ]
    }

    func testGroupsByCoalitionAndTotals() {
        let lone = sample(pid: 50, name: "syslogd", coalition: 3, footprintMB: 5)
        let unknown = sample(pid: 60, name: "mystery", coalition: nil, footprintMB: 9)
        let result = AppGrouping.group(safari + [lone, unknown])

        XCTAssertEqual(result.groups.count, 1)
        let group = result.groups[0]
        XCTAssertEqual(group.members.count, 3)
        XCTAssertEqual(group.leader.pid, 100)
        XCTAssertEqual(group.total.displayName, "Safari")
        XCTAssertEqual(group.total.physFootprint, 2_000 * mb)
        XCTAssertEqual(group.total.cpuPercent, 17, accuracy: 1e-9)
        XCTAssertEqual(group.total.threadCount, 70)
        XCTAssertEqual(group.total.fdTotal, 6)
        XCTAssertEqual(group.total.gpuPercent ?? -1, 4, accuracy: 1e-9)
        // The total is the leader's sample, so it draws the leader's icon and
        // its id resolves to the leader's live sample.
        XCTAssertEqual(group.total.id, group.leader.id)

        // Alone in a coalition, or with none readable, stays a plain row.
        XCTAssertEqual(Set(result.loose.map(\.pid)), [50, 60])
    }

    func testLeaderIsTheResponsibleMemberEvenWhenNotOldest() {
        // A helper started before the app (a launch race) must not name it.
        var members = safari
        members[1].startTime = Date(timeIntervalSince1970: 1)
        let group = AppGrouping.makeGroup(coalitionID: 7, members: members)
        XCTAssertEqual(group.leader.pid, 100)
    }

    func testLeaderFallsBackToAppExecutableThenOldest() {
        // No responsible pid readable (root processes): prefer the app's main
        // executable over an older daemon in the same coalition.
        let members = [
            sample(
                pid: 10, name: "helperd", path: "/usr/libexec/helperd", coalition: 9, started: 1),
            sample(
                pid: 20, name: "MSTeams",
                path: "/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams",
                coalition: 9, started: 5),
        ]
        let group = AppGrouping.makeGroup(coalitionID: 9, members: members)
        XCTAssertEqual(group.leader.pid, 20)
        // Named after the bundle, not the binary.
        XCTAssertEqual(group.total.displayName, "Microsoft Teams")

        let daemons = [
            sample(pid: 31, name: "b", coalition: 4, started: 3),
            sample(pid: 30, name: "a", coalition: 4, started: 2),
        ]
        XCTAssertEqual(AppGrouping.makeGroup(coalitionID: 4, members: daemons).leader.pid, 30)
    }

    func testResponsiblePIDOutsideTheGroupIsIgnored() {
        // Members blaming a process that is not in the coalition (or has
        // exited) fall through to the oldest member.
        let members = [
            sample(pid: 41, name: "worker", coalition: 5, responsible: 999, started: 2),
            sample(pid: 40, name: "main", coalition: 5, responsible: 999, started: 1),
        ]
        XCTAssertEqual(AppGrouping.makeGroup(coalitionID: 5, members: members).leader.pid, 40)
    }

    func testUnreadableMembersDoNotBlankTheApp() {
        var members = safari
        members[1].footprintReadable = false
        members[1].physFootprint = 0
        let group = AppGrouping.makeGroup(coalitionID: 7, members: members)
        XCTAssertTrue(group.total.footprintReadable)
        XCTAssertEqual(group.total.physFootprint, 1_100 * mb)
    }

    func testGPUStaysNilWhenNoMemberUsesIt() {
        let members = [
            sample(pid: 1, name: "a", coalition: 2), sample(pid: 2, name: "b", coalition: 2),
        ]
        XCTAssertNil(AppGrouping.makeGroup(coalitionID: 2, members: members).total.gpuPercent)
    }

    func testAppGroupIdentityNeverMatchesAProcess() {
        let id = ProcessIdentity.appGroup(coalitionID: 7)
        XCTAssertTrue(id.isAppGroup)
        XCTAssertEqual(id, .appGroup(coalitionID: 7))
        XCTAssertNotEqual(id, .appGroup(coalitionID: 8))
        XCTAssertFalse(safari[0].id.isAppGroup)
        // Coalition IDs beyond Int32 still map to a valid negative pid.
        XCTAssertTrue(ProcessIdentity.appGroup(coalitionID: UInt64.max).pid < 0)
    }

    func testAppBundleName() {
        XCTAssertEqual(
            AppGrouping.appBundleName(
                forExecutablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode"), "Xcode")
        // The innermost bundle owns the executable.
        XCTAssertEqual(
            AppGrouping.appBundleName(
                forExecutablePath:
                    "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
            ), "Simulator")
        XCTAssertNil(AppGrouping.appBundleName(forExecutablePath: "/usr/libexec/trustd"))
        XCTAssertNil(
            AppGrouping.appBundleName(
                forExecutablePath:
                    "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
            ))
        XCTAssertNil(AppGrouping.appBundleName(forExecutablePath: nil))
        // A second binary in an app's Contents/MacOS (a privileged helper) is
        // not the app: only the bundle's CFBundleExecutable takes its name.
        XCTAssertEqual(
            AppGrouping.appBundleName(
                forExecutablePath: "/System/Applications/Calculator.app/Contents/MacOS/Calculator"),
            "Calculator")
        XCTAssertNil(
            AppGrouping.appBundleName(
                forExecutablePath:
                    "/System/Applications/Calculator.app/Contents/MacOS/CalculatorHelper"))
        XCTAssertEqual(
            AppGrouping.appBundlePath(
                forExecutablePath: "/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams"),
            "/Applications/Microsoft Teams.app")
    }

    func testReaderReadsCoalitionForThisProcess() {
        let reader = ProcessReader()
        let pid = getpid()
        XCTAssertNotNil(reader.coalitionID(pid))
        // A process launched by xctest shares nothing with launchd's.
        XCTAssertNotEqual(reader.coalitionID(pid), reader.coalitionID(1))
    }
}
