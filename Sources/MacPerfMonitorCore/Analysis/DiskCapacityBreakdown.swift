import Foundation

/// One slice of a capacity bar. Bytes only; colors and layout belong to the
/// view. Slices are emitted in their fixed render order (named volumes by size,
/// then purgeable, then folded extras, then free), which the Disk page maps
/// onto its fixed color slots, so the order here is a UI contract, not
/// cosmetics.
public struct DiskCapacitySlice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case volume
        /// Volumes beyond the named cap, folded into one slice.
        case otherVolumes(count: Int)
        /// Space the system can reclaim for important writes (caches, local
        /// snapshots). Carved out of the largest volume's used bytes, where
        /// purgeable content overwhelmingly lives.
        case purgeable
        case free
    }

    public var id: String
    public var label: String
    /// Mount point for volume slices, nil otherwise.
    public var detail: String?
    public var role: VolumeRole?
    public var bytes: UInt64
    public var kind: Kind
}

/// Pure derivation of capacity-bar slices from a volume snapshot, kept in Core
/// so the arithmetic (clamping, carving, folding) is unit-tested away from any
/// view code.
public enum DiskCapacityBreakdown {
    /// Named volume slices before folding into "Other volumes". Three, so the
    /// full bar (3 named + purgeable + other) matches the validated five-color
    /// order the page renders with.
    public static let maxNamedVolumes = 3

    /// Slices for one APFS container. Members share the container's free pool,
    /// so per-volume used bytes come from each mount's own accounting while
    /// free space is derived once from the container capacity.
    public static func slices(
        container: APFSContainerInfo, volumes: [VolumeInfo]
    ) -> [DiskCapacitySlice] {
        let members = volumes.filter { $0.containerBSDName == container.bsdName }
        let capacity = container.capacityBytes ?? members.map(\.totalBytes).max() ?? 0
        return build(
            capacity: capacity,
            members: members,
            purgeable: members.compactMap(\.purgeableBytes).max() ?? 0,
            idPrefix: container.bsdName)
    }

    /// Slices for a volume with no known APFS container (external drives,
    /// non-APFS filesystems).
    public static func slices(standaloneVolume volume: VolumeInfo) -> [DiskCapacitySlice] {
        build(
            capacity: volume.totalBytes,
            members: [volume],
            purgeable: volume.purgeableBytes ?? 0,
            idPrefix: volume.mountPoint)
    }

    private static func build(
        capacity: UInt64, members: [VolumeInfo], purgeable: UInt64, idPrefix: String
    ) -> [DiskCapacitySlice] {
        let sorted = members.sorted { $0.usedBytes > $1.usedBytes }
        let named = Array(sorted.prefix(maxNamedVolumes))
        let folded = Array(sorted.dropFirst(maxNamedVolumes))

        // Purgeable bytes are allocated space, so they must be carved out of a
        // used slice (the largest volume's, where caches and snapshots live)
        // or the bar would double-count them and overflow the capacity.
        let clampedPurgeable = min(purgeable, named.first?.usedBytes ?? 0)
        var namedBytes = named.map(\.usedBytes)
        if !namedBytes.isEmpty { namedBytes[0] -= clampedPurgeable }

        var slices: [DiskCapacitySlice] = []
        for (volume, bytes) in zip(named, namedBytes) {
            slices.append(
                DiskCapacitySlice(
                    id: "\(idPrefix)/\(volume.mountPoint)",
                    label: volume.name,
                    detail: volume.mountPoint,
                    role: volume.role,
                    bytes: bytes,
                    kind: .volume))
        }
        if clampedPurgeable > 0 {
            slices.append(
                DiskCapacitySlice(
                    id: "\(idPrefix)/purgeable", label: "Purgeable", detail: nil, role: nil,
                    bytes: clampedPurgeable, kind: .purgeable))
        }
        if !folded.isEmpty {
            slices.append(
                DiskCapacitySlice(
                    id: "\(idPrefix)/other",
                    label: "Other volumes",
                    detail: nil, role: nil,
                    bytes: folded.reduce(0) { $0 + $1.usedBytes },
                    kind: .otherVolumes(count: folded.count)))
        }

        let used = slices.reduce(0) { $0 + $1.bytes }
        slices.append(
            DiskCapacitySlice(
                id: "\(idPrefix)/free", label: "Free", detail: nil, role: nil,
                bytes: capacity > used ? capacity - used : 0, kind: .free))

        // Drop empty volume slices (a freshly created volume can be 0 bytes
        // used) but never the free slice: an entirely full disk should still
        // show its zero-byte free slice in the legend.
        return slices.filter { $0.bytes > 0 || $0.kind == .free }
    }
}

extension VolumeInfo {
    /// Bytes this volume itself consumes: the `ATTR_VOL_SPACEUSED` figure when
    /// the reader obtained one, else total minus free. The fallback is only
    /// correct for non-APFS filesystems; on APFS, `statfs` free fields report
    /// the shared container pool, which is why the attribute is preferred.
    public var usedBytes: UInt64 {
        spaceUsedBytes ?? (totalBytes > freeBytes ? totalBytes - freeBytes : 0)
    }
}
