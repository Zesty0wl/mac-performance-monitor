import MacPerfMonitorCore
import SwiftUI

/// Where every byte of the volume went, in one bar: what the scan counted,
/// what it could not account for, the non-removable macOS volumes of the
/// startup disk, and what is free. Beneath it, chips for the figures that
/// qualify the bar (purgeable, shared blocks, folders that could not be read)
/// so the total the user sees matches Finder's and the caveats are explicit.
struct DiskMapReconciliationBar: View {
    let reconciliation: DiskMapReconciliation
    let scope: DiskMapScope
    /// Bytes moved to the Trash from this page since the scan; the volume
    /// does not shrink until Finder empties it.
    var inTrashBytes: UInt64 = 0
    var onGrantAccess: (() -> Void)?
    var onFolderAccess: (() -> Void)?

    private struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: UInt64
        let color: Color
    }

    private var scanned: UInt64 { reconciliation.scannedBytes }
    private var systemBytes: UInt64 { reconciliation.systemVolumes.reduce(0) { $0 + $1.usedBytes } }

    private var segments: [Segment] {
        var result: [Segment] = [
            Segment(id: "scanned", label: scannedLabel, bytes: scanned, color: DiskStyle.read)
        ]
        if reconciliation.unaccountedBytes > 0 {
            result.append(
                Segment(
                    id: "unaccounted", label: "Unaccounted", bytes: reconciliation.unaccountedBytes,
                    color: Color.secondary.opacity(0.45)))
        }
        if systemBytes > 0 {
            result.append(Segment(id: "macos", label: "macOS", bytes: systemBytes, color: .teal))
        }
        if let free = reconciliation.availableBytes, free > 0 {
            result.append(
                Segment(id: "free", label: "Free", bytes: free, color: DiskStyle.freeTrack))
        }
        return result
    }

    private var scannedLabel: String {
        switch scope {
        case .startupDisk, .volume: return "Scanned"
        case .home, .folder: return scope.rootName
        }
    }

    private var totalBytes: UInt64 { max(segments.reduce(0) { $0 + $1.bytes }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                headlineText
                    .font(.subheadline.weight(.semibold))
                subheadlineText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            bar
                .frame(height: 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Space accounting")
                .accessibilityValue(accessibilitySummary)
            legendAndChips
        }
    }

    private var headlineText: Text {
        if let used = reconciliation.usedBytes {
            let name = reconciliation.volumeName ?? String(localized: "Volume")
            return Text("\(name): \(ByteFormat.string(used)) used")
        }
        return Text("\(ByteFormat.string(scanned)) scanned")
    }

    private var subheadlineText: Text {
        var parts: [Text] = [
            Text("\(ByteFormat.string(scanned)) in \(compact(reconciliation.scannedItems)) items")
        ]
        if let total = reconciliation.totalBytes {
            parts.append(Text("\(ByteFormat.string(total)) capacity"))
        }
        if reconciliation.volumeChangedDuringScan {
            parts.append(Text("volume changed during the scan"))
        }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(" \u{00B7} ") + $1 }
    }

    private var bar: some View {
        GeometryReader { geometry in
            let gaps = CGFloat(max(segments.count - 1, 0)) * 2
            let available = max(geometry.size.width - gaps, 1)
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.color)
                        .frame(
                            width: max(
                                available * CGFloat(segment.bytes) / CGFloat(totalBytes),
                                segment.bytes > 0 ? 3 : 0))
                }
            }
        }
    }

    private var legendAndChips: some View {
        HStack(spacing: 14) {
            ForEach(segments) { segment in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.color)
                        .frame(width: 8, height: 8)
                    Text(LocalizedStringKey(segment.label))
                        .font(.caption)
                    Text(ByteFormat.string(segment.bytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            chips
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var chips: some View {
        if inTrashBytes > 0 {
            chipButton(
                "In Trash \(ByteFormat.string(inTrashBytes))",
                tint: .green,
                help:
                    "Moved to the Trash from here. The space is freed when the Trash is emptied in Finder.",
                action: nil)
        }
        if let purgeable = reconciliation.purgeableBytes, purgeable > 0 {
            chip("Purgeable \(ByteFormat.string(purgeable))", help: purgeableHelp)
        }
        if reconciliation.overshootBytes > 0 {
            chip(
                "Clones \(ByteFormat.string(reconciliation.overshootBytes)) over",
                help:
                    "Cloned files are counted at full size, so the scan exceeds the volume's used figure by their shared blocks."
            )
        } else if reconciliation.sharedBytes > 0 {
            chip(
                "Shared \(ByteFormat.string(reconciliation.sharedBytes))",
                help: "Bytes shared with clones or held by snapshots.")
        }
        if let snapshots = reconciliation.localSnapshotCount, snapshots == 1 {
            chip(
                "1 local snapshot",
                help:
                    "Time Machine local snapshots hold space the scan cannot attribute to files. macOS thins them when space is needed."
            )
        } else if let snapshots = reconciliation.localSnapshotCount, snapshots > 1 {
            chip(
                "\(snapshots) local snapshots",
                help:
                    "Time Machine local snapshots hold space the scan cannot attribute to files. macOS thins them when space is needed."
            )
        }
        let counts = reconciliation.counts
        if counts.notPermitted > 0 {
            chipButton(
                "\(counts.notPermitted) not permitted", tint: .orange,
                help:
                    "Folders macOS did not let \(AppInfo.displayName) read. Full Disk Access unlocks them.",
                action: onGrantAccess)
        }
        if counts.dataVaults > 0 {
            chip(
                "\(counts.dataVaults) protected by macOS",
                help: "Data vaults only Apple's own software may read; no setting changes this.")
        }
        if counts.accessDenied > 0 {
            chip(
                "\(counts.accessDenied) owned by others",
                help:
                    "Folders belonging to another user or to the system that your account cannot list."
            )
        }
        if counts.separateVolumes == 1 {
            chip(
                "1 other volume",
                help:
                    "Mount points inside this scope. Their contents belong to other volumes; scan them from the scope menu."
            )
        } else if counts.separateVolumes > 1 {
            chip(
                "\(counts.separateVolumes) other volumes",
                help:
                    "Mount points inside this scope. Their contents belong to other volumes; scan them from the scope menu."
            )
        }
    }

    private var purgeableHelp: LocalizedStringKey {
        "Space macOS can reclaim on its own when needed: caches, optimised originals, synced content. It overlaps the files the scan counted."
    }

    private func chip(_ text: LocalizedStringKey, help: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
            .foregroundStyle(.secondary)
            .help(help)
    }

    private func chipButton(
        _ text: LocalizedStringKey, tint: Color, help: LocalizedStringKey, action: (() -> Void)?
    ) -> some View {
        Button(action: { action?() }) {
            HStack(spacing: 4) {
                Image(systemName: tint == .green ? "trash" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text(text)
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func compact(_ value: UInt64) -> String {
        DiskMapModel.compactCount(value)
    }

    private var accessibilitySummary: String {
        segments.map { "\($0.label) \(ByteFormat.string($0.bytes))" }.joined(separator: ", ")
    }
}
