// SPDX-License-Identifier: MIT

import Foundation

/// Maps Data-volume paths back to the paths people know. Since Catalina the
/// startup disk is a volume group: the sealed System volume is mounted at `/`
/// and the writable Data volume at `/System/Volumes/Data`, with firmlinks
/// (`/usr/share/firmlinks`) grafting `/Users`, `/Applications`, `/Library`
/// and a few more onto it. The scanner walks the Data volume so its total
/// equals that one volume's used space, and this map turns
/// `/System/Volumes/Data/Users/neil` into `/Users/neil` for display and for
/// Finder.
///
/// Note that a device-id check cannot find the boundary: the System and Data
/// volumes of a group report the same `st_dev`. Mount status is the signal,
/// and this map is only about naming.
public struct FirmlinkMap: Sendable, Equatable {
    public static let dataVolumeRoot = "/System/Volumes/Data"

    /// `(dataPath, canonicalPath)` sorted longest data path first so the most
    /// specific prefix wins.
    private let entries: [(data: String, canonical: String)]

    /// The system table, parsed once. Empty when the file is missing (a
    /// pre-Catalina layout or a stripped-down environment), in which case
    /// paths pass through unchanged.
    public static let system: FirmlinkMap = {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else {
            return FirmlinkMap(lines: [])
        }
        return FirmlinkMap(lines: text.split(whereSeparator: \.isNewline).map(String.init))
    }()

    /// Each line is `<canonical path>\t<relative target on the Data volume>`.
    public init(lines: [String], dataVolumeRoot: String = FirmlinkMap.dataVolumeRoot) {
        var parsed: [(data: String, canonical: String)] = []
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0].hasPrefix("/"), !parts[1].isEmpty else { continue }
            let target = parts[1].hasPrefix("/") ? String(parts[1].dropFirst()) : parts[1]
            parsed.append((data: dataVolumeRoot + "/" + target, canonical: parts[0]))
        }
        parsed.sort { $0.data.count > $1.data.count }
        self.entries = parsed
        self.dataVolumeRoot = dataVolumeRoot
    }

    private let dataVolumeRoot: String

    public static func == (lhs: FirmlinkMap, rhs: FirmlinkMap) -> Bool {
        lhs.dataVolumeRoot == rhs.dataVolumeRoot
            && lhs.entries.map(\.data) == rhs.entries.map(\.data)
            && lhs.entries.map(\.canonical) == rhs.entries.map(\.canonical)
    }

    /// The path as the user knows it. Paths outside the Data volume root pass
    /// through; the root itself becomes `/`; Data paths under a firmlink are
    /// rewritten; other Data paths (for example `.Spotlight-V100`) stay as
    /// they are because nothing else names them.
    public func canonicalPath(_ path: String) -> String {
        guard path.hasPrefix(dataVolumeRoot) else { return path }
        if path.count == dataVolumeRoot.count { return "/" }
        guard
            path.utf8[path.utf8.index(path.utf8.startIndex, offsetBy: dataVolumeRoot.utf8.count)]
                == UInt8(ascii: "/")
        else { return path }
        for entry in entries where path.hasPrefix(entry.data) {
            if path.count == entry.data.count { return entry.canonical }
            let boundary = path.utf8.index(path.utf8.startIndex, offsetBy: entry.data.utf8.count)
            if path.utf8[boundary] == UInt8(ascii: "/") {
                return entry.canonical + path[boundary...]
            }
        }
        return path
    }

    /// The Data-volume path for a canonical one, when a firmlink covers it.
    /// Used to turn a user-chosen folder like `/Users/neil` into the path the
    /// scanner should open so its totals match the volume.
    public func dataVolumePath(_ canonical: String) -> String {
        for entry in entries where canonical.hasPrefix(entry.canonical) {
            if canonical.count == entry.canonical.count { return entry.data }
            let boundary = canonical.utf8.index(
                canonical.utf8.startIndex, offsetBy: entry.canonical.utf8.count)
            if canonical.utf8[boundary] == UInt8(ascii: "/") {
                return entry.data + canonical[boundary...]
            }
        }
        return canonical
    }
}
