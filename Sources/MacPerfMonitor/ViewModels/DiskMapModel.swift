import AppKit
import Combine
import Foundation
import MacPerfMonitorCore

/// One line of a Disk Map slice (Largest, Oldest, Kinds): a node flattened
/// for a table.
struct DiskMapRow: Identifiable, Hashable, Sendable {
    let id: Int32
    let name: String
    /// The canonical path the user knows (firmlinks resolved).
    let path: String
    let bytes: UInt64
    let modified: Date
    let kind: FileKind
    let isDirectory: Bool
    let flags: FileNodeFlags
    let count: UInt32
    /// Share of everything the scan counted.
    let fraction: Double

    var kindLabel: String { isDirectory && kind == .folder ? "Folder" : kind.label }
    var parentPath: String { (path as NSString).deletingLastPathComponent }
}

/// One file behind a small-files fold, listed live from the directory.
struct DiskMapFoldEntry: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let bytes: UInt64
}

/// State for the Disk Map page: the scope, the last scan (restored from disk
/// on open), the scan in flight, the selection, the map's zoom, the advisor's
/// analysis and the memoised rows of the active slice. One shared instance,
/// like `HardwareExplorerModel`, because `TabGate` unmounts the page on every
/// tab switch and a multi-minute scan must survive that. What it must not
/// survive is the window closing: the arena is dropped then (memory budget)
/// and comes back from the snapshot file on the next open. Nothing here runs
/// on the sampler's tick.
@MainActor
final class DiskMapModel: ObservableObject {
    static let shared = DiskMapModel()

    /// Rows a slice keeps: enough to scroll through, few enough that a SwiftUI
    /// `Table` stays cheap (it never ticks).
    nonisolated static let rowLimit = 2_000

    enum ViewMode: String, CaseIterable, Identifiable {
        case map = "Map"
        case largest = "Largest"
        case oldest = "Oldest"
        case kinds = "Kinds"
        case reclaim = "Reclaim"
        case changes = "Changes"
        var id: String { rawValue }
    }

    enum LargestKind: String, CaseIterable, Identifiable {
        case files = "Files"
        case folders = "Folders"
        var id: String { rawValue }
    }

