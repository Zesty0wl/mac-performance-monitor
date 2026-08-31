// SPDX-License-Identifier: MIT

import Foundation
import os

/// Tallies the scanner keeps as it goes. Published in progress events and
/// frozen into the reconciliation at the end.
public struct DiskMapScanCounts: Sendable, Equatable, Codable {
    /// Every entry read from a listing, whatever became of it.
    public var entries: UInt64 = 0
    /// Directories listed successfully.
    public var directories: UInt64 = 0
    /// Regular files kept as individual nodes.
    public var files: UInt64 = 0
    /// Regular files folded into per-kind small-file nodes.
    public var foldedFiles: UInt64 = 0
    public var symlinks: UInt64 = 0
    /// Directories that returned EPERM (TCC; Full Disk Access clears it).
    public var notPermitted: Int = 0
    /// Data vaults (`UF_DATAVAULT`) that returned EPERM: entitlement-only,
    /// nothing the user can grant.
    public var dataVaults: Int = 0
    /// Directories that returned EACCES (Unix permissions).
    public var accessDenied: Int = 0
    /// Directories that failed for any other reason.
    public var unreadable: Int = 0
    /// Directories that disappeared between their parent's listing and their own.
    public var vanished: Int = 0
    /// Evicted (dataless) directories, never opened.
    public var datalessDirectories: Int = 0
    /// Mount points and automount triggers, never descended.
    public var separateVolumes: Int = 0
    /// Later encounters of hard-linked files, counted once.
    public var hardLinkDuplicates: Int = 0
    /// Files with no local data (iCloud or file provider placeholders).
    public var datalessFiles: Int = 0
    /// Files flagged as possibly sharing blocks (clones or snapshot-held).
    public var sharedBlockFiles: Int = 0
    /// Entries the filesystem reported a per-entry error for.
    public var entryErrors: Int = 0

    public init() {}

    /// Directories whose contents are missing from the tree, all causes.
    public var unlistedDirectories: Int {
        notPermitted + dataVaults + accessDenied + unreadable + vanished + datalessDirectories
    }
}

/// A sibling volume of the scanned one that shares its container: the sealed
/// System volume, Preboot, VM, Update. Not scannable, not removable, but part
/// of what Finder calls "Macintosh HD used".
public struct DiskMapSystemVolume: Sendable, Equatable, Identifiable, Codable {
    public var id: String { mountPoint }
    public var mountPoint: String
    public var name: String
    public var role: VolumeRole
    public var usedBytes: UInt64
}

/// Why the scanned total and the volume's used figure differ, and by how
/// much. The identity is `used = scanned + unaccounted`; purgeable space is an
/// overlay (it overlaps files the scan counted as well as snapshot space it
/// did not), shared blocks come straight from the tree, and the overshoot case
/// (scanned exceeds used, which clones cause) is reported rather than hidden.
public struct DiskMapReconciliation: Sendable, Equatable, Codable {
    public var volumeMountPoint: String
    public var volumeName: String?
    public var totalBytes: UInt64?
    /// `VolumeInfo.usedBytes` read after the scan finished.
    public var usedBytes: UInt64?
    public var availableBytes: UInt64?
    /// Finder-style headline free figure (available plus purgeable).
    public var importantUsageAvailableBytes: UInt64?
    public var purgeableBytes: UInt64?
    public var scannedBytes: UInt64
    public var sharedBytes: UInt64
    public var scannedItems: UInt64
    /// `max(0, used - scanned)`: metadata, local snapshots, drift.
    public var unaccountedBytes: UInt64
    /// `max(0, scanned - used)`: clones counted at full size.
    public var overshootBytes: UInt64
    public var localSnapshotCount: Int?
    public var counts: DiskMapScanCounts
    public var systemVolumes: [DiskMapSystemVolume]
    /// The volume's used bytes before the scan started, to expose drift.
    public var usedBytesBeforeScan: UInt64?
    /// True when used space moved more than 1% while the scan ran; the
    /// unaccounted figure is then partly drift, not just metadata.
    public var volumeChangedDuringScan: Bool

    /// Bytes of scanned content the scan could see. When the scope is a
    /// folder this is still the volume's figure; the UI labels it as such.
    public var accountedFraction: Double? {
        guard let usedBytes, usedBytes > 0 else { return nil }
        return min(1, Double(scannedBytes) / Double(usedBytes))
    }

    static func compute(
        scope: DiskMapScope,
        mountPoint: String,
        volume: VolumeInfo?,
        allVolumes: [VolumeInfo],
        usedBefore: UInt64?,
        scannedBytes: UInt64,
        sharedBytes: UInt64,
        scannedItems: UInt64,
        counts: DiskMapScanCounts,
        localSnapshotCount: Int?
    ) -> DiskMapReconciliation {
        let used = volume?.usedBytes
        let unaccounted = used.map { $0 > scannedBytes ? $0 - scannedBytes : 0 } ?? 0
        let overshoot = used.map { scannedBytes > $0 ? scannedBytes - $0 : 0 } ?? 0
        var changed = false
        if let used, let usedBefore, used > 0 {
            let delta = used > usedBefore ? used - usedBefore : usedBefore - used
            changed = Double(delta) / Double(used) > 0.01
        }

        var system: [DiskMapSystemVolume] = []
        if scope == .startupDisk, let container = volume?.containerBSDName {
            for sibling in allVolumes
            where sibling.containerBSDName == container && sibling.mountPoint != mountPoint {
                switch sibling.role {
                case .system, .preboot, .recovery, .vm, .support:
                    system.append(
                        DiskMapSystemVolume(
                            mountPoint: sibling.mountPoint, name: sibling.name,
                            role: sibling.role, usedBytes: sibling.usedBytes))
                case .data, .user:
                    continue
                }
            }
            system.sort { $0.usedBytes > $1.usedBytes }
        }

        return DiskMapReconciliation(
            volumeMountPoint: mountPoint,
            volumeName: volume?.name,
            totalBytes: volume?.totalBytes,
            usedBytes: used,
            availableBytes: volume?.availableBytes,
            importantUsageAvailableBytes: volume?.importantUsageAvailableBytes,
            purgeableBytes: volume?.purgeableBytes,
            scannedBytes: scannedBytes,
            sharedBytes: sharedBytes,
            scannedItems: scannedItems,
            unaccountedBytes: unaccounted,
            overshootBytes: overshoot,
            localSnapshotCount: localSnapshotCount,
            counts: counts,
            systemVolumes: system,
            usedBytesBeforeScan: usedBefore,
            volumeChangedDuringScan: changed)
    }
}

/// Counts local Time Machine snapshots on a volume by asking `tmutil`; there
/// is no public API for it and `fs_snapshot_list` needs an entitlement. Bounded
/// by a short timeout so a wedged tool can never hold a scan's completion.
public enum LocalSnapshotCounter {
    private static let log = Logger(subsystem: "uk.co.bzwrd.macperfmonitor", category: "diskmap")

    public static func count(mountPoint: String, timeout: TimeInterval = 3) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", mountPoint]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            log.notice("tmutil unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
            .count
    }
}
