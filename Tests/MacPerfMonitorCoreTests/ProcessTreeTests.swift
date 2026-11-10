import XCTest

@testable import MacPerfMonitorCore

final class ProcessTreeTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(
        _ pid: Int32, parent: Int32, startedAfter seconds: TimeInterval = 0
    )
        -> ProcessSample
    {
        ProcessSample(
            timestamp: epoch.addingTimeInterval(600), pid: pid, ppid: parent, name: "p\(pid)",
            physFootprint: 0, residentSize: 0, virtualSize: 0, lifetimeMaxFootprint: 0,
            cpuPercent: 0, cpuTimeUser: 0, cpuTimeSystem: 0, threadCount: 1, fdTotal: 0,
            fdVnode: 0, fdSocket: 0, fdPipe: 0, fdOther: 0, diskBytesRead: 0,
            diskBytesWritten: 0, isTranslated: false, architecture: .arm64,
            startTime: epoch.addingTimeInterval(seconds), uid: 501, dataSource: .directUserRead,
            footprintReadable: true)
    }

    func testDescendantsComeNearestGenerationFirst() {
        let processes = [
            sample(100, parent: 1),
            sample(130, parent: 110, startedAfter: 3),
            sample(110, parent: 100, startedAfter: 1),
            sample(120, parent: 100, startedAfter: 2),
            sample(140, parent: 130, startedAfter: 4),
            sample(200, parent: 1),
        ]
        let found = ProcessTree.descendants(of: processes[0].id, in: processes)
        XCTAssertEqual(found.map(\.pid), [110, 120, 130, 140])
    }

    func testProcessWithNoChildrenHasNoDescendants() {
        let processes = [sample(100, parent: 1), sample(200, parent: 1)]
        XCTAssertTrue(ProcessTree.descendants(of: processes[0].id, in: processes).isEmpty)
    }

    /// An old process whose `ppid` now names a newer, unrelated process is not
    /// that process's child: the number was reused after its real parent exited.
    func testReusedParentPIDIsNotAParent() {
        let root = sample(100, parent: 1, startedAfter: 50)
        let orphan = sample(90, parent: 100, startedAfter: 10)
        let child = sample(110, parent: 100, startedAfter: 60)
        let found = ProcessTree.descendants(of: root.id, in: [root, orphan, child])
        XCTAssertEqual(found.map(\.pid), [110])
    }

    func testCycleInParentLinksTerminates() {
        let a = sample(100, parent: 110)
        let b = sample(110, parent: 100)
        let own = sample(120, parent: 120)
        let found = ProcessTree.descendants(of: a.id, in: [a, b, own])
        XCTAssertEqual(found.map(\.pid), [110])
    }
}
