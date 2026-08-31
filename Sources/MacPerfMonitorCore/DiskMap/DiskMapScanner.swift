// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import os

/// Knobs for one scan. Defaults are what the app uses; the CLI exposes them
/// so the defaults can be measured rather than guessed.
public struct DiskMapScanOptions: Sendable {
    /// Files smaller than this are folded into per-kind small-file nodes
    /// (see `FileTreeBuilder`). Nil picks a threshold from the volume's used
    /// inode count; 0 disables folding.
    public var smallFileThreshold: UInt64?
    /// A directory folds only when it has more small files than this, so a
    /// tidy folder of a dozen documents keeps every file visible.
    public var minimumSmallFilesToFold: Int
    public var workerCount: Int
    /// Ask for `ATTR_CMNEXT_PRIVATESIZE` on every entry (exact clone and
    /// snapshot accounting in the tree). Off by default: measured over 2 M
    /// entries it turned a 15 s scan into a 23 s one, so the app fetches the
    /// private size lazily for the item the user is looking at instead.
    public var fetchPrivateSize: Bool
    /// How often a progress event with a pruned preview is emitted.
    public var previewInterval: TimeInterval
    public var qualityOfService: QualityOfService
    /// Mark the scan's disk reads as utility-class so foreground work is not
    /// starved. Off only for benchmarking.
    public var throttleIO: Bool
    /// Ask `tmutil` for the local snapshot count when the scan finishes.
    public var countLocalSnapshots: Bool
    /// Replace the filesystem reader (tests use a synthetic one).
    public var lister: (any DirectoryLister)?

    public init(
        smallFileThreshold: UInt64? = nil,
        minimumSmallFilesToFold: Int = 24,
        workerCount: Int = DiskMapScanOptions.defaultWorkerCount,
        fetchPrivateSize: Bool = false,
        previewInterval: TimeInterval = 0.5,
        qualityOfService: QualityOfService = .utility,
        throttleIO: Bool = true,
        countLocalSnapshots: Bool = true,
        lister: (any DirectoryLister)? = nil
    ) {
        self.smallFileThreshold = smallFileThreshold
        self.minimumSmallFilesToFold = minimumSmallFilesToFold
        self.workerCount = workerCount
        self.fetchPrivateSize = fetchPrivateSize
        self.previewInterval = previewInterval
        self.qualityOfService = qualityOfService
        self.throttleIO = throttleIO
        self.countLocalSnapshots = countLocalSnapshots
        self.lister = lister
    }

    /// Measured on an M3 Pro over 145 k warm entries: 1 worker 11.3 s, 2 4.4 s,
    /// 4 2.4 s, 6 1.9 s, 8 1.7 s. Six takes most of the win without occupying
    /// every core of a smaller chip while the sampler keeps ticking.
    public static let defaultWorkerCount = min(
        6, max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// Fold nothing on a small volume, 16 KiB on a typical one, 64 KiB on a
    /// very large one. The point is bounding node count (about 80 bytes each)
    /// without hiding anything the map could ever draw.
    public static func adaptiveThreshold(usedInodes: UInt64?) -> UInt64 {
        guard let usedInodes else { return 16_384 }
        if usedInodes < 250_000 { return 0 }
        if usedInodes < 3_500_000 { return 16_384 }
        return 65_536
    }
}

public struct DiskMapScanProgress: Sendable, Equatable {
    public var scope: DiskMapScope
    public var entries: UInt64
    public var directories: UInt64
    public var bytes: UInt64
    /// Canonical path of the directory most recently merged.
    public var currentPath: String
    public var elapsed: TimeInterval
    public var counts: DiskMapScanCounts
    /// Used inodes on the volume when the scope is a whole volume; the
    /// denominator for a determinate progress bar.
    public var expectedEntries: UInt64?

