import XCTest

@testable import MacPerfMonitorCore

final class VolumeReaderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testSnapshotJoinsMountsResourcesAndContainers() {
        let reader = VolumeReader(
            fsstatSource: {
                [
                    self.row(
                        mount: "/System/Volumes/Data", device: "/dev/disk3s1",
                        total: 500_000, available: 100_000),
                    self.row(mount: "/", device: "/dev/disk3s3s1", total: 500_000, root: true),
                ]
            },
            resourceSource: { mount in
                mount == "/System/Volumes/Data"
                    ? VolumeReader.VolumeResourceReadout(
                        name: "Macintosh HD - Data", uuid: "AAAA",
                        importantUsageAvailableBytes: 130_000,
                        isInternal: true, isEjectable: false, isEncrypted: true)
                    : nil
            },
            containerSource: {
                [
                    VolumeReader.APFSContainerReadout(
                        bsdName: "disk3", capacityBytes: 500_000,
                        physicalStoreBSDNames: ["disk0s2"],
                        volumes: [
                            .init(bsdName: "disk3s1", roles: ["Data"]),
                            .init(bsdName: "disk3s3", roles: ["System"]),
                        ])
                ]
            })

        let snapshot = reader.read(now: t0)
        XCTAssertEqual(snapshot.timestamp, t0)
        XCTAssertEqual(snapshot.volumes.count, 2)

        // Root sorts first even though it mounted from a snapshot device.
        let root = snapshot.volumes[0]
        XCTAssertTrue(root.isRoot)
        XCTAssertEqual(root.role, .system)
        XCTAssertEqual(root.containerBSDName, "disk3", "snapshot suffix must strip to disk3s3")
        XCTAssertEqual(root.name, "Macintosh HD", "no resource values still names the boot volume")
        XCTAssertNil(root.isInternal)

        let data = snapshot.volumes[1]
        XCTAssertEqual(data.name, "Macintosh HD - Data")
        XCTAssertEqual(data.role, .data)
        XCTAssertEqual(data.isEncrypted, true)
        XCTAssertEqual(data.purgeableBytes, 30_000)
        XCTAssertEqual(data.containerBSDName, "disk3")

