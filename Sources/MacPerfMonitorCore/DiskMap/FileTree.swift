// SPDX-License-Identifier: MIT

import Foundation

/// Per-node facts that do not fit a size or a date. Raw values are persisted
/// in snapshots; append new bits, never reassign them.
public struct FileNodeFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = FileNodeFlags(rawValue: 1 << 0)
    /// A directory whose extension marks it as a package (app, bundle,
    /// library). Scanned fully, drawn as a leaf until drilled into.
    public static let package = FileNodeFlags(rawValue: 1 << 1)
    public static let symlink = FileNodeFlags(rawValue: 1 << 2)
    /// A later encounter of a hard-linked file already counted elsewhere.
    /// Carries zero bytes so the total matches `du`.
    public static let hardLinkDuplicate = FileNodeFlags(rawValue: 1 << 3)
    /// `EF_MAY_SHARE_BLOCKS`: an APFS clone or a file held by a snapshot.
    public static let mayShareBlocks = FileNodeFlags(rawValue: 1 << 4)
    /// `SF_DATALESS`: an evicted iCloud or file-provider item. Zero local
    /// bytes; the scanner never materialises it.
    public static let dataless = FileNodeFlags(rawValue: 1 << 5)
    /// `SF_RESTRICTED`: SIP-protected, cannot be trashed.
    public static let restricted = FileNodeFlags(rawValue: 1 << 6)
    /// A directory that returned EPERM: TCC denied it, Full Disk Access fixes it.
    public static let notPermitted = FileNodeFlags(rawValue: 1 << 7)
    /// A directory that returned EACCES: Unix permissions, owned by another user.
    public static let accessDenied = FileNodeFlags(rawValue: 1 << 8)
    /// A directory that failed for any other reason (the errno is not kept).
    public static let unreadable = FileNodeFlags(rawValue: 1 << 9)
    /// A mount point or automount trigger: another volume lives here, never
    /// descended, zero bytes.
    public static let separateVolume = FileNodeFlags(rawValue: 1 << 10)
    /// A synthetic child holding a directory's many small files of one kind.
    /// `count` is how many, `bytes` their exact total.
    public static let smallFilesFold = FileNodeFlags(rawValue: 1 << 11)
    /// `UF_HIDDEN` or a leading dot.
    public static let hidden = FileNodeFlags(rawValue: 1 << 12)
    /// Moved to the Trash from inside the app after the scan; bytes were
    /// re-homed into the In Trash bucket.
    public static let trashed = FileNodeFlags(rawValue: 1 << 13)
    /// `SF_IMMUTABLE`: locked by the system.
    public static let immutable = FileNodeFlags(rawValue: 1 << 14)
    /// `UF_DATAVAULT`: a macOS data vault, readable only with an entitlement.
    /// Full Disk Access does not open these, so an EPERM here is not the
    /// user's to fix and must not feed the "grant access" banner.
    public static let dataVault = FileNodeFlags(rawValue: 1 << 15)

    /// Flags that mean a directory's contents are not in the tree.
    public static let unlisted: FileNodeFlags = [
        .notPermitted, .accessDenied, .unreadable, .separateVolume, .dataless, .dataVault,
    ]
}

