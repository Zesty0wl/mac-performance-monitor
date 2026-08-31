// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// The fast path: `getattrlistbulk(2)` returns many entries per call with
/// exactly the attributes asked for, so a directory of ten thousand files is
/// a handful of syscalls and no per-entry `lstat`. About an order of magnitude
/// quicker than `FileManager` enumeration on APFS, which is the difference
/// between a scan the user waits for and one they give up on.
///
/// Record layout (per the man page): a `u_int32_t` length, then
/// `ATTR_CMN_RETURNED_ATTRS`, then `ATTR_CMN_ERROR` if set, then the remaining
/// attributes in bit order within each group (common, dir, file, then the
/// `ATTR_CMNEXT_*` group carried in `forkattr` under `FSOPT_ATTR_CMN_EXTENDED`).
/// Every value starts on a 4-byte boundary, so 8-byte values are read with
/// unaligned loads. The walker consumes only attributes the returned bitmap
/// says are present, which is what makes it correct for files (no dir attrs),
/// directories (no file attrs) and errored entries (name only) alike.
public struct BulkAttributeLister: DirectoryLister {
    /// Whether to ask for `ATTR_CMNEXT_PRIVATESIZE` (bytes that would be freed
    /// on delete, the exact clone and snapshot accounting). Off by default: it
    /// costs about half again the scan time, see `DiskMapScanOptions`.
    public var fetchPrivateSize: Bool

    public init(fetchPrivateSize: Bool = false) {
        self.fetchPrivateSize = fetchPrivateSize
    }

    public func list(path: String) throws -> DirectoryListing {
        let fd = try DirectoryOpener.open(path)
        defer { close(fd) }
        return try Self.list(fd: fd, fetchPrivateSize: fetchPrivateSize)
    }

    /// One buffer per call; 128 KiB holds a few hundred entries per syscall.
    static let bufferSize = 128 * 1024

    static func list(fd: Int32, fetchPrivateSize: Bool) throws -> DirectoryListing {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        if fetchPrivateSize {
            request.forkattr |= attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        }
        let options = UInt64(FSOPT_ATTR_CMN_EXTENDED)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var listing = DirectoryListing()
        listing.entries.reserveCapacity(256)
        listing.nameBytes.reserveCapacity(256 * 24)

        while true {
            let returned = getattrlistbulk(fd, &request, buffer, bufferSize, options)
            if returned < 0 {
                throw DirectoryListingError(errno: errno)
            }
            if returned == 0 { break }
            var cursor = UnsafeRawPointer(buffer)
            let end = cursor + bufferSize
            for _ in 0..<Int(returned) {
                guard cursor + 4 <= end else { break }
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                guard length >= 24, cursor + length <= end else { break }
                Self.decode(record: cursor, length: length, into: &listing)
                cursor += length
            }
        }
        return listing
    }

    // MARK: - Record decoding

