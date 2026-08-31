import MacPerfMonitorCore
import SwiftUI

/// The Disk tab's second page: scan a volume or folder and see what is using
/// the space. This page hosts the scope and scan controls, the reconciliation
/// bar, the active slice (Largest, Oldest) and the detail rail. The model is
/// shared so a scan survives switching tabs; the page merely observes it.
struct DiskMapView: View {
    @ObservedObject private var model = DiskMapModel.shared
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var fullDiskAccess: FullDiskAccessManager

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
                searchField
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
                DiskMapSliceTable(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                DiskMapDetailRail(model: model)
                    .frame(width: Self.railWidth)
            }
        }
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
