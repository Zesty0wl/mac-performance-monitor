import XCTest

@testable import MacPerfMonitorCore

final class DiskCapacityBreakdownTests: XCTestCase {
    func testSlicesSumToContainerCapacityWithPurgeableCarvedFromLargest() {
        let container = APFSContainerInfo(
            bsdName: "disk3", capacityBytes: 1_000,
            physicalStoreBSDNames: ["disk0s2"], volumeBSDNames: [])
        let slices = DiskCapacityBreakdown.slices(
            container: container,
            volumes: [
                volume(mount: "/System/Volumes/Data", used: 600, purgeable: 50, role: .data),
                volume(mount: "/", used: 100, role: .system),
            ])

        XCTAssertEqual(slices.reduce(0) { $0 + $1.bytes }, 1_000)
        XCTAssertEqual(
            slices.map(\.label), ["Macintosh HD - Data", "Macintosh HD", "Purgeable", "Free"])
        // Purgeable (50) carved out of Data (600 - 50 = 550), not double counted.
        XCTAssertEqual(slices[0].bytes, 550)
        XCTAssertEqual(slices[2].bytes, 50)
        XCTAssertEqual(slices[3].bytes, 300)
        XCTAssertEqual(slices[3].kind, .free)
    }

    func testFoldsVolumesBeyondTheNamedCapAfterPurgeable() {
        let container = APFSContainerInfo(
            bsdName: "disk3", capacityBytes: 1_000,
            physicalStoreBSDNames: [], volumeBSDNames: [])
        let slices = DiskCapacityBreakdown.slices(
            container: container,
            volumes: [
                volume(mount: "/a", used: 400, purgeable: 10),
                volume(mount: "/b", used: 200),
                volume(mount: "/c", used: 100),
                volume(mount: "/d", used: 50),
                volume(mount: "/e", used: 25),
            ])

        // Fixed render order: 3 named, purgeable, folded other, free.
        XCTAssertEqual(slices.count, 6)
        XCTAssertEqual(slices[3].kind, .purgeable)
        XCTAssertEqual(slices[4].kind, .otherVolumes(count: 2))
        XCTAssertEqual(slices[4].bytes, 75)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.bytes }, 1_000)
    }

    func testOverfullContainerClampsFreeToZeroNotUnderflow() {
        let container = APFSContainerInfo(
            bsdName: "disk3", capacityBytes: 100,
            physicalStoreBSDNames: [], volumeBSDNames: [])
        let slices = DiskCapacityBreakdown.slices(
            container: container, volumes: [volume(mount: "/a", used: 150)])
        XCTAssertEqual(slices.last?.bytes, 0)
        XCTAssertEqual(slices.last?.kind, .free)
    }

    func testPurgeableLargerThanBiggestVolumeIsClamped() {
        // Purgeable claims 80 but only 30 bytes are used: clamp to 30, which
        // empties the volume slice (dropped at 0) and leaves purgeable + free.
        let slices = DiskCapacityBreakdown.slices(
            standaloneVolume: volume(mount: "/v", used: 30, purgeable: 80, total: 100))
        XCTAssertEqual(slices.map(\.kind), [.purgeable, .free])
        XCTAssertEqual(slices.map(\.bytes), [30, 70])
    }

    func testStandaloneVolumeShape() {
        let slices = DiskCapacityBreakdown.slices(
            standaloneVolume: volume(
                mount: "/Volumes/Backup", used: 700, purgeable: 100, total: 1_000, role: .user))
        XCTAssertEqual(slices.map(\.kind), [.volume, .purgeable, .free])
        XCTAssertEqual(slices.map(\.bytes), [600, 100, 300])
        XCTAssertEqual(slices[0].role, .user)
    }

    func testZeroByteVolumesDropButFreeAlwaysRemains() {
        let container = APFSContainerInfo(
            bsdName: "disk3", capacityBytes: 100, physicalStoreBSDNames: [], volumeBSDNames: [])
        let slices = DiskCapacityBreakdown.slices(
            container: container,
            volumes: [volume(mount: "/x", used: 0), volume(mount: "/y", used: 100)])
        XCTAssertEqual(slices.map(\.kind), [.volume, .free])
        XCTAssertEqual(slices.last?.bytes, 0, "full disk still shows its zero free slice")
    }

    private func volume(
        mount: String, used: UInt64, purgeable: UInt64? = nil, total: UInt64 = 1_000,
        role: VolumeRole = .user
    ) -> VolumeInfo {
        VolumeInfo(
            mountPoint: mount,
            name: mount == "/"
                ? "Macintosh HD"
                : mount == "/System/Volumes/Data"
                    ? "Macintosh HD - Data"
                    : (mount as NSString).lastPathComponent,
            bsdName: nil, fsTypeName: "apfs", volumeUUID: nil, role: role,
            isRoot: mount == "/", isLocal: true, isReadOnly: false,
            isInternal: true, isEjectable: false, isEncrypted: nil,
            totalBytes: total, freeBytes: total - used, availableBytes: total - used,
            importantUsageAvailableBytes: nil, purgeableBytes: purgeable,
            containerBSDName: "disk3", blockSize: 4096)
    }
}
