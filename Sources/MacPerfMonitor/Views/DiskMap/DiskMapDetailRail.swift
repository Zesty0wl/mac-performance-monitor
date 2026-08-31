import MacPerfMonitorCore
import QuickLook
import SwiftUI

/// The right-hand rail: everything about the selected item and the ways to
/// act on it. Facts the scan did not carry (logical length, the bytes a delete
/// would free) are read on selection with one `getattrlist`, off the main
/// thread, and shown when they arrive.
struct DiskMapDetailRail: View {
    @ObservedObject var model: DiskMapModel
    @State private var facts: DiskMapItemFacts?
    @State private var quickLookURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node = model.selection, let snapshot = model.snapshot,
                    Int(node) < snapshot.tree.nodeCount
                {
                    content(node: node, snapshot: snapshot)
                } else {
                    placeholder
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.selection) { await loadFacts() }
        .quickLookPreview($quickLookURL)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("Select an item")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Its size, age and location appear here, with Reveal in Finder and Quick Look.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func content(node: Int32, snapshot: DiskMapSnapshot) -> some View {
        let tree = snapshot.tree
        let i = Int(node)
        let flags = tree.flags[i]
        let isFold = flags.contains(.smallFilesFold)
        let isDirectory = flags.contains(.directory)
        let displayPath = snapshot.displayPath(of: node)
        let name =
            isFold
            ? foldName(tree, node)
            : (node == FileTree.root ? snapshot.scope.rootName : tree.name(of: node))
        let parentBytes = node == FileTree.root ? tree.bytes[0] : tree.bytes[Int(tree.parent[i])]

        header(
            name: name, path: displayPath, isFold: isFold, kind: tree.kind[i],
            isDirectory: isDirectory)

        pathRow(displayPath)

        factsGrid(
            tree: tree, node: node, parentBytes: parentBytes, isDirectory: isDirectory,
            isFold: isFold)

        if !badges(flags).isEmpty {
            badgeRow(badges(flags))
        }

        if !isFold {
            actions(displayPath: displayPath, isDirectory: isDirectory)
        }

        if isDirectory, tree.childCount[i] > 0 {
            topContents(tree: tree, node: node)
        } else if flags.contains(.notPermitted) {
            note(
                "macOS did not allow \(AppInfo.displayName) to read this folder. Full Disk Access unlocks it."
            )
        } else if flags.contains(.dataVault) {
            note("A data vault: only Apple's own software may read it, whatever access is granted.")
        } else if flags.contains(.accessDenied) {
            note("Owned by another user or by the system; your account cannot list it.")
        } else if flags.contains(.separateVolume) {
            note("Another volume is mounted here. Its contents are not part of this scan.")
        } else if flags.contains(.dataless), isDirectory {
            note("Stored in iCloud and not downloaded. Nothing here takes local space.")
        }
    }