    enum AgeBand: Int, CaseIterable, Identifiable {
        case any = 0
        case oneYear = 1
        case twoYears = 2
        case fiveYears = 5
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .any: return "Any age"
            case .oneYear: return "Untouched 1+ year"
            case .twoYears: return "Untouched 2+ years"
            case .fiveYears: return "Untouched 5+ years"
            }
        }
        func cutoff(now: Date) -> Date? {
            self == .any ? nil : now.addingTimeInterval(-Double(rawValue) * 365 * 86_400)
        }
    }

    enum MinimumSize: UInt64, CaseIterable, Identifiable {
        case any = 0
        case oneMB = 1_048_576
        case tenMB = 10_485_760
        case hundredMB = 104_857_600
        case oneGB = 1_073_741_824
        var id: UInt64 { rawValue }
        var label: String {
            switch self {
            case .any: return "Any size"
            case .oneMB: return "1 MB and up"
            case .tenMB: return "10 MB and up"
            case .hundredMB: return "100 MB and up"
            case .oneGB: return "1 GB and up"
            }
        }
    }

    @Published private(set) var scope: DiskMapScope = .startupDisk
    @Published private(set) var snapshot: DiskMapSnapshot?
    @Published private(set) var preview: DiskMapPreviewNode?
    @Published private(set) var progress: DiskMapScanProgress?
    @Published private(set) var isScanning = false
    /// True while the Desktop / Documents / Downloads prompts are being
    /// sequenced ahead of the workers (only without Full Disk Access).
    @Published private(set) var isPreparing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var lastError: String?
    /// Mounted user volumes offered in the scope menu.
    @Published private(set) var externalVolumes: [VolumeInfo] = []
    /// The advisor's tiers, Reclaim items and kind totals for the snapshot.
    @Published private(set) var analysis: DiskMapAnalysis?
    @Published var selection: Int32?
    @Published var viewMode: ViewMode = .map
    @Published var colorMode: DiskMapColorMode = .kind
    /// The directory the map is zoomed into; the root when not zoomed.
    @Published private(set) var zoomRoot: Int32 = FileTree.root
    /// The cell under the pointer, for the hover card.
    @Published var hover: TreemapHover?
    @Published var largestKind: LargestKind = .files
    @Published var ageBand: AgeBand = .oneYear
    @Published var minimumSize: MinimumSize = .oneMB
    @Published var selectedKind: FileKind?
    @Published var filterText = ""
    /// The active slice, memoised per (snapshot revision, mode, filters) and
    /// built off the main thread. `rowsRevision` is what views compare.
    @Published private(set) var rows: [DiskMapRow] = []
    @Published private(set) var rowsRevision = 0
    @Published private(set) var rowsBuilding = false
    /// A node awaiting the Move to Trash confirmation.
    @Published var pendingTrash: Int32?
    @Published var trashError: String?
    /// The current scan compared with the previous one of the same scope,
    /// computed on demand when the Changes view opens.
    @Published private(set) var diff: DiskMapDiff?
    @Published private(set) var diffState: DiffState = .idle

    enum DiffState: Equatable {
        case idle
        case loading
        case ready
        /// No previous scan of this scope is on disk yet.
        case noPrevious
    }

    let advisor = DiskMapAdvisor()

    private let scanner = DiskMapScanner()
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private var restoreID = UUID()
    private var rowsGeneration = 0
    private var analysisGeneration = 0
    private var diffGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private var windowCancellable: AnyCancellable?
    private var unmountObserver: NSObjectProtocol?
    private weak var fullDiskAccess: FullDiskAccessManager?

    private init() {
        // `@Published` emits on willSet, so a sink that reads the properties
        // synchronously sees the value being replaced. Hopping through the main
        // queue delivers after the assignment, which is the value to build for.
        Publishers.CombineLatest4($viewMode, $largestKind, $ageBand, $minimumSize)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.rebuildRows() }
            .store(in: &cancellables)
        $selectedKind
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildRows() }
            .store(in: &cancellables)
        $filterText
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.rebuildRows() }
            .store(in: &cancellables)
        $viewMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                if mode == .changes { self?.loadDiffIfNeeded() }
            }
            .store(in: &cancellables)
        // A volume that goes away mid-scan: stop rather than report a
        // partial tree as if the disk had shrunk.
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else { return }
            Task { @MainActor in self?.volumeDidUnmount(url.path) }
        }
    }

    private func volumeDidUnmount(_ mountPoint: String) {
        guard isScanning else { return }
        let root = scope.scanRoot
        let prefix = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
        guard root == mountPoint || root.hasPrefix(prefix) else { return }
        cancelScan()
        lastError = "\((mountPoint as NSString).lastPathComponent) was ejected during the scan."
        AppLog.ui.notice("Disk Map scan stopped: volume unmounted \(mountPoint, privacy: .public)")
    }

    // MARK: - Lifecycle

    /// Hook up the window gate and the access manager. Idempotent; the page
    /// calls it on every appear.
    func bind(appState: AppState, fullDiskAccess: FullDiskAccessManager) {
        self.fullDiskAccess = fullDiskAccess
        guard windowCancellable == nil else { return }
        // Transitions only: the page exists, so the current value is not a
        // close, whatever it reads (the benchmark harness mounts the page
        // without ever opening a window).
        windowCancellable = appState.$mainWindowOpen
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] open in
                if !open { self?.windowClosed() }
            }
    }

    /// The page appeared: bring back the last scan for this scope if nothing
    /// is loaded, and refresh the volume list for the scope menu.
    func appear() {
        if snapshot == nil, !isScanning, !isRestoring {
            restore(scope)
        }
        refreshVolumes()
    }

    private func windowClosed() {
        // Drop the arena before MemoryReclaim's pressure relief runs; a scan
        // in flight is abandoned (its partial result would only shadow the
        // last complete one on disk).
        cancelScan()
        clearSnapshot()
        AppLog.ui.notice("Disk Map released its tree on window close")
    }

    private func clearSnapshot() {
        snapshot = nil
        analysis = nil
        diff = nil
        diffState = .idle
        rows = []
        rowsRevision += 1
        selection = nil
        zoomRoot = FileTree.root
        hover = nil
        pendingTrash = nil
    }

    // MARK: - Scope

    var scopeTitle: String { scope.rootName }

    func setScope(_ newScope: DiskMapScope) {
        guard newScope != scope else { return }
        cancelScan()
        scope = newScope
        clearSnapshot()
        lastError = nil
        restore(newScope)
    }

    /// "Choose Folder…": any directory, normalised through `DiskMapScope`.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to map."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setScope(DiskMapScope.resolved(folder: url.path))
    }

    private func refreshVolumes() {
        Task.detached(priority: .utility) {
            let volumes = VolumeReader().read().volumes.filter {
                $0.role == .user && $0.isLocal && $0.mountPoint != "/"
                    && !$0.mountPoint.hasPrefix("/System/")
                    && !$0.mountPoint.hasPrefix("/private/")
            }
            await MainActor.run { self.externalVolumes = volumes }
        }
    }

    // MARK: - Scanning

    var progressFraction: Double? { progress?.fraction }

    var statusText: String {
        if isPreparing { return "Checking folder access\u{2026}" }
        guard let progress else { return "Starting\u{2026}" }
        let items = Self.compactCount(progress.entries)
        let elapsed = Int(progress.elapsed)
        let clock = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        return "\(items) items \u{00B7} \(ByteFormat.string(progress.bytes)) \u{00B7} \(clock)"
    }

    var currentPathText: String { progress?.currentPath ?? "" }

    func startScan() {
        guard !isScanning else { return }
        cancelScan()
        lastError = nil
        isScanning = true
        let id = UUID()
        scanID = id
        AppLog.ui.notice("Disk Map scan requested: \(self.scope.scanRoot, privacy: .public)")
        let needsPreflight =
            (fullDiskAccess?.isGranted != true) && (scope == .startupDisk || scope == .home)
        guard needsPreflight else {
            launch(id)
            return
        }
        // Without Full Disk Access the first touch of Desktop, Documents and
        // Downloads raises a system prompt on the thread that touched it. Six
        // workers would stack three alerts and block inside them; one thread
        // visiting the three folders in turn shows them one at a time.
        isPreparing = true
        let home = NSHomeDirectory()
        Task.detached(priority: .userInitiated) {
            let lister = BulkAttributeLister()
            for folder in ["Desktop", "Documents", "Downloads"] {
                _ = try? lister.list(path: home + "/" + folder)
            }
            await MainActor.run {
                guard self.scanID == id else { return }
                self.isPreparing = false
                self.launch(id)
            }
        }
    }

    private func launch(_ id: UUID) {
        guard scanID == id else { return }
        let events = scanner.scan(scope, options: DiskMapScanOptions())
        scanTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, self.scanID == id else { return }
                self.apply(event)
            }
        }
    }

    func cancelScan() {
        scanID = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        isPreparing = false
        progress = nil
        preview = nil
    }

    private func apply(_ event: DiskMapScanEvent) {
        switch event {
        case .progress(let progress, let preview):
            self.progress = progress
            self.preview = preview
        case .completed(let snapshot):
            finish(snapshot)
        case .failed(let error):
            isScanning = false
            scanTask = nil
            progress = nil
            preview = nil
            lastError = error.localizedDescription
            AppLog.ui.error("Disk Map scan failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finish(_ snapshot: DiskMapSnapshot) {
        install(snapshot)
        isScanning = false
        scanTask = nil
        progress = nil
        preview = nil
        FDWatchdog.check(after: "disk map scan")
        let counts = snapshot.reconciliation.counts
        AppLog.ui.notice(
            "Disk Map scan finished: \(snapshot.tree.nodeCount) nodes, \(counts.entries) entries, \(snapshot.reconciliation.scannedBytes) bytes, \(counts.notPermitted) not permitted"
        )
        guard !snapshot.partial else { return }
        persist(snapshot)
    }

    private func install(_ snapshot: DiskMapSnapshot) {
        self.snapshot = snapshot
        analysis = nil
        diff = nil
        diffState = .idle
        selection = nil
        zoomRoot = FileTree.root
        hover = nil
        pendingTrash = nil
        rebuildRows()
        analyze()
        if viewMode == .changes { loadDiffIfNeeded() }
    }

    private func persist(_ snapshot: DiskMapSnapshot) {
        Task.detached(priority: .utility) {
            do {
                try DiskMapSnapshotStore.save(snapshot)
                AppLog.ui.notice("Disk Map snapshot saved")
            } catch {
                AppLog.ui.error(
                    "Disk Map snapshot save failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func restore(_ scope: DiskMapScope) {
        isRestoring = true
        let id = UUID()
        restoreID = id
        Task.detached(priority: .userInitiated) {
            let loaded: DiskMapSnapshot?
            do {
                loaded = try DiskMapSnapshotStore.load(for: scope)
            } catch {
                loaded = nil
                AppLog.ui.error(
                    "Disk Map snapshot load failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await MainActor.run {
                guard self.restoreID == id else { return }
                self.isRestoring = false
                guard let loaded, self.scope == scope, self.snapshot == nil else { return }
                self.install(loaded)
                AppLog.ui.notice("Disk Map snapshot restored (\(loaded.tree.nodeCount) nodes)")
            }
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Analysis

    /// Run the advisor over the snapshot off the main thread; results are
    /// applied only if the snapshot has not been replaced meanwhile.
    private func analyze() {
        guard let snapshot else { return }
        analysisGeneration += 1
        let generation = analysisGeneration
        let advisor = advisor
        Task.detached(priority: .userInitiated) {
            let result = advisor.analyze(snapshot)
            await MainActor.run {
                guard self.analysisGeneration == generation,
                    self.snapshot?.revision == snapshot.revision
                else { return }
                self.analysis = result
                if self.viewMode == .kinds, self.selectedKind == nil {
                    self.selectedKind = result.kinds.first?.kind
                }
            }
        }
    }

    /// What the advisor says about a node: from the analysis when it has
    /// landed, else from the path directly.
    func advice(for node: Int32) -> DiskMapAdvice? {
        guard let snapshot, Int(node) < snapshot.tree.nodeCount else { return nil }
        if let analysis, analysis.revision == snapshot.revision,
            Int(node) < analysis.ruleIndex.count
        {
            return advisor.advice(for: node, in: analysis, tree: snapshot.tree)
        }
        let flags = snapshot.tree.flags[Int(node)]
        return advisor.advice(
            forCanonicalPath: snapshot.displayPath(of: node),
            isDirectory: flags.contains(.directory), flags: flags)
    }

    var trashedBytes: UInt64 { analysis?.trashedBytes ?? 0 }

    // MARK: - Changes since the previous scan

    /// Load the previous snapshot of this scope from disk and diff it against
    /// the current one, off the main thread; once per snapshot revision.
    func loadDiffIfNeeded() {
        guard let snapshot, diffState == .idle || diff.map({ _ in false }) ?? true else { return }
        guard diffState != .loading else { return }
        diffState = .loading
        diffGeneration += 1
        let generation = diffGeneration
        let scope = scope
        Task.detached(priority: .userInitiated) {
            let previous = try? DiskMapSnapshotStore.load(for: scope, previous: true)
            let result = previous.map { DiskMapDiff.compute(current: snapshot, previous: $0) }
            await MainActor.run {
                guard self.diffGeneration == generation,
                    self.snapshot?.revision == snapshot.revision
                else { return }
                self.diff = result
                self.diffState = result == nil ? .noPrevious : .ready
            }
        }
    }

    // MARK: - Map navigation

    /// Zoom the map into a directory that has children to show.
    func zoom(into node: Int32) {
        guard let tree = snapshot?.tree, Int(node) < tree.nodeCount else { return }
        let flags = tree.flags[Int(node)]
        guard flags.contains(.directory), !flags.contains(.smallFilesFold),
            tree.childCount[Int(node)] > 0
        else { return }
        zoomRoot = node
        hover = nil
        if let selection, !tree.node(selection, isWithin: node) { self.selection = nil }
    }

    /// One level up, keeping the directory just left as the selection so the
    /// eye lands back where it was.
    func zoomOut() {
        guard let tree = snapshot?.tree, zoomRoot != FileTree.root else { return }
        let leaving = zoomRoot
        zoomRoot = tree.parent[Int(zoomRoot)]
        selection = leaving
        hover = nil
    }

    /// Show a node in the map: zoom to its parent and select it.
    func reveal(_ node: Int32) {
        guard let tree = snapshot?.tree, Int(node) < tree.nodeCount else { return }
        viewMode = .map
        zoomRoot = node == FileTree.root ? FileTree.root : tree.parent[Int(node)]
        selection = node
        hover = nil
    }

    /// The zoom root's ancestry, root first, with display names.
    var breadcrumbs: [(node: Int32, name: String)] {
        guard let snapshot else { return [] }
        return snapshot.tree.ancestry(of: zoomRoot).map { node in
            (node, node == FileTree.root ? snapshot.scope.rootName : snapshot.tree.name(of: node))
        }
    }

    /// Hand a snapshot in directly, for the chart benchmark harness.
    func installForBenchmark(_ snapshot: DiskMapSnapshot) {
        cancelScan()
        scope = snapshot.scope
        install(snapshot)
    }

    // MARK: - Selection and lookups

    func select(_ node: Int32?) {
        selection = node
    }

    func displayPath(of node: Int32) -> String? {
        snapshot?.displayPath(of: node)
    }

    func filesystemPath(of node: Int32) -> String? {
        snapshot?.filesystemPath(of: node)
    }

    /// Children of a directory, largest first, folds included.
    func childrenBySize(of node: Int32) -> [Int32] {
        snapshot?.tree.childrenBySize(of: node) ?? []
    }

    /// The files behind a small-files fold, read live from its directory
    /// (the arena keeps only their total). Largest first, capped.
    func foldListing(for node: Int32, limit: Int = 40) async -> [DiskMapFoldEntry] {
        guard let snapshot, Int(node) < snapshot.tree.nodeCount,
            snapshot.tree.flags[Int(node)].contains(.smallFilesFold)
        else { return [] }
        let tree = snapshot.tree
        let parent = tree.parent[Int(node)]
        let kind = tree.kind[Int(node)]
        let threshold = snapshot.smallFileThreshold
        let path = snapshot.filesystemPath(of: parent)
        return await Task.detached(priority: .userInitiated) {
            guard let listing = try? BulkAttributeLister().list(path: path) else { return [] }
            var entries: [DiskMapFoldEntry] = []
            for entry in listing.entries where entry.type == .regular && entry.error == 0 {
                guard threshold == 0 || entry.allocated < threshold else { continue }
                let name = listing.nameString(of: entry)
                guard FileKindClassifier.kind(forName: name, isDirectory: false) == kind else {
                    continue
                }
                entries.append(DiskMapFoldEntry(name: name, bytes: entry.allocated))
            }
            entries.sort { $0.bytes > $1.bytes }
            return Array(entries.prefix(limit))
        }.value
    }

    // MARK: - Trash

    /// Whether Move to Trash is offered for a node: not a fold, not already
    /// trashed, not a place the app refuses, and not tiered as protected.
    func canTrash(_ node: Int32) -> Bool {
        guard let snapshot, Int(node) < snapshot.tree.nodeCount else { return false }
        let flags = snapshot.tree.flags[Int(node)]
        if flags.contains(.smallFilesFold) || flags.contains(.trashed)
            || flags.contains(.separateVolume) || flags.contains(.restricted)
            || flags.contains(.immutable) || node == FileTree.root
        {
            return false
        }
        if advisor.isRefusedForTrash(
            canonicalPath: snapshot.displayPath(of: node), scanRoot: snapshot.scope.displayRoot)
        {
            return false
        }
        return advice(for: node)?.canTrash ?? true
    }

    /// Ask for confirmation; the page hosts the dialog.
    func requestTrash(_ node: Int32) {
        guard canTrash(node) else { return }
        pendingTrash = node
    }

    /// The confirmed move. The inode is checked first so a scan that is days
    /// old never removes something that replaced the item the user saw; on
    /// success the tree is patched in place (bytes re-homed to In Trash) and
    /// the revision bumps so every view follows.
    func performTrash(_ node: Int32) {
        pendingTrash = nil
        guard let snapshot, Int(node) < snapshot.tree.nodeCount, canTrash(node) else { return }
        let path = snapshot.filesystemPath(of: node)
        let displayPath = snapshot.displayPath(of: node)
        let fileID = snapshot.tree.fileID[Int(node)]
        let revision = snapshot.revision
        let advisor = advisor
        let scanRoot = snapshot.scope.displayRoot
        Task.detached(priority: .userInitiated) {
            let check = DiskMapTrash.precheck(
                path: path, canonicalPath: displayPath, expectedFileID: fileID, advisor: advisor,
                scanRoot: scanRoot)
            let outcome: DiskMapTrash.Outcome
            switch check {
            case .ok: outcome = DiskMapTrash.trash(path: path)
            case .vanished: outcome = .alreadyGone
            case .replaced:
                outcome = .failed(
                    "\u{201C}\((displayPath as NSString).lastPathComponent)\u{201D} has changed since the scan. Scan again before removing it."
                )
            case .refused(let reason): outcome = .failed(reason)
            }
            await MainActor.run {
                self.finishTrash(node: node, revision: revision, outcome: outcome)
            }
        }
    }

    private func finishTrash(node: Int32, revision: Int, outcome: DiskMapTrash.Outcome) {
        guard var snapshot, snapshot.revision == revision else { return }
        switch outcome {
        case .trashed, .alreadyGone:
            let removed = snapshot.tree.markTrashed(node)
            snapshot.revision += 1
            self.snapshot = snapshot
            rebuildRows()
            analyze()
            AppLog.ui.notice(
                "Disk Map moved \(removed) bytes to the Trash (\(outcome == .alreadyGone ? "already gone" : "ok", privacy: .public))"
            )
        case .failed(let message):
            // Deferred so the confirmation dialog has fully dismissed; SwiftUI
            // swallows an alert presented in the same tick.
            DispatchQueue.main.async { self.trashError = message }
        }
    }

    // MARK: - Rows

    private func rebuildRows() {
        guard let snapshot else {
            rows = []
            rowsRevision += 1
            return
        }
        rowsGeneration += 1
        let generation = rowsGeneration
        let mode = viewMode
        let kind = largestKind
        let band = ageBand
        let minimum = minimumSize
        let filter = filterText.trimmingCharacters(in: .whitespaces)
        let kindItems = selectedKind.flatMap { selected in
            analysis?.kinds.first { $0.kind == selected }?.topItems
        }
        rowsBuilding = true
        Task.detached(priority: .userInitiated) {
            let built = Self.buildRows(
                snapshot: snapshot, mode: mode, largestKind: kind, ageBand: band,
                minimumSize: minimum, filter: filter, kindItems: kindItems, now: Date(),
                limit: Self.rowLimit)
            await MainActor.run {
                guard self.rowsGeneration == generation else { return }
                self.rows = built
                self.rowsRevision += 1
                self.rowsBuilding = false
            }
        }
    }

    /// One pass over the arena to pick the slice, then paths for the survivors
    /// only. The filter matches a node or any ancestor by name, computed as a
    /// forward pass (parents precede children) over raw name bytes so no
    /// strings are made for the millions that do not match.
    nonisolated static func buildRows(
        snapshot: DiskMapSnapshot, mode: ViewMode, largestKind: LargestKind, ageBand: AgeBand,
        minimumSize: MinimumSize, filter: String, kindItems: [Int32]?, now: Date, limit: Int
    ) -> [DiskMapRow] {
        let tree = snapshot.tree
        let n = tree.nodeCount
        guard n > 1 else { return [] }
        let total = max(tree.bytes[0], 1)

        var hit: [Bool] = []
        let needle = Array(filter.lowercased().utf8)
        if !needle.isEmpty {
            hit = [Bool](repeating: false, count: n)
            for i in 1..<n {
                let p = Int(tree.parent[i])
                hit[i] = hit[p] || nameContains(tree.nameBytes(of: Int32(i)), needle)
            }
        }

        func row(_ node: Int32) -> DiskMapRow {
            let i = Int(node)
            return DiskMapRow(
                id: node, name: tree.name(of: node), path: snapshot.displayPath(of: node),
                bytes: tree.bytes[i], modified: tree.modifiedDate(of: node), kind: tree.kind[i],
                isDirectory: tree.flags[i].contains(.directory), flags: tree.flags[i],
                count: tree.count[i], fraction: Double(tree.bytes[i]) / Double(total))
        }

        switch mode {
        case .map, .reclaim, .changes:
            return []
        case .kinds:
            guard let kindItems else { return [] }
            return kindItems.prefix(limit).compactMap { node in
                let i = Int(node)
                guard i < n, !tree.flags[i].contains(.trashed) else { return nil }
                if !needle.isEmpty, !hit[i] { return nil }
                return row(node)
            }
        case .largest, .oldest:
            break
        }

        let cutoff = ageBand.cutoff(now: now).map {
            UInt32(clamping: Int($0.timeIntervalSince1970))
        }
        var candidates: [(key: UInt64, node: Int32)] = []
        candidates.reserveCapacity(min(n, 1 << 20))
        for i in 1..<n {
            let flags = tree.flags[i]
            if flags.contains(.smallFilesFold) || flags.contains(.trashed) { continue }
            if !needle.isEmpty, !hit[i] { continue }
            let isDirectory = flags.contains(.directory)
            switch mode {
            case .largest:
                switch largestKind {
                case .files:
                    if isDirectory { continue }
                case .folders:
                    if !isDirectory || flags.contains(.separateVolume) { continue }
                }
                if tree.bytes[i] == 0 { continue }
                candidates.append((key: tree.bytes[i], node: Int32(i)))
            case .oldest:
                if isDirectory { continue }
                if tree.bytes[i] < minimumSize.rawValue { continue }
                if let cutoff, tree.modified[i] > cutoff { continue }
                if tree.modified[i] == 0 { continue }
                candidates.append((key: UInt64(tree.modified[i]), node: Int32(i)))
            case .map, .kinds, .reclaim, .changes:
                break
            }
        }
        switch mode {
        case .largest: candidates.sort { $0.key > $1.key }
        case .oldest: candidates.sort { $0.key < $1.key }
        case .map, .kinds, .reclaim, .changes: break
        }
        return candidates.prefix(limit).map { row($0.node) }
    }

    /// ASCII case-insensitive substring search on raw UTF-8.
    private nonisolated static func nameContains(
        _ name: ArraySlice<UInt8>, _ needle: [UInt8]
    )
        -> Bool
    {
        let m = needle.count
        guard m > 0, name.count >= m else { return false }
        let start = name.startIndex
        let last = name.count - m
        outer: for offset in 0...last {
            for j in 0..<m {
                var byte = name[start + offset + j]
                if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { byte += 32 }
                if byte != needle[j] { continue outer }
            }
            return true
        }
        return false
    }

    static func compactCount(_ value: UInt64) -> String {
        switch value {
        case 0..<1_000: return "\(value)"
        case 1_000..<1_000_000: return String(format: "%.1f k", Double(value) / 1_000)
        default: return String(format: "%.2f M", Double(value) / 1_000_000)
        }
    }
}
