import Foundation
import IOKit

/// `statfs` names both the C struct and the C function; Swift resolves a bare
/// `statfs()` expression to the function, so the struct needs its own name.
private typealias FSStatBuffer = statfs

/// Enumerates mounted volumes with capacity, purgeable-aware free space, and
/// APFS container topology. On-demand only: the Disk page pulls a snapshot
/// every poll while visible. `getfsstat` runs with `MNT_NOWAIT` so a dead
/// network mount can never stall the call, and every enrichment layer (resource
/// values, IORegistry) degrades field by field like the other readers.
public final class VolumeReader {
    struct FSStatRow: Sendable, Equatable {
        var mountPoint: String
        var deviceNode: String
        var fsTypeName: String
        var blockSize: UInt64
        var totalBytes: UInt64
        var freeBytes: UInt64
        var availableBytes: UInt64
        var isLocal: Bool
        var isReadOnly: Bool
        var isRoot: Bool
        /// Bytes this volume itself consumes, from `getattrlist`'s
        /// `ATTR_VOL_SPACEUSED` (what `df` reports as Used). On APFS,
        /// `statfs.f_bfree` is the container's shared free pool for most
        /// mounts, so `total - free` wildly overstates per-volume usage; this
        /// attribute is the only per-volume truth. Nil when the query fails.
        var spaceUsedBytes: UInt64? = nil
    }

    struct VolumeResourceReadout: Sendable, Equatable {
        var name: String?
        var uuid: String?
        var importantUsageAvailableBytes: UInt64?
        var isInternal: Bool?
        var isEjectable: Bool?
        var isEncrypted: Bool?
    }

    struct APFSVolumeReadout: Sendable, Equatable {
        var bsdName: String
        var roles: [String]
    }

    struct APFSContainerReadout: Sendable, Equatable {
        var bsdName: String
        var capacityBytes: UInt64?
        var physicalStoreBSDNames: [String]
        var volumes: [APFSVolumeReadout]
    }

    private let fsstatSource: () -> [FSStatRow]
    private let resourceSource: (String) -> VolumeResourceReadout?
    private let containerSource: () -> [APFSContainerReadout]

    public convenience init() {
        self.init(
            fsstatSource: Self.readFSStat,
            resourceSource: Self.readResources,
            containerSource: Self.readContainers)
    }

    init(
        fsstatSource: @escaping () -> [FSStatRow],
        resourceSource: @escaping (String) -> VolumeResourceReadout?,
        containerSource: @escaping () -> [APFSContainerReadout]
    ) {
        self.fsstatSource = fsstatSource
        self.resourceSource = resourceSource
        self.containerSource = containerSource
    }

    public func read(now: Date = Date()) -> VolumeSnapshot {
        // Pseudo filesystems (devfs, autofs) report zero capacity; they are
        // noise on a storage page.
        let rows = fsstatSource().filter { $0.totalBytes > 0 }
        let containers = containerSource()

        var containerByVolume: [String: String] = [:]
        var rolesByVolume: [String: [String]] = [:]
        for container in containers {
            for volume in container.volumes {
                containerByVolume[volume.bsdName] = container.bsdName
                rolesByVolume[volume.bsdName] = volume.roles
            }
        }

        var volumes: [VolumeInfo] = rows.map { row in
            let resources = resourceSource(row.mountPoint)
            let bsdName = Self.bsdName(fromDeviceNode: row.deviceNode)
            // The root mount is a sealed snapshot named like "disk3s3s1"; its
            // registry volume is the parent "disk3s3".
            let registryBSDName = bsdName.map(Self.strippingSnapshotSuffix)
            let importantUsage = Self.sanitizedImportantUsage(
                resources?.importantUsageAvailableBytes, totalBytes: row.totalBytes)
            return VolumeInfo(
                mountPoint: row.mountPoint,
                name: resources?.name ?? Self.fallbackName(forMountPoint: row.mountPoint),
                bsdName: bsdName,
                fsTypeName: row.fsTypeName,
                volumeUUID: resources?.uuid,
                role: Self.classifyRole(
                    registryRoles: registryBSDName.flatMap { rolesByVolume[$0] } ?? [],
                    mountPoint: row.mountPoint,
                    isRoot: row.isRoot),
                isRoot: row.isRoot,
                isLocal: row.isLocal,
                isReadOnly: row.isReadOnly,
                isInternal: resources?.isInternal,
                isEjectable: resources?.isEjectable,
                isEncrypted: resources?.isEncrypted,
                totalBytes: row.totalBytes,
                freeBytes: row.freeBytes,
                availableBytes: row.availableBytes,
                importantUsageAvailableBytes: importantUsage,
                purgeableBytes: importantUsage.map {
                    $0 > row.availableBytes ? $0 - row.availableBytes : 0
                },
                containerBSDName: registryBSDName.flatMap { containerByVolume[$0] },
                blockSize: row.blockSize,
                spaceUsedBytes: row.spaceUsedBytes)
        }
        volumes = Self.deduplicatingMultipleMounts(volumes)
        volumes.sort {
            if $0.isRoot != $1.isRoot { return $0.isRoot }
            return $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending
        }

        let containerInfos = containers.map { container in
            APFSContainerInfo(
                bsdName: container.bsdName,
                capacityBytes: container.capacityBytes,
                physicalStoreBSDNames: container.physicalStoreBSDNames,
                volumeBSDNames: container.volumes.map(\.bsdName))
        }
        return VolumeSnapshot(timestamp: now, volumes: volumes, containers: containerInfos)
    }

