import MacPerfMonitorCore
import SwiftUI

/// The "which of this can I remove safely" answer: the known locations the
/// advisor found in the scan, grouped by how safe they are, largest first,
/// each with its reason and the proper way to reclaim the space.
struct DiskMapReclaimView: View {
    @ObservedObject var model: DiskMapModel

    private static let tierOrder: [DiskMapSafetyTier] = [
        .safeToRemove, .reviewBeforeRemoving, .managedByApp, .systemProtected,
    ]

    var body: some View {
        if let analysis = model.analysis, let snapshot = model.snapshot,
            analysis.revision == snapshot.revision
        {
            if analysis.reclaim.isEmpty {
                ContentUnavailableView(
                    "Nothing recognised", systemImage: "sparkles",
                    description: Text(
                        "None of the folders this scan covered is a known cache, library or download location."
                    ))
            } else {
                list(analysis, snapshot: snapshot)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking through the scan\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ analysis: DiskMapAnalysis, snapshot: DiskMapSnapshot) -> some View {
        let total = max(snapshot.tree.bytes[0], 1)
        let grouped = Dictionary(grouping: analysis.reclaim, by: \.advice.tier)
        return List(selection: selectionBinding) {
            ForEach(Self.tierOrder, id: \.self) { tier in
                if let items = grouped[tier], !items.isEmpty {
                    Section {
                        ForEach(items.prefix(150)) { item in
                            row(item, snapshot: snapshot, total: total)
                                .tag(item.node)
                        }
                    } header: {
                        header(tier, items: items)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func header(_ tier: DiskMapSafetyTier, items: [DiskMapReclaimItem]) -> some View {
        let bytes = items.reduce(UInt64(0)) { $0 &+ $1.bytes }
        return HStack(spacing: 8) {
            Circle()
                .fill(DiskMapStyle.safetyTint(tier))
                .frame(width: 8, height: 8)
            Text(LocalizedStringKey(tier.label))
                .font(.caption.weight(.semibold))
            Text(ByteFormat.string(bytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(tierHint(tier)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
        }
        .textCase(nil)
    }

    private func tierHint(_ tier: DiskMapSafetyTier) -> String {
        switch tier {
        case .safeToRemove: return "regenerates when needed"
        case .reviewBeforeRemoving: return "your files, look first"
        case .managedByApp: return "use the app's own controls"
        case .systemProtected: return "shown for the accounting, not removable"
        }
    }

    private func row(
        _ item: DiskMapReclaimItem, snapshot: DiskMapSnapshot, total: UInt64
    )
        -> some View
    {
        let path = snapshot.displayPath(of: item.node)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(LocalizedStringKey(item.advice.title))
                    .font(.subheadline.weight(.semibold))
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(ByteFormat.string(item.bytes))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                (item.count == 1 ? Text("1 item") : Text("\(item.count.formatted()) items"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 84, alignment: .trailing)
            }
            GroupProportionBar(
                fraction: Double(item.bytes) / Double(total),
                tint: DiskMapStyle.safetyTint(item.advice.tier))
            Text(LocalizedStringKey(item.advice.reason))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let how = item.advice.howToReclaim {
                Text(LocalizedStringKey(how))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                model.reveal(item.node)
            } label: {
                Label("Show in Map", systemImage: "rectangle.3.group")
            }
            Button {
                ProcessActions.revealInFinder(path: path)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            if model.canTrash(item.node) {
                Divider()
                Button(role: .destructive) {
                    model.requestTrash(item.node)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
    }

    private var selectionBinding: Binding<Int32?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }
}

/// Bytes by kind, with the largest items of the chosen kind beside it.
struct DiskMapKindsView: View {
    @ObservedObject var model: DiskMapModel

    var body: some View {
        HStack(spacing: 0) {
            kindsColumn
                .frame(width: 280)
            Divider()
            DiskMapSliceTable(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var kindsColumn: some View {
        if let analysis = model.analysis, let snapshot = model.snapshot,
            analysis.revision == snapshot.revision
        {
            let total = max(snapshot.tree.bytes[0], 1)
            List(selection: kindBinding) {
                ForEach(analysis.kinds) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(kindColor(entry.kind))
                                .frame(width: 9, height: 9)
                            Text(LocalizedStringKey(entry.kind.label))
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Text(ByteFormat.string(entry.bytes))
                                .font(.subheadline.monospacedDigit())
                        }
                        GroupProportionBar(
                            fraction: Double(entry.bytes) / Double(total),
                            tint: kindColor(entry.kind))
                        Text(
                            "\(Self.percent(entry.bytes, of: total)) \u{00B7} \(Self.count(entry.count))"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(entry.kind)
                }
            }
            .listStyle(.inset)
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Totalling by kind\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var kindBinding: Binding<FileKind?> {
        Binding(get: { model.selectedKind }, set: { model.selectedKind = $0 })
    }

    private func kindColor(_ kind: FileKind) -> Color {
        DiskMapStyle.legend(for: .kind).first { $0.label == kind.label }?.color ?? .secondary
    }

    private static func percent(_ bytes: UInt64, of total: UInt64) -> String {
        let value = Double(bytes) / Double(total) * 100
        return value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
    }

    private static func count(_ value: UInt64) -> String {
        value == 1
            ? String(localized: "1 item")
            : String(format: String(localized: "%@ items"), DiskMapModel.compactCount(value))
    }
}
