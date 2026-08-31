// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// What a Disk Map scan covers. The startup disk means the Data volume (see
/// `FirmlinkMap`), presented as "Macintosh HD"; a folder is any directory the
/// user picks; a volume is an external or secondary mount.
public enum DiskMapScope: Hashable, Codable, Sendable {
    case startupDisk
    case home
    case folder(String)
    case volume(String)

    /// The directory the scanner opens.
    public var scanRoot: String {
        switch self {
        case .startupDisk: return Self.startupDiskScanRoot
        case .home: return NSHomeDirectory()
        case .folder(let path): return path
        case .volume(let mountPoint): return mountPoint
        }
    }

    /// The path shown to the user for the root.
    public var displayRoot: String {
        switch self {
        case .startupDisk: return "/"
        case .home: return NSHomeDirectory()
        case .folder(let path): return FirmlinkMap.system.canonicalPath(path)
        case .volume(let mountPoint): return mountPoint
        }
    }

    /// The root node's name.
    public var rootName: String {
        switch self {
        case .startupDisk: return "Macintosh HD"
        case .home: return (NSHomeDirectory() as NSString).lastPathComponent
        case .folder(let path):
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        case .volume(let mountPoint):
            return mountPoint == "/" ? "Macintosh HD" : (mountPoint as NSString).lastPathComponent
        }
    }

    /// Whether the scan covers a whole volume, in which case the volume's
    /// used inode count is a fair progress denominator and the reconciliation
    /// bar can compare against the volume's used bytes directly.
    public var isWholeVolume: Bool {
        switch self {
        case .startupDisk, .volume: return true
        case .home, .folder: return false
        }
    }

    /// A stable file-name-safe key for the persisted snapshot.
    public var id: String {
        switch self {
        case .startupDisk: return "startup"
        case .home: return "home"
        case .folder(let path): return "folder-" + Self.fileSafe(path)
        case .volume(let mountPoint): return "volume-" + Self.fileSafe(mountPoint)
        }
    }

    /// Normalise a user-chosen directory into a scope. `/`, `/System` and the
    /// Data volume root all mean the startup disk (scanning `/` would walk the
    /// sealed System volume and the Data volume together, which no volume
    /// figure reconciles against); the home directory is `.home`; a folder
    /// under a firmlink is opened by its Data-volume path so its bytes are
    /// counted where they live.
    public static func resolved(folder path: String) -> DiskMapScope {
        let standardized = (path as NSString).standardizingPath
        let trimmed =
            standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast()) : standardized
        if trimmed == "/" || trimmed == "/System" || trimmed == FirmlinkMap.dataVolumeRoot {
            return .startupDisk
        }
        if trimmed == NSHomeDirectory() { return .home }
        return .folder(trimmed)
    }

    /// The Data volume when the startup disk is a volume group, else `/`.
    static var startupDiskScanRoot: String {
        var st = stat()
        if stat(FirmlinkMap.dataVolumeRoot, &st) == 0, st.st_mode & S_IFMT == S_IFDIR {
            return FirmlinkMap.dataVolumeRoot
        }
        return "/"
    }

    /// The mount point of the volume containing `path`, from `statfs`.
    public static func mountPoint(ofPath path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafePointer(to: &fs.f_mntonname) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Inodes in use on the volume containing `path` (`f_files - f_ffree`),
    /// the denominator for a determinate progress bar and the input to the
    /// adaptive small-file threshold.
    public static func usedInodes(ofPath path: String) -> UInt64? {
        var fs = statfs()
        guard statfs(path, &fs) == 0, fs.f_files >= fs.f_ffree else { return nil }
        return fs.f_files - fs.f_ffree
    }

    private static func fileSafe(_ path: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = path.map { allowed.contains($0) ? String($0) : "_" }.joined()
        // Bound the length and keep it unique with a short hash of the path.
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(mapped.suffix(40)) + "-" + String(hash, radix: 16)
    }
}
