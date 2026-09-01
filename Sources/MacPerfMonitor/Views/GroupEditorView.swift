import MacPerfMonitorCore
import SwiftUI

/// What the editor sheet is editing: a brand-new group, or an existing one.
struct GroupEditorTarget: Identifiable {
    let id: UUID
    var group: ProcessGroup
    var isNew: Bool

    static func new() -> GroupEditorTarget {
        let g = ProcessGroup(
            name: "New Group",
            rule: .any([.condition(GroupCondition(field: .bundleID))]))
        return GroupEditorTarget(id: g.id, group: g, isNew: true)
    }

    static func existing(_ g: ProcessGroup) -> GroupEditorTarget {
        GroupEditorTarget(id: g.id, group: g, isNew: false)
    }
}

/// A Team ID we can offer in the picker: the id plus a friendly label (vendor or
/// a representative app name).
struct TeamIDEntry: Identifiable, Hashable {
    let teamID: String
    let label: String
    var id: String { teamID }
}

/// Create or edit a group: name, icon, colour, and a nested boolean rule tree.
/// Conditions (a field + operator + value) are combined with ALL/ANY, negated
/// with NOT, and nested arbitrarily; a live panel shows exactly which running
/// processes the rule currently catches.
struct GroupEditorView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var groupStore: ProcessGroupStore
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var draft: ProcessGroup
    /// Team IDs recorded on this machine, each labelled by its signing org —
    /// loaded off the main thread from the store on appear.
    @State private var directory: [TeamIDEntry] = []
    /// False until the async directory load finishes, so a set Team ID shows no
    /// status line (rather than flashing "unrecognised") while resolving.
    @State private var directoryLoaded = false

    init(target: GroupEditorTarget) {
        self.isNew = target.isNew
        var g = target.group
        // The root is always a group node so the user can combine several
        // conditions; wrap a bare condition/NOT if an older group has one.
        switch g.rule {
        case .all, .any: break
        default: g.rule = .any([g.rule])
        }
        _draft = State(initialValue: g)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Group" : "Edit Group").font(.headline)
                Spacer()
            }
            .padding()
            Divider()

            // A draggable split: rules on top, the live matched-process list below.
            // Drag the divider to give either side more room; no dead gap.
            VSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identitySection
                        Divider()
                        rulesSection
                    }
                    .padding(18)
                }
                .frame(minHeight: 220)

                matchedPanel
                    .frame(minHeight: 140)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 820, height: 900)
        .onAppear {
            model.loadTeamIDDirectory {
                directory = $0
                directoryLoaded = true
            }
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        TextField("Group name", text: $draft.name)
            .textFieldStyle(.roundedBorder)
    }

    // MARK: - Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Membership").font(.caption).foregroundStyle(.secondary)
            RuleNodeEditor(
                node: $draft.rule, isRoot: true, teamIDs: directory,
                teamIDsLoaded: directoryLoaded, onDelete: nil)
        }
    }

    // MARK: - Live matched processes

    private var matchedPanel: some View {
        let matched = matchedProcesses
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(
                    systemName: draft.rule.hasCondition
                        ? "scope" : "exclamationmark.triangle"
                )
                .foregroundStyle(draft.rule.hasCondition ? Color.secondary : Color.orange)
                Text(
                    draft.rule.hasCondition
                        ? (matched.count == 1
                            ? t("Caught now: %@ process", String(matched.count))
                            : t("Caught now: %@ processes", String(matched.count)))
                        : t("No conditions yet — this group matches nothing")
                )
                .font(.subheadline.weight(.medium))
                Spacer()
            }

            if draft.rule.hasCondition {
                if matched.isEmpty {
                    Text("Nothing running matches this rule right now.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matched, id: \.id) { s in
                                HStack(spacing: 8) {
                                    Image(
                                        nsImage: ProcessIconProvider.shared.icon(
                                            forPath: s.executablePath)
                                    )
                                    .resizable().frame(width: 16, height: 16)
                                    Text(s.displayName).font(.callout).lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(matchLabel(for: s))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Distinct live processes the draft rule matches right now, heaviest first.
    private var matchedProcesses: [ProcessSample] {
        guard draft.rule.hasCondition else { return [] }
        let glossary = ProcessGlossaryStore.shared.glossary
        let live = (model.latest?.processes ?? []).filter {
            GroupMatcher.matches(.init(sample: $0), rule: draft.rule, glossary: glossary)
        }
        var seen = Set<String>()
        return live.sorted { $0.physFootprint > $1.physFootprint }
            .filter { seen.insert($0.displayName).inserted }
    }

    /// A short trailing label for a matched row — vendor if known, else Team ID.
    private func matchLabel(for s: ProcessSample) -> String {
        let glossary = ProcessGlossaryStore.shared.glossary
        if let vendor = glossary.lookup(name: s.name, bundleID: s.bundleID, path: s.executablePath)?
            .vendor
        {
            return vendor
        }
        return s.teamID ?? ""
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if isNew { groupStore.add(draft) } else { groupStore.update(draft) }
        dismiss()
    }
}

// MARK: - Recursive node editor

/// Edits one node of the boolean rule tree. A node is shown as either a single
/// condition row or a group (ALL/ANY) box that recurses into its children; a NOT
/// badge negates any node.
private struct RuleNodeEditor: View {
    @Binding var node: GroupRule
    let isRoot: Bool
    let teamIDs: [TeamIDEntry]
    let teamIDsLoaded: Bool
    let onDelete: (() -> Void)?

    @State private var showTeamPicker = false

    var body: some View {
        let negated = Self.isNegated(node)
        VStack(alignment: .leading, spacing: 6) {
            switch Self.inner(node) {
            case .condition:
                conditionRow(negated: negated)
            case .all, .any:
                groupBox(negated: negated)
            case .not:
                EmptyView()  // normalised away by `inner`
            }
        }
    }

    // MARK: Condition row

    private func conditionRow(negated: Bool) -> some View {
        HStack(spacing: 6) {
            notToggle(negated)

            Picker("", selection: conditionBinding.field) {
                ForEach(GroupCondition.Field.allCases, id: \.self) { f in
                    Text(t(Self.fieldLabel(f))).tag(f)
                }
            }
            .labelsHidden()
            .frame(width: 124)

            Picker("", selection: conditionBinding.op) {
                ForEach(
                    GroupCondition.operators(for: conditionBinding.field.wrappedValue), id: \.self
                ) { Text(t(Self.opLabel($0))).tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)

            valueField

            Spacer(minLength: 4)
            deleteButton
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var valueField: some View {
        switch conditionBinding.field.wrappedValue {
        case .classification:
            Picker("", selection: conditionBinding.value) {
                Text("choose…").tag("")
                ForEach(Self.knownCategories, id: \.self) { category in
                    Text(t(Self.classificationLabel(category))).tag(category)
                }
            }
            .labelsHidden()
            .frame(minWidth: 130)
        case .teamID:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    TextField("ABCDE12345", text: conditionBinding.value)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 110)
                    Button {
                        showTeamPicker = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .help("Pick a known Team ID by name")
                    .popover(isPresented: $showTeamPicker) {
                        TeamIDPicker(entries: teamIDs) { picked in
                            conditionBinding.value.wrappedValue = picked
                            showTeamPicker = false
                        }
                    }
                }
                // Resolve the entered Team ID to a friendly name. While the
                // directory is still loading, show nothing rather than flashing
                // "unrecognised"; once loaded, show the org name or "unrecognised".
                teamIDStatus(conditionBinding.value.wrappedValue)
            }
        default:
            TextField(
                Self.valuePlaceholder(conditionBinding.field.wrappedValue),
                text: conditionBinding.value
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 150)
        }
    }

    // MARK: Group box (ALL / ANY)

    private func groupBox(negated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                notToggle(negated)
                Picker("", selection: combinatorBinding) {
                    Text("ALL of").tag(Combinator.all)
                    Text("ANY of").tag(Combinator.any)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                Text("the following:").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !isRoot { deleteButton }
            }

            ForEach(childIndices, id: \.self) { i in
                RuleNodeEditor(
                    node: childBinding(i), isRoot: false, teamIDs: teamIDs,
                    teamIDsLoaded: teamIDsLoaded, onDelete: { removeChild(i) })
            }

            HStack(spacing: 10) {
                Button {
                    addChild(.condition(GroupCondition(field: .bundleID)))
                } label: {
                    Label("Condition", systemImage: "plus")
                }
                Button {
                    addChild(.any([.condition(GroupCondition(field: .bundleID))]))
                } label: {
                    Label("Group", systemImage: "plus.square.on.square")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func notToggle(_ negated: Bool) -> some View {
        Button {
            node = Self.setNegated(node, !negated)
        } label: {
            Text("NOT")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(
                    negated ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .foregroundStyle(negated ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(Self.isGroup(node) ? "Negate this group" : "Negate this condition")
    }

    @ViewBuilder
    private var deleteButton: some View {
        if let onDelete {
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Bindings into the enum

    private enum Combinator { case all, any }

    private var combinatorBinding: Binding<Combinator> {
        Binding(
            get: { if case .all = Self.inner(node) { return .all } else { return .any } },
            set: { newValue in
                let kids = Self.children(Self.inner(node))
                let core: GroupRule = newValue == .all ? .all(kids) : .any(kids)
                node = Self.isNegated(node) ? .not(core) : core
            })
    }

    /// A binding to the underlying `GroupCondition`, preserving any NOT wrapper.
    private var conditionBinding: Binding<GroupCondition> {
        Binding(
            get: {
                if case .condition(let c) = Self.inner(node) { return c }
                return GroupCondition(field: .bundleID)
            },
            set: { newCond in
                let core = GroupRule.condition(newCond)
                node = Self.isNegated(node) ? .not(core) : core
            })
    }

    private var childIndices: Range<Int> { Self.children(Self.inner(node)).indices }

    private func childBinding(_ index: Int) -> Binding<GroupRule> {
        Binding(
            get: {
                let kids = Self.children(Self.inner(node))
                return index < kids.count ? kids[index] : .any([])
            },
            set: { newChild in
                var kids = Self.children(Self.inner(node))
                guard index < kids.count else { return }
                kids[index] = newChild
                setChildren(kids)
            })
    }

    private func addChild(_ child: GroupRule) {
        var kids = Self.children(Self.inner(node))
        kids.append(child)
        setChildren(kids)
    }

    private func removeChild(_ index: Int) {
        var kids = Self.children(Self.inner(node))
        guard index < kids.count else { return }
        kids.remove(at: index)
        setChildren(kids)
    }

    private func setChildren(_ kids: [GroupRule]) {
        let isAll: Bool = {
            if case .all = Self.inner(node) { return true } else { return false }
        }()
        let core: GroupRule = isAll ? .all(kids) : .any(kids)
        node = Self.isNegated(node) ? .not(core) : core
    }

    // MARK: Team ID lookup

    private func knownTeamID(_ value: String) -> TeamIDEntry? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        return teamIDs.first { $0.teamID.caseInsensitiveCompare(v) == .orderedSame }
    }

    /// The status line under a Team ID field: guidance when empty, **nothing while
    /// the directory is still loading** (so a set Team ID doesn't flash
    /// "unrecognised"), then the signing org name or "unrecognised".
    @ViewBuilder
    private func teamIDStatus(_ rawValue: String) -> some View {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            statusLabel(t("Enter or pick a Team ID"), icon: "questionmark.circle")
        } else if !teamIDsLoaded {
            EmptyView()
        } else if let entry = knownTeamID(value) {
            statusLabel(entry.label, icon: "checkmark.seal")
        } else {
            statusLabel(t("Unrecognised Team ID"), icon: "questionmark.circle")
        }
    }

    private func statusLabel(_ text: String, icon: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: Enum helpers

    static func isNegated(_ r: GroupRule) -> Bool {
        if case .not = r { return true }
        return false
    }

    static func inner(_ r: GroupRule) -> GroupRule {
        if case .not(let child) = r { return child }
        return r
    }

    static func setNegated(_ r: GroupRule, _ negated: Bool) -> GroupRule {
        let base = inner(r)
        return negated ? .not(base) : base
    }

    static func isGroup(_ r: GroupRule) -> Bool {
        switch inner(r) {
        case .all, .any: return true
        default: return false
        }
    }

    static func children(_ r: GroupRule) -> [GroupRule] {
        switch r {
        case .all(let c), .any(let c): return c
        default: return []
        }
    }

    // MARK: Labels

    static let knownCategories = ["security", "developer", "system", "background", "app", "helper"]

    static func fieldLabel(_ f: GroupCondition.Field) -> String {
        switch f {
        case .bundleID: return "Bundle ID"
        case .name: return "Process name"
        case .path: return "Path"
        case .teamID: return "Team ID"
        case .classification: return "Classification"
        case .vendor: return "Vendor"
        }
    }

    static func opLabel(_ o: GroupCondition.Op) -> String {
        switch o {
        case .equals: return "is"
        case .contains: return "contains"
        case .startsWith: return "starts with"
        }
    }

    /// The picker's display text for a raw classification value. The raw value
    /// itself (`cat`) stays untranslated: it is a data value matched against
    /// glossary-derived classifications elsewhere, not just a label.
    static func classificationLabel(_ raw: String) -> String {
        switch raw {
        case "security": return "Security"
        case "developer": return "Developer"
        case "system": return "System"
        case "background": return "Background"
        case "app": return "App"
        case "helper": return "Helper"
        default: return raw
        }
    }

    static func valuePlaceholder(_ f: GroupCondition.Field) -> String {
        switch f {
        case .bundleID: return "com.vendor.app"
        case .name: return t("process name")
        case .path: return "/Library/…"
        case .teamID: return "ABCDE12345"
        case .vendor: return "Microsoft"
        case .classification: return "security"
        }
    }
}

// MARK: - Team ID picker

/// A searchable popover of known Team IDs (by vendor/app name), for filling a
/// Team ID condition without typing the raw identifier.
private struct TeamIDPicker: View {
    let entries: [TeamIDEntry]
    let onPick: (String) -> Void

    @State private var search = ""

    private var filtered: [TeamIDEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.label.localizedCaseInsensitiveContains(search)
                || $0.teamID.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search vendor or Team ID", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filtered.isEmpty {
                        Text("No known Team IDs match.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding()
                    }
                    ForEach(filtered) { e in
                        Button {
                            onPick(e.teamID)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.label).font(.callout).lineLimit(1)
                                    Text(e.teamID).font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .frame(width: 300, height: 360)
    }
}
