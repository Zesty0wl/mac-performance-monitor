import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

/// The process list as an AppKit `NSOutlineView`, wrapped for SwiftUI.
///
/// This replaced SwiftUI's `Table`. A live table of ~700 processes updates
/// once a second, and `Table` re-hosted every visible cell through SwiftUI on
/// each update: about 4 ms per visible row, so on a tall window (60 rows)
/// each update cost 250 ms of main-thread time and everything else on the
/// main thread, including the 4 Hz charts, queued behind it. An outline view
/// with fixed-height reused cells sets a few hundred strings in a couple of
/// milliseconds.
///
/// Flat and hierarchy modes are the same view: rows are items, and a row with
/// children shows a disclosure triangle. Items are stable objects keyed by
/// process identity, so expansion survives a reload; selection is re-applied
/// from the binding after each reload. Sorting goes through the column
/// headers' sort descriptors, mapped to the same `KeyPathComparator`s the
/// SwiftUI table used, so the list's sort logic is unchanged.
struct ProcessOutlineTable: NSViewRepresentable {
    let rows: [ProcessNode]
    /// Bumped by the owner whenever `rows` is rebuilt; stands in for comparing
    /// the array so an unchanged revision skips the reload.
    let revision: Int
    let showHierarchy: Bool
    let leakingIDs: Set<ProcessIdentity>
    let terminatedIDs: Set<ProcessIdentity>
    @Binding var selection: Set<ProcessIdentity>
    @Binding var sortOrder: [KeyPathComparator<ProcessNode>]
    /// The context menu for the rows a right-click lands on (the clicked row
    /// joins the selection first, as the SwiftUI table did).
    let menu: (Set<ProcessIdentity>) -> NSMenu?
    /// Dial-rate value patches for rows on screen (`SamplerModel.processValuesTick`):
    /// the cells update in place, with no SwiftUI involvement and no re-sort.
    var values: AnyPublisher<[ProcessIdentity: ProcessSample], Never> =
        Empty().eraseToAnyPublisher()
    /// Told which processes' rows are on screen, as they scroll in and out.
    var onVisibleRowsChange: ([pid_t]) -> Void = { _ in }
    /// The columns to show, in order. The Processes tab uses `ColumnSpec.all`,
    /// the GPU tab `ColumnSpec.gpu`.
    var columns: [ColumnSpec] = ColumnSpec.all

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let outline = ContextMenuOutlineView()
        outline.menuProvider = { [weak coordinator] in coordinator?.contextMenu(for: $0) }
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.rowHeight = 22
        outline.usesAutomaticRowHeights = false
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.intercellSpacing = NSSize(width: 10, height: 2)
        outline.focusRingType = .none
        outline.autosaveTableColumns = false

