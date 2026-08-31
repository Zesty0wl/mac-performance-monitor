import MacPerfMonitorCore
import SwiftUI

/// The flat slices of a scan: Largest (files or folders) and Oldest. A SwiftUI
/// `Table` is fine here because the rows are static and capped; the cost that
/// pushed the Processes tab to `NSOutlineView` was re-hosting cells every tick.
struct DiskMapSliceTable: View {
    @ObservedObject var model: DiskMapModel
    @State private var sortOrder: [KeyPathComparator<DiskMapRow>] = [
        KeyPathComparator(\DiskMapRow.bytes, order: .reverse)
    ]
    @State private var sortedRows: [DiskMapRow] = []

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            if sortedRows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .onAppear { resort() }
        .onChange(of: model.rowsRevision) { _, _ in resort() }
        .onChange(of: sortOrder) { _, _ in resort() }
        .onChange(of: model.viewMode) { _, mode in
            sortOrder = [
                mode == .oldest
                    ? KeyPathComparator(\DiskMapRow.modified, order: .forward)
                    : KeyPathComparator(\DiskMapRow.bytes, order: .reverse)
            ]
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            switch model.viewMode {
            case .map, .reclaim, .changes:
                EmptyView()
            case .kinds:
                if let kind = model.selectedKind {
                    Text(LocalizedStringKey(kind.label))
                        .font(.subheadline.weight(.semibold))
                }
            case .largest:
                Picker("Show", selection: $model.largestKind) {
                    ForEach(DiskMapModel.LargestKind.allCases) {
                        Text(LocalizedStringKey($0.rawValue)).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            case .oldest:
                Picker("Age", selection: $model.ageBand) {
                    ForEach(DiskMapModel.AgeBand.allCases) {
                        Text(LocalizedStringKey($0.label)).tag($0)
                    }
                }
                .controlSize(.small)
                .fixedSize()
                Picker("Size", selection: $model.minimumSize) {
                    ForEach(DiskMapModel.MinimumSize.allCases) {
                        Text(LocalizedStringKey($0.label)).tag($0)
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
            Spacer()
            if model.rowsBuilding {
                ProgressView().controlSize(.small)
            }
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var countText: String {
        let shown = sortedRows.count
        if shown >= DiskMapModel.rowLimit { return "Top \(shown)" }
        return shown == 1 ? "1 item" : "\(shown) items"
    }

    private var table: some View {
        Table(sortedRows, selection: selectionBinding, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: ProcessIconProvider.shared.icon(forPath: row.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(row.name.isEmpty ? row.path : row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Size", value: \.bytes) { row in
                Text(ByteFormat.string(row.bytes))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84)
            TableColumn("Share", value: \.fraction) { row in
                Text(shareText(row.fraction))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 56)
            TableColumn("Modified", value: \.modified) { row in
                Text(row.modified.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 104)
            TableColumn("Kind", value: \.kindLabel) { row in
                Text(LocalizedStringKey(row.kindLabel))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Location", value: \.parentPath) { row in
                Text(row.parentPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 140, ideal: 320)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Int32.self) { ids in
            if let id = ids.first, let path = model.displayPath(of: id) {
                Button {
                    ProcessActions.revealInFinder(path: path)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                Button {
                    model.reveal(id)
                } label: {
                    Label("Show in Map", systemImage: "rectangle.3.group")
                }
                if model.canTrash(id) {
                    Divider()
                    Button(role: .destructive) {
                        model.requestTrash(id)
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let path = model.displayPath(of: id) {
                ProcessActions.revealInFinder(path: path)
            }
        }
    }

    private var selectionBinding: Binding<Int32?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    private var emptyState: some View {
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        switch model.viewMode {
        case .kinds:
            title = model.selectedKind == nil ? "Choose a kind" : "Nothing of this kind"
            detail =
                model.selectedKind == nil
                ? "Pick a kind on the left to list its largest items."
                : "The scan found nothing of this kind."
        case .map, .largest, .reclaim, .changes:
            title = model.filterText.isEmpty ? "Nothing to show" : "No matches"
            detail =
                model.filterText.isEmpty
                ? (model.largestKind == .files
                    ? "The scan found no files here." : "The scan found no folders here.")
                : "Nothing named like \u{201C}\(model.filterText)\u{201D} in this scan."
        case .oldest:
            title = "Nothing that old"
            let age = String(localized: String.LocalizationValue(model.ageBand.label))
            let size = String(localized: String.LocalizationValue(model.minimumSize.label))
            detail =
                "No files match \(age.localizedLowercase) and \(size.localizedLowercase). Widen the filters to see more."
        }
        return ContentUnavailableView(title, systemImage: "tray", description: Text(detail))
    }

    private func resort() {
        sortedRows = model.rows.sorted(using: sortOrder)
    }

    private func shareText(_ fraction: Double) -> String {
        let percent = fraction * 100
        if percent > 0 && percent < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", percent)
    }
}