    public var fraction: Double? {
        guard let expectedEntries, expectedEntries > 0 else { return nil }
        return min(1, Double(entries) / Double(expectedEntries))
    }
}

public enum DiskMapScanError: Error, LocalizedError, Sendable, Equatable {
    case rootNotADirectory(String)
    case rootNotReadable(String, DirectoryListingError)

    public var errorDescription: String? {
        switch self {
        case .rootNotADirectory(let path):
            return "\(path) is not a folder."
        case .rootNotReadable(let path, let reason):
            switch reason {
            case .notPermitted:
                return
                    "macOS did not allow access to \(path). Grant Full Disk Access and try again."
            case .accessDenied:
                return "\(path) is not readable by your user account."
            case .vanished:
                return "\(path) no longer exists."
            case .dataless:
                return "\(path) is stored in iCloud and has not been downloaded."
            case .notSupported, .other:
                return "\(path) could not be read."
            }
        }
    }
}

/// A finished scan: the frozen tree plus everything needed to explain it.
public struct DiskMapSnapshot: Sendable {
    public var scope: DiskMapScope
    /// The directory that was opened (the Data volume root for the startup
    /// disk); node paths hang off this.
    public var rootPath: String
    public var tree: FileTree
    public var reconciliation: DiskMapReconciliation
    public var scannedAt: Date
    public var duration: TimeInterval
    /// True when the scan was cancelled: the tree is what had been read.
    public var partial: Bool
    public var smallFileThreshold: UInt64
    /// Bumped by in-place edits (a trash) so views can compare cheaply.
    public var revision: Int

    public init(
        scope: DiskMapScope, rootPath: String, tree: FileTree,
        reconciliation: DiskMapReconciliation, scannedAt: Date, duration: TimeInterval,
        partial: Bool, smallFileThreshold: UInt64, revision: Int
    ) {
        self.scope = scope
        self.rootPath = rootPath
        self.tree = tree
        self.reconciliation = reconciliation
        self.scannedAt = scannedAt
        self.duration = duration
        self.partial = partial
        self.smallFileThreshold = smallFileThreshold
        self.revision = revision
    }

    /// The path the user should see (and Finder should open) for a node.
    public func displayPath(of node: Int32) -> String {
        FirmlinkMap.system.canonicalPath(tree.path(of: node, rootPath: rootPath))
    }

    /// The path to open on disk for a node.
    public func filesystemPath(of node: Int32) -> String {
        tree.path(of: node, rootPath: rootPath)
    }
}

public enum DiskMapScanEvent: Sendable {
    case progress(DiskMapScanProgress, DiskMapPreviewNode)
    case completed(DiskMapSnapshot)
    case failed(DiskMapScanError)
}

/// Lets a blocking caller (the CLI on SIGINT) stop a scan.
public final class DiskMapCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (() -> Void)?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let handler = self.handler
        lock.unlock()
        handler?()
    }

    func attach(_ handler: @escaping () -> Void) {
        lock.lock()
        self.handler = handler
        let already = cancelled
        lock.unlock()
        if already { handler() }
    }
}

/// Walks a scope and builds a `FileTree`. One coordinator thread owns the
/// tree; a handful of worker threads read directories. Threads rather than
/// tasks because the IO policies that keep the scan polite (no dataless
/// materialisation, utility-class disk reads) are per thread, and a
/// cooperative-pool thread is shared with everything else in the process.
///
/// Work is a LIFO stack of directories (depth-first keeps the frontier small)
/// and results flow back through a bounded inbox, so a fast reader cannot
/// outrun the coordinator's memory. Cancelling finalises what has been read
/// into a partial snapshot instead of throwing the work away.
public final class DiskMapScanner: @unchecked Sendable {
    private let volumeSource: @Sendable () -> [VolumeInfo]
    private let snapshotCounter: @Sendable (String) -> Int?

    public init(
        volumeSource: @escaping @Sendable () -> [VolumeInfo] = { VolumeReader().read().volumes },
        snapshotCounter: @escaping @Sendable (String) -> Int? = {
            LocalSnapshotCounter.count(mountPoint: $0)
        }
    ) {
        self.volumeSource = volumeSource
        self.snapshotCounter = snapshotCounter
    }

