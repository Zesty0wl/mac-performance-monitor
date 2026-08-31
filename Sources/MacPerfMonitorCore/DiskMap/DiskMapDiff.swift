// SPDX-License-Identifier: MIT

import Foundation

/// One path whose size moved between two scans.
public struct DiskMapDiffEntry: Sendable, Equatable, Identifiable {
    public var id: String { relativePath }
    /// Path relative to the scan root, `""` for the root itself.
    public var relativePath: String
    /// The node in the current tree, nil when the item is gone.
    public var node: Int32?
    public var before: UInt64
    public var after: UInt64
    public var isDirectory: Bool

    public var delta: Int64 { Int64(after) - Int64(before) }
    public var isNew: Bool { before == 0 }
    public var isGone: Bool { after == 0 && node == nil }
}

/// What changed between the last two scans of a scope: the flight-recorder
/// angle. Directories and large files are compared by path; every entry
/// whose size moved by at least `minimumDelta` is listed, largest movement
/// first, so "Library grew 30 GB" sits next to "Library/Caches grew 28 GB"
/// and the eye can follow the growth down.
public struct DiskMapDiff: Sendable, Equatable {
    public var previousScannedAt: Date
    public var currentScannedAt: Date
    public var totalBefore: UInt64
    public var totalAfter: UInt64
    /// Entries that grew, largest growth first.
    public var grown: [DiskMapDiffEntry]
    /// Entries that shrank or disappeared, largest shrink first.
    public var shrunk: [DiskMapDiffEntry]

    public var totalDelta: Int64 { Int64(totalAfter) - Int64(totalBefore) }

    public static let defaultMinimumDelta: UInt64 = 10 * 1024 * 1024

    /// Compare two snapshots of the same scope. Files below `minimumDelta`
    /// are never indexed (their movement is invisible at that threshold and
    /// they are most of the entries), so the index holds directories plus
    /// the large files only.
    public static func compute(
        current: DiskMapSnapshot, previous: DiskMapSnapshot,
        minimumDelta: UInt64 = defaultMinimumDelta, limit: Int = 200
    ) -> DiskMapDiff {
        let before = index(previous.tree, minimumBytes: minimumDelta)
        let after = index(current.tree, minimumBytes: minimumDelta)

        var grown: [DiskMapDiffEntry] = []
        var shrunk: [DiskMapDiffEntry] = []
        for (path, now) in after {
            let was = before[path]?.bytes ?? 0
            guard now.bytes != was else { continue }
            let magnitude = now.bytes > was ? now.bytes - was : was - now.bytes
            guard magnitude >= minimumDelta else { continue }
            let entry = DiskMapDiffEntry(
                relativePath: path, node: now.node, before: was, after: now.bytes,
                isDirectory: now.isDirectory)
            if now.bytes > was { grown.append(entry) } else { shrunk.append(entry) }
        }
        // Gone: in the previous index, not in the current one. Only the
        // top-most gone path is listed; its descendants went with it.
        var gone: [DiskMapDiffEntry] = []
        for (path, was) in before where after[path] == nil && was.bytes >= minimumDelta {
            gone.append(
                DiskMapDiffEntry(
                    relativePath: path, node: nil, before: was.bytes, after: 0,
                    isDirectory: was.isDirectory))
        }
        if !gone.isEmpty {
            let gonePaths = Set(gone.map(\.relativePath))
            gone.removeAll { entry in
                var parent = entry.relativePath
                while let slash = parent.lastIndex(of: "/") {
                    parent = String(parent[..<slash])
                    if gonePaths.contains(parent) { return true }
                }
                return false
            }
            shrunk.append(contentsOf: gone)
        }
        // Largest movement first; among equal movements the shallower path
        // (the folder before the child that grew inside it), then by name, so
        // the order is stable across runs.
        grown.sort { a, b in
            a.delta != b.delta ? a.delta > b.delta : shallowerFirst(a, b)
        }
        shrunk.sort { a, b in
            a.delta != b.delta ? a.delta < b.delta : shallowerFirst(a, b)
        }
        return DiskMapDiff(
            previousScannedAt: previous.scannedAt, currentScannedAt: current.scannedAt,
            totalBefore: previous.tree.bytes.first ?? 0, totalAfter: current.tree.bytes.first ?? 0,
            grown: Array(grown.prefix(limit)), shrunk: Array(shrunk.prefix(limit)))
    }

    private static func shallowerFirst(_ a: DiskMapDiffEntry, _ b: DiskMapDiffEntry) -> Bool {
        let depthA = a.relativePath.isEmpty ? 0 : a.relativePath.filter { $0 == "/" }.count + 1
        let depthB = b.relativePath.isEmpty ? 0 : b.relativePath.filter { $0 == "/" }.count + 1
        return depthA != depthB ? depthA < depthB : a.relativePath < b.relativePath
    }

    struct Indexed {
        var bytes: UInt64
        var node: Int32
        var isDirectory: Bool
    }

    /// Relative path to size for every directory and every large file. Paths
    /// are built from the parent's in one forward pass; the root is `""`.
    static func index(_ tree: FileTree, minimumBytes: UInt64) -> [String: Indexed] {
        let n = tree.nodeCount
        var result: [String: Indexed] = [:]
        guard n > 0 else { return result }
        result.reserveCapacity(min(n, 1 << 19))
        var directoryPath = [String?](repeating: nil, count: n)
        directoryPath[0] = ""
        result[""] = Indexed(bytes: tree.bytes[0], node: 0, isDirectory: true)
        for i in 1..<n {
            let flags = tree.flags[i]
            if flags.contains(.smallFilesFold) || flags.contains(.trashed) { continue }
            let isDirectory = flags.contains(.directory)
            if !isDirectory, tree.bytes[i] < minimumBytes { continue }
            let parentPath = directoryPath[Int(tree.parent[i])] ?? ""
            let name = tree.name(of: Int32(i))
            let path = parentPath.isEmpty ? name : parentPath + "/" + name
            if isDirectory { directoryPath[i] = path }
            result[path] = Indexed(bytes: tree.bytes[i], node: Int32(i), isDirectory: isDirectory)
        }
        return result
    }
}
