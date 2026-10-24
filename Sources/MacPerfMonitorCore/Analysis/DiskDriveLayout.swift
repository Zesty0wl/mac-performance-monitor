import Foundation

/// The volumes on one physical drive, sorted into the ones people use and
/// the ones macOS keeps for itself.
public struct DiskDriveVolumes: Sendable, Equatable, Identifiable {
    public var id: String { bsdName }
    /// The physical disk: "disk0".
    public var bsdName: String
    /// APFS containers holding a volume people use (System, Data or a plain
    /// user volume): the boot container first, then the largest.
    public var containers: [APFSContainerInfo] = []
    /// Non-APFS volumes on the drive (an exFAT or HFS+ partition).
    public var volumes: [VolumeInfo] = []
    /// Containers holding only OS bookkeeping: Preboot, Recovery, xART.
    public var systemContainers: [APFSContainerInfo] = []
    /// The name people know the drive by: the boot volume's, else the
    /// largest volume's. Nil when nothing on it is mounted.
    public var name: String?
    public var holdsBootVolume = false
    /// Capacity of the containers and volumes people use.
    public var capacityBytes: UInt64 = 0
    /// What could be written there: available space plus purgeable content,
    /// the figure Finder shows.
    public var freeBytes: UInt64 = 0
    /// The bar for the drive's card: its main container's or volume's.
    public var primarySlices: [DiskCapacitySlice] = []

    public var hasVolumes: Bool { !containers.isEmpty || !volumes.isEmpty }
}

/// Every mounted volume and APFS container, grouped by the physical drive
/// under it. What is left over (disk images, cryptexes, simulator runtimes,
/// devfs) sits on no physical drive.
public struct DiskVolumeLayout: Sendable, Equatable {
    public var drives: [DiskDriveVolumes]
    public var otherContainers: [APFSContainerInfo]
    public var otherVolumes: [VolumeInfo]

    /// The drive with this whole-disk BSD name.
    public func drive(_ bsdName: String) -> DiskDriveVolumes? {
        drives.first { $0.bsdName == bsdName }
    }

    /// Roles a person works with; a container holding only other roles is
    /// macOS's own.
    static let userRoles: Set<VolumeRole> = [.system, .data, .user]

    /// `drives` are the physical disks' whole-disk BSD names, in the order
    /// the page lists them; the drive holding the boot volume moves first.
    public init(drives driveNames: [String], snapshot: VolumeSnapshot) {
        var drives = driveNames.map { DiskDriveVolumes(bsdName: $0) }
        var otherContainers: [APFSContainerInfo] = []
        var otherVolumes: [VolumeInfo] = []
        let volumes = snapshot.volumes

        for container in snapshot.containers {
            let wholeDisks = Set(container.physicalStoreBSDNames.compactMap(Self.wholeDisk))
            guard let index = drives.firstIndex(where: { wholeDisks.contains($0.bsdName) }) else {
                otherContainers.append(container)
                continue
            }
            let members = volumes.filter { $0.containerBSDName == container.bsdName }
            if members.contains(where: { Self.userRoles.contains($0.role) }) {
                drives[index].containers.append(container)
                if members.contains(where: \.isRoot) { drives[index].holdsBootVolume = true }
            } else {
                drives[index].systemContainers.append(container)
            }
        }
        for volume in volumes where volume.containerBSDName == nil {
            guard let disk = volume.bsdName.flatMap(Self.wholeDisk),
                let index = drives.firstIndex(where: { $0.bsdName == disk })
            else {
                otherVolumes.append(volume)
                continue
            }
            drives[index].volumes.append(volume)
        }

        for index in drives.indices {
            Self.summarize(&drives[index], volumes: volumes)
        }
        if let boot = drives.firstIndex(where: \.holdsBootVolume), boot > 0 {
            drives.insert(drives.remove(at: boot), at: 0)
        }
        self.drives = drives
        self.otherContainers = otherContainers
        self.otherVolumes = otherVolumes
    }

    private static func summarize(_ drive: inout DiskDriveVolumes, volumes: [VolumeInfo]) {
        func members(_ container: APFSContainerInfo) -> [VolumeInfo] {
            volumes.filter { $0.containerBSDName == container.bsdName }
        }
        func capacity(_ container: APFSContainerInfo) -> UInt64 {
            container.capacityBytes ?? members(container).map(\.totalBytes).max() ?? 0
        }
        // The boot container first, then by size.
        drive.containers.sort {
            let lhsBoot = members($0).contains(where: \.isRoot)
            let rhsBoot = members($1).contains(where: \.isRoot)
            if lhsBoot != rhsBoot { return lhsBoot }
            return capacity($0) > capacity($1)
        }
        drive.volumes.sort { $0.totalBytes > $1.totalBytes }

        var capacityBytes: UInt64 = 0
        var freeBytes: UInt64 = 0
        for container in drive.containers {
            capacityBytes += capacity(container)
            // Members share the container's pool, so any one of them reports
            // it; take the largest in case one reads without purgeable.
            let pool = members(container).map {
                $0.importantUsageAvailableBytes ?? $0.availableBytes
            }
            freeBytes += pool.max() ?? 0
        }
        for volume in drive.volumes {
            capacityBytes += volume.totalBytes
            freeBytes += volume.importantUsageAvailableBytes ?? volume.availableBytes
        }
        drive.capacityBytes = capacityBytes
        drive.freeBytes = min(freeBytes, capacityBytes)

        let named = drive.containers.flatMap(members) + drive.volumes
        drive.name =
            named.first(where: \.isRoot)?.name
            ?? named.filter { userRoles.contains($0.role) }.max { $0.usedBytes < $1.usedBytes }?
            .name

        // The card's bar covers one pool: the larger of the main container
        // and the largest plain volume.
        let container = drive.containers.first
        let volume = drive.volumes.first
        if let container, capacity(container) >= volume?.totalBytes ?? 0 {
            drive.primarySlices = DiskCapacityBreakdown.slices(
                container: container, volumes: volumes)
        } else if let volume {
            drive.primarySlices = DiskCapacityBreakdown.slices(standaloneVolume: volume)
        }
    }

    /// "disk0" from "disk0s2" (or "disk0" itself); nil for names that are
    /// not BSD disk names.
    static func wholeDisk(_ bsdName: String) -> String? {
        guard bsdName.hasPrefix("disk") else { return nil }
        let digits = bsdName.dropFirst(4).prefix { $0.isNumber }
        return digits.isEmpty ? nil : "disk\(digits)"
    }
}
