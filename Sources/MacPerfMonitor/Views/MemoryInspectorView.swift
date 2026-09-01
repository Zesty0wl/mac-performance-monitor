import AppKit
import MacPerfMonitorCore
import SwiftUI
import UniformTypeIdentifiers

/// The Memory Inspector window: an on-demand, deep look at one process's memory,
/// built for a developer or systems engineer chasing a leak or a bloated
/// footprint. It runs Apple's own `footprint`, `heap`, and `leaks` tools (in
/// app for the user's own processes, via the root helper for system /
/// other-user ones) and renders their output as a footprint-by-region
/// breakdown, a heap class census, a leak summary, and a baseline/compare
/// "leak hunt" that ranks the object classes growing fastest.
///
/// It observes only its own on-demand model and the helper manager — never the
/// live sample stream — so the window stays still between explicit runs rather
/// than re-rendering every tick.
struct MemoryInspectorView: View {
    let target: InspectorTarget

    @EnvironmentObject private var helper: HelperManager
    @StateObject private var inspector: MemoryInspectorModel
    @State private var mode: Mode = .snapshot
    @State private var exportError: String?

    enum Mode: String, CaseIterable, Identifiable {
        case snapshot = "Snapshot"
        case leakHunt = "Leak Hunt"
        var id: String { rawValue }
    }

    init(target: InspectorTarget) {
        self.target = target
        _inspector = StateObject(wrappedValue: MemoryInspectorModel(target: target))
    }

    private var capability: MemoryInspectorModel.Capability {
        inspector.capability(canEscalate: helper.canEscalate)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(minWidth: 580, minHeight: 460)
        .navigationTitle(t("Memory · %@", target.name))
        .onAppear {
            // Auto-run the first snapshot when the user opens the window: they
            // clicked "Inspect Memory" precisely to see this. Guarded so a
            // re-appear (tab switch, refocus) doesn't kick off a duplicate run.
            if capability != .needsCoverage, inspector.footprint == nil, inspector.heap == nil,
                !inspector.isLoadingSnapshot
            {
                inspector.loadSnapshot(helper: helper)
            }
        }
        .alert(
            "Couldn't save the report",
            isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "memorychip")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("PID \(target.pid) · UID \(target.uid)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            capabilityBadge
        }
        .padding(16)
    }

    @ViewBuilder private var capabilityBadge: some View {
        switch capability {
        case .ownProcess:
            badge("Your process", "checkmark.shield", .green)
        case .privileged:
            badge("Root helper", "lock.shield", .blue)
        case .needsCoverage:
            badge("Limited access", "exclamationmark.triangle", .orange)
        }
    }