    private func header(
        name: String, path: String, isFold: Bool, kind: FileKind, isDirectory: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if isFold {
                Image(systemName: "square.stack.3d.up")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            } else {
                Image(nsImage: ProcessIconProvider.shared.icon(forPath: path))
                    .resizable()
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(isDirectory && kind == .folder ? "Folder" : kind.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pathRow(_ path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(path)
                .font(.callout.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy path")
        }
    }

    @ViewBuilder
    private func factsGrid(
        tree: FileTree, node: Int32, parentBytes: UInt64, isDirectory: Bool, isFold: Bool
    )
        -> some View
    {
        let i = Int(node)
        let bytes = tree.bytes[i]
        let total = max(tree.bytes[0], 1)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            factRow("Size", ByteFormat.string(bytes))
            if let facts, !isDirectory, !isFold {
                if facts.logicalBytes != facts.allocatedBytes {
                    factRow("Length", ByteFormat.string(facts.logicalBytes), dim: true)
                }
                if facts.privateBytes != nil {
                    factRow(
                        "Would free now", ByteFormat.string(facts.wouldFreeBytes),
                        dim: facts.wouldFreeBytes == bytes)
                }
                if facts.linkCount > 1 {
                    factRow("Hard links", "\(facts.linkCount)", dim: true)
                }
            }
            if isDirectory || isFold {
                factRow("Items", tree.count[i].formatted())
            }
            factRow("Share of scan", shareText(Double(bytes) / Double(total)))
            if node != FileTree.root, parentBytes > 0 {
                factRow("Share of parent", shareText(Double(bytes) / Double(parentBytes)))
            }
            if tree.modified[i] > 0 {
                factRow("Modified", modifiedText(tree.modifiedDate(of: node)))
            }
        }
    }

    private func factRow(_ label: String, _ value: String, dim: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(dim ? .secondary : .primary)
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func badges(_ flags: FileNodeFlags) -> [String] {
        var out: [String] = []
        if flags.contains(.package) { out.append("Package") }
        if flags.contains(.mayShareBlocks) { out.append("Clone") }
        if flags.contains(.hardLinkDuplicate) { out.append("Hard link (counted elsewhere)") }
        if flags.contains(.dataless) { out.append("In iCloud, not on this disk") }
        if flags.contains(.restricted) { out.append("Protected by SIP") }
        if flags.contains(.immutable) { out.append("Locked") }
        if flags.contains(.symlink) { out.append("Alias") }
        if flags.contains(.hidden) { out.append("Hidden") }
        if flags.contains(.smallFilesFold) { out.append("Small files") }
        if flags.contains(.trashed) { out.append("In Trash") }
        return out
    }

    private func badgeRow(_ badges: [String]) -> some View {
        HardwareFlowLayout(spacing: 5) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actions(displayPath: String, isDirectory: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                ProcessActions.revealInFinder(path: displayPath)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Show this item in the Finder")
            Button {
                quickLookURL = URL(fileURLWithPath: displayPath)
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .help("Preview without opening (Space)")
            .keyboardShortcut(.space, modifiers: [])
        }
        .controlSize(.small)
    }

    private func topContents(tree: FileTree, node: Int32) -> some View {
        let children = tree.childrenBySize(of: node).prefix(8)
        let parentBytes = max(tree.bytes[Int(node)], 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("TOP CONTENTS")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            ForEach(Array(children), id: \.self) { child in
                let c = Int(child)
                Button {
                    model.select(child)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: tree.flags[c].contains(.directory) ? "folder" : "doc")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text(childName(tree, child))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteFormat.string(tree.bytes[c]))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GroupProportionBar(
                            fraction: Double(tree.bytes[c]) / Double(parentBytes),
                            tint: DiskStyle.read)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func childName(_ tree: FileTree, _ child: Int32) -> String {
        tree.flags[Int(child)].contains(.smallFilesFold)
            ? foldName(tree, child) : tree.name(of: child)
    }

    private func foldName(_ tree: FileTree, _ node: Int32) -> String {
        let i = Int(node)
        let kind = tree.kind[i]
        let what = kind == .other ? "small items" : "small \(kind.label.lowercased())"
        return "\(tree.count[i].formatted()) \(what)"
    }

    private func shareText(_ fraction: Double) -> String {
        let percent = fraction * 100
        if percent > 0 && percent < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", percent)
    }

    private func modifiedText(_ date: Date) -> String {
        let relative = date.formatted(.relative(presentation: .named))
        return "\(relative)"
    }

    private func loadFacts() async {
        facts = nil
        guard let node = model.selection, let snapshot = model.snapshot,
            Int(node) < snapshot.tree.nodeCount,
            !snapshot.tree.flags[Int(node)].contains(.smallFilesFold)
        else { return }
        let path = snapshot.filesystemPath(of: node)
        let read = await Task.detached(priority: .userInitiated) {
            DiskMapItemFacts.read(path: path)
        }.value
        guard !Task.isCancelled, model.selection == node else { return }
        facts = read
    }
}