    /// Progress events at `options.previewInterval`, then exactly one
    /// `completed` or `failed`, then the stream ends. Dropping the stream
    /// cancels the scan.
    public func scan(
        _ scope: DiskMapScope, options: DiskMapScanOptions = DiskMapScanOptions()
    )
        -> AsyncStream<DiskMapScanEvent>
    {
        AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let job = DiskMapScanJob(
                scope: scope, options: options, volumeSource: volumeSource,
                snapshotCounter: snapshotCounter
            ) { event in
                continuation.yield(event)
                switch event {
                case .completed, .failed: continuation.finish()
                case .progress: break
                }
            }
            continuation.onTermination = { _ in job.cancel() }
            job.start()
        }
    }

    /// Synchronous variant for the CLI and for tests.
    public func scanBlocking(
        _ scope: DiskMapScope,
        options: DiskMapScanOptions = DiskMapScanOptions(),
        cancellation: DiskMapCancellationToken? = nil,
        onProgress: ((DiskMapScanProgress, DiskMapPreviewNode) -> Void)? = nil
    ) throws -> DiskMapSnapshot {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let job = DiskMapScanJob(
            scope: scope, options: options, volumeSource: volumeSource,
            snapshotCounter: snapshotCounter
        ) { event in
            switch event {
            case .progress(let progress, let preview):
                onProgress?(progress, preview)
            case .completed(let snapshot):
                box.result = .success(snapshot)
                done.signal()
            case .failed(let error):
                box.result = .failure(error)
                done.signal()
            }
        }
        cancellation?.attach { job.cancel() }
        job.start()
        done.wait()
        return try box.result!.get()
    }

    private final class ResultBox: @unchecked Sendable {
        var result: Result<DiskMapSnapshot, DiskMapScanError>?
    }
}

// MARK: - The job

final class DiskMapScanJob: @unchecked Sendable {
    private static let log = Logger(subsystem: "uk.co.bzwrd.macperfmonitor", category: "diskmap")

    private struct DirectoryJob {
        var node: Int32
        var path: String
    }

    private enum Message {
        case listing(node: Int32, path: String, DirectoryListing)
        case failure(node: Int32, path: String, DirectoryListingError)
    }