        for spec in columns {
            let column = NSTableColumn(identifier: spec.identifier.identifier)
            column.title = spec.title
            column.minWidth = spec.minWidth
            column.width = spec.idealWidth
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.identifier.rawValue, ascending: spec.ascendingByDefault)
            column.headerCell.alignment = spec.rightAligned ? .right : .left
            column.resizingMask =
                spec.identifier == .process
                ? [.autoresizingMask, .userResizingMask]
                : [.userResizingMask]
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.sortDescriptors = Self.sortDescriptors(for: sortOrder)

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        coordinator.outlineView = outline
        coordinator.menu = menu
        coordinator.onSelectionChange = { ids in
            if selection != ids { selection = ids }
        }
        coordinator.onSortChange = { comparators in
            if comparators.map(\.keyPath) != sortOrder.map(\.keyPath)
                || comparators.map(\.order) != sortOrder.map(\.order)
            {
                sortOrder = comparators
            }
        }
        coordinator.onVisibleRowsChange = onVisibleRowsChange
        coordinator.observeScrolling(scrollView)
        coordinator.valuesCancellable = values.sink { [weak coordinator] patches in
            coordinator?.applyValues(patches)
        }
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.valuesCancellable = nil
        coordinator.onVisibleRowsChange?([])
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.menu = menu
        coordinator.onSelectionChange = { ids in
            if selection != ids { selection = ids }
        }
        coordinator.onSortChange = { comparators in
            if comparators.map(\.keyPath) != sortOrder.map(\.keyPath)
                || comparators.map(\.order) != sortOrder.map(\.order)
            {
                sortOrder = comparators
            }
        }
        coordinator.onVisibleRowsChange = onVisibleRowsChange
        coordinator.apply(
            rows: rows, revision: revision, showHierarchy: showHierarchy,
            leakingIDs: leakingIDs, terminatedIDs: terminatedIDs)
        coordinator.applySelection(selection)
        if let outline = coordinator.outlineView {
            let wanted = Self.sortDescriptors(for: sortOrder)
            if outline.sortDescriptors != wanted { outline.sortDescriptors = wanted }
        }
    }

    // MARK: - Columns

    enum ColumnID: String {
        case process, memory, cpu, threads, fds, arch, pid
        /// GPU tab columns: share of one GPU, GPU time per second, how long
        /// since the last submission, and the workload category.
        case gpu, gpuRate, gpuIdle, category

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
    }

    struct ColumnSpec {
        let identifier: ColumnID
        let title: String
        let minWidth: CGFloat
        let idealWidth: CGFloat
        let rightAligned: Bool
        let ascendingByDefault: Bool

        static let all: [ColumnSpec] = [
            ColumnSpec(
                identifier: .process, title: "Process", minWidth: 160, idealWidth: 260,
                rightAligned: false, ascendingByDefault: true),
            ColumnSpec(
                identifier: .memory, title: "Memory", minWidth: 84, idealWidth: 104,
                rightAligned: true, ascendingByDefault: false),
            ColumnSpec(
                identifier: .cpu, title: "CPU", minWidth: 58, idealWidth: 70, rightAligned: true,
                ascendingByDefault: false),
            ColumnSpec(
                identifier: .threads, title: "Threads", minWidth: 60, idealWidth: 72,
                rightAligned: true, ascendingByDefault: false),
            ColumnSpec(
                identifier: .fds, title: "FDs", minWidth: 50, idealWidth: 62, rightAligned: true,
                ascendingByDefault: false),
            ColumnSpec(
                identifier: .arch, title: "Arch", minWidth: 60, idealWidth: 72,
                rightAligned: false, ascendingByDefault: true),
            ColumnSpec(
                identifier: .pid, title: "PID", minWidth: 52, idealWidth: 72, rightAligned: true,
                ascendingByDefault: true),
        ]

        /// The GPU tab's table: who is using the GPU, ranked by share.
        static let gpu: [ColumnSpec] = [
            ColumnSpec(
                identifier: .process, title: "Process", minWidth: 160, idealWidth: 240,
                rightAligned: false, ascendingByDefault: true),
            ColumnSpec(
                identifier: .category, title: "Category", minWidth: 84, idealWidth: 104,
                rightAligned: false, ascendingByDefault: true),
            ColumnSpec(
                identifier: .gpu, title: "GPU", minWidth: 58, idealWidth: 70, rightAligned: true,
                ascendingByDefault: false),
            ColumnSpec(
                identifier: .gpuRate, title: "GPU ms/s", minWidth: 70, idealWidth: 84,
                rightAligned: true, ascendingByDefault: false),
            ColumnSpec(
                identifier: .gpuIdle, title: "Last active", minWidth: 78, idealWidth: 92,
                rightAligned: true, ascendingByDefault: true),
            ColumnSpec(
                identifier: .cpu, title: "CPU", minWidth: 58, idealWidth: 70, rightAligned: true,
                ascendingByDefault: false),
            ColumnSpec(
                identifier: .memory, title: "Memory", minWidth: 84, idealWidth: 104,
                rightAligned: true, ascendingByDefault: false),
            ColumnSpec(
                identifier: .pid, title: "PID", minWidth: 52, idealWidth: 72, rightAligned: true,
                ascendingByDefault: true),
        ]
    }

    /// The column a comparator sorts by, if it is one of ours.
    static func columnID(for comparator: KeyPathComparator<ProcessNode>) -> ColumnID? {
        let keyPath = comparator.keyPath
        if keyPath == \ProcessNode.process.displayName { return .process }
        if keyPath == \ProcessNode.process.physFootprint { return .memory }
        if keyPath == \ProcessNode.process.cpuPercent { return .cpu }
        if keyPath == \ProcessNode.process.threadCount { return .threads }
        if keyPath == \ProcessNode.process.fdTotal { return .fds }
        if keyPath == \ProcessNode.process.architecture.label { return .arch }
        if keyPath == \ProcessNode.process.pid { return .pid }
        if keyPath == \ProcessNode.process.gpuPercentValue { return .gpu }
        if keyPath == \ProcessNode.process.gpuMillisecondsPerSecond { return .gpuRate }
        if keyPath == \ProcessNode.process.gpuIdleSeconds { return .gpuIdle }
        if keyPath == \ProcessNode.badge { return .category }
        return nil
    }

    static func comparator(for column: ColumnID, ascending: Bool) -> KeyPathComparator<ProcessNode>
    {
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .process: return KeyPathComparator(\.process.displayName, order: order)
        case .memory: return KeyPathComparator(\.process.physFootprint, order: order)
        case .cpu: return KeyPathComparator(\.process.cpuPercent, order: order)
        case .threads: return KeyPathComparator(\.process.threadCount, order: order)
        case .fds: return KeyPathComparator(\.process.fdTotal, order: order)
        case .arch: return KeyPathComparator(\.process.architecture.label, order: order)
        case .pid: return KeyPathComparator(\.process.pid, order: order)
        case .gpu: return KeyPathComparator(\.process.gpuPercentValue, order: order)
        case .gpuRate: return KeyPathComparator(\.process.gpuMillisecondsPerSecond, order: order)
        case .gpuIdle: return KeyPathComparator(\.process.gpuIdleSeconds, order: order)
        case .category: return KeyPathComparator(\.badge, order: order)
        }
    }

    static func sortDescriptors(
        for comparators: [KeyPathComparator<ProcessNode>]
    )
        -> [NSSortDescriptor]
    {
        comparators.compactMap { comparator in
            columnID(for: comparator).map {
                NSSortDescriptor(key: $0.rawValue, ascending: comparator.order == .forward)
            }
        }
    }

    // MARK: - Coordinator

    /// A row's backing object. Stable per process identity across reloads so
    /// the outline view keeps expansion state; its `node` is refreshed in place.
    final class Item {
        var node: ProcessNode
        var children: [Item]?
        init(node: ProcessNode) { self.node = node }
        var id: ProcessIdentity { node.id }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outlineView: NSOutlineView?
        var menu: ((Set<ProcessIdentity>) -> NSMenu?)?
        var onSelectionChange: ((Set<ProcessIdentity>) -> Void)?
        var onSortChange: (([KeyPathComparator<ProcessNode>]) -> Void)?
        var onVisibleRowsChange: (([pid_t]) -> Void)?
        var valuesCancellable: AnyCancellable?
        private var lastVisiblePIDs: [pid_t] = []
        private var boundsObserver: NSObjectProtocol?

        deinit {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        }

        /// The columns a dial-rate value patch can change.
        static let valueColumns: Set<ColumnID> = [
            .cpu, .memory, .threads, .fds, .gpu, .gpuRate, .gpuIdle,
        ]

        /// Report the rows on screen whenever the scroll position changes.
        func observeScrolling(_ scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in self?.reportVisibleRows() }
        }

        /// Tell the owner which processes are on screen, when that changed.
        func reportVisibleRows() {
            guard let outlineView else { return }
            let visible = outlineView.rows(in: outlineView.visibleRect)
            var pids: [pid_t] = []
            pids.reserveCapacity(visible.length)
            if visible.length > 0 {
                for row in visible.location..<(visible.location + visible.length) {
                    if let item = outlineView.item(atRow: row) as? Item {
                        pids.append(item.node.process.pid)
                    }
                }
            }
            if pids != lastVisiblePIDs {
                lastVisiblePIDs = pids
                onVisibleRowsChange?(pids)
            }
        }

        /// Fold dial-rate value patches into the items and repaint only the
        /// value cells on screen. The order is untouched: re-sorting stays on
        /// the table publish cadence.
        func applyValues(_ patches: [ProcessIdentity: ProcessSample]) {
            guard let outlineView, !patches.isEmpty else { return }
            var touched = false
            for (id, sample) in patches {
                guard let item = itemsByID[id] else { continue }
                item.node.process = sample
                touched = true
            }
            if touched { refreshVisibleCells(outlineView, columns: Self.valueColumns) }
        }

        private var roots: [Item] = []
        private var itemsByID: [ProcessIdentity: Item] = [:]
        private var appliedRevision: Int?
        private var appliedHierarchy: Bool?
        private var leakingIDs: Set<ProcessIdentity> = []
        private var terminatedIDs: Set<ProcessIdentity> = []
        /// Set while we change the selection ourselves, so the delegate echo is
        /// not written back to the binding.
        private var isApplyingSelection = false

        /// Push new rows into the view.
        ///
        /// Flat mode treats the outline view's rows as slots: the same `Item`
        /// object stays at each row and its `node` is replaced, so the view's
        /// internal row cache stays valid and the visible cells are updated in
        /// place with no `reloadData`. A full reload (which drops and rebuilds
        /// every visible cell view) happens only when the row count changes.
        /// Hierarchy mode keys items by identity so expansion survives, and
        /// reloads; it is the opt-in mode.
        func apply(
            rows: [ProcessNode], revision: Int, showHierarchy: Bool,
            leakingIDs: Set<ProcessIdentity>, terminatedIDs: Set<ProcessIdentity>
        ) {
            let stylingChanged =
                leakingIDs != self.leakingIDs || terminatedIDs != self.terminatedIDs
            let modeChanged = showHierarchy != appliedHierarchy
            guard revision != appliedRevision || modeChanged || stylingChanged else { return }
            self.leakingIDs = leakingIDs
            self.terminatedIDs = terminatedIDs
            appliedRevision = revision
            appliedHierarchy = showHierarchy
            guard let outlineView else { return }

            if showHierarchy {
                var seen: Set<ProcessIdentity> = []
                func build(_ nodes: [ProcessNode]) -> [Item] {
                    nodes.map { node in
                        let item: Item
                        if let existing = itemsByID[node.id], !modeChanged {
                            existing.node = node
                            item = existing
                        } else {
                            item = Item(node: node)
                            itemsByID[node.id] = item
                        }
                        seen.insert(node.id)
                        item.children = node.children.map(build)
                        return item
                    }
                }
                if modeChanged { itemsByID.removeAll() }
                roots = build(rows)
                for id in itemsByID.keys where !seen.contains(id) {
                    itemsByID.removeValue(forKey: id)
                }
                reload(outlineView)
                return
            }

            if modeChanged {
                roots = rows.map { Item(node: $0) }
                itemsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
                reload(outlineView)
                return
            }
            // Slots are positional: slot i always shows row i. When the process
            // count changes (most seconds, as processes come and go), grow or
            // trim the slot list at the end and tell the outline view about
            // just those rows, so the visible cells are re-configured in place
            // rather than rebuilt by `reloadData`, which discards every row
            // view and asks for new ones (about 17 ms of cell construction).
            let old = roots.count
            let new = rows.count
            for (slot, node) in zip(roots, rows) {
                slot.node = node
                slot.children = nil
            }
            if new > old {
                roots.append(contentsOf: rows[old...].map { Item(node: $0) })
            } else if new < old {
                roots.removeLast(old - new)
            }
            itemsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
            if new != old {
                isApplyingSelection = true
                let selected = selectedIDs()
                if new > old {
                    outlineView.insertItems(
                        at: IndexSet(old..<new), inParent: nil, withAnimation: [])
                } else {
                    outlineView.removeItems(
                        at: IndexSet(new..<old), inParent: nil, withAnimation: [])
                }
                refreshVisibleCells(outlineView)
                select(selected)
                isApplyingSelection = false
            } else {
                refreshVisibleCells(outlineView)
            }
        }

        private func reload(_ outlineView: NSOutlineView) {
            isApplyingSelection = true
            let selected = selectedIDs()
            outlineView.reloadData()
            select(selected)
            isApplyingSelection = false
            reportVisibleRows()
        }

        /// Re-configure the materialised cells of the visible rows (all
        /// columns, or just `only`). Rows the view has not built yet are
        /// configured when it asks for them.
        private func refreshVisibleCells(
            _ outlineView: NSOutlineView, columns only: Set<ColumnID>? = nil
        ) {
            let visible = outlineView.rows(in: outlineView.visibleRect)
            guard visible.length > 0 else { return }
            let columns = outlineView.tableColumns
            for row in visible.location..<(visible.location + visible.length) {
                guard let item = outlineView.item(atRow: row) as? Item else { continue }
                for (index, column) in columns.enumerated() {
                    if let only, let id = ColumnID(rawValue: column.identifier.rawValue),
                        !only.contains(id)
                    {
                        continue
                    }
                    guard
                        let view = outlineView.view(
                            atColumn: index, row: row, makeIfNecessary: false)
                    else { continue }
                    configure(view, column: column, item: item)
                }
            }
            if only == nil { reportVisibleRows() }
        }

        private func configure(_ view: NSView, column: NSTableColumn, item: Item) {
            guard let columnID = ColumnID(rawValue: column.identifier.rawValue) else { return }
            let process = item.node.process
            let terminated = terminatedIDs.contains(process.id)
            if let cell = view as? ProcessCellView {
                cell.configure(
                    process: process,
                    isLeaking: leakingIDs.contains(process.id),
                    descendantLeaking: hasLeakingDescendant(item),
                    isTerminated: terminated)
            } else if let cell = view as? ValueCellView {
                cell.configure(
                    column: columnID, process: process, isTerminated: terminated,
                    badge: item.node.badge)
            }
        }

        /// Mirror the binding into the view when they differ.
        func applySelection(_ wanted: Set<ProcessIdentity>) {
            guard outlineView != nil, selectedIDs() != wanted else { return }
            isApplyingSelection = true
            select(wanted)
            isApplyingSelection = false
        }

        private func selectedIDs() -> Set<ProcessIdentity> {
            guard let outlineView else { return [] }
            var ids: Set<ProcessIdentity> = []
            for row in outlineView.selectedRowIndexes {
                if let item = outlineView.item(atRow: row) as? Item { ids.insert(item.id) }
            }
            return ids
        }

        private func select(_ ids: Set<ProcessIdentity>) {
            guard let outlineView else { return }
            let indexes = NSMutableIndexSet()
            for id in ids {
                if let item = itemsByID[id] {
                    let row = outlineView.row(forItem: item)
                    if row >= 0 { indexes.add(row) }
                }
            }
            outlineView.selectRowIndexes(indexes as IndexSet, byExtendingSelection: false)
        }

        func contextMenu(for clickedRow: Int) -> NSMenu? {
            guard let outlineView else { return nil }
            if clickedRow >= 0, !outlineView.selectedRowIndexes.contains(clickedRow) {
                outlineView.selectRowIndexes(
                    IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            let ids = selectedIDs()
            guard !ids.isEmpty else { return nil }
            return menu?(ids)
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? Item else { return roots.count }
            return item.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item = item as? Item else { return roots[index] }
            return item.children![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? Item, let children = item.children else { return false }
            return !children.isEmpty
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            let comparators = outlineView.sortDescriptors.compactMap { descriptor in
                descriptor.key.flatMap(ColumnID.init(rawValue:)).map {
                    ProcessOutlineTable.comparator(for: $0, ascending: descriptor.ascending)
                }
            }
            guard !comparators.isEmpty else { return }
            onSortChange?(comparators)
        }

        // MARK: Delegate

        func outlineView(
            _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
        ) -> NSView? {
            guard let item = item as? Item, let tableColumn,
                let column = ColumnID(rawValue: tableColumn.identifier.rawValue)
            else { return nil }
            let view: NSView
            if column == .process {
                view =
                    outlineView.makeView(withIdentifier: ProcessCellView.identifier, owner: nil)
                    as? ProcessCellView ?? ProcessCellView()
            } else {
                view =
                    outlineView.makeView(withIdentifier: ValueCellView.identifier, owner: nil)
                    as? ValueCellView ?? ValueCellView()
            }
            configure(view, column: tableColumn, item: item)
            return view
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection else { return }
            onSelectionChange?(selectedIDs())
        }

        func outlineView(
            _ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer,
            tableColumn: NSTableColumn?, item: Any, mouseLocation: NSPoint
        ) -> String {
            guard let item = item as? Item, let tableColumn,
                let column = ColumnID(rawValue: tableColumn.identifier.rawValue)
            else { return "" }
            switch column {
            case .process:
                if !leakingIDs.contains(item.id), hasLeakingDescendant(item) {
                    return "A process started by this one looks like it's leaking memory."
                }
                return item.node.process.displayName
            case .memory:
                return item.node.process.footprintReadable
                    ? "" : "Footprint not readable at the user level for this process."
            default:
                return ""
            }
        }

        /// Whether any process nested beneath `item` is a suspected leak, so a
        /// collapsed parent still shows the warning.
        private func hasLeakingDescendant(_ item: Item) -> Bool {
            guard let children = item.children else { return false }
            for child in children {
                if leakingIDs.contains(child.id) || hasLeakingDescendant(child) { return true }
            }
            return false
        }
    }
}

/// An outline view whose right-click menu comes from the coordinator, for the
/// rows the click lands on.
final class ContextMenuOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(row(at: point))
    }
}