/// The scanned filesystem as a compact arena: one entry per node in parallel
/// arrays indexed by `Int32`, names in a single UTF-8 buffer. A directory's
/// children occupy one contiguous index range (`firstChild ..< firstChild +
/// childCount`) because a listing is appended in one go, which is what makes
/// the arena cheap to walk, to persist, and to bounds-check on load. Index 0
/// is the scan root. Children always have higher indices than their parent.
///
/// Sizes are allocated bytes (what the file occupies on disk), never logical
/// length: sparse and compressed files count what they actually use, which is
/// the only number that reconciles against the volume's used space.
///
/// Values are immutable once built; the scanner produces one through
/// `FileTreeBuilder` and the app treats the result as a frozen snapshot.
public struct FileTree: Sendable {
    public private(set) var parent: [Int32]
    public private(set) var firstChild: [Int32]
    public private(set) var childCount: [Int32]
    /// Allocated bytes: the file's own for a leaf, the subtree total for a
    /// directory (folds and unlisted directories included).
    public private(set) var bytes: [UInt64]
    /// Bytes shared with a clone or trapped in a snapshot (allocated minus
    /// `ATTR_CMNEXT_PRIVATESIZE`), aggregated like `bytes`. All zero when the
    /// scan did not fetch private sizes.
    public private(set) var shared: [UInt64]
    /// `ATTR_CMN_FILEID`, so an action taken later can confirm the entry is
    /// still the one the user looked at.
    public private(set) var fileID: [UInt64]
    /// Modification time as whole seconds since 1970.
    public private(set) var modified: [UInt32]
    /// Items under a directory (files, folds and directories, recursively);
    /// 1 for a file; the folded file count for a fold.
    public private(set) var count: [UInt32]
    public private(set) var flags: [FileNodeFlags]
    public private(set) var kind: [FileKind]
    /// `nameBytes[nameOffsets[i] ..< nameOffsets[i + 1]]` is node i's name.
    public private(set) var nameOffsets: [UInt32]
    public private(set) var nameBytes: [UInt8]

    public var nodeCount: Int { parent.count }
    public var isEmpty: Bool { parent.isEmpty }

    public static let root: Int32 = 0

    init(
        parent: [Int32], firstChild: [Int32], childCount: [Int32], bytes: [UInt64],
        shared: [UInt64], fileID: [UInt64], modified: [UInt32], count: [UInt32],
        flags: [FileNodeFlags], kind: [FileKind], nameOffsets: [UInt32], nameBytes: [UInt8]
    ) {
        self.parent = parent
        self.firstChild = firstChild
        self.childCount = childCount
        self.bytes = bytes
        self.shared = shared
        self.fileID = fileID
        self.modified = modified
        self.count = count
        self.flags = flags
        self.kind = kind
        self.nameOffsets = nameOffsets
        self.nameBytes = nameBytes
    }

    public static let empty = FileTree(
        parent: [], firstChild: [], childCount: [], bytes: [], shared: [], fileID: [],
        modified: [], count: [], flags: [], kind: [], nameOffsets: [0], nameBytes: [])

    // MARK: - Accessors

    public func name(of node: Int32) -> String {
        let i = Int(node)
        let start = Int(nameOffsets[i])
        let end = Int(nameOffsets[i + 1])
        return String(decoding: nameBytes[start..<end], as: UTF8.self)
    }

    public func nameBytes(of node: Int32) -> ArraySlice<UInt8> {
        let i = Int(node)
        return nameBytes[Int(nameOffsets[i])..<Int(nameOffsets[i + 1])]
    }

    public func children(of node: Int32) -> Range<Int32> {
        let i = Int(node)
        let first = firstChild[i]
        return first..<(first + childCount[i])
    }

    public func isDirectory(_ node: Int32) -> Bool {
        flags[Int(node)].contains(.directory)
    }