    // MARK: - Pure derivations (unit-tested against fixtures)

    /// One APFS volume can be mounted more than once at a time: the System
    /// volume appears as the sealed snapshot at "/" AND as a staging mount
    /// under /System/Volumes/Update during a pending macOS update. Counting
    /// both would double the volume's bytes in the capacity bar, so keep one
    /// mount per underlying volume, preferring the root mount, then the first
    /// by mount point.
    static func deduplicatingMultipleMounts(_ volumes: [VolumeInfo]) -> [VolumeInfo] {
        var seen: [String: Int] = [:]
        var result: [VolumeInfo] = []
        for volume in volumes {
            guard let bsd = volume.bsdName else {
                result.append(volume)
                continue
            }
            let key = strippingSnapshotSuffix(bsd)
            if let existingIndex = seen[key] {
                if volume.isRoot && !result[existingIndex].isRoot {
                    result[existingIndex] = volume
                }
            } else {
                seen[key] = result.count
                result.append(volume)
            }
        }
        return result
    }

    /// Map IORegistry role strings to the display role, falling back to
    /// well-known mount points when the registry gave nothing. Pure so the
    /// whole table is testable.
    static func classifyRole(
        registryRoles: [String], mountPoint: String, isRoot: Bool
    ) -> VolumeRole {
        switch registryRoles.first {
        case "System": return .system
        case "Data": return .data
        case "Preboot": return .preboot
        case "Recovery": return .recovery
        case "VM": return .vm
        case "Update", "xART", "Hardware", "iSCPreboot", "Sysdiagnose": return .support
        default: break
        }
        if isRoot { return .system }
        switch mountPoint {
        case "/System/Volumes/Data": return .data
        case "/System/Volumes/Preboot": return .preboot
        case "/System/Volumes/Recovery": return .recovery
        case "/System/Volumes/VM": return .vm
        default: break
        }
        // OS plumbing that mounts real volumes in system locations: update
        // staging, cryptexes, and simulator runtime images are not the user's
        // storage even though they are ordinary APFS mounts.
        let supportPrefixes = [
            "/System/Volumes/", "/System/Cryptexes/", "/private/var/run/",
            "/Library/Developer/CoreSimulator/Volumes/",
        ]
        if supportPrefixes.contains(where: mountPoint.hasPrefix) { return .support }
        return .user
    }

    /// "/dev/disk3s1" -> "disk3s1"; non device-backed mounts return nil.
    static func bsdName(fromDeviceNode node: String) -> String? {
        guard node.hasPrefix("/dev/") else { return nil }
        return String(node.dropFirst("/dev/".count))
    }

