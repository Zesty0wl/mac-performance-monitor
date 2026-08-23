import AppKit
import MacPerfMonitorCore
import SwiftUI

/// A live, sortable, filterable table of every visible process. Row identity is
/// the stable `ProcessIdentity` (pid + start time), so rows keep their place and
/// selection across re-sorts and live updates rather than flickering.
///
/// This view owns the data and the table's state (search, sort, hierarchy) and
/// prepares the sorted/filtered `rows` once per real change. The table itself is
/// the separate, `Equatable` `ProcessTable` child: the enclosing views re-render
/// once a second to keep the live system header moving, and isolating the table
/// behind `Equatable` stops SwiftUI re-laying-out its ~600 rows on every one of
/// those ticks — it re-renders only when the rows, selection, or row styling
/// actually change. (Re-laying-out the whole table every second was the
/// dominant CPU cost on this tab.)
struct ProcessListView: View {
    let processes: [ProcessSample]
    @Binding var selection: ProcessIdentity?

    @EnvironmentObject private var model: SamplerModel
    @State private var sortOrder = [
        KeyPathComparator(\ProcessNode.process.physFootprint, order: .reverse)
    ]
    @State private var search = ""

    /// When on, processes are shown as a tree keyed on parent PID (which process
    /// launched which) instead of one flat sorted list. Persisted so the choice
    /// survives relaunches.
    @AppStorage("processShowHierarchy") private var showHierarchy = false

    /// `launchd`, the ancestor of nearly every process. Hidden as a node in the
    /// hierarchy view since its parentage is implied.
    private static let launchdPID: Int32 = 1

    /// Multi-row selection backing the table. A `Set` makes the table support
    /// cmd-click (toggle one) and shift-click (extend a range) natively. The
    /// parent's single `selection`, which drives the detail inspector, is kept in
    /// sync inside `ProcessTable`.
    @State private var multiSelection: Set<ProcessIdentity> = []

    /// The prepared rows the table draws, memoized in `@State`. Rebuilt by
    /// `rebuildRows()` only when an input that affects them changes (the data
    /// version, sort order, search text, or hierarchy toggle) — never on the 1 s
    /// `latest` republish — so the O(n log n) filter+sort over ~600 processes does
    /// not run on every render.
    @State private var rows: [ProcessNode] = []