    private let scope: DiskMapScope
    private let options: DiskMapScanOptions
    private let volumeSource: @Sendable () -> [VolumeInfo]
    private let snapshotCounter: @Sendable (String) -> Int?
    private let emit: (DiskMapScanEvent) -> Void

    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)
    private let startFlag = OSAllocatedUnfairLock(initialState: false)
    private let stack = WorkStack()
    private let inbox = Inbox(capacity: 64)
    private let workersDone = DispatchGroup()

    // Coordinator-thread state.
    private let builder = FileTreeBuilder()
    private var counts = DiskMapScanCounts()
    private var hardLinks = Set<UInt64>()
    private var threshold: UInt64 = 0
    private var lister: any DirectoryLister = BulkAttributeLister()
    private var outstanding = 0
    private var lastPath = ""

    init(
        scope: DiskMapScope,
        options: DiskMapScanOptions,
        volumeSource: @escaping @Sendable () -> [VolumeInfo],
        snapshotCounter: @escaping @Sendable (String) -> Int?,
        emit: @escaping (DiskMapScanEvent) -> Void
    ) {
        self.scope = scope
        self.options = options
        self.volumeSource = volumeSource
        self.snapshotCounter = snapshotCounter
        self.emit = emit
    }

    var isCancelled: Bool { cancelFlag.withLock { $0 } }

    func cancel() {
        let first = cancelFlag.withLock { flag -> Bool in
            let was = flag
            flag = true
            return !was
        }
        guard first else { return }
        stack.finish()
        inbox.close()
    }

    func start() {
        let first = startFlag.withLock { flag -> Bool in
            let was = flag
            flag = true
            return !was
        }
        guard first else { return }
        let thread = Thread { [self] in run() }
        thread.name = "uk.co.bzwrd.macperfmonitor.diskmap.coordinator"
        thread.qualityOfService = options.qualityOfService
        thread.start()
    }

    // MARK: Coordinator

    private func run() {
        Self.applyThreadPolicies(throttle: options.throttleIO)
        let startedAt = Date()
        let startClock = DispatchTime.now()
        let rootPath = scope.scanRoot

        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else {
            emit(.failed(.rootNotReadable(rootPath, DirectoryListingError(errno: errno))))
            return
        }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else {
            emit(.failed(.rootNotADirectory(rootPath)))
            return
        }

        let mountPoint = DiskMapScope.mountPoint(ofPath: rootPath) ?? rootPath
        let usedInodes = DiskMapScope.usedInodes(ofPath: rootPath)
        threshold =
            options.smallFileThreshold
            ?? DiskMapScanOptions.adaptiveThreshold(usedInodes: usedInodes)
        let usedBefore = volumeSource().first { $0.mountPoint == mountPoint }?.usedBytes

        lister = options.lister ?? BulkAttributeLister(fetchPrivateSize: options.fetchPrivateSize)
        let rootListing: DirectoryListing
        do {
            rootListing = try listRoot(rootPath)
        } catch let error as DirectoryListingError {
            emit(.failed(.rootNotReadable(rootPath, error)))
            return
        } catch {
            emit(.failed(.rootNotReadable(rootPath, .other(errno: 0))))
            return
        }

        Self.log.notice(
            "Disk Map scan start: \(rootPath, privacy: .public) threshold \(self.threshold) workers \(self.options.workerCount)"
        )

        // Folding leaves roughly six nodes in ten for a whole volume; reserving
        // that up front avoids the last array doubling (which peaked RSS at
        // twice the arena on a 3 M-inode disk). Folder scopes grow from zero.
        if scope.isWholeVolume, let usedInodes {
            builder.reserve(Int(min(usedInodes * 3 / 5, 4_000_000)))
        }
        let rootSeconds = rootStat.st_mtimespec.tv_sec
        builder.appendRoot(
            name: scope.rootName, fileID: rootStat.st_ino,
            modified: rootSeconds > 0 ? UInt32(clamping: rootSeconds) : 0,
            flags: Self.flags(forBSDFlags: rootStat.st_flags, name: []))
        merge(rootListing, into: FileTree.root, path: rootPath)

        let workerCount = max(1, options.workerCount)
        for index in 0..<workerCount {
            workersDone.enter()
            let thread = Thread { [self] in
                workerLoop()
                workersDone.leave()
            }
            thread.name = "uk.co.bzwrd.macperfmonitor.diskmap.worker-\(index)"
            thread.qualityOfService = options.qualityOfService
            thread.start()
        }

        var lastPreview = startClock
        let previewNanos = UInt64(max(0.001, options.previewInterval) * 1_000_000_000)
        while outstanding > 0, !isCancelled {
            guard let message = inbox.take() else { break }
            outstanding -= 1
            handle(message)
            let now = DispatchTime.now()
            if now.uptimeNanoseconds - lastPreview.uptimeNanoseconds >= previewNanos {
                emitProgress(startedAt: startedAt, usedInodes: usedInodes)
                lastPreview = now
            }
        }

        stack.finish()
        _ = workersDone.wait(timeout: .now() + 5)
        // Listings that landed after the loop stopped (cancellation) are
        // still good data; fold them in rather than drop them.
        while let message = inbox.takeIfAvailable() {
            outstanding -= 1
            handle(message)
        }

        let partial = isCancelled
        let tree = builder.build()
        let volumesAfter = volumeSource()
        let volume = volumesAfter.first { $0.mountPoint == mountPoint }
        let snapshots = options.countLocalSnapshots ? snapshotCounter(mountPoint) : nil
        let reconciliation = DiskMapReconciliation.compute(
            scope: scope, mountPoint: mountPoint, volume: volume, allVolumes: volumesAfter,
            usedBefore: usedBefore, scannedBytes: tree.bytes[0], sharedBytes: tree.shared[0],
            scannedItems: UInt64(tree.count[0]), counts: counts, localSnapshotCount: snapshots)
        let duration = Date().timeIntervalSince(startedAt)
        Self.log.notice(
            "Disk Map scan \(partial ? "cancelled" : "done", privacy: .public): \(tree.nodeCount) nodes, \(self.counts.entries) entries, \(tree.bytes[0]) bytes in \(duration, format: .fixed(precision: 1))s"
        )
        emit(
            .completed(
                DiskMapSnapshot(
                    scope: scope, rootPath: rootPath, tree: tree, reconciliation: reconciliation,
                    scannedAt: Date(), duration: duration, partial: partial,
                    smallFileThreshold: threshold, revision: 1)))
    }

    /// The root listing doubles as the filesystem probe: `ENOTSUP` from the
    /// bulk reader means this volume wants the readdir path for the whole scan.
    private func listRoot(_ path: String) throws -> DirectoryListing {
        do {
            return try lister.list(path: path)
        } catch DirectoryListingError.notSupported where options.lister == nil {
            lister = ReaddirLister()
            return try lister.list(path: path)
        }
    }

    private func handle(_ message: Message) {
        switch message {
        case .listing(let node, let path, let listing):
            merge(listing, into: node, path: path)
        case .failure(let node, let path, let error):
            if error == .notPermitted, builder.flags(of: node).contains(.dataVault) {
                // A vault refuses everyone without the entitlement; keep it
                // out of the Full Disk Access count so the banner stays true.
                counts.dataVaults += 1
                lastPath = path
                return
            }
            builder.markUnlisted(node, error.nodeFlag)
            switch error {
            case .notPermitted: counts.notPermitted += 1
            case .accessDenied: counts.accessDenied += 1
            case .vanished: counts.vanished += 1
            case .dataless: counts.datalessDirectories += 1
            case .notSupported, .other: counts.unreadable += 1
            }
            lastPath = path
        }
    }

    /// Turn one listing into the directory's child block, dedupe hard links,
    /// fold small files, and queue the subdirectories worth descending into.
    private func merge(_ listing: DirectoryListing, into node: Int32, path: String) {
        counts.directories += 1
        counts.entries += UInt64(listing.entries.count)
        lastPath = path

        var block: [FileTreeBuilder.Entry] = []
        block.reserveCapacity(listing.entries.count)
        var small: [FileTreeBuilder.Entry] = []
        var childDirectories: [(offset: Int, path: String)] = []
        let basePath = path == "/" ? "" : path

        for raw in listing.entries {
            let name = listing.name(of: raw)
            if raw.error != 0 {
                counts.entryErrors += 1
                block.append(
                    FileTreeBuilder.Entry(
                        name: name, bytes: 0, fileID: raw.fileID, modified: raw.modified,
                        flags: [.unreadable], kind: .other))
                continue
            }
            var flags = Self.flags(forBSDFlags: raw.bsdFlags, name: name)

            switch raw.type {
            case .directory:
                flags.insert(.directory)
                let kind = name.withUnsafeBufferPointer {
                    FileKindClassifier.kind(forNameBytes: $0, isDirectory: true)
                }
                if kind != .folder { flags.insert(.package) }
                var descend = true
                if raw.isMountPoint {
                    flags.insert(.separateVolume)
                    counts.separateVolumes += 1
                    descend = false
                } else if raw.bsdFlags & UInt32(SF_DATALESS) != 0 {
                    counts.datalessDirectories += 1
                    descend = false
                }
                if descend {
                    let childPath = basePath + "/" + String(decoding: name, as: UTF8.self)
                    childDirectories.append((block.count, childPath))
                }
                block.append(
                    FileTreeBuilder.Entry(
                        name: name, bytes: 0, fileID: raw.fileID, modified: raw.modified,
                        count: 1, flags: flags, kind: kind))

            case .regular:
                var bytes = raw.allocated
                var shared = raw.privateSize < raw.allocated ? raw.allocated - raw.privateSize : 0
                if raw.bsdFlags & UInt32(SF_DATALESS) != 0 { counts.datalessFiles += 1 }
                if raw.extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 {
                    flags.insert(.mayShareBlocks)
                    counts.sharedBlockFiles += 1
                }
                if raw.linkCount > 1, !hardLinks.insert(raw.fileID).inserted {
                    flags.insert(.hardLinkDuplicate)
                    bytes = 0
                    shared = 0
                    counts.hardLinkDuplicates += 1
                }
                let kind = name.withUnsafeBufferPointer {
                    FileKindClassifier.kind(forNameBytes: $0, isDirectory: false)
                }
                let entry = FileTreeBuilder.Entry(
                    name: name, bytes: bytes, shared: shared, fileID: raw.fileID,
                    modified: raw.modified, count: 1, flags: flags, kind: kind)
                if threshold > 0, bytes < threshold {
                    small.append(entry)
                } else {
                    counts.files += 1
                    block.append(entry)
                }

            case .symlink:
                flags.insert(.symlink)
                counts.symlinks += 1
                let entry = FileTreeBuilder.Entry(
                    name: name, bytes: raw.allocated, fileID: raw.fileID,
                    modified: raw.modified, count: 1, flags: flags, kind: .other)
                if threshold > 0 { small.append(entry) } else { block.append(entry) }

            case .other:
                let entry = FileTreeBuilder.Entry(
                    name: name, bytes: 0, fileID: raw.fileID, modified: raw.modified, count: 1,
                    flags: flags, kind: .other)
                if threshold > 0 { small.append(entry) } else { block.append(entry) }
            }
        }

        if small.count > options.minimumSmallFilesToFold {
            counts.foldedFiles += UInt64(small.count)
            block.append(contentsOf: Self.folds(of: small))
        } else {
            counts.files += UInt64(small.filter { !$0.flags.contains(.symlink) }.count)
            block.append(contentsOf: small)
        }

        let range = builder.appendChildren(of: node, block)
        for child in childDirectories {
            stack.push(DirectoryJob(node: range.lowerBound + Int32(child.offset), path: child.path))
            outstanding += 1
        }
    }

    /// One synthetic child per kind present, in display order, carrying the
    /// exact bytes and count of the files it stands in for.
    private static func folds(of small: [FileTreeBuilder.Entry]) -> [FileTreeBuilder.Entry] {
        struct Accumulator {
            var bytes: UInt64 = 0
            var shared: UInt64 = 0
            var count: UInt32 = 0
            var modified: UInt32 = 0
        }
        var byKind: [FileKind: Accumulator] = [:]
        for entry in small {
            var acc = byKind[entry.kind] ?? Accumulator()
            acc.bytes &+= entry.bytes
            acc.shared &+= entry.shared
            acc.count &+= 1
            acc.modified = max(acc.modified, entry.modified)
            byKind[entry.kind] = acc
        }
        var folds: [FileTreeBuilder.Entry] = []
        for kind in FileKind.displayOrder {
            guard let acc = byKind[kind] else { continue }
            folds.append(
                FileTreeBuilder.Entry(
                    name: [], bytes: acc.bytes, shared: acc.shared, fileID: 0,
                    modified: acc.modified, count: acc.count, flags: [.smallFilesFold],
                    kind: kind))
        }
        return folds
    }

    private func emitProgress(startedAt: Date, usedInodes: UInt64?) {
        let total = builder.totalBytes
        let progress = DiskMapScanProgress(
            scope: scope, entries: counts.entries, directories: counts.directories,
            bytes: total, currentPath: FirmlinkMap.system.canonicalPath(lastPath),
            elapsed: Date().timeIntervalSince(startedAt), counts: counts,
            expectedEntries: scope.isWholeVolume ? usedInodes : nil)
        let preview = builder.preview(
            depthLimit: 3, minimumBytes: max(1 << 20, total / 1000), maxChildren: 48)
        emit(.progress(progress, preview))
    }

    private static func flags(forBSDFlags bsd: UInt32, name: ArraySlice<UInt8>) -> FileNodeFlags {
        var flags: FileNodeFlags = []
        if bsd & UInt32(UF_HIDDEN) != 0 || name.first == UInt8(ascii: ".") { flags.insert(.hidden) }
        if bsd & UInt32(SF_RESTRICTED) != 0 { flags.insert(.restricted) }
        if bsd & UInt32(SF_IMMUTABLE) != 0 { flags.insert(.immutable) }
        if bsd & UInt32(SF_DATALESS) != 0 { flags.insert(.dataless) }
        if bsd & UInt32(UF_DATAVAULT) != 0 { flags.insert(.dataVault) }
        return flags
    }

    // MARK: Workers

    private func workerLoop() {
        Self.applyThreadPolicies(throttle: options.throttleIO)
        while let job = stack.pop() {
            if isCancelled { break }
            do {
                let listing = try lister.list(path: job.path)
                inbox.post(.listing(node: job.node, path: job.path, listing))
            } catch let error as DirectoryListingError {
                inbox.post(.failure(node: job.node, path: job.path, error))
            } catch {
                inbox.post(.failure(node: job.node, path: job.path, .other(errno: 0)))
            }
        }
    }

    /// Per-thread IO policies: never materialise dataless (iCloud) content,
    /// never bump access times, and read at utility priority so the person's
    /// foreground work keeps the disk.
    static func applyThreadPolicies(throttle: Bool) {
        _ = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        _ = setiopolicy_np(
            IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_THREAD, IOPOL_ATIME_UPDATES_OFF)
        if throttle {
            _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_UTILITY)
        }
    }

    // MARK: Queues

    /// Directories waiting to be read. LIFO: the newest (deepest) first, so
    /// the frontier stays about depth times fan-out instead of the whole
    /// breadth of a level.
    private final class WorkStack {
        private let condition = NSCondition()
        private var jobs: [DirectoryJob] = []
        private var finished = false

        func push(_ job: DirectoryJob) {
            condition.lock()
            jobs.append(job)
            condition.signal()
            condition.unlock()
        }

        /// Blocks until a job is available; nil once finished and drained.
        func pop() -> DirectoryJob? {
            condition.lock()
            defer { condition.unlock() }
            while jobs.isEmpty, !finished {
                condition.wait()
            }
            return jobs.popLast()
        }

        func finish() {
            condition.lock()
            finished = true
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Results flowing back to the coordinator, bounded so readers wait for
    /// the merger rather than piling listings up in memory.
    private final class Inbox {
        private let condition = NSCondition()
        private var items: [Message] = []
        private var head = 0
        private var closed = false
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
        }

        func post(_ message: Message) {
            condition.lock()
            while items.count - head >= capacity, !closed {
                condition.wait()
            }
            if !closed {
                items.append(message)
                condition.broadcast()
            }
            condition.unlock()
        }

        /// Blocks until a message arrives; nil once closed and empty.
        func take() -> Message? {
            condition.lock()
            defer { condition.unlock() }
            while items.count == head, !closed {
                condition.wait()
            }
            return dequeue()
        }

        func takeIfAvailable() -> Message? {
            condition.lock()
            defer { condition.unlock() }
            return dequeue()
        }

        func close() {
            condition.lock()
            closed = true
            condition.broadcast()
            condition.unlock()
        }

        private func dequeue() -> Message? {
            guard items.count > head else { return nil }
            let message = items[head]
            head += 1
            if head >= 256 || head == items.count {
                items.removeFirst(head)
                head = 0
            }
            condition.broadcast()
            return message
        }
    }
}