    /// "disk3s3s1" (a mounted snapshot) -> "disk3s3"; anything else unchanged.
    /// Only the digits after the "disk" prefix are split, since the word
    /// "disk" itself contains an "s".
    static func strippingSnapshotSuffix(_ bsdName: String) -> String {
        guard bsdName.hasPrefix("disk") else { return bsdName }
        let parts = bsdName.dropFirst("disk".count)
            .split(separator: "s", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return bsdName }
        return "disk\(parts[0])s\(parts[1])"
    }

    /// Foundation sometimes reports 0 for the important-usage capacity on
    /// volumes it cannot assess; a literal zero next to a nonzero total is far
    /// more likely "unknown" than "completely full", so treat it as nil.
    static func sanitizedImportantUsage(_ value: UInt64?, totalBytes: UInt64) -> UInt64? {
        guard let value else { return nil }
        return (value == 0 && totalBytes > 0) ? nil : value
    }

    static func fallbackName(forMountPoint mountPoint: String) -> String {
        mountPoint == "/" ? "Macintosh HD" : (mountPoint as NSString).lastPathComponent
    }

    // MARK: - Real sources

    private static func readFSStat() -> [FSStatRow] {
        var count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = [FSStatBuffer](repeating: FSStatBuffer(), count: Int(count))
        let bufferBytes = Int32(MemoryLayout<FSStatBuffer>.stride * buffer.count)
        count = getfsstat(&buffer, bufferBytes, MNT_NOWAIT)
        guard count > 0 else { return [] }

        return buffer.prefix(Int(count)).map { fs in
            let blockSize = UInt64(fs.f_bsize)
            let flags = UInt32(fs.f_flags)
            let mountPoint = string(fromCString: fs.f_mntonname)
            return FSStatRow(
                mountPoint: mountPoint,
                deviceNode: string(fromCString: fs.f_mntfromname),
                fsTypeName: string(fromCString: fs.f_fstypename),
                blockSize: blockSize,
                totalBytes: fs.f_blocks * blockSize,
                freeBytes: fs.f_bfree * blockSize,
                availableBytes: UInt64(max(0, fs.f_bavail)) * blockSize,
                isLocal: flags & UInt32(MNT_LOCAL) != 0,
                isReadOnly: flags & UInt32(MNT_RDONLY) != 0,
                isRoot: flags & UInt32(MNT_ROOTFS) != 0,
                spaceUsedBytes: spaceUsed(atMountPoint: mountPoint))
        }
    }