    /// Bumped each time `rows` is rebuilt. Passed to `ProcessTable` as its
    /// `revision` so its `Equatable` conformance can detect a real row change
    /// without comparing the (non-`Equatable`) `rows` array element by element.
    @State private var rowsRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            ProcessTable(
                rows: rows,
                revision: rowsRevision,
                showHierarchy: showHierarchy,
                leakingIDs: model.leakingProcessIDs,
                terminatedIDs: model.terminatedProcessIDs,
                selection: $selection,
                multiSelection: $multiSelection,
                sortOrder: $sortOrder,
                model: model
            )
            .equatable()
            // Rebuild the rows only when something that affects them changes. The
            // data version covers the heavy-tick refresh and kills; the rest are
            // user actions. The 1 s header tick touches none of these.
            .onChange(of: model.displayProcessesVersion, initial: true) { _, _ in rebuildRows() }
            .onChange(of: sortOrder) { _, _ in rebuildRows() }
            .onChange(of: search) { _, _ in rebuildRows() }
            .onChange(of: showHierarchy) { _, _ in rebuildRows() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by name", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
            Divider()
                .frame(height: 16)
            Toggle(isOn: $showHierarchy) {
                Label("Hierarchy", systemImage: "list.bullet.indent")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Group processes by which launched which.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The visible processes after the search filter, before sorting or nesting.
    private var filteredSamples: [ProcessSample] {
        search.isEmpty
            ? processes
            : processes.filter {
                $0.displayName.localizedCaseInsensitiveContains(search)
                    || $0.name.localizedCaseInsensitiveContains(search)
            }
    }

    /// Recompute the table's rows from the current inputs and bump the revision.
    /// Flat mode is a single sorted level; hierarchy mode nests each process under
    /// the visible process that launched it, with every level sorted by the active
    /// column.
    private func rebuildRows() {
        let compare = Self.comparison(for: sortOrder)
        if showHierarchy {
            rows = buildForest(from: filteredSamples, compare: compare)
        } else {
            rows = Self.sortedNodes(filteredSamples, compare: compare)
        }
        rowsRevision &+= 1
    }

    /// Sort with direct property access. `sorted(using:)` over the table's
    /// `KeyPathComparator`s applied each key path dynamically on every one of
    /// the ~5,000 comparisons a 600-row sort makes, about 5 ms per second at
    /// the table cadence. Each comparator is matched to its column once, and
    /// an index permutation is sorted so the 200-byte samples are not shuffled.
    /// Flat rows sorted by `comparators`, for any table of process samples
    /// (the GPU tab reuses it).
    static func sortedNodes(
        _ samples: [ProcessSample], comparators: [KeyPathComparator<ProcessNode>]
    ) -> [ProcessNode] {
        sortedNodes(samples, compare: comparison(for: comparators))
    }

    private static func sortedNodes(
        _ samples: [ProcessSample], compare: @escaping (ProcessSample, ProcessSample) -> Bool
    ) -> [ProcessNode] {
        let order = samples.indices.sorted { compare(samples[$0], samples[$1]) }
        return order.map { ProcessNode(process: samples[$0], children: nil) }
    }

    /// A strict "comes before" for the table's comparators, composed in order.
    /// Strings use the same localized standard comparison the comparators do.
    private static func comparison(
        for comparators: [KeyPathComparator<ProcessNode>]
    ) -> (ProcessSample, ProcessSample) -> Bool {
        typealias Step = (ProcessSample, ProcessSample) -> ComparisonResult
        let steps: [Step] = comparators.map { comparator -> Step in
            let ascending = comparator.order == .forward
            func ordered<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
                if a == b { return .orderedSame }
                return (a < b) == ascending ? .orderedAscending : .orderedDescending
            }
            func text(_ a: String, _ b: String) -> ComparisonResult {
                let result = a.localizedStandardCompare(b)
                if ascending || result == .orderedSame { return result }
                return result == .orderedAscending ? .orderedDescending : .orderedAscending
            }
            let keyPath = comparator.keyPath
            if keyPath == \ProcessNode.process.displayName {
                return { text($0.displayName, $1.displayName) }
            }
            if keyPath == \ProcessNode.process.physFootprint {
                return { ordered($0.physFootprint, $1.physFootprint) }
            }
            if keyPath == \ProcessNode.process.cpuPercent {
                return { ordered($0.cpuPercent, $1.cpuPercent) }
            }
            if keyPath == \ProcessNode.process.threadCount {
                return { ordered($0.threadCount, $1.threadCount) }
            }
            if keyPath == \ProcessNode.process.fdTotal {
                return { ordered($0.fdTotal, $1.fdTotal) }
            }
            if keyPath == \ProcessNode.process.architecture.label {
                return { text($0.architecture.label, $1.architecture.label) }
            }
            if keyPath == \ProcessNode.process.pid {
                return { ordered($0.pid, $1.pid) }
            }
            if keyPath == \ProcessNode.process.gpuPercentValue {
                return { ordered($0.gpuPercentValue, $1.gpuPercentValue) }
            }
            if keyPath == \ProcessNode.process.gpuIdleSeconds {
                return { ordered($0.gpuIdleSeconds, $1.gpuIdleSeconds) }
            }
            // A column this list does not know: let the comparator do it.
            return {
                comparator.compare(
                    ProcessNode(process: $0, children: nil), ProcessNode(process: $1, children: nil)
                )
            }
        }
        return { a, b in
            for step in steps {
                let result = step(a, b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return false
        }
    }

    /// Build a parent/child forest from the visible processes, nesting each one
    /// under the visible process whose PID matches its parent PID. Processes
    /// whose parent is not in the visible set become roots, and every level is
    /// sorted by the active sort order. A visited set plus a final sweep for any
    /// unvisited process keep the build safe against PID reuse or cycles, so no
    /// process is ever dropped or shown twice.
    ///
    /// `launchd` (PID 1) is dropped from the tree: it is the ancestor of almost
    /// everything, so showing it adds a layer of indentation with no information.
    /// Removing it promotes its direct children to top-level roots.
    private func buildForest(
        from samples: [ProcessSample], compare: @escaping (ProcessSample, ProcessSample) -> Bool
    ) -> [ProcessNode] {
        func sortNodes(_ nodes: [ProcessNode]) -> [ProcessNode] {
            nodes.sorted { compare($0.process, $1.process) }
        }
        let samples = samples.filter { $0.pid != Self.launchdPID }
        let byPID = Dictionary(
            samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenByPPID: [Int32: [ProcessSample]] = [:]
        var childPIDs: Set<Int32> = []
        for sample in samples where sample.ppid != sample.pid && byPID[sample.ppid] != nil {
            childrenByPPID[sample.ppid, default: []].append(sample)
            childPIDs.insert(sample.pid)
        }

        var visited: Set<Int32> = []
        func makeNode(_ sample: ProcessSample) -> ProcessNode {
            visited.insert(sample.pid)
            let kids = sortNodes(
                (childrenByPPID[sample.pid] ?? [])
                    .filter { !visited.contains($0.pid) }
                    .map(makeNode))
            return ProcessNode(process: sample, children: kids.isEmpty ? nil : kids)
        }

        var forest = sortNodes(
            samples
                .filter { !childPIDs.contains($0.pid) }
                .map(makeNode))

        // Anything left unvisited (only possible under a PID cycle) is surfaced
        // as a root so a process is never silently dropped.
        let orphans = samples.filter { !visited.contains($0.pid) }
        if !orphans.isEmpty {
            forest += sortNodes(orphans.map { ProcessNode(process: $0, children: nil) })
        }
        return forest
    }
}

/// The process table proper, isolated behind `Equatable` so SwiftUI re-evaluates
/// and re-lays-out its rows only when the data, selection, or row styling
/// actually change — not on the once-a-second re-render that the live system
/// header forces on the enclosing views. `model` is held as a plain (unobserved)
/// reference: it is used only for on-demand row actions, so it never drives a
/// render. All render-affecting inputs are compared in `==`.
private struct ProcessTable: View, Equatable {
    let rows: [ProcessNode]
    /// Stands in for comparing the non-`Equatable` `rows` array; bumped whenever
    /// the parent rebuilds the rows.
    let revision: Int
    let showHierarchy: Bool
    let leakingIDs: Set<ProcessIdentity>
    let terminatedIDs: Set<ProcessIdentity>
    @Binding var selection: ProcessIdentity?
    @Binding var multiSelection: Set<ProcessIdentity>
    @Binding var sortOrder: [KeyPathComparator<ProcessNode>]
    let model: SamplerModel

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var monitor: MonitorSelection
    @EnvironmentObject private var groupStore: ProcessGroupStore
    @Environment(\.openWindow) private var openWindow

    /// Re-render only on a genuine change. Bindings, closures, and the unobserved
    /// `model` are deliberately excluded; everything that affects what the table
    /// draws is a value compared here. `revision` proxies for the row contents.
    static func == (lhs: ProcessTable, rhs: ProcessTable) -> Bool {
        lhs.revision == rhs.revision
            && lhs.showHierarchy == rhs.showHierarchy
            && lhs.selection == rhs.selection
            && lhs.multiSelection == rhs.multiSelection
            && lhs.leakingIDs == rhs.leakingIDs
            && lhs.terminatedIDs == rhs.terminatedIDs
    }

    var body: some View {
        ProcessOutlineTable(
            rows: rows,
            revision: revision,
            showHierarchy: showHierarchy,
            leakingIDs: leakingIDs,
            terminatedIDs: terminatedIDs,
            selection: $multiSelection,
            sortOrder: $sortOrder,
            menu: { ids in contextMenu(for: ids) },
            values: model.processValuesTick.eraseToAnyPublisher(),
            onVisibleRowsChange: { pids in model.setVisibleProcesses(pids) }
        )
        .onChange(of: multiSelection) { _, ids in
            // Drive the single-row inspector from the table selection. An
            // EMPTY set is deliberately ignored: in hierarchy mode the Table
            // cannot materialise a row nested under a collapsed parent, so
            // when an external selection (a notification or a click from
            // another view) sets `selection` and we mirror it into
            // `multiSelection` below, the Table rejects it and writes the set
            // back to empty. Clearing `selection` on that echo snapped the
            // inspector straight shut, so a navigation target "didn't
            // select". Leaving `selection` untouched on empty keeps the
            // target open; a multi-row selection still clears the single-row
            // inspector for the batch action.
            if ids.count == 1 {
                selection = ids.first
            } else if ids.count > 1 {
                selection = nil
            }
        }
        .onChange(of: selection) { _, newValue in
            // Reflect an external selection (the auto-selected top row, or a
            // notification's navigation target) back into the table highlight.
            if let id = newValue, multiSelection != [id] {
                multiSelection = [id]
            }
        }
        .onAppear {
            if let id = selection { multiSelection = [id] }
        }
    }

    /// The right-click menu for `ids`: the batch menu for several rows, the
    /// full process action menu for one. Mirrors `ProcessActionMenu` item for
    /// item, built as an `NSMenu` because the table is AppKit-hosted.
    private func contextMenu(for ids: Set<ProcessIdentity>) -> NSMenu? {
        let menu = NSMenu()
        if ids.count > 1 {
            let addable = addableCount(ids)
            menu.addItem(
                ClosureMenuItem(
                    addable > 0
                        ? "Add \(addable) \(addable == 1 ? "Process" : "Processes") to Analytics"
                        : "Analytics Full",
                    symbol: "chart.xyaxis.line", enabled: addable > 0
                ) { addSelectionToMonitor(ids) })
            return menu
        }
        guard let id = ids.first else { return nil }
        let live = model.currentSample(for: id)
        let path = live?.executablePath.flatMap { $0.isEmpty ? nil : $0 }

        menu.addItem(
            ClosureMenuItem("Codesign\u{2026}", symbol: "checkmark.seal", enabled: path != nil) {
                if let live = model.currentSample(for: id) {
                    ProcessRowIntent.showCodesign(
                        sample: live, appState: appState, bringWindowForward: false)
                }
            })
        menu.addItem(
            ClosureMenuItem("Reveal in Finder", symbol: "folder", enabled: path != nil) {
                _ = ProcessActions.revealInFinder(path: path)
            })
        if let inspect = inspectAction(for: id) {
            menu.addItem(
                ClosureMenuItem("Inspect Memory\u{2026}", symbol: "scope", handler: inspect))
        }
        if let openFiles = openFilesAction(for: id) {
            menu.addItem(
                ClosureMenuItem(
                    "Open Files & Sockets\u{2026}", symbol: "doc.on.doc", handler: openFiles))
        }
        if let deepDive = deepDiveAction(for: id) {
            menu.addItem(
                ClosureMenuItem("Deep Dive\u{2026}", symbol: "stethoscope", handler: deepDive))
        }
        let isMonitored = monitor.contains(id)
        menu.addItem(
            ClosureMenuItem(
                isMonitored ? "In Analytics" : "Add to Analytics", symbol: "chart.xyaxis.line",
                enabled: !isMonitored && !monitor.isFull
            ) { monitor.add(id) })

        let groupItem = NSMenuItem(title: "Add to Group", action: nil, keyEquivalent: "")
        groupItem.image = NSImage(
            systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        let groupMenu = NSMenu()
        for group in groupStore.addTargets {
            groupMenu.addItem(
                ClosureMenuItem(group.name) {
                    if let s = model.currentSample(for: id) {
                        groupStore.addRule(Self.groupRule(for: s), toGroup: group.id)
                    }
                })
        }
        if !groupStore.addTargets.isEmpty { groupMenu.addItem(.separator()) }
        groupMenu.addItem(
            ClosureMenuItem("New Group from This\u{2026}") {
                if let s = model.currentSample(for: id) {
                    groupStore.add(
                        ProcessGroup(name: s.displayName, rule: .any([Self.groupRule(for: s)])))
                }
            })
        groupItem.submenu = groupMenu
        menu.addItem(groupItem)

        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem("Force Quit (kill -9)", symbol: "xmark.octagon", enabled: live != nil) {
                appState.pendingForceQuit = id
            })
        return menu
    }

    /// The most durable membership rule for a process: prefer its code-signing
    /// Team ID, then bundle id, then executable path, then name.
    static func groupRule(for s: ProcessSample) -> GroupRule {
        GroupMatcher.condition(for: GroupMatcher.Candidate(sample: s))
    }

    /// How many of the selected processes can still be pinned: those not already
    /// monitored, capped by the Monitor's remaining slots.
    private func addableCount(_ ids: Set<ProcessIdentity>) -> Int {
        let notMonitored = ids.filter { !monitor.contains($0) }.count
        let room = monitor.capacity - monitor.identities.count
        return max(0, min(notMonitored, room))
    }

    /// Build the Inspect Memory action for a row, seeding a self-contained
    /// `InspectorTarget` (pid, start time, name, uid) from the *live* sample so
    /// the inspector window never has to subscribe to the sample stream. Returns
    /// nil when the row has no live sample (a just-exited process), which omits
    /// the menu item rather than opening an inspector on a dead pid.
    private func inspectAction(for id: ProcessIdentity) -> (() -> Void)? {
        guard let sample = model.currentSample(for: id) else { return nil }
        let target = InspectorTarget(
            pid: sample.pid,
            startTime: sample.startTime,
            name: sample.displayName,
            uid: UInt32(sample.uid)
        )
        return {
            openWindow(value: target)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Build the Open Files & Sockets action for a row, seeding a self-contained
    /// `OpenFilesTarget` from the *live* sample so the window never subscribes to
    /// the sample stream. Returns nil when the row has no live sample (a
    /// just-exited process), which omits the menu item rather than opening a
    /// window on a dead pid.
    private func openFilesAction(for id: ProcessIdentity) -> (() -> Void)? {
        guard let sample = model.currentSample(for: id) else { return nil }
        let target = OpenFilesTarget(
            pid: sample.pid,
            startTime: sample.startTime,
            name: sample.displayName,
            uid: UInt32(sample.uid)
        )
        return {
            openWindow(value: target)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Build the AI Deep Dive action for a row, seeding a self-contained
    /// `DeepDiveTarget` from the *live* sample. Returns nil for a just-exited
    /// process (no live sample), which omits the menu item rather than profiling a
    /// dead pid.
    private func deepDiveAction(for id: ProcessIdentity) -> (() -> Void)? {
        guard let sample = model.currentSample(for: id) else { return nil }
        let model = self.model
        let openWindow = self.openWindow
        return {
            // Uptime distinguishes a young process warming up from an old one still
            // growing (the leak check uses it).
            let uptimeMinutes = max(0, Date().timeIntervalSince(sample.startTime) / 60)
            // Pull the persisted DB history (a long window) so the trends/leak check
            // see real long-run behaviour, not just the short in-memory trail.
            model.loadProcessHistory(id, window: .sixHours) { history in
                let points = history.count >= 2 ? history : model.trailSamples(for: id)
                let span: Int = {
                    guard let first = points.first?.date, let last = points.last?.date, last > first
                    else { return 0 }
                    return max(1, Int(last.timeIntervalSince(first) / 60))
                }()
                let target = DeepDiveTarget(
                    pid: sample.pid,
                    startTime: sample.startTime,
                    name: sample.displayName,
                    uid: UInt32(sample.uid),
                    arch: sample.architecture.label,
                    isTranslated: sample.isTranslated,
                    cpuPercent: sample.cpuPercent,
                    footprintBytes: sample.physFootprint,
                    peakFootprintBytes: sample.lifetimeMaxFootprint,
                    threadCount: Int(sample.threadCount),
                    systemRAMBytes: ProcessInfo.processInfo.physicalMemory,
                    uptimeMinutes: uptimeMinutes,
                    cpuTrail: points.map(\.cpuPercent),
                    memoryTrail: points.map { Double($0.footprint) },
                    diskReadTrail: points.map { Double($0.diskRead) },
                    diskWriteTrail: points.map { Double($0.diskWritten) },
                    fdTrail: points.map { Double($0.fdTotal) },
                    spanMinutes: span
                )
                openWindow(value: target)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Pin the selected processes to the Monitor in their current sorted order,
    /// stopping once the Monitor is full.
    private func addSelectionToMonitor(_ ids: Set<ProcessIdentity>) {
        for process in flatten(rows) where ids.contains(process.id) {
            if monitor.isFull { break }
            monitor.add(process.id)
        }
    }

    /// Flatten a forest into depth-first display order.
    private func flatten(_ nodes: [ProcessNode]) -> [ProcessSample] {
        nodes.flatMap { [$0.process] + flatten($0.children ?? []) }
    }

    /// Whether any process nested beneath `node` is a suspected leak. Used to
    /// surface the leak warning on a parent row so a leaking child hidden under a
    /// collapsed parent is still visible at the top level (the hierarchical table
    /// gives no expansion state, so the parent keeps the hint even once expanded,
    /// where the child shows its own).
    private func hasLeakingDescendant(_ node: ProcessNode) -> Bool {
        guard let children = node.children else { return false }
        for child in children {
            if leakingIDs.contains(child.process.id) { return true }
            if hasLeakingDescendant(child) { return true }
        }
        return false
    }

    /// Whether a row is a recently force-quit process, kept greyed out as
    /// confirmation that the kill took effect (see `SamplerModel`).
    private func isTerminated(_ process: ProcessSample) -> Bool {
        terminatedIDs.contains(process.id)
    }
}

/// A process plus the processes it launched, for the optional hierarchy view.
/// Identity is the wrapped process's stable identity, so table selection, row
/// expansion, and the detail inspector all key on the same value as flat mode.
struct ProcessNode: Identifiable, Equatable {
    var process: ProcessSample
    var children: [ProcessNode]?
    /// A short label for the GPU table's category column (empty elsewhere).
    var badge: String = ""
    var id: ProcessIdentity { process.id }
}

extension ProcessSample {
    /// GPU share as a plain number, for sorting and the GPU table (0 when the
    /// process has no Metal context).
    var gpuPercentValue: Double { gpuPercent ?? 0 }
    /// GPU time per second in milliseconds, the Activity Monitor style figure.
    var gpuMillisecondsPerSecond: Double { (gpuPercent ?? 0) * 10 }
    /// Seconds since the last GPU submission, for sorting; large when never.
    var gpuIdleSeconds: Double {
        guard let last = gpuLastActive else { return .greatestFiniteMagnitude }
        return max(0, Date().timeIntervalSince(last))
    }
}
