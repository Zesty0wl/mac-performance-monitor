import MacPerfMonitorCore
import SwiftUI

/// The Groups tab: each enabled process group as a card showing its blended
/// footprint score (% of device capacity), a score sparkline over the selected
/// window, its member count, and top contributors. Tapping a card opens the
/// detail view; disabled presets and a "New group" button live below.
struct GroupsView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var groupStore: ProcessGroupStore
    @EnvironmentObject private var appState: AppState

    @State private var window: HistoryWindow = .oneHour
    @State private var reports: [ProcessGroup.ID: GroupReport] = [:]
    @State private var loading = false
    @State private var editorTarget: GroupEditorTarget?
    @State private var showScoreInfo = false

    private var enabled: [ProcessGroup] { groupStore.enabledGroups }
    private var disabled: [ProcessGroup] { groupStore.groups.filter { !$0.isEnabled } }

    /// Changes whenever a group is added/removed, toggled, or its rules edited —
    /// the trigger to recompute the cards.
    private var reloadSignature: [String] {
        groupStore.groups.map { "\($0.id.uuidString)|\($0.isEnabled)|\($0.rule.hashValue)" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if !model.hasHistory {
                        unavailableNote
                    }

                    if enabled.isEmpty {
                        emptyState
                    } else {
                        ForEach(enabled) { group in
                            NavigationLink(value: group.id) {
                                GroupCard(group: group, report: reports[group.id], loading: loading)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: group) }
                        }
                    }

                    if !disabled.isEmpty {
                        disabledSection
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationDestination(for: ProcessGroup.ID.self) { id in
                if let group = groupStore.group(id: id) {
                    GroupDetailView(group: group)
                }
            }
        }
        .onAppear(perform: reloadAll)
        .onChange(of: window) { reloadAll() }
        .onChange(of: reloadSignature) { reloadAll() }
        .onChange(of: model.displayProcessesVersion) {
            if appState.mainWindowVisible { reloadAll() }
        }
        .sheet(item: $editorTarget) { target in
            GroupEditorView(target: target)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Groups").font(.title2.weight(.semibold))
                    Button {
                        showScoreInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("How the footprint score works")
                    .popover(isPresented: $showScoreInfo) { GroupScoreInfoView() }
                }
                Text(
                    "How much of this device each stack uses — e.g. your security/IT tools — to inform laptop sizing."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Picker("Window", selection: $window) {
                ForEach(HistoryWindow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .historyRangeGate()

            Button {
                editorTarget = .new()
            } label: {
                Label("New Group", systemImage: "plus")
            }
        }
    }

    private var unavailableNote: some View {
        Label(
            "History store unavailable — group scores need logged history.",
            systemImage: "externaldrive.badge.xmark"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No groups yet",
            systemImage: "square.stack.3d.up",
            description: Text(
                "Create a group with the \u{201C}New Group\u{201D} button, or from a process's right-click menu in the Processes list."
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var disabledSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Disabled").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(disabled) { group in
                HStack(spacing: 10) {
                    Text(group.name).foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable") { groupStore.setEnabled(group.id, true) }
                    Button(role: .destructive) {
                        groupStore.delete(id: group.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func menu(for group: ProcessGroup) -> some View {
        Button("Edit\u{2026}") { editorTarget = .existing(group) }
        Button("Disable") { groupStore.setEnabled(group.id, false) }
        Divider()
        Button("Delete", role: .destructive) { groupStore.delete(id: group.id) }
    }

    // MARK: - Loading

    private func reloadAll() {
        let groups = enabled
        guard !groups.isEmpty else {
            reports = [:]
            return
        }
        loading = true
        let glossary = ProcessGlossaryStore.shared.glossary
        let group = DispatchGroup()
        var collected: [ProcessGroup.ID: GroupReport] = [:]
        for g in groups {
            group.enter()
            model.loadGroupReport(group: g, window: window, glossary: glossary) { report in
                collected[g.id] = report
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.reports = collected
            self.loading = false
        }
    }
}

// MARK: - Card

private struct GroupCard: View {
    let group: ProcessGroup
    let report: GroupReport?
    let loading: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            if let values = sparkValues, values.count >= 2 {
                Sparkline(values: values)
                    .tint(.accentColor)
                    .frame(width: 96, height: 28)
            }

            if report == nil && loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 96, alignment: .trailing)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(scoreText)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(report == nil ? .secondary : .primary)
                    Text("of device")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 96, alignment: .trailing)
            }

            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var scoreText: String {
        guard let report else { return loading ? "…" : "—" }
        return String(format: "%.1f%%", report.score)
    }

    /// Members are merged one row per program (restarts and an app's concurrent
    /// helper instances count once), so the card counts programs and names the
    /// biggest contributors rather than whichever PIDs happened to sort first.
    private var subtitle: String {
        guard let report, !report.members.isEmpty else {
            return loading ? t("Loading…") : t("No processes recorded in this window.")
        }
        let names = report.topMembers(3).map(\.displayName).joined(separator: ", ")
        let count = report.memberCount
        return count == 1
            ? t("%1$@ program · %2$@", String(count), names)
            : t("%1$@ programs · %2$@", String(count), names)
    }

    private var sparkValues: [Double]? {
        guard let report else { return nil }
        let pts = report.scorePoints().map { $0.value }
        return pts.count >= 2 ? pts : nil
    }
}
