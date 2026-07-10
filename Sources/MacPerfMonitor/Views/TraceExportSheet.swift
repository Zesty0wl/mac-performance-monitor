// SPDX-License-Identifier: MIT

import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The export configuration sheet for the Analytics tab: pick any running
/// processes, a timeframe, and a resolution, then write a compressed,
/// shareable `.mpmtrace` file. Presented from `PerformanceMonitorView`.
struct TraceExportSheet: View {
    @EnvironmentObject private var model: SamplerModel
    @Environment(\.dismiss) private var dismiss

    /// The window the chart is currently showing, offered as "Current view".
    let currentView: ClosedRange<Date>
    /// Processes to pre-tick (the ones already pinned on the chart), if any.
    let preselected: [ProcessIdentity]

    /// Running, readable processes snapshotted on appear so the list does not
    /// churn while the user is choosing.
    @State private var candidates: [ProcessSample] = []
    @State private var selected: Set<ProcessIdentity> = []
    @State private var search = ""
    @State private var timeframe: ExportTimeframe = .currentView
    @State private var resolution: ExportResolution = .full
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var exportOperation: TraceExportOperation?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            processList
            Divider()
            options
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
        .onAppear(perform: loadCandidates)
        .onDisappear { exportOperation?.cancel() }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Export process data")
                .font(.headline)
            Text(
                "Save one or more processes' recorded history to a compressed file you can share. The recipient can open it in \(AppInfo.displayName), even without those processes on their Mac."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: - Process list

    private var filteredCandidates: [ProcessSample] {
        guard !search.isEmpty else { return candidates }
        return candidates.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.name.localizedCaseInsensitiveContains(search)
                || "\($0.pid)".contains(search)
        }
    }

    private var processList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Processes")
                    .font(.subheadline.weight(.semibold))
                Text("\(selected.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select all") { selected = Set(candidates.map(\.id)) }
                    .controlSize(.small)
                    .disabled(candidates.isEmpty || selected.count == candidates.count)
                Button("Clear") { selected.removeAll() }
                    .controlSize(.small)
                    .disabled(selected.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter processes", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredCandidates) { process in
                        row(for: process)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(for process: ProcessSample) -> some View {
        let isOn = selected.contains(process.id)
        return Button {
            toggle(process.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))
                Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                    .resizable()
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(process.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("PID \(process.pid)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(ByteFormat.string(process.physFootprint))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isOn ? Color.accentColor.opacity(0.08) : .clear)
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Timeframe").font(.subheadline.weight(.semibold))
                Picker("Timeframe", selection: $timeframe) {
                    ForEach(ExportTimeframe.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Resolution").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(resolution.detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Picker("Resolution", selection: $resolution) {
                    ForEach(ExportResolution.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(estimateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    /// A rough "about N points per process" hint. The real file is produced from
    /// whatever history actually exists in the window.
    private var estimateText: String {
        let now = Date()
        let window = timeframe.window(now: now, currentView: currentView)
        let span = max(0, window.upperBound.timeIntervalSince(window.lowerBound))
        let perProcess = Int((span / max(resolution.nominalSeconds, 1)).rounded())
        let count = max(selected.count, 0)
        if count == 0 { return "Higher resolution means a larger file." }
        return
            "Up to about \(perProcess.formatted()) points per process \u{00B7} \(count) selected. Higher resolution means a larger file."
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if isExporting {
                ProgressView().controlSize(.small)
                Text("Preparing\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                exportOperation?.cancel()
                exportOperation = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Export\u{2026}") { performExport() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || isExporting)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func loadCandidates() {
        let readable = (model.latest?.processes ?? []).filter { $0.footprintReadable }
        candidates = readable.sorted { $0.physFootprint > $1.physFootprint }
        // Pre-tick the pinned processes that are still running.
        let running = Set(candidates.map(\.id))
        selected = Set(preselected).intersection(running)
    }

    private func toggle(_ id: ProcessIdentity) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func performExport() {
        // Keep the on-screen order (heaviest first) so series draw predictably.
        let ordered = candidates.map(\.id).filter { selected.contains($0) }
        guard !ordered.isEmpty else { return }
        let sampleByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        let window = timeframe.window(now: now, currentView: currentView)
        let res = resolution
        guard
            let destination = chooseDestination(
                for: ordered.compactMap { sampleByID[$0] }, exportedAt: now)
        else { return }

        exportOperation?.cancel()
        let operation = TraceExportOperation()
        exportOperation = operation
        isExporting = true
        model.loadProcessHistoriesForExport(
            ordered, granularity: res.granularity,
            from: window.lowerBound, to: window.upperBound,
            maximumPointCount: ProcessTraceCodec.maximumPointCount,
            isCancelled: { operation.isCancelled }
        ) { loadResult in
            guard exportOperation === operation, !operation.isCancelled else { return }
            let map: [ProcessIdentity: [ProcessHistoryPoint]]
            switch loadResult {
            case .success(let histories):
                map = histories
            case .failure(let error):
                exportOperation = nil
                isExporting = false
                errorMessage = error.localizedDescription
                return
            }
            TraceFileExporter.write(
                histories: map,
                orderedIdentities: ordered,
                samples: sampleByID,
                window: window,
                resolutionSeconds: res.nominalSeconds,
                exportedAt: now,
                destination: destination,
                operation: operation
            ) { result in
                guard exportOperation === operation else { return }
                exportOperation = nil
                isExporting = false
                switch result {
                case .success:
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    dismiss()
                case .failure(let error):
                    errorMessage =
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func chooseDestination(
        for processes: [ProcessSample], exportedAt: Date
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Process Data"
        panel.message = "Save a shareable Mac Performance Monitor trace."
        panel.nameFieldStringValue = suggestedFileName(for: processes, exportedAt: exportedAt)
        panel.allowedContentTypes = [TraceFileType.utType]
        panel.canCreateDirectories = true
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        {
            panel.directoryURL = desktop
        }
        // The app is an accessory (LSUIElement); activate it so the panel comes
        // to the front instead of opening behind everything.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func suggestedFileName(
        for processes: [ProcessSample], exportedAt: Date
    ) -> String {
        let stamp = Self.stampFormatter.string(from: exportedAt)
        let base: String
        if processes.count == 1, let only = processes.first {
            let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            let safe = only.displayName.components(separatedBy: illegal).joined(separator: "_")
                .trimmingCharacters(in: .whitespaces)
            base = safe.isEmpty ? "process" : safe
        } else {
            base = "\(processes.count)-processes"
        }
        return "performance-\(base)-\(stamp).\(ProcessTraceCodec.fileExtension)"
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
