import MacPerfMonitorCore
import SwiftUI

/// What changed since the previous scan of this scope: the folders and large
/// files that grew or shrank, largest movement first, with a signed bar. The
/// flight-recorder answer to "where did 30 GB go this week".
struct DiskMapChangesView: View {
    @ObservedObject var model: DiskMapModel

    var body: some View {
        Group {
            switch model.diffState {
            case .idle, .loading:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Comparing with the previous scan\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noPrevious:
                ContentUnavailableView(
                    "No earlier scan to compare with", systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "The previous scan of \(model.scopeTitle) is kept when you rescan. Scan again later and this view shows what grew and what shrank in between."
                    ))
            case .ready:
                if let diff = model.diff, let snapshot = model.snapshot {
                    content(diff, snapshot: snapshot)
                }
            }
        }
        .onAppear { model.loadDiffIfNeeded() }
    }

    private func content(_ diff: DiskMapDiff, snapshot: DiskMapSnapshot) -> some View {
        VStack(spacing: 0) {
            summary(diff)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if diff.grown.isEmpty && diff.shrunk.isEmpty {
                ContentUnavailableView(
                    "Nothing moved by 10 MB or more", systemImage: "equal.circle",
                    description: Text(
                        "Between the two scans no folder or large file changed size enough to show."
                    ))
            } else {
                List(selection: selectionBinding) {
                    if !diff.grown.isEmpty {
                        Section {
                            ForEach(diff.grown) { entry in
                                row(entry, diff: diff, snapshot: snapshot)
                                    .tag(entry.node ?? -1)
                            }
                        } header: {
                            sectionHeader("Grew", entries: diff.grown, tint: .orange)
                        }
                    }
                    if !diff.shrunk.isEmpty {
                        Section {
                            ForEach(diff.shrunk) { entry in
                                row(entry, diff: diff, snapshot: snapshot)
                                    .tag(entry.node ?? -1)
                            }
                        } header: {
                            sectionHeader("Shrank or gone", entries: diff.shrunk, tint: .green)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func summary(_ diff: DiskMapDiff) -> some View {
        let when = diff.previousScannedAt.formatted(date: .abbreviated, time: .shortened)
        let delta = diff.totalDelta
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Since \(when)")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "\(ByteFormat.string(diff.totalBefore)) then, \(ByteFormat.string(diff.totalAfter)) now"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(signed(delta))
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(delta > 0 ? .orange : (delta < 0 ? .green : .secondary))
        }
    }

    private func sectionHeader(
        _ title: String, entries: [DiskMapDiffEntry], tint: Color
    ) -> some View {
        let total = entries.reduce(Int64(0)) { $0 + $1.delta }
        return HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(signed(total))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(entries.count) entries")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .textCase(nil)
    }

    private func row(
        _ entry: DiskMapDiffEntry, diff: DiskMapDiff, snapshot: DiskMapSnapshot
    )
        -> some View
    {
        let largest = max(
            abs(diff.grown.first?.delta ?? 0), abs(diff.shrunk.first?.delta ?? 0), 1)
        let fraction = Double(abs(entry.delta)) / Double(largest)
        let tint: Color = entry.delta > 0 ? .orange : .green
        let name =
            entry.relativePath.isEmpty
            ? snapshot.scope.rootName : (entry.relativePath as NSString).lastPathComponent
        let location =
            entry.relativePath.isEmpty
            ? snapshot.scope.displayRoot
            : FirmlinkMap.system.canonicalPath(
                snapshot.rootPath == "/"
                    ? "/" + (entry.relativePath as NSString).deletingLastPathComponent
                    : snapshot.rootPath + "/"
                        + (entry.relativePath as NSString).deletingLastPathComponent)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.isNew {
                    badge("new")
                } else if entry.isGone {
                    badge("gone")
                }
                Text(location)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(
                    "\(ByteFormat.string(entry.before)) \u{2192} \(ByteFormat.string(entry.after))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Text(signed(entry.delta))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 90, alignment: .trailing)
            }
            GroupProportionBar(fraction: fraction, tint: tint)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            if let node = entry.node {
                Button {
                    model.reveal(node)
                } label: {
                    Label("Show in Map", systemImage: "rectangle.3.group")
                }
                Button {
                    ProcessActions.revealInFinder(path: snapshot.displayPath(of: node))
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .foregroundStyle(.secondary)
    }

    private func signed(_ delta: Int64) -> String {
        if delta == 0 { return "no change" }
        let magnitude = ByteFormat.string(UInt64(abs(delta)))
        return delta > 0 ? "+\(magnitude)" : "\u{2212}\(magnitude)"
    }

    private var selectionBinding: Binding<Int32?> {
        Binding(
            get: { model.selection },
            set: { model.select(($0 ?? -1) < 0 ? nil : $0) })
    }
}
