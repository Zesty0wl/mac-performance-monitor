import MacPerfMonitorCore
import XCTest

@testable import MacPerfMonitor

/// The one line the Details panel shows for what started a process.
/// `MetadataSection` is private, so this goes through the same text function
/// by way of a small accessor.
final class StartedByTextTests: XCTestCase {
    private func job(_ domain: LaunchJob.Domain) -> LaunchOrigin {
        .job(LaunchJob(plistPath: "/x/a.plist", label: "a", program: "/x/a", domain: domain))
    }

    func testEveryKnownOriginHasItsOwnLine() {
        let lines = [
            job(.daemon), job(.agent), job(.userAgent), job(.appDaemon), job(.appAgent),
            .xpcService(owner: "/Applications/Safari.app"), .parent(pid: 812, name: "zsh"),
        ].map { ProcessDetailStartedBy.text($0) }
        XCTAssertFalse(lines.contains(nil))
        XCTAssertEqual(Set(lines).count, lines.count)
    }

    func testOwnerAndParentAreNamed() {
        XCTAssertEqual(
            ProcessDetailStartedBy.text(.xpcService(owner: "/Applications/Safari.app")),
            t("launchd, as an XPC service of %@", "Safari"))
        XCTAssertEqual(
            ProcessDetailStartedBy.text(.parent(pid: 812, name: "zsh")),
            t("%1$@ (PID %2$d)", "zsh", 812))
    }

    func testNothingIsClaimedWhenTheOriginIsUnknown() {
        XCTAssertNil(ProcessDetailStartedBy.text(.unknown))
        XCTAssertNil(ProcessDetailStartedBy.text(nil))
    }
}
