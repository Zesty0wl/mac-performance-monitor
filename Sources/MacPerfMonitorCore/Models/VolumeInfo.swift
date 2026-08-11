import Foundation

/// A point-in-time enumeration of mounted volumes and the APFS containers they
/// live in. Produced on demand by `VolumeReader` for the Disk page; it never
/// rides the 1 Hz sampler because enumerating mounts and reading per-volume
/// resource values costs milliseconds, not microseconds.
public struct VolumeSnapshot: Sendable, Equatable {
    public var timestamp: Date
    public var volumes: [VolumeInfo]
    public var containers: [APFSContainerInfo]
}

/// The role a volume plays inside its APFS container, mapped from the
/// IORegistry role strings with a well-known mount point fallback for non-APFS
/// or unmatched volumes.
public enum VolumeRole: String, Sendable, Equatable {
    case system
    case data
    case preboot
    case recovery
    case vm
    /// Small OS bookkeeping volumes: Update, xART, Hardware, iSCPreboot.
    case support
    /// A plain user volume (external drive, secondary partition).
    case user

    /// Short badge text for UI use, kept here so the mapping stays testable.
    public var label: String {
        switch self {
        case .system: return "System"
        case .data: return "Data"
        case .preboot: return "Preboot"
        case .recovery: return "Recovery"
        case .vm: return "VM"
        case .support: return "Support"
        case .user: return "User"
        }
    }
}

/// One mounted filesystem. Capacity fields come from `getfsstat`; the
/// purgeable-aware figures come from Foundation's volume resource values and
/// are nil when the query fails, so "unknown" never renders as "0 bytes".
public struct VolumeInfo: Sendable, Equatable, Identifiable {
    public var id: String { mountPoint }
    public var mountPoint: String
    public var name: String
    public var bsdName: String?
    public var fsTypeName: String
    public var volumeUUID: String?
    public var role: VolumeRole
    public var isRoot: Bool
    public var isLocal: Bool
    public var isReadOnly: Bool
    public var isInternal: Bool?
    public var isEjectable: Bool?
    public var isEncrypted: Bool?
    public var totalBytes: UInt64
    /// Free blocks including space reserved for root (`f_bfree`).
    public var freeBytes: UInt64
    /// Free blocks available to ordinary processes (`f_bavail`), the figure
    /// `df` prints in its Available column.
    public var availableBytes: UInt64
    /// What the system could free up for important writes: available space
    /// plus purgeable content. This is the Finder-style number and is the one
    /// to show as the headline free figure when present.
    public var importantUsageAvailableBytes: UInt64?
    /// Purgeable content on this volume, derived as the gap between the
    /// important-usage figure and plain available space.
    public var purgeableBytes: UInt64?
    /// The APFS container (synthesized whole disk, e.g. "disk3") this volume
    /// belongs to, nil for non-APFS volumes.
    public var containerBSDName: String?
    public var blockSize: UInt64
    /// Bytes this volume itself consumes, from `getattrlist`'s
    /// `ATTR_VOL_SPACEUSED`. On APFS this is the only per-volume truth:
    /// `statfs` reports the shared container pool in its free fields for most
    /// mounts, so `total - free` is container-wide, not per-volume.
    public var spaceUsedBytes: UInt64? = nil
}

/// One APFS container: a pool of space shared by its volumes on top of one or
/// more physical store partitions.
public struct APFSContainerInfo: Sendable, Equatable, Identifiable {
    public var id: String { bsdName }
    /// The synthesized whole-disk BSD name, e.g. "disk3".
    public var bsdName: String
    /// Total pool capacity from the synthesized media's Size, nil when the
    /// registry lookup fails.
    public var capacityBytes: UInt64?
    /// Physical partitions backing the pool, e.g. ["disk0s2"].
    public var physicalStoreBSDNames: [String]
    /// BSD names of the container's volumes, mounted or not.
    public var volumeBSDNames: [String]
}