    private func badge(_ text: LocalizedStringKey, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .snapshot: snapshotTab
        case .leakHunt: leakHuntTab
        }
    }

    // MARK: - Snapshot tab

    @ViewBuilder private var snapshotTab: some View {
        if capability == .needsCoverage {
            coverageUnavailable
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    snapshotToolbar
                    summaryRow
                    if let footprint = inspector.footprint {
                        footprintSection(footprint)
                    }
                    if let heap = inspector.heap {
                        heapSection(heap)
                    }
                    if let leaks = inspector.leaks {
                        leaksSection(leaks)
                    }
                    if let message = inspector.snapshotMessage {
                        InfoNote(text: message, kind: inspector.privilegeDenied ? .warning : .info)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var snapshotToolbar: some View {
        HStack(spacing: 10) {
            Button {
                inspector.loadSnapshot(helper: helper)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(inspector.isLoadingSnapshot)

            if inspector.isLoadingSnapshot {
                ProgressView()
                    .controlSize(.small)
                Text(t("Sampling %@…", target.name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let date = inspector.lastSnapshotDate {
                Text("Updated \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                exportSnapshot()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.down")
            }
            .disabled(!inspector.hasExportableSnapshot || inspector.isLoadingSnapshot)
            .help(t("Save a full memory dump of %@ to a file.", target.name))
        }
    }

    /// Save the captured snapshot as a text "dump". Defaults to the Desktop but
    /// lets the user pick any location, then reveals the file in Finder. The app
    /// is unsandboxed, so a chosen path is writable without extra entitlements.
    private func exportSnapshot() {
        guard let report = inspector.buildReport() else { return }
        let panel = NSSavePanel()
        panel.title = t("Export Memory Dump")
        panel.message = t("Save a full memory inspection report for %@.", target.name)
        panel.nameFieldStringValue = inspector.suggestedReportFileName()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        {
            panel.directoryURL = desktop
        }
        // The app is an accessory (LSUIElement); activate it so the panel comes
        // to the front instead of opening behind everything.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.utf8).write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = error.localizedDescription
        }
        FDWatchdog.check(after: "memory export")
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            SummaryCard(
                title: "Footprint",
                value: inspector.footprint.map { ByteFormat.string($0.totalBytes) } ?? "—",
                caption: "phys. memory")
            SummaryCard(
                title: "Heap",
                value: inspector.heap.map { ByteFormat.string($0.totalBytes) } ?? "—",
                caption: inspector.heap.map { "\($0.totalNodes.formatted()) nodes" } ?? "all zones")
            SummaryCard(
                title: "Leaks",
                value: leaksValue,
                caption: leaksCaption,
                emphasis: inspector.leaks?.significance == .notable ? .warning : .normal)
        }
    }

    private var leaksValue: String {
        guard let leaks = inspector.leaks else { return "—" }
        return leaks.leakCount.formatted()
    }

    private var leaksCaption: String {
        guard let leaks = inspector.leaks else { return "unreachable" }
        if leaks.leakCount == 0 { return "none found" }
        let bytes = ByteFormat.string(leaks.leakedBytes)
        // For a process we can't fully inspect, the count is a conservative-scan
        // estimate, not a confirmed leak — label it as such instead of "leaked".
        if !leaks.isDebuggable { return bytes + " · estimate" }
        return leaks.significance == .notable ? bytes + " leaked" : bytes + " · likely normal"
    }

    // MARK: footprint section

    private func footprintSection(_ snapshot: MemoryInspection.FootprintSnapshot) -> some View {
        let maxDirty = max(1, snapshot.regions.map(\.dirtyBytes).max() ?? 1)
        return SectionCard(
            title: "Footprint by region",
            subtitle: "Dirty memory per category — the biggest consumers of real RAM."
        ) {
            VStack(spacing: 8) {
                ForEach(snapshot.regions.prefix(12)) { region in
                    VStack(spacing: 3) {
                        HStack {
                            Text(region.category)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(ByteFormat.string(region.dirtyBytes))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ProportionBar(
                            fraction: Double(region.dirtyBytes) / Double(maxDirty))
                    }
                }
            }
        }
    }

    // MARK: heap section

    private func heapSection(_ snapshot: MemoryInspection.HeapSnapshot) -> some View {
        let shown = Array(snapshot.classes.prefix(120))
        return SectionCard(
            title: "Heap by class",
            subtitle: "Live object classes by total size — where the allocations actually are."
        ) {
            VStack(spacing: 0) {
                CensusHeaderRow()
                Divider().padding(.vertical, 2)
                ForEach(shown) { row in
                    CensusDataRow(row: row)
                }
                if snapshot.classes.count > shown.count {
                    Text("+ \((snapshot.classes.count - shown.count).formatted()) smaller classes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
        }
    }

    // MARK: leaks section

    private func leaksSection(_ leaks: MemoryInspection.LeaksSummary) -> some View {
        SectionCard(
            title: "Leaks",
            subtitle: "Allocations the process can no longer reach."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 24) {
                    LabeledStat(
                        label: "Leaked blocks", value: leaks.leakCount.formatted())
                    LabeledStat(
                        label: "Leaked bytes", value: ByteFormat.string(leaks.leakedBytes))
                    LabeledStat(
                        label: "Allocated", value: ByteFormat.string(leaks.totalBytes))
                }
                if leaks.leakCount == 0 {
                    InfoNote(text: "No leaks detected in this snapshot.", kind: .success)
                } else if !leaks.isDebuggable {
                    InfoNote(
                        text:
                            "\(target.name) is a hardened app (no get-task-allow), so leaks can only partially inspect it and falls back to a conservative scan that over-reports — most of these \(leaks.leakCount.formatted()) blocks are very likely not real leaks, and their allocation backtraces can't be shown. This is normal even for Apple's own apps. To find a genuine leak, use Leak Hunt: capture a baseline, exercise the app, and watch for object classes that keep growing.",
                        kind: .info)
                } else if leaks.significance == .notable {
                    InfoNote(
                        text:
                            "This build is fully debuggable and still shows a large amount of unreachable memory. Use Leak Hunt to capture a baseline, exercise the app, and see which object classes keep growing.",
                        kind: .warning)
                } else {
                    InfoNote(
                        text:
                            "A few small unreachable blocks like this are typically one-time allocations, not a leak. The real signal is sustained growth — use Leak Hunt to see whether a class keeps climbing over time.",
                        kind: .info)
                }
            }
        }
    }

    // MARK: - Leak hunt tab

    @ViewBuilder private var leakHuntTab: some View {
        if capability == .needsCoverage {
            coverageUnavailable
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InfoNote(
                        text:
                            "Capture a baseline heap, exercise the app to reproduce the suspected leak, then compare. Classes whose instance count keeps climbing while the workload is steady are the leak suspects.",
                        kind: .info)
                    leakHuntControls
                    if let date = inspector.baselineDate, let baseline = inspector.baseline {
                        baselineSummary(date: date, baseline: baseline)
                    }
                    if let message = inspector.leakHuntMessage {
                        InfoNote(text: message, kind: .info)
                    }
                    if let deltas = inspector.deltas, !deltas.isEmpty {
                        deltaSection(deltas)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var leakHuntControls: some View {
        HStack(spacing: 10) {
            Button {
                inspector.captureBaseline(helper: helper)
            } label: {
                Label(
                    inspector.baseline == nil
                        ? LocalizedStringKey("Capture Baseline")
                        : LocalizedStringKey("Re-capture Baseline"),
                    systemImage: "camera.viewfinder")
            }
            .disabled(inspector.isCapturingBaseline || inspector.isComparing)

            Button {
                inspector.compareNow(helper: helper)
            } label: {
                Label("Compare Now", systemImage: "arrow.left.arrow.right")
            }
            .disabled(
                inspector.baseline == nil || inspector.isComparing || inspector.isCapturingBaseline)

            if inspector.isCapturingBaseline || inspector.isComparing {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if inspector.baseline != nil {
                Button(role: .destructive) {
                    inspector.resetLeakHunt()
                } label: {
                    Label("Reset", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func baselineSummary(date: Date, baseline: MemoryInspection.HeapSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.checkered")
                .foregroundStyle(.secondary)
            Text(
                "Baseline at \(date.formatted(date: .omitted, time: .standard)) · \(baseline.totalNodes.formatted()) nodes · \(ByteFormat.string(baseline.totalBytes))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func deltaSection(_ deltas: [MemoryInspection.HeapClassDelta]) -> some View {
        let shown = Array(deltas.prefix(120))
        return SectionCard(
            title: "Growth since baseline",
            subtitle: "Classes that gained instances — ranked leak suspects, fastest-growing first."
        ) {
            VStack(spacing: 0) {
                DeltaHeaderRow()
                Divider().padding(.vertical, 2)
                ForEach(shown) { row in
                    DeltaDataRow(row: row)
                }
                if deltas.count > shown.count {
                    Text("+ \((deltas.count - shown.count).formatted()) more growing classes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
        }
    }

    // MARK: - Shared states

    private var coverageUnavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Limited access")
                .font(.title3.weight(.semibold))
            Text(
                t(
                    "%1$@ is owned by another user (UID %2$@), so its memory can't be read without elevated privileges. Enable Full Coverage in Settings to inspect system and other-user processes.",
                    target.name, String(target.uid))
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Presentational subviews

/// A small headline metric card used in the snapshot summary row.
private struct SummaryCard: View {
    enum Emphasis { case normal, warning }
    let title: String
    let value: String
    var caption: String? = nil
    var emphasis: Emphasis = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(emphasis == .warning ? Color.orange : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
    }
}

/// A titled, bordered container for a snapshot section.
private struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)))
    }
}

/// A thin proportion bar (no gradient, hairline track) for region sizes.
private struct ProportionBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// A label/value pair stacked vertically, for the leaks stat strip.
private struct LabeledStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
                .monospacedDigit()
        }
    }
}

/// Column header for the heap census list.
private struct CensusHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Class")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Count").frame(width: 72, alignment: .trailing)
            Text("Bytes").frame(width: 84, alignment: .trailing)
            Text("Type").frame(width: 56, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// One heap census row.
private struct CensusDataRow: View {
    let row: MemoryInspection.HeapClassCensus

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.className)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.binary.isEmpty {
                    Text(row.binary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.instanceCount.formatted())
                .frame(width: 72, alignment: .trailing)
                .monospacedDigit()
            Text(ByteFormat.string(row.totalBytes))
                .frame(width: 84, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(row.type.isEmpty ? "—" : row.type)
                .frame(width: 56, alignment: .leading)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 2)
    }
}

/// Column header for the leak-hunt growth list.
private struct DeltaHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Class")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Δ Count").frame(width: 72, alignment: .trailing)
            Text("Δ Bytes").frame(width: 88, alignment: .trailing)
            Text("Now").frame(width: 64, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// One leak-hunt growth row.
private struct DeltaDataRow: View {
    let row: MemoryInspection.HeapClassDelta

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.className)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.binary.isEmpty {
                    Text(row.binary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("+\(row.countDelta.formatted())")
                .frame(width: 72, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.orange)
            Text(signedBytes(row.bytesDelta))
                .frame(width: 88, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(row.bytesDelta >= 0 ? .orange : .secondary)
            Text(row.currentCount.formatted())
                .frame(width: 64, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 2)
    }

    private func signedBytes(_ delta: Int64) -> String {
        let magnitude = ByteFormat.string(UInt64(abs(delta)))
        return (delta >= 0 ? "+" : "−") + magnitude
    }
}

/// A small inline note with a leading icon, tinted by kind.
/// Takes a `String` rather than a `LocalizedStringKey` because two call sites pass
/// a message the model has already localised. `LocalizedStringKey(_:)` at the
/// render point looks up the literal call sites and passes an already-translated
/// message through untouched, since it simply misses the table.
private struct InfoNote: View {
    enum Kind { case info, success, warning }
    let text: String
    var kind: Kind = .info

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(LocalizedStringKey(text))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.10)))
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        }
    }
}