    private static func decode(
        record: UnsafeRawPointer, length: Int, into listing: inout DirectoryListing
    ) {
        var field = record + 4
        let commonReturned = field.loadUnaligned(as: UInt32.self)
        let dirReturned = (field + 8).loadUnaligned(as: UInt32.self)
        let fileReturned = (field + 12).loadUnaligned(as: UInt32.self)
        let forkReturned = (field + 16).loadUnaligned(as: UInt32.self)
        field += 20

        var error: Int32 = 0
        if commonReturned & UInt32(ATTR_CMN_ERROR) != 0 {
            error = Int32(bitPattern: field.loadUnaligned(as: UInt32.self))
            field += 4
        }

        var nameStart: UnsafeRawPointer?
        var nameLength = 0
        if commonReturned & UInt32(ATTR_CMN_NAME) != 0 {
            let offset = Int(field.loadUnaligned(as: Int32.self))
            var count = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let start = field + offset
            // attr_length includes the NUL terminator; strip it when present.
            if count > 0, start.load(fromByteOffset: count - 1, as: UInt8.self) == 0 {
                count -= 1
            }
            if offset >= 0, count >= 0, start + count <= record + length {
                nameStart = start
                nameLength = count
            }
            field += 8
        }
        guard let nameStart, nameLength > 0 else { return }

        var type: DirectoryEntryType = .other
        if commonReturned & UInt32(ATTR_CMN_OBJTYPE) != 0 {
            type = DirectoryEntryType(vnodeType: field.loadUnaligned(as: UInt32.self))
            field += 4
        }
        var modified: UInt32 = 0
        if commonReturned & UInt32(ATTR_CMN_MODTIME) != 0 {
            let seconds = field.loadUnaligned(as: Int64.self)
            modified = seconds > 0 ? UInt32(clamping: seconds) : 0
            field += 16
        }
        var bsdFlags: UInt32 = 0
        if commonReturned & UInt32(ATTR_CMN_FLAGS) != 0 {
            bsdFlags = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var fileID: UInt64 = 0
        if commonReturned & UInt32(ATTR_CMN_FILEID) != 0 {
            fileID = field.loadUnaligned(as: UInt64.self)
            field += 8
        }

        var isMountPoint = false
        if dirReturned & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 {
            let status = field.loadUnaligned(as: UInt32.self)
            let boundary = UInt32(DIR_MNTSTATUS_MNTPOINT) | UInt32(DIR_MNTSTATUS_TRIGGER)
            isMountPoint = status & boundary != 0
            field += 4
        }

        var linkCount: UInt32 = 1
        if fileReturned & UInt32(ATTR_FILE_LINKCOUNT) != 0 {
            linkCount = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var allocated: UInt64 = 0
        if fileReturned & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
            let value = field.loadUnaligned(as: Int64.self)
            allocated = value > 0 ? UInt64(value) : 0
            field += 8
        }

        var privateSize: UInt64? = nil
        if forkReturned & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 {
            let value = field.loadUnaligned(as: Int64.self)
            privateSize = value > 0 ? UInt64(value) : 0
            field += 8
        }
        var extendedFlags: UInt64 = 0
        if forkReturned & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0 {
            extendedFlags = field.loadUnaligned(as: UInt64.self)
            field += 8
        }

        let name = UnsafeRawBufferPointer(start: nameStart, count: nameLength)
        listing.append(name: name) { offset, count in
            RawDirectoryEntry(
                nameOffset: offset, nameLength: count, type: type, error: error,
                allocated: allocated, privateSize: privateSize, fileID: fileID,
                modified: modified, bsdFlags: bsdFlags, linkCount: linkCount,
                extendedFlags: extendedFlags, isMountPoint: isMountPoint)
        }
    }
}

/// The portable path for filesystems that reject `getattrlistbulk` (exFAT,
/// FAT, some network and third-party filesystems): `readdir` plus one
/// `fstatat(AT_SYMLINK_NOFOLLOW)` per entry. Same contract, several times
/// slower, no clone or private-size information.
public struct ReaddirLister: DirectoryLister {
    public init() {}

    public func list(path: String) throws -> DirectoryListing {
        let fd = try DirectoryOpener.open(path)
        guard let dir = fdopendir(fd) else {
            let code = errno
            close(fd)
            throw DirectoryListingError(errno: code)
        }
        defer { closedir(dir) }

        var dirStat = stat()
        let haveDirStat = fstat(fd, &dirStat) == 0

        var listing = DirectoryListing()
        while let entry = readdir(dir) {
            let nameLength = Int(entry.pointee.d_namlen)
            guard nameLength > 0 else { continue }
            let (isDot, isDotDot) = withUnsafePointer(to: &entry.pointee.d_name) {
                raw -> (Bool, Bool) in
                let bytes = UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self)
                if nameLength == 1, bytes[0] == UInt8(ascii: ".") { return (true, false) }
                if nameLength == 2, bytes[0] == UInt8(ascii: "."), bytes[1] == UInt8(ascii: ".") {
                    return (false, true)
                }
                return (false, false)
            }
            if isDot || isDotDot { continue }

            var st = stat()
            let statResult = withUnsafePointer(to: &entry.pointee.d_name) { raw in
                raw.withMemoryRebound(to: CChar.self, capacity: nameLength + 1) { cName in
                    fstatat(fd, cName, &st, AT_SYMLINK_NOFOLLOW)
                }
            }
            let statError: Int32 = statResult == 0 ? 0 : errno

            withUnsafePointer(to: &entry.pointee.d_name) { raw in
                let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(raw), count: nameLength)
                listing.append(name: bytes) { offset, count in
                    guard statError == 0 else {
                        return RawDirectoryEntry(
                            nameOffset: offset, nameLength: count, type: .other, error: statError)
                    }
                    let type = DirectoryEntryType(mode: st.st_mode)
                    let seconds = st.st_mtimespec.tv_sec
                    let crossesDevice = haveDirStat && st.st_dev != dirStat.st_dev
                    return RawDirectoryEntry(
                        nameOffset: offset, nameLength: count, type: type,
                        allocated: st.st_blocks > 0 ? UInt64(st.st_blocks) * 512 : 0,
                        fileID: st.st_ino,
                        modified: seconds > 0 ? UInt32(clamping: seconds) : 0,
                        bsdFlags: st.st_flags, linkCount: UInt32(st.st_nlink),
                        isMountPoint: type == .directory && crossesDevice)
                }
            }
        }
        return listing
    }
}
