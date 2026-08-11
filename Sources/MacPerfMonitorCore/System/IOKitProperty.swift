import Foundation
import IOKit

/// Typed wrappers over `IORegistryEntryCreateCFProperty`, shared by the disk
/// and volume readers so every registry read releases its CF value the same
/// way. Each returns nil when the key is absent or has an unexpected type.
enum IOKitProperty {
    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    static func stringArray(_ entry: io_registry_entry_t, _ key: String) -> [String]? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String]
    }

    static func bool(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    static func number(_ entry: io_registry_entry_t, _ key: String) -> UInt64? {
        (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.uint64Value
    }

    static func dictionary(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }

    /// Raw data property, for fixed-layout blobs like SMART logs.
    static func data(_ entry: io_registry_entry_t, _ key: String) -> Data? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
    }

    /// First parent in the service plane that conforms to `className`, walking
    /// upward at most `maxDepth` levels. The caller owns the returned entry and
    /// must `IOObjectRelease` it.
    static func firstParent(
        of entry: io_registry_entry_t, conformingTo className: String, maxDepth: Int = 6
    ) -> io_registry_entry_t? {
        var current = entry
        for depth in 0..<maxDepth {
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if depth > 0 { IOObjectRelease(current) }
            guard status == KERN_SUCCESS, parent != 0 else { return nil }
            if IOObjectConformsTo(parent, className) != 0 { return parent }
            current = parent
        }
        if current != entry { IOObjectRelease(current) }
        return nil
    }
}