    /// Per-volume bytes consumed, via `getattrlist(ATTR_VOL_SPACEUSED)`: the
    /// figure `df` prints as Used. The attribute buffer is packed (a 4-byte
    /// length then an 8-byte value at offset 4), so the value needs an
    /// unaligned load rather than a struct overlay.
    private static func spaceUsed(atMountPoint mountPoint: String) -> UInt64? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 16)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(mountPoint, &attributes, raw.baseAddress, raw.count, 0)
        }
        guard status == 0 else { return nil }
        let value = buffer.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
        }
        return value >= 0 ? UInt64(value) : nil
    }

    private static func readResources(mountPoint: String) -> VolumeResourceReadout? {
        let url = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsEncryptedKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeResourceReadout(
            name: values.volumeName,
            uuid: values.volumeUUIDString,
            importantUsageAvailableBytes: values.volumeAvailableCapacityForImportantUsage
                .map { UInt64(max(0, $0)) },
            isInternal: values.volumeIsInternal,
            isEjectable: values.volumeIsEjectable,
            isEncrypted: values.volumeIsEncrypted)
    }

    /// Walk the registry once: each `AppleAPFSContainer` yields its volumes
    /// (children) and physical store (parent `IOMedia`); the synthesized
    /// container media (`AppleAPFSMedia`) supplies the container's BSD name and
    /// capacity, joined via the volume BSD prefix ("disk3s1" lives in "disk3").
    private static func readContainers() -> [APFSContainerReadout] {
        var mediaSizeByBSD: [String: UInt64] = [:]
        forEachService(matching: "AppleAPFSMedia") { media in
            if let bsd = IOKitProperty.string(media, "BSD Name"),
                let size = IOKitProperty.number(media, "Size")
            {
                mediaSizeByBSD[bsd] = size
            }
        }

        var containers: [APFSContainerReadout] = []
        forEachService(matching: "AppleAPFSContainer") { container in
            var volumes: [APFSVolumeReadout] = []
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(container, kIOServicePlane, &iterator)
                == KERN_SUCCESS
            {
                defer { IOObjectRelease(iterator) }
                var child = IOIteratorNext(iterator)
                while child != 0 {
                    if IOObjectConformsTo(child, "AppleAPFSVolume") != 0,
                        let bsd = IOKitProperty.string(child, "BSD Name")
                    {
                        volumes.append(
                            APFSVolumeReadout(
                                bsdName: bsd,
                                roles: IOKitProperty.stringArray(child, "Role") ?? []))
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(iterator)
                }
            }
            guard let containerBSD = volumes.first.flatMap({ containerName(ofVolume: $0.bsdName) })
            else { return }

            // The parent chain above a container interleaves synthesized APFS
            // media (the container's own "diskN") with the real partition; the
            // physical store is the first IOMedia ancestor that is NOT itself
            // an AppleAPFSMedia (e.g. "disk0s2").
            var stores: [String] = []
            var ancestor = IOKitProperty.firstParent(of: container, conformingTo: kIOMediaClass)
            while let media = ancestor {
                if IOObjectConformsTo(media, "AppleAPFSMedia") == 0 {
                    if let bsd = IOKitProperty.string(media, "BSD Name") { stores.append(bsd) }
                    IOObjectRelease(media)
                    break
                }
                ancestor = IOKitProperty.firstParent(of: media, conformingTo: kIOMediaClass)
                IOObjectRelease(media)
            }
            containers.append(
                APFSContainerReadout(
                    bsdName: containerBSD,
                    capacityBytes: mediaSizeByBSD[containerBSD],
                    physicalStoreBSDNames: stores,
                    volumes: volumes.sorted {
                        $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
                    }))
        }
        return containers.sorted {
            $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
        }
    }

    /// "disk3s1" -> "disk3".
    private static func containerName(ofVolume bsdName: String) -> String? {
        guard let range = bsdName.range(of: "s", options: .backwards),
            bsdName.hasPrefix("disk")
        else { return nil }
        return String(bsdName[..<range.lowerBound])
    }

    private static func forEachService(
        matching className: String, _ body: (io_registry_entry_t) -> Void
    ) {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            body(entry)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    private static func string<T>(fromCString tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}

/// The one volume figure that rides the sampler: root filesystem capacity, so
/// free-space history accrues even while the Disk page is closed. A single
/// cached `statfs("/")` refreshed at most once a minute; free space moves far
/// too slowly to deserve the 1 Hz tick. On APFS the root volume's available
/// space is the container's shared free pool, exactly the "disk filling up"
/// number.
public final class BootVolumeReader {
    public struct Capacity: Sendable, Equatable {
        public var totalBytes: UInt64
        public var freeBytes: UInt64
    }

    private let source: () -> Capacity?
    private let minInterval: TimeInterval
    private var cached: Capacity?
    private var lastReadAt: Date?

    public convenience init() {
        self.init(source: Self.readRoot)
    }

    init(minInterval: TimeInterval = 60, source: @escaping () -> Capacity?) {
        self.minInterval = minInterval
        self.source = source
    }

    public func read(now: Date = Date()) -> Capacity? {
        let due = lastReadAt.map { now.timeIntervalSince($0) >= minInterval } ?? true
        if due {
            // Gate on time regardless of the result, so a failing statfs also
            // stops retrying every tick (the battery reader's convention).
            cached = source() ?? cached
            lastReadAt = now
        }
        return cached
    }

    public func reset() {
        cached = nil
        lastReadAt = nil
    }

    private static func readRoot() -> Capacity? {
        var fs = FSStatBuffer()
        guard statfs("/", &fs) == 0 else { return nil }
        let blockSize = UInt64(fs.f_bsize)
        return Capacity(
            totalBytes: fs.f_blocks * blockSize,
            freeBytes: UInt64(max(0, fs.f_bavail)) * blockSize)
    }
}