// MARK: - Cells

/// The Process column: icon, leak warning, name, and a Rosetta or Stopped
/// badge. Laid out by hand (no Auto Layout, no stack view) and re-styled only
/// when something it shows actually changed: with ~300 visible cells updated
/// every second, constraint solving and needless redraws were most of the cost.
final class ProcessCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ProcessCellView")

    private static let warningImage: NSImage? = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: "Possible memory leak"
    )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    private static let nameFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let badgeFont = NSFont.systemFont(
        ofSize: NSFont.smallSystemFontSize - 1, weight: .medium)

    private let icon = NSImageView()
    private let warning = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    private var shownPath: String??
    private var shownName: String?
    private var shownStyle: (leaking: Bool, warning: Bool, terminated: Bool, translated: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        warning.image = Self.warningImage
        warning.contentTintColor = .systemOrange
        warning.isHidden = true
        name.font = Self.nameFont
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.cell?.truncatesLastVisibleLine = true
        badge.font = Self.badgeFont
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.alignment = .center
        badge.isHidden = true
        for view in [icon, warning, name, badge] { addSubview(view) }
        textField = name
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x: CGFloat = 2
        icon.frame = NSRect(x: x, y: (height - 16) / 2, width: 16, height: 16)
        x += 16 + 6
        if !warning.isHidden {
            warning.frame = NSRect(x: x, y: (height - 14) / 2, width: 14, height: 14)
            x += 14 + 4
        }
        var badgeWidth: CGFloat = 0
        if !badge.isHidden {
            badgeWidth = ceil(badge.intrinsicContentSize.width) + 2
        }
        let nameHeight = ceil(Self.nameFont.ascender - Self.nameFont.descender) + 2
        let nameWidth = max(0, bounds.width - x - 2 - (badgeWidth > 0 ? badgeWidth + 6 : 0))
        name.frame = NSRect(
            x: x, y: (height - nameHeight) / 2, width: nameWidth, height: nameHeight)
        if !badge.isHidden {
            let badgeHeight = ceil(Self.badgeFont.ascender - Self.badgeFont.descender) + 3
            badge.frame = NSRect(
                x: x + nameWidth + 6, y: (height - badgeHeight) / 2, width: badgeWidth,
                height: badgeHeight)
        }
    }

    func configure(
        process: ProcessSample, isLeaking: Bool, descendantLeaking: Bool, isTerminated: Bool
    ) {
        if shownPath != .some(process.executablePath) {
            shownPath = .some(process.executablePath)
            icon.image = ProcessIconProvider.shared.icon(forPath: process.executablePath)
        }
        let style = (
            leaking: isLeaking, warning: !isTerminated && (isLeaking || descendantLeaking),
            terminated: isTerminated, translated: process.isTranslated
        )
        let styleChanged =
            shownStyle.map {
                $0.leaking != style.leaking || $0.warning != style.warning
                    || $0.terminated != style.terminated || $0.translated != style.translated
            } ?? true
        if styleChanged || shownName != process.displayName {
            shownName = process.displayName
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.nameFont,
                .foregroundColor: isTerminated
                    ? NSColor.secondaryLabelColor
                    : (isLeaking ? NSColor.systemOrange : NSColor.labelColor),
                .strikethroughStyle: isTerminated ? NSUnderlineStyle.single.rawValue : 0,
                .strikethroughColor: NSColor.secondaryLabelColor,
            ]
            name.attributedStringValue = NSAttributedString(
                string: process.displayName, attributes: attributes)
        }
        guard styleChanged else { return }
        shownStyle = style
        icon.alphaValue = isTerminated ? 0.5 : 1
        warning.isHidden = !style.warning
        if isTerminated {
            badge.isHidden = false
            badge.stringValue = " Stopped "
            badge.textColor = .secondaryLabelColor
            badge.layer?.backgroundColor =
                NSColor.secondaryLabelColor.withAlphaComponent(0.18)
                .cgColor
        } else if process.isTranslated {
            badge.isHidden = false
            badge.stringValue = " Rosetta "
            badge.textColor = .systemOrange
            badge.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.2).cgColor
        } else {
            badge.isHidden = true
        }
        needsLayout = true
    }
}