        XCTAssertEqual(
            snapshot.containers,
            [
                APFSContainerInfo(
                    bsdName: "disk3", capacityBytes: 500_000,
                    physicalStoreBSDNames: ["disk0s2"],
                    volumeBSDNames: ["disk3s1", "disk3s3"])
            ])
    }

    func testZeroCapacityPseudoFilesystemsAreDropped() {
        let reader = VolumeReader(
            fsstatSource: {
                [
                    self.row(mount: "/dev", device: "devfs", fsType: "devfs", total: 0),
                    self.row(mount: "/", device: "/dev/disk3s3s1", total: 500_000, root: true),
                ]
            },
            resourceSource: { _ in nil },
            containerSource: { [] })

        XCTAssertEqual(reader.read(now: t0).volumes.map(\.mountPoint), ["/"])
    }

    func testRoleClassificationTable() {
        // Registry roles win outright.
        XCTAssertEqual(
            VolumeReader.classifyRole(registryRoles: ["System"], mountPoint: "/x", isRoot: false),
            .system)
        XCTAssertEqual(
            VolumeReader.classifyRole(registryRoles: ["VM"], mountPoint: "/x", isRoot: false), .vm)
        XCTAssertEqual(
            VolumeReader.classifyRole(registryRoles: ["xART"], mountPoint: "/x", isRoot: false),
            .support)
        // Fallbacks: root, well-known mounts, system-volume prefix, then user.
        XCTAssertEqual(
            VolumeReader.classifyRole(registryRoles: [], mountPoint: "/", isRoot: true), .system)
        XCTAssertEqual(
            VolumeReader.classifyRole(
                registryRoles: [], mountPoint: "/System/Volumes/VM", isRoot: false), .vm)
        XCTAssertEqual(
            VolumeReader.classifyRole(
                registryRoles: [], mountPoint: "/System/Volumes/Update", isRoot: false), .support)
        XCTAssertEqual(
            VolumeReader.classifyRole(
                registryRoles: [], mountPoint: "/Volumes/Backup", isRoot: false), .user)
    }

    func testPurgeableDerivationAndImportantUsageSanitizing() {
        // Important usage below plain available clamps purgeable to zero.
        let reader = VolumeReader(
            fsstatSource: {
                [self.row(mount: "/v", device: "/dev/disk5s1", total: 1_000, available: 400)]
            },
            resourceSource: { _ in
                VolumeReader.VolumeResourceReadout(
                    name: "V", uuid: nil, importantUsageAvailableBytes: 300,
                    isInternal: nil, isEjectable: nil, isEncrypted: nil)
            },
            containerSource: { [] })
        XCTAssertEqual(reader.read(now: t0).volumes[0].purgeableBytes, 0)

        // A zero important-usage reading against a nonzero total means
        // "unknown", not "full": both derived fields must come back nil.
        XCTAssertNil(VolumeReader.sanitizedImportantUsage(0, totalBytes: 1_000))
        XCTAssertEqual(VolumeReader.sanitizedImportantUsage(50, totalBytes: 1_000), 50)
        XCTAssertNil(VolumeReader.sanitizedImportantUsage(nil, totalBytes: 1_000))
    }

    func testSnapshotSuffixStripping() {
        XCTAssertEqual(VolumeReader.strippingSnapshotSuffix("disk3s3s1"), "disk3s3")
        XCTAssertEqual(VolumeReader.strippingSnapshotSuffix("disk3s1"), "disk3s1")
        XCTAssertEqual(VolumeReader.strippingSnapshotSuffix("disk10s2s1"), "disk10s2")
        XCTAssertEqual(VolumeReader.strippingSnapshotSuffix("weird"), "weird")
    }

    func testBSDNameParsing() {
        XCTAssertEqual(VolumeReader.bsdName(fromDeviceNode: "/dev/disk3s1"), "disk3s1")
        XCTAssertNil(VolumeReader.bsdName(fromDeviceNode: "map auto_home"))
    }

    func testBootVolumeReaderThrottlesToOneReadPerMinute() {
        var reads = 0
        let reader = BootVolumeReader(minInterval: 60) {
            reads += 1
            return .init(totalBytes: 1_000, freeBytes: UInt64(500 - reads))
        }

        XCTAssertEqual(reader.read(now: t0)?.freeBytes, 499)
        XCTAssertEqual(reader.read(now: t0.addingTimeInterval(30))?.freeBytes, 499)
        XCTAssertEqual(reads, 1, "a second read inside the interval must hit the cache")

        XCTAssertEqual(reader.read(now: t0.addingTimeInterval(61))?.freeBytes, 498)
        XCTAssertEqual(reads, 2)

        reader.reset()
        XCTAssertEqual(reader.read(now: t0.addingTimeInterval(62))?.freeBytes, 497)
        XCTAssertEqual(reads, 3, "reset must force a fresh read")
    }

    func testBootVolumeReaderKeepsLastGoodValueThroughFailures() {
        var results: [BootVolumeReader.Capacity?] = [
            .init(totalBytes: 1_000, freeBytes: 400), nil,
        ]
        let reader = BootVolumeReader(minInterval: 60) { results.removeFirst() }

        XCTAssertEqual(reader.read(now: t0)?.freeBytes, 400)
        // The failed refresh keeps the previous figure rather than dropping to
        // nil for a minute.
        XCTAssertEqual(reader.read(now: t0.addingTimeInterval(61))?.freeBytes, 400)
    }

    func testDeduplicatesMultipleMountsOfOneVolume() {
        // The System volume mounted twice: as the root snapshot (disk3s3s1)
        // and as update staging (disk3s3). One survivor, and it is the root.
        let reader = VolumeReader(
            fsstatSource: {
                [
                    self.row(
                        mount: "/System/Volumes/Update/mnt1", device: "/dev/disk3s3",
                        total: 500_000),
                    self.row(mount: "/", device: "/dev/disk3s3s1", total: 500_000, root: true),
                    self.row(mount: "/System/Volumes/Data", device: "/dev/disk3s1", total: 500_000),
                ]
            },
            resourceSource: { _ in nil },
            containerSource: { [] })

        let volumes = reader.read(now: t0).volumes
        XCTAssertEqual(volumes.count, 2)
        XCTAssertTrue(volumes[0].isRoot, "the root mount must win the dedupe")
        XCTAssertEqual(volumes[1].mountPoint, "/System/Volumes/Data")
    }

    func testSpaceUsedAttributeIsPreferredOverStatfsArithmetic() {
        // On APFS, statfs free fields are the shared pool, so total - free
        // would claim 460 GB used for a 17 GB volume. The getattrlist figure
        // must win; the arithmetic only backstops filesystems without it.
        let withAttribute = VolumeInfo(
            mountPoint: "/v", name: "V", bsdName: "disk3s4", fsTypeName: "apfs",
            volumeUUID: nil, role: .preboot, isRoot: false, isLocal: true, isReadOnly: false,
            isInternal: true, isEjectable: false, isEncrypted: nil,
            totalBytes: 494_000, freeBytes: 37_000, availableBytes: 37_000,
            importantUsageAvailableBytes: nil, purgeableBytes: nil,
            containerBSDName: "disk3", blockSize: 4096, spaceUsedBytes: 17_600)
        XCTAssertEqual(withAttribute.usedBytes, 17_600)

        var withoutAttribute = withAttribute
        withoutAttribute.spaceUsedBytes = nil
        XCTAssertEqual(withoutAttribute.usedBytes, 457_000)
    }

    func testCryptexAndSimulatorMountsClassifyAsSupport() {
        XCTAssertEqual(
            VolumeReader.classifyRole(
                registryRoles: [],
                mountPoint: "/private/var/run/com.apple.security.cryptexd/mnt/x",
                isRoot: false),
            .support)
        XCTAssertEqual(
            VolumeReader.classifyRole(
                registryRoles: [],
                mountPoint: "/Library/Developer/CoreSimulator/Volumes/iOS_23C54",
                isRoot: false),
            .support)
        XCTAssertEqual(
            VolumeReader.classifyRole(
                registryRoles: [], mountPoint: "/Volumes/Backup", isRoot: false),
            .user)
    }

    func testLiveVolumeReaderReturnsRootAndSaneBounds() {
        // Live smoke: must pass on any Mac. Root exists, capacities are
        // consistent, and every volume's free space fits inside its total.
        let snapshot = VolumeReader().read(now: Date())
        guard let root = snapshot.volumes.first(where: \.isRoot) else {
            return XCTFail("no root volume in live snapshot")
        }
        XCTAssertGreaterThan(root.totalBytes, 0)
        for volume in snapshot.volumes {
            XCTAssertLessThanOrEqual(volume.availableBytes, volume.totalBytes)
            XCTAssertFalse(volume.mountPoint.isEmpty)
            XCTAssertLessThanOrEqual(
                volume.usedBytes, volume.totalBytes,
                "\(volume.mountPoint) used must fit inside its capacity")
        }
        // The root snapshot's own usage is a fraction of the disk; if the
        // shared-pool arithmetic ever leaks back in, this catches it (the bug
        // showed the sealed system volume as consuming the whole container).
        XCTAssertLessThan(
            root.usedBytes, root.totalBytes / 2,
            "root snapshot usage should be far below container capacity")
        for container in snapshot.containers {
            XCTAssertFalse(container.volumeBSDNames.isEmpty)
        }
    }

    func testLiveBootVolumeReaderMatchesRootStatfs() {
        guard let capacity = BootVolumeReader().read(now: Date()) else {
            return XCTFail("statfs of / must succeed")
        }
        XCTAssertGreaterThan(capacity.totalBytes, 0)
        XCTAssertLessThan(capacity.freeBytes, capacity.totalBytes)
    }

    private func row(
        mount: String, device: String, fsType: String = "apfs", total: UInt64,
        available: UInt64 = 0, root: Bool = false
    ) -> VolumeReader.FSStatRow {
        VolumeReader.FSStatRow(
            mountPoint: mount, deviceNode: device, fsTypeName: fsType, blockSize: 4096,
            totalBytes: total, freeBytes: available, availableBytes: available,
            isLocal: true, isReadOnly: false, isRoot: root)
    }
}
