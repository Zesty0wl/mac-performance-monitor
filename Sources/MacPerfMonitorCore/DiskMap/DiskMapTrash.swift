// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Move to Trash, with the checks that make it safe to offer from a scan
/// that may be minutes or days old: the item must still be the one the user
/// looked at (same inode), and it must not be one of the places the app
/// refuses to touch. Trashing is a same-volume rename into `~/.Trash` or the
/// volume's `.Trashes`, so it frees nothing until Finder empties the Trash;
/// callers re-home the bytes into an In Trash bucket rather than subtract
/// them from the volume.
public enum DiskMapTrash {
    public enum Precheck: Equatable, Sendable {
        /// Safe to proceed.
        case ok
        /// The path no longer exists: treat as already gone.
        case vanished
        /// Something else now sits at that path (a different inode).
        case replaced
        /// One of the hard refusals.
        case refused(String)
    }

    public enum Outcome: Equatable, Sendable {
        case trashed(URL?)
        case alreadyGone
        case failed(String)
    }

    /// Confirm the item at `path` is still the scanned one.
    public static func precheck(
        path: String, expectedFileID: UInt64, advisor: DiskMapAdvisor, scanRoot: String
    ) -> Precheck {
        if advisor.isRefusedForTrash(canonicalPath: path, scanRoot: scanRoot) {
            return .refused("\(AppInfoName.short) does not remove this location.")
        }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return errno == ENOENT ? .vanished : .refused("The item could not be checked.")
        }
        if st.st_flags & UInt32(SF_RESTRICTED) != 0 || st.st_flags & UInt32(SF_IMMUTABLE) != 0 {
            return .refused("macOS protects this item.")
        }
        if expectedFileID != 0, st.st_ino != expectedFileID {
            return .replaced
        }
        return .ok
    }

    /// Move the item to the Trash as the current user (Put Back works).
    public static func trash(path: String) -> Outcome {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
            return .trashed(resulting as URL?)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return .alreadyGone
        } catch let error as CocoaError
            where error.code == .fileReadNoPermission
            || error.code == .fileWriteNoPermission
        {
            return .failed(
                "macOS did not allow it to be moved. It may belong to another user or be in use.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// The product name for user-facing copy in Core, where `AppInfo` is not
/// visible.
enum AppInfoName {
    static let short = "Mac Performance Monitor"
}
