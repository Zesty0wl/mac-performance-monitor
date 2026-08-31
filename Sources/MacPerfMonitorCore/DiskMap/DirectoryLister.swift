// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// What a directory entry is, as far as the scanner cares.
public enum DirectoryEntryType: UInt8, Sendable {
    case regular
    case directory
    case symlink
    /// Sockets, fifos, devices: kept as zero-byte leaves.
    case other
}

/// One directory entry, straight from the filesystem, with no strings: the
/// name is a range into the listing's shared byte buffer. Fixed-size and
/// trivially copyable so a listing of ten thousand entries is one allocation
/// plus the names.
public struct RawDirectoryEntry: Sendable, Equatable {
    public var nameOffset: UInt32
    public var nameLength: UInt16
    public var type: DirectoryEntryType
    /// Non-zero when the filesystem reported a per-entry error; only the name
    /// is meaningful then.
    public var error: Int32
    /// Allocated bytes on disk (`ATTR_FILE_ALLOCSIZE`, `st_blocks * 512`).
    public var allocated: UInt64
    /// `ATTR_CMNEXT_PRIVATESIZE` when fetched, else equal to `allocated`.
    public var privateSize: UInt64
    public var fileID: UInt64
    /// Whole seconds since 1970.
    public var modified: UInt32
    /// BSD `st_flags`.
    public var bsdFlags: UInt32
    public var linkCount: UInt32
    /// `ATTR_CMNEXT_EXT_FLAGS` (zero from listers that cannot read it).
    public var extendedFlags: UInt64
    /// A directory that is a mount point or an automount trigger.
    public var isMountPoint: Bool

    public init(
        nameOffset: UInt32, nameLength: UInt16, type: DirectoryEntryType, error: Int32 = 0,
        allocated: UInt64 = 0, privateSize: UInt64? = nil, fileID: UInt64 = 0,
        modified: UInt32 = 0, bsdFlags: UInt32 = 0, linkCount: UInt32 = 1,
        extendedFlags: UInt64 = 0, isMountPoint: Bool = false
    ) {
        self.nameOffset = nameOffset
        self.nameLength = nameLength
        self.type = type
        self.error = error
        self.allocated = allocated
        self.privateSize = privateSize ?? allocated
        self.fileID = fileID
        self.modified = modified
        self.bsdFlags = bsdFlags
        self.linkCount = linkCount
        self.extendedFlags = extendedFlags
        self.isMountPoint = isMountPoint
    }
}

/// Everything read from one directory. Names exclude "." and ".." and are
/// raw UTF-8 without terminators.
public struct DirectoryListing: Sendable {
    public var entries: [RawDirectoryEntry]
    public var nameBytes: [UInt8]

    public init(entries: [RawDirectoryEntry] = [], nameBytes: [UInt8] = []) {
        self.entries = entries
        self.nameBytes = nameBytes
    }

    public func name(of entry: RawDirectoryEntry) -> ArraySlice<UInt8> {
        let start = Int(entry.nameOffset)
        return nameBytes[start..<(start + Int(entry.nameLength))]
    }

    public func nameString(of entry: RawDirectoryEntry) -> String {
        String(decoding: name(of: entry), as: UTF8.self)
    }

    /// Append one entry, copying its name into the shared buffer.
    public mutating func append(
        name: some Collection<UInt8>, _ make: (UInt32, UInt16) -> RawDirectoryEntry
    ) {
        let offset = UInt32(nameBytes.count)
        nameBytes.append(contentsOf: name)
        entries.append(make(offset, UInt16(min(name.count, Int(UInt16.max)))))
    }
}

/// Why a directory could not be listed. The distinction between `notPermitted`
/// and `accessDenied` is load-bearing: the first is TCC and Full Disk Access
/// clears it, the second is ordinary Unix permissions and nothing the app can
/// ask for will change it.
public enum DirectoryListingError: Error, Sendable, Equatable {
    /// EPERM: privacy protection (TCC) refused the open.
    case notPermitted
    /// EACCES: the directory is not readable by this user.
    case accessDenied
    /// ENOENT or ENOTDIR: it went away (or changed) since its parent was read.
    case vanished
    /// EDEADLK: an evicted (dataless) directory that would need to download.
    case dataless
    /// ENOTSUP from `getattrlistbulk`: this filesystem wants the readdir path.
    case notSupported
    case other(errno: Int32)

    init(errno code: Int32) {
        switch code {
        case EPERM: self = .notPermitted
        case EACCES: self = .accessDenied
        case ENOENT, ENOTDIR: self = .vanished
        case EDEADLK: self = .dataless
        case ENOTSUP: self = .notSupported
        default: self = .other(errno: code)
        }
    }

    /// The tree flag a directory carries when its listing fails this way.
    public var nodeFlag: FileNodeFlags {
        switch self {
        case .notPermitted: return .notPermitted
        case .accessDenied: return .accessDenied
        case .dataless: return .dataless
        case .vanished, .notSupported, .other: return .unreadable
        }
    }
}

/// Reads one directory. Implementations must be safe to call from several
/// threads at once (each call is independent) and must never follow symlinks,
/// cross into another volume, or materialise dataless content.
public protocol DirectoryLister: Sendable {
    func list(path: String) throws -> DirectoryListing
}

/// Shared open logic. Paths deeper than `PATH_MAX` (deep `node_modules` trees
/// reach it) cannot be opened in one call, so long paths are walked with
/// `openat` one component at a time, holding a single descriptor.
enum DirectoryOpener {
    static let flags: Int32 = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    /// Below this many bytes a plain `open` is used; `PATH_MAX` is 1024.
    static let directOpenLimit = 960

    /// Returns a descriptor the caller must close, or throws the mapped error.
    static func open(_ path: String) throws -> Int32 {
        let utf8Count = path.utf8.count
        if utf8Count < directOpenLimit {
            let fd = Darwin.open(path, flags)
            guard fd >= 0 else { throw DirectoryListingError(errno: errno) }
            return fd
        }
        return try openLong(path)
    }

    private static func openLong(_ path: String) throws -> Int32 {
        var fd = Darwin.open("/", flags)
        guard fd >= 0 else { throw DirectoryListingError(errno: errno) }
        // Walk in chunks that each fit comfortably under PATH_MAX so the
        // number of opens stays small even for very deep trees.
        var chunk = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if chunk.utf8.count + component.utf8.count + 1 >= directOpenLimit {
                fd = try step(from: fd, relative: chunk)
                chunk = ""
            }
            if !chunk.isEmpty { chunk += "/" }
            chunk += component
        }
        if !chunk.isEmpty {
            fd = try step(from: fd, relative: chunk)
        }
        return fd
    }

    private static func step(from fd: Int32, relative: String) throws -> Int32 {
        let next = openat(fd, relative, flags)
        let code = errno
        close(fd)
        guard next >= 0 else { throw DirectoryListingError(errno: code) }
        return next
    }
}

extension DirectoryEntryType {
    /// From `fsobj_type_t` (the `vtype` enumeration).
    init(vnodeType: UInt32) {
        switch vnodeType {
        case UInt32(VREG.rawValue): self = .regular
        case UInt32(VDIR.rawValue): self = .directory
        case UInt32(VLNK.rawValue): self = .symlink
        default: self = .other
        }
    }

    init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFREG: self = .regular
        case S_IFDIR: self = .directory
        case S_IFLNK: self = .symlink
        default: self = .other
        }
    }
}