    public func modifiedDate(of node: Int32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(modified[Int(node)]))
    }

    /// Root first, node last.
    public func ancestry(of node: Int32) -> [Int32] {
        var chain: [Int32] = [node]
        var current = node
        while current != Self.root {
            current = parent[Int(current)]
            chain.append(current)
        }
        chain.reverse()
        return chain
    }

    public func depth(of node: Int32) -> Int {
        var depth = 0
        var current = node
        while current != Self.root {
            current = parent[Int(current)]
            depth += 1
        }
        return depth
    }

    /// The node's path under `rootPath` (the scan root, not the display
    /// root; see `FirmlinkMap` for the canonical form). Folds have no path of
    /// their own and return their parent's.
    public func path(of node: Int32, rootPath: String) -> String {
        var components: [ArraySlice<UInt8>] = []
        var current = node
        while current != Self.root {
            if !flags[Int(current)].contains(.smallFilesFold) {
                components.append(nameBytes(of: current))
            }
            current = parent[Int(current)]
        }
        guard !components.isEmpty else { return rootPath }
        var bytes = Array(rootPath.utf8)
        if bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
        for component in components.reversed() {
            bytes.append(UInt8(ascii: "/"))
            bytes.append(contentsOf: component)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Children of `node` sorted by bytes, largest first. Sorting is done at
    /// query time on the few thousand nodes a view can show rather than once
    /// over the whole arena, because the arena keeps children contiguous.
    public func childrenBySize(of node: Int32) -> [Int32] {
        Array(children(of: node)).sorted { bytes[Int($0)] > bytes[Int($1)] }
    }

    /// Whether `ancestor` is on `node`'s parent chain (or is the node).
    public func node(_ node: Int32, isWithin ancestor: Int32) -> Bool {
        var current = node
        while true {
            if current == ancestor { return true }
            if current == Self.root { return false }
            current = parent[Int(current)]
        }
    }

    /// Re-home a trashed node's bytes: the node keeps its own figures and
    /// gains `.trashed`; every ancestor loses the bytes, shared and count.
    /// Returns the bytes removed from the ancestors.
    @discardableResult
    public mutating func markTrashed(_ node: Int32) -> UInt64 {
        let i = Int(node)
        guard !flags[i].contains(.trashed) else { return 0 }
        flags[i].insert(.trashed)
        let removedBytes = bytes[i]
        let removedShared = shared[i]
        let removedCount = count[i]
        var current = node
        while current != Self.root {
            current = parent[Int(current)]
            let c = Int(current)
            bytes[c] = bytes[c] >= removedBytes ? bytes[c] - removedBytes : 0
            shared[c] = shared[c] >= removedShared ? shared[c] - removedShared : 0
            count[c] = count[c] >= removedCount ? count[c] - removedCount : 0
        }
        return removedBytes
    }

    /// Structural validation for data read from disk: every index must point
    /// inside the arena, parents must precede children, child ranges must be
    /// in bounds, and the name offsets must be monotonic and end at the name
    /// buffer's end. Cheap (one linear pass) and the reason a corrupt
    /// snapshot file can never crash a walk.
    public var isStructurallyValid: Bool {
        let n = parent.count
        guard firstChild.count == n, childCount.count == n, bytes.count == n,
            shared.count == n, fileID.count == n, modified.count == n, count.count == n,
            flags.count == n, kind.count == n, nameOffsets.count == n + 1
        else { return false }
        guard nameOffsets.first == 0, Int(nameOffsets[n]) == nameBytes.count else { return false }
        if n == 0 { return true }
        guard parent[0] == 0 else { return false }
        for i in 0..<n {
            if i > 0 {
                let p = parent[i]
                guard p >= 0, Int(p) < i else { return false }
            }
            let c = childCount[i]
            guard c >= 0 else { return false }
            if c > 0 {
                let first = firstChild[i]
                guard first > Int32(i), Int(first) + Int(c) <= n else { return false }
            }
            guard nameOffsets[i] <= nameOffsets[i + 1] else { return false }
        }
        return true
    }
}

/// Single-writer builder for `FileTree`. The scanner's coordinator owns one,
/// appends each directory listing as one contiguous block of children, and
/// keeps subtree totals current on the way (a walk up the parent chain per
/// listing) so previews can be cut from a half-built tree without a second
/// pass.
public final class FileTreeBuilder {
    private var parent: [Int32] = []
    private var firstChild: [Int32] = []
    private var childCount: [Int32] = []
    private var bytes: [UInt64] = []
    private var shared: [UInt64] = []
    private var fileID: [UInt64] = []
    private var modified: [UInt32] = []
    private var count: [UInt32] = []
    private var flags: [FileNodeFlags] = []
    private var kind: [FileKind] = []
    private var nameOffsets: [UInt32] = [0]
    private var nameBytes: [UInt8] = []

    public init(expectedNodes: Int = 0) {
        reserve(expectedNodes)
    }

    public var nodeCount: Int { parent.count }
    public var totalBytes: UInt64 { bytes.first ?? 0 }
    public var totalCount: UInt32 { count.first ?? 0 }

    public func reserve(_ nodes: Int) {
        guard nodes > 0 else { return }
        parent.reserveCapacity(nodes)
        firstChild.reserveCapacity(nodes)
        childCount.reserveCapacity(nodes)
        bytes.reserveCapacity(nodes)
        shared.reserveCapacity(nodes)
        fileID.reserveCapacity(nodes)
        modified.reserveCapacity(nodes)
        count.reserveCapacity(nodes)
        flags.reserveCapacity(nodes)
        kind.reserveCapacity(nodes)
        nameOffsets.reserveCapacity(nodes + 1)
        nameBytes.reserveCapacity(nodes * 20)
    }

    /// One node's facts as handed in by a listing.
    public struct Entry: Sendable {
        public var name: ArraySlice<UInt8>
        public var bytes: UInt64
        public var shared: UInt64
        public var fileID: UInt64
        public var modified: UInt32
        public var count: UInt32
        public var flags: FileNodeFlags
        public var kind: FileKind

        public init(
            name: ArraySlice<UInt8>, bytes: UInt64, shared: UInt64 = 0, fileID: UInt64 = 0,
            modified: UInt32 = 0, count: UInt32 = 1, flags: FileNodeFlags = [],
            kind: FileKind = .other
        ) {
            self.name = name
            self.bytes = bytes
            self.shared = shared
            self.fileID = fileID
            self.modified = modified
            self.count = count
            self.flags = flags
            self.kind = kind
        }
    }

    /// Must be the first call. The root's own bytes and count start at zero
    /// and accumulate as listings land.
    @discardableResult
    public func appendRoot(
        name: String, fileID: UInt64, modified: UInt32, flags: FileNodeFlags
    )
        -> Int32
    {
        precondition(parent.isEmpty, "root already appended")
        append(
            Entry(
                name: ArraySlice(name.utf8), bytes: 0, fileID: fileID, modified: modified,
                count: 0, flags: flags.union(.directory), kind: .folder),
            parent: 0)
        return 0
    }

    /// Append a directory's children as one contiguous block, then push the
    /// block's own bytes and count up through every ancestor. Directories in
    /// the block start with their own entry only (bytes 0, count 1); their
    /// listings arrive later and accumulate the same way.
    /// Returns the index range the children were given.
    @discardableResult
    public func appendChildren(of directory: Int32, _ entries: [Entry]) -> Range<Int32> {
        let d = Int(directory)
        precondition(d < parent.count, "unknown directory")
        precondition(childCount[d] == 0, "directory listed twice")
        let first = Int32(parent.count)
        var blockBytes: UInt64 = 0
        var blockShared: UInt64 = 0
        var blockCount: UInt32 = 0
        for entry in entries {
            append(entry, parent: directory)
            blockBytes &+= entry.bytes
            blockShared &+= entry.shared
            blockCount &+= entry.count
        }
        firstChild[d] = first
        childCount[d] = Int32(entries.count)
        accumulate(from: directory, bytes: blockBytes, shared: blockShared, count: blockCount)
        return first..<(first + Int32(entries.count))
    }

    /// Mark a directory whose listing failed. Its entry stays, so the map
    /// shows where the hole is.
    public func markUnlisted(_ directory: Int32, _ reason: FileNodeFlags) {
        flags[Int(directory)].insert(reason)
    }

    public func flags(of node: Int32) -> FileNodeFlags { flags[Int(node)] }
    public func bytes(of node: Int32) -> UInt64 { bytes[Int(node)] }
    public func count(of node: Int32) -> UInt32 { count[Int(node)] }
    public func kind(of node: Int32) -> FileKind { kind[Int(node)] }
    public func parent(of node: Int32) -> Int32 { parent[Int(node)] }
    public func childRange(of node: Int32) -> Range<Int32> {
        let i = Int(node)
        return firstChild[i]..<(firstChild[i] + childCount[i])
    }

    public func name(of node: Int32) -> String {
        let i = Int(node)
        return String(
            decoding: nameBytes[Int(nameOffsets[i])..<Int(nameOffsets[i + 1])], as: UTF8.self)
    }

    /// Freeze into a value. The builder is left empty; it is not reusable.
    public func build() -> FileTree {
        let tree = FileTree(
            parent: parent, firstChild: firstChild, childCount: childCount, bytes: bytes,
            shared: shared, fileID: fileID, modified: modified, count: count, flags: flags,
            kind: kind, nameOffsets: nameOffsets, nameBytes: nameBytes)
        parent = []
        firstChild = []
        childCount = []
        bytes = []
        shared = []
        fileID = []
        modified = []
        count = []
        flags = []
        kind = []
        nameOffsets = [0]
        nameBytes = []
        return tree
    }

    /// A pruned copy of the top of the tree for progressive rendering while
    /// the scan is still running: directories and files down to `depthLimit`
    /// whose bytes clear `minimumBytes`, largest first, at most `maxChildren`
    /// per level, with the remainder folded into one aggregate child.
    public func preview(
        depthLimit: Int, minimumBytes: UInt64, maxChildren: Int
    ) -> DiskMapPreviewNode {
        guard !parent.isEmpty else {
            return DiskMapPreviewNode(
                name: "", bytes: 0, count: 0, isDirectory: true, children: [], omittedBytes: 0,
                omittedCount: 0)
        }
        return previewNode(
            0, depth: 0, depthLimit: depthLimit, minimumBytes: minimumBytes,
            maxChildren: maxChildren)
    }

    // MARK: - Private

    private func append(_ entry: Entry, parent p: Int32) {
        parent.append(p)
        firstChild.append(0)
        childCount.append(0)
        bytes.append(entry.bytes)
        shared.append(entry.shared)
        fileID.append(entry.fileID)
        modified.append(entry.modified)
        count.append(entry.count)
        flags.append(entry.flags)
        kind.append(entry.kind)
        nameBytes.append(contentsOf: entry.name)
        nameOffsets.append(UInt32(nameBytes.count))
    }

    private func accumulate(
        from directory: Int32, bytes b: UInt64, shared s: UInt64, count c: UInt32
    ) {
        var current = directory
        while true {
            let i = Int(current)
            bytes[i] &+= b
            shared[i] &+= s
            count[i] &+= c
            if current == 0 { break }
            current = parent[i]
        }
    }

    private func previewNode(
        _ node: Int32, depth: Int, depthLimit: Int, minimumBytes: UInt64, maxChildren: Int
    ) -> DiskMapPreviewNode {
        let i = Int(node)
        let isDirectory = flags[i].contains(.directory)
        var children: [DiskMapPreviewNode] = []
        var omittedBytes: UInt64 = 0
        var omittedCount: UInt32 = 0
        if isDirectory, depth < depthLimit, childCount[i] > 0 {
            let range = childRange(of: node)
            let sorted = range.sorted { bytes[Int($0)] > bytes[Int($1)] }
            for child in sorted {
                let c = Int(child)
                if children.count < maxChildren, bytes[c] >= minimumBytes {
                    children.append(
                        previewNode(
                            child, depth: depth + 1, depthLimit: depthLimit,
                            minimumBytes: minimumBytes, maxChildren: maxChildren))
                } else {
                    omittedBytes &+= bytes[c]
                    omittedCount &+= count[c]
                }
            }
        }
        return DiskMapPreviewNode(
            name: name(of: node), bytes: bytes[i], count: count[i], isDirectory: isDirectory,
            children: children, omittedBytes: omittedBytes, omittedCount: omittedCount)
    }
}

/// A pruned, value-typed slice of the tree, small enough to publish to the UI
/// twice a second while the arena is still growing.
public struct DiskMapPreviewNode: Sendable, Equatable {
    public var name: String
    public var bytes: UInt64
    public var count: UInt32
    public var isDirectory: Bool
    public var children: [DiskMapPreviewNode]
    /// Bytes and items of children that did not make the cut.
    public var omittedBytes: UInt64
    public var omittedCount: UInt32
}
