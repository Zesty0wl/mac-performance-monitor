// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Facts about one item read on demand with a single `getattrlist`, for the
/// detail rail: the logical length (shown when it differs from the allocated
/// size), and `ATTR_CMNEXT_PRIVATESIZE`, the bytes that would actually be
/// freed if the item were deleted, which the scan itself does not fetch
/// because it cost half again the scan time over millions of entries.
public struct DiskMapItemFacts: Sendable, Equatable {
    public var allocatedBytes: UInt64
    public var logicalBytes: UInt64
    /// Nil when the filesystem does not report it (non-APFS volumes).
    public var privateBytes: UInt64?
    public var linkCount: UInt32
    public var mayShareBlocks: Bool
    public var cloneID: UInt64?
    public var isDirectory: Bool

    /// What deleting this item frees right now: the private size when known,
    /// else the allocated size.
    public var wouldFreeBytes: UInt64 { privateBytes ?? allocatedBytes }

    /// Bytes held in common with a clone or a snapshot.
    public var sharedBytes: UInt64 {
        guard let privateBytes, privateBytes < allocatedBytes else { return 0 }
        return allocatedBytes - privateBytes
    }

    public static func read(path: String) -> DiskMapItemFacts? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_OBJTYPE)
        request.fileattr =
            attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            | attrgroup_t(ATTR_FILE_DATALENGTH)
        request.forkattr =
            attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID)
            | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        var buffer = [UInt8](repeating: 0, count: 128)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, options)
        }
        guard status == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> DiskMapItemFacts? in
            let base = raw.baseAddress!
            let length = Int(base.loadUnaligned(as: UInt32.self))
            guard length >= 24, length <= buffer.count else { return nil }
            var field = base + 4
            let commonReturned = field.loadUnaligned(as: UInt32.self)
            let fileReturned = (field + 12).loadUnaligned(as: UInt32.self)
            let forkReturned = (field + 16).loadUnaligned(as: UInt32.self)
            field += 20

            var isDirectory = false
            if commonReturned & UInt32(ATTR_CMN_OBJTYPE) != 0 {
                isDirectory = field.loadUnaligned(as: UInt32.self) == UInt32(VDIR.rawValue)
                field += 4
            }
            var linkCount: UInt32 = 1
            if fileReturned & UInt32(ATTR_FILE_LINKCOUNT) != 0 {
                linkCount = field.loadUnaligned(as: UInt32.self)
                field += 4
            }
            var allocated: UInt64 = 0
            if fileReturned & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
                allocated = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                field += 8
            }
            var logical: UInt64 = 0
            if fileReturned & UInt32(ATTR_FILE_DATALENGTH) != 0 {
                logical = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                field += 8
            }
            var privateBytes: UInt64?
            if forkReturned & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                privateBytes = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                field += 8
            }
            var cloneID: UInt64?
            if forkReturned & UInt32(ATTR_CMNEXT_CLONEID) != 0 {
                cloneID = field.loadUnaligned(as: UInt64.self)
                field += 8
            }
            var mayShareBlocks = false
            if forkReturned & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0 {
                let flags = field.loadUnaligned(as: UInt64.self)
                mayShareBlocks = flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
                field += 8
            }
            return DiskMapItemFacts(
                allocatedBytes: allocated, logicalBytes: logical, privateBytes: privateBytes,
                linkCount: linkCount, mayShareBlocks: mayShareBlocks, cloneID: cloneID,
                isDirectory: isDirectory)
        }
    }
}
