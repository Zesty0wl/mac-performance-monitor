import XCTest

@testable import MacPerfMonitorCore

final class DiskDriveLayoutTests: XCTestCase {
    private let gb: UInt64 = 1_000_000_000

    private func volume(
        _ mount: String, name: String, role: VolumeRole, container: String?, bsd: String?,
        total: UInt64, used: UInt64, available: UInt64, important: UInt64? = nil
    ) -> VolumeInfo {
        var volume = VolumeInfo(
            mountPoint: mount, name: name, bsdName: bsd,
            fsTypeName: container == nil ? "exfat" : "apfs",
            volumeUUID: nil, role: role, isRoot: mount == "/", isLocal: true, isReadOnly: false,
            isInternal: nil, isEjectable: nil, isEncrypted: nil, totalBytes: total,
            freeBytes: available, availableBytes: available,
            importantUsageAvailableBytes: important, purgeableBytes: nil,
            containerBSDName: container, blockSize: 4096)
        volume.spaceUsedBytes = used
        return volume
    }

    /// This Mac on 2026-10-24: the internal SSD (boot container plus the
    /// two macOS containers), a USB SSD, a cryptex disk image and devfs.
    private func snapshot() -> VolumeSnapshot {
        VolumeSnapshot(
            timestamp: Date(),
            volumes: [
                volume(
                    "/", name: "Macintosh HD", role: .system, container: "disk3", bsd: "disk3s3s1",
                    total: 460 * gb, used: 13 * gb, available: 56 * gb, important: 57 * gb),
                volume(
                    "/System/Volumes/Data", name: "Macintosh HD", role: .data, container: "disk3",
                    bsd: "disk3s1", total: 460 * gb, used: 372 * gb, available: 56 * gb,
                    important: 57 * gb),
                volume(
                    "/System/Volumes/xarts", name: "xART", role: .support, container: "disk1",
                    bsd: "disk1s2", total: gb / 2, used: gb / 100, available: gb / 2),
                volume(
                    "/Volumes/Hypervisaur", name: "Hypervisaur", role: .user, container: "disk10",
                    bsd: "disk10s1", total: 238 * gb, used: 79 * gb, available: 159 * gb),
                volume(
                    "/Volumes/Camera", name: "CAMERA", role: .user, container: nil, bsd: "disk5s3",
                    total: 32 * gb, used: 2 * gb, available: 30 * gb),
                volume(
                    "/private/var/run/cryptex", name: "MetalToolchainCryptex", role: .support,
                    container: "disk7", bsd: "disk7s1", total: 3 * gb, used: 3 * gb,
                    available: gb / 10),
                volume(
                    "/dev", name: "dev", role: .user, container: nil, bsd: nil, total: 1, used: 1,
                    available: 0),
            ],
            containers: [
                APFSContainerInfo(
                    bsdName: "disk1", capacityBytes: gb / 2, physicalStoreBSDNames: ["disk0s1"],
                    volumeBSDNames: ["disk1s1", "disk1s2"]),
                APFSContainerInfo(
                    bsdName: "disk2", capacityBytes: 5 * gb, physicalStoreBSDNames: ["disk0s3"],
                    volumeBSDNames: ["disk2s1", "disk2s2"]),
                APFSContainerInfo(
                    bsdName: "disk3", capacityBytes: 460 * gb, physicalStoreBSDNames: ["disk0s2"],
                    volumeBSDNames: ["disk3s1", "disk3s3"]),
                APFSContainerInfo(
                    bsdName: "disk7", capacityBytes: 3 * gb, physicalStoreBSDNames: ["disk6s1"],
                    volumeBSDNames: ["disk7s1"]),
                APFSContainerInfo(
                    bsdName: "disk10", capacityBytes: 238 * gb, physicalStoreBSDNames: ["disk5s2"],
                    volumeBSDNames: ["disk10s1"]),
            ])
    }

    func testGroupsVolumesByPhysicalDrive() {
        // The external drive listed first still yields to the boot drive.
        let layout = DiskVolumeLayout(drives: ["disk5", "disk0"], snapshot: snapshot())
        XCTAssertEqual(layout.drives.map(\.bsdName), ["disk0", "disk5"])

        let boot = layout.drives[0]
        XCTAssertTrue(boot.holdsBootVolume)
        XCTAssertEqual(boot.name, "Macintosh HD")
        XCTAssertEqual(boot.containers.map(\.bsdName), ["disk3"])
        // Preboot bookkeeping and the unmounted Recovery container fold away.
        XCTAssertEqual(boot.systemContainers.map(\.bsdName), ["disk1", "disk2"])
        XCTAssertEqual(boot.capacityBytes, 460 * gb)
        // The Finder figure, purgeable included, counted once for the pool.
        XCTAssertEqual(boot.freeBytes, 57 * gb)

        let external = layout.drives[1]
        XCTAssertEqual(external.name, "Hypervisaur")
        XCTAssertEqual(external.containers.map(\.bsdName), ["disk10"])
        XCTAssertEqual(external.volumes.map(\.name), ["CAMERA"])
        XCTAssertEqual(external.capacityBytes, 270 * gb)
        XCTAssertEqual(external.freeBytes, 189 * gb)
        // The card's bar is the larger pool's.
        XCTAssertEqual(external.primarySlices.first?.label, "Hypervisaur")

        // Disk images and devfs sit on no physical drive.
        XCTAssertEqual(layout.otherContainers.map(\.bsdName), ["disk7"])
        XCTAssertEqual(layout.otherVolumes.map(\.name), ["dev"])
    }

    func testDriveWithNothingMounted() {
        let layout = DiskVolumeLayout(drives: ["disk0", "disk9"], snapshot: snapshot())
        let empty = layout.drive("disk9")
        XCTAssertNotNil(empty)
        XCTAssertFalse(empty?.hasVolumes ?? true)
        XCTAssertNil(empty?.name)
        XCTAssertEqual(empty?.capacityBytes, 0)
        // Without the drive, its volumes count as other mounts.
        XCTAssertTrue(layout.otherVolumes.contains { $0.name == "CAMERA" })
    }

    func testWholeDiskNames() {
        XCTAssertEqual(DiskVolumeLayout.wholeDisk("disk0s2"), "disk0")
        XCTAssertEqual(DiskVolumeLayout.wholeDisk("disk12"), "disk12")
        XCTAssertEqual(DiskVolumeLayout.wholeDisk("disk3s3s1"), "disk3")
        XCTAssertNil(DiskVolumeLayout.wholeDisk("devfs"))
        XCTAssertNil(DiskVolumeLayout.wholeDisk("disk"))
    }
}
