import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The Disk tab's second page: scan a volume or folder and see what is using
/// the space. This page hosts the scope and scan controls, the reconciliation
/// bar, the active view (the map, Largest, Oldest) and the detail rail. The
/// model is shared so a scan survives switching tabs; the page merely
/// observes it.
struct DiskMapView: View {
    @ObservedObject private var model = DiskMapModel.shared
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var fullDiskAccess: FullDiskAccessManager
    @State private var quickLookURL: URL?

    static let railWidth: CGFloat = 330

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            Group {
                if let snapshot = model.snapshot {
                    ready(snapshot)
                } else if model.isScanning {
                    scanning
                } else if model.isRestoring {
                    ProgressView("Loading the last scan\u{2026}")
                        .controlSize(.small)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            model.bind(appState: appState, fullDiskAccess: fullDiskAccess)
            model.appear()
        }
        .quickLookPreview($quickLookURL)
        .confirmationDialog(
            trashTitle, isPresented: trashConfirming, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let node = model.pendingTrash { model.performTrash(node) }
            }
            Button("Cancel", role: .cancel) { model.pendingTrash = nil }
        } message: {
            Text(trashMessage)
        }
        .alert(
            "Couldn\u{2019}t move to the Trash",
            isPresented: Binding(
                get: { model.trashError != nil },
                set: { if !$0 { model.trashError = nil } })
        ) {
            Button("OK", role: .cancel) { model.trashError = nil }
        } message: {
            Text(model.trashError ?? "")
        }
        .alert(
            "Scan failed",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.clearError() } })
        ) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - Trash

    private var trashConfirming: Binding<Bool> {
        Binding(
            get: { model.pendingTrash != nil },
            set: { if !$0 { model.pendingTrash = nil } })
    }

    private var trashTitle: String {
        guard let node = model.pendingTrash, let snapshot = model.snapshot,
            Int(node) < snapshot.tree.nodeCount
        else { return "Move to the Trash?" }
        return "Move \u{201C}\(snapshot.tree.name(of: node))\u{201D} to the Trash?"
    }

    private var trashMessage: String {
        guard let node = model.pendingTrash, let snapshot = model.snapshot,
            Int(node) < snapshot.tree.nodeCount
        else { return "" }
        let tree = snapshot.tree
        let i = Int(node)
        var parts = [ByteFormat.string(tree.bytes[i])]
        if tree.flags[i].contains(.directory) {
            parts.append(tree.count[i] == 1 ? "1 item" : "\(tree.count[i].formatted()) items")
        }
        var text = parts.joined(separator: ", ") + ". "
        if let advice = model.advice(for: node), advice.tier == .managedByApp,
            let how = advice.howToReclaim
        {
            text += "\(advice.title) is managed by an app; the recommended way is: \(how) "
        }
        text +=
            "The space is freed when you empty the Trash in Finder, and you can put the item back until then."
        return text
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            scopeMenu
            if model.isScanning {
                Button("Cancel") { model.cancelScan() }
                    .controlSize(.small)
                Group {
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .frame(width: 140)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Button {
                    model.startScan()
                } label: {
                    Label(model.snapshot == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan \(model.scopeTitle) again (Command-R)")
                if let snapshot = model.snapshot {
                    Text(scannedText(snapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if model.snapshot != nil {
                Picker("View", selection: $model.viewMode) {
                    ForEach(DiskMapModel.ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
                if model.viewMode == .map {
                    Picker("Colour", selection: $model.colorMode) {
                        ForEach(DiskMapColorMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .help(model.colorMode.help)
                } else {
                    searchField
                }
            }
        }
    }

    private var scopeMenu: some View {
        Menu {
            Button {
                model.setScope(.startupDisk)
            } label: {
                Label("Macintosh HD", systemImage: "internaldrive")
            }
            Button {
                model.setScope(.home)
            } label: {
                Label("Home", systemImage: "house")
            }
            Button {
                model.setScope(.folder("/Applications"))
            } label: {
                Label("Applications", systemImage: "square.grid.2x2")
            }
            if !model.externalVolumes.isEmpty {
                Divider()
                ForEach(model.externalVolumes) { volume in
                    Button {
                        model.setScope(.volume(volume.mountPoint))
                    } label: {
                        Label(volume.name, systemImage: "externaldrive")
                    }
                }
            }
            Divider()
            Button("Choose Folder\u{2026}") { model.chooseFolder() }
        } label: {
            Label(model.scopeTitle, systemImage: scopeSymbol)
                .font(.headline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isScanning)
        .help("Choose what to map")
    }

    private var scopeSymbol: String {
        switch model.scope {
        case .startupDisk: return "internaldrive"
        case .home: return "house"
        case .folder: return "folder"
        case .volume: return "externaldrive"
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by name", text: $model.filterText)
                .textFieldStyle(.plain)
            if !model.filterText.isEmpty {
                Button {
                    model.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .frame(width: 220)
    }

    private func scannedText(_ snapshot: DiskMapSnapshot) -> String {
        let when = snapshot.scannedAt.formatted(.relative(presentation: .named))
        return snapshot.partial ? "Partial scan \(when)" : "Scanned \(when)"
    }

    // MARK: - States

    private func ready(_ snapshot: DiskMapSnapshot) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                DiskMapReconciliationBar(
                    reconciliation: snapshot.reconciliation, scope: snapshot.scope,
                    inTrashBytes: model.trashedBytes,
                    onGrantAccess: { fullDiskAccess.openSystemSettings() })
                if snapshot.reconciliation.counts.notPermitted > 0, !fullDiskAccess.isGranted {
                    FullDiskAccessCard(
                        notPermittedCount: snapshot.reconciliation.counts.notPermitted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                Group {
                    switch model.viewMode {
                    case .map:
                        mapContent(snapshot)
                    case .largest, .oldest:
                        DiskMapSliceTable(model: model)
                    case .kinds:
                        DiskMapKindsView(model: model)
                    case .reclaim:
                        DiskMapReclaimView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                DiskMapDetailRail(model: model)
                    .frame(width: Self.railWidth)
            }
        }
    }

    // MARK: - Map

    private func mapContent(_ snapshot: DiskMapSnapshot) -> some View {
        VStack(spacing: 0) {
            breadcrumbBar
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    TreemapSurface(
                        tree: snapshot.tree, revision: snapshot.revision, zoomRoot: model.zoomRoot,
                        selection: model.selection, colorMode: model.colorMode,
                        tiers: model.analysis?.revision == snapshot.revision
                            ? model.analysis?.tiers : nil,
                        onSelect: { model.select($0) },
                        onOpen: { model.zoom(into: $0) },
                        onBack: { model.zoomOut() },
                        onHover: { model.hover = $0 },
                        onQuickLook: { node in
                            quickLookURL = URL(fileURLWithPath: snapshot.displayPath(of: node))
                        },
                        menu: { node in cellMenu(node, snapshot: snapshot) })
                    if let hover = model.hover {
                        hoverCard(hover, snapshot: snapshot, in: geometry.size)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            legend
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            Button {
                model.zoomOut()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(model.zoomRoot == FileTree.root)
            .help("Back out one level (Escape)")
            let crumbs = model.breadcrumbs
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Text("\u{203A}")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button(crumb.name) {
                    if crumb.node != model.zoomRoot { model.zoom(into: crumb.node) }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(index == crumbs.count - 1 ? .semibold : .regular))
                .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("Double-click a folder to open it \u{00B7} Escape to go back")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(DiskMapStyle.legend(for: model.colorMode)) { entry in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(entry.color)
                        .frame(width: 9, height: 9)
                    Text(entry.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func hoverCard(
        _ hover: TreemapHover, snapshot: DiskMapSnapshot, in size: CGSize
    )
        -> some View
    {
        let tree = snapshot.tree
        let parentBytes = max(tree.bytes[Int(hover.parent)], 1)
        let name: String
        let bytes: UInt64
        var detail: String
        var isFolder = false
        if hover.node == TreemapCell.aggregateNode {
            name = "\(hover.aggregateCount.formatted()) more items"
            bytes = hover.aggregateBytes
            detail = "Too small to draw separately"
        } else {
            let i = Int(hover.node)
            let flags = tree.flags[i]
            bytes = tree.bytes[i]
            if flags.contains(.smallFilesFold) {
                let kind = tree.kind[i]
                name =
                    "\(tree.count[i].formatted()) small \(kind == .other ? "items" : kind.label.lowercased())"
                detail = "Folded together for the map"
            } else {
                name = tree.name(of: hover.node)
                isFolder = flags.contains(.directory) && tree.childCount[i] > 0
                detail =
                    isFolder && !flags.contains(.smallFilesFold)
                    ? "\(tree.count[i].formatted()) items \u{00B7} double-click to open"
                    : (flags.contains(.directory) ? "Folder" : tree.kind[i].label)
            }
        }
        let share = Double(bytes) / Double(parentBytes) * 100
        let parentName =
            hover.parent == FileTree.root ? snapshot.scope.rootName : tree.name(of: hover.parent)
        let cardWidth: CGFloat = 250
        let cardHeight: CGFloat = 64
        let x = min(max(8, hover.rect.midX - cardWidth / 2), max(8, size.width - cardWidth - 8))
        let below = hover.rect.maxY + 8
        let y = below + cardHeight <= size.height ? below : max(8, hover.rect.minY - cardHeight - 8)
        return VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(ByteFormat.string(bytes))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                Text(String(format: "%.1f%% of %@", share, parentName))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: cardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.15)))
        .offset(x: x, y: y)
    }

    private func cellMenu(_ node: Int32, snapshot: DiskMapSnapshot) -> NSMenu? {
        let tree = snapshot.tree
        guard Int(node) < tree.nodeCount else { return nil }
        let path = snapshot.displayPath(of: node)
        let flags = tree.flags[Int(node)]
        let menu = NSMenu()
        if flags.contains(.directory), !flags.contains(.smallFilesFold),
            tree.childCount[Int(node)] > 0
        {
            menu.addItem(
                ClosureMenuItem("Open in Map", symbol: "square.grid.2x2") { model.zoom(into: node) }
            )
        }
        menu.addItem(
            ClosureMenuItem("Reveal in Finder", symbol: "folder") {
                ProcessActions.revealInFinder(path: path)
            })
        if !flags.contains(.smallFilesFold) {
            menu.addItem(
                ClosureMenuItem("Quick Look", symbol: "eye") {
                    quickLookURL = URL(fileURLWithPath: path)
                })
        }
        menu.addItem(
            ClosureMenuItem("Copy Path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            })
        if model.canTrash(node) {
            menu.addItem(.separator())
            menu.addItem(
                ClosureMenuItem("Move to Trash", symbol: "trash") { model.requestTrash(node) })
        }
        return menu
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scanning \(model.scopeTitle)")
                    .font(.headline)
                Text(model.currentPathText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let preview = model.preview, !preview.children.isEmpty {
                Text("LARGEST SO FAR")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                let total = max(preview.bytes, 1)
                ForEach(Array(preview.children.prefix(16).enumerated()), id: \.offset) { _, child in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: child.isDirectory ? "folder" : "doc")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text(child.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteFormat.string(child.bytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GroupProportionBar(
                            fraction: Double(child.bytes) / Double(total), tint: DiskStyle.read)
                    }
                }
                Text("Folders fill in as the scan runs.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.isPreparing ? "Checking folder access" : "Reading the first folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Map \(model.scopeTitle)")
                    .font(.title3.weight(.semibold))
                Text(
                    "Scan to see what is using the space, largest first, with a way to act on each item."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            if !fullDiskAccess.isGranted, model.scope == .startupDisk || model.scope == .home {
                FullDiskAccessCard(onScanAnyway: { model.startScan() })
                    .frame(maxWidth: 520)
            } else {
                Button {
                    model.startScan()
                } label: {
                    Label("Scan \(model.scopeTitle)", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