/// A single-value column: a monospaced-digit label, right-aligned for numbers,
/// redrawn only when its text or styling changes.
final class ValueCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ValueCellView")

    private let label = NSTextField(labelWithString: "")
    private static let digitFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)
    private static let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private var shownText: String?
    private var shownSecondary: Bool?
    private var shownDimmed: Bool?
    private var shownColumn: ProcessOutlineTable.ColumnID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.font = Self.digitFont
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let font = label.font ?? Self.digitFont
        let textHeight = ceil(font.ascender - font.descender) + 2
        label.frame = NSRect(
            x: 2, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - 4),
            height: textHeight)
    }

    /// "now", "12 s", "3 m", "2 h", or "never" for the GPU table's last-active
    /// column, coarse enough not to churn at the dial rate.
    static func idleText(_ last: Date?) -> String {
        guard let last else { return "never" }
        let seconds = max(0, Date().timeIntervalSince(last))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    func configure(
        column: ProcessOutlineTable.ColumnID, process: ProcessSample, isTerminated: Bool,
        badge: String = ""
    ) {
        let text: String
        var secondary = false
        switch column {
        case .gpu:
            text = String(format: "%.1f%%", process.gpuPercentValue)
            secondary = process.gpuPercentValue < 0.05
        case .gpuRate:
            text = String(format: "%.0f", process.gpuMillisecondsPerSecond)
            secondary = process.gpuPercentValue < 0.05
        case .gpuIdle:
            text = Self.idleText(process.gpuLastActive)
            secondary = process.gpuIdleSeconds > 60
        case .category:
            text = badge
            secondary = true
        case .memory:
            text = process.footprintReadable ? ByteFormat.string(process.physFootprint) : "—"
            secondary = !process.footprintReadable
        case .cpu: text = String(format: "%.1f%%", process.cpuPercent)
        case .threads: text = "\(process.threadCount)"
        case .fds: text = "\(process.fdTotal)"
        case .arch:
            text = process.architecture.label
            secondary = true
        case .pid:
            text = "\(process.pid)"
            secondary = true
        case .process: text = process.displayName
        }
        if shownColumn != column {
            shownColumn = column
            let leftAligned = column == .arch || column == .category
            label.alignment = leftAligned ? .left : .right
            label.font = leftAligned ? Self.captionFont : Self.digitFont
            needsLayout = true
        }
        if shownText != text {
            shownText = text
            label.stringValue = text
        }
        if shownSecondary != secondary {
            shownSecondary = secondary
            label.textColor = secondary ? .secondaryLabelColor : .labelColor
        }
        if shownDimmed != isTerminated {
            shownDimmed = isTerminated
            label.alphaValue = isTerminated ? 0.5 : 1
        }
    }
}

/// A menu item that runs a closure, so the table's context menu can be built
/// from the same actions the SwiftUI menu used.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(
        _ title: String, symbol: String? = nil, enabled: Bool = true, handler: @escaping () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
