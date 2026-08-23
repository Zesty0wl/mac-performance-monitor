import Darwin
import Foundation
import IOKit

/// One process's share of the GPU, summed over its Metal contexts.
public struct GPUClientUsage: Sendable, Equatable {
    public var pid: pid_t
    /// Accumulated GPU time across the process's contexts, in nanoseconds.
    public var gpuTimeNanos: UInt64
    /// The newest submission across the contexts, in nanoseconds on the mach
    /// absolute clock (the clock `mach_absolute_time` counts, which pauses in
    /// sleep). 0 when nothing was ever submitted.
    public var lastSubmittedNanos: UInt64
    /// How many contexts (command queues) the process holds open.
    public var contextCount: Int

    public init(pid: pid_t, gpuTimeNanos: UInt64, lastSubmittedNanos: UInt64, contextCount: Int) {
        self.pid = pid
        self.gpuTimeNanos = gpuTimeNanos
        self.lastSubmittedNanos = lastSubmittedNanos
        self.contextCount = contextCount
    }
}

/// Per-process GPU time from the AGX driver, read from the IORegistry without
/// privilege.
///
/// Every process that has touched Metal owns one `AGXDeviceUserClient` per
/// context under the accelerator. Each carries `IOUserClientCreator`
/// ("pid 413, WindowServer"; the name is truncated to 16 characters, so the
/// pid is the key) and `AppUsage`, an array with one entry per context:
/// `{"API": "Metal", "accumulatedGPUTime": ns, "lastSubmittedTime": ns}`.
/// The GPU time is nanoseconds (measured: WindowServer gained 819 ms of it per
/// wall second while the device counter read 83%), and the submission time is
/// nanoseconds since boot on the mach absolute clock. This is the figure
/// Activity Monitor's "% GPU" column differences.
///
/// Entries live as long as the context, so an app that rendered once an hour
/// ago still appears with a flat counter; callers rank by the rate of change
/// and use `lastSubmittedNanos` for "last active". One pass over the clients
/// (about 80 on a busy Mac) costs well under a millisecond.
public final class GPUProcessReader {
    /// Registry entry id of each client seen, to its pid. A client's creator
    /// never changes, so after the first sight only its `AppUsage` needs
    /// reading; entries that disappear from a full walk are dropped.
    private var pidByEntry: [UInt64: pid_t] = [:]

    public init() {}

    /// GPU usage for every process with a Metal context, keyed by pid, or for
    /// just the `pids` given (the rows on screen, at the dial rate), which
    /// skips the property reads of every other client.
    ///
    /// User clients are attached to the accelerator without being registered
    /// as services, so `IOServiceGetMatchingServices` never sees them (which
    /// is why `ioreg -c AGXDeviceUserClient` lists them while the matching API
    /// returns nothing). Walk each accelerator's children instead. Each IOKit
    /// property read costs tens of microseconds, so a full pass over ~90
    /// clients is a few milliseconds and a filtered pass for 30 rows about one.
    public func read(pids wanted: Set<pid_t>? = nil) -> [pid_t: GPUClientUsage] {
        var accelerators: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators)
                == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(accelerators) }

        var out: [pid_t: GPUClientUsage] = [:]
        var seen: Set<UInt64> = []
        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children)
                == KERN_SUCCESS
            {
                var child = IOIteratorNext(children)
                while child != 0 {
                    if IOObjectConformsTo(child, "IOUserClient") != 0 {
                        accumulate(child, wanted: wanted, seen: &seen, into: &out)
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(accelerators)
        }
        if wanted == nil {
            pidByEntry = pidByEntry.filter { seen.contains($0.key) }
        }
        return out
    }

    /// Fold one user client's accounting into the per-pid totals.
    private func accumulate(
        _ client: io_registry_entry_t, wanted: Set<pid_t>?, seen: inout Set<UInt64>,
        into out: inout [pid_t: GPUClientUsage]
    ) {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(client, &entryID) == KERN_SUCCESS else { return }
        seen.insert(entryID)
        let pid: pid_t
        if let known = pidByEntry[entryID] {
            pid = known
        } else {
            guard
                let creator = IORegistryEntryCreateCFProperty(
                    client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String,
                let parsed = Self.pid(fromCreator: creator)
            else { return }
            pidByEntry[entryID] = parsed
            pid = parsed
        }
        if let wanted, !wanted.contains(pid) { return }
        let appUsage =
            IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] ?? []
        let usage = Self.usage(pid: pid, appUsage: appUsage)
        if var existing = out[pid] {
            existing.gpuTimeNanos &+= usage.gpuTimeNanos
            existing.lastSubmittedNanos = max(existing.lastSubmittedNanos, usage.lastSubmittedNanos)
            existing.contextCount += usage.contextCount
            out[pid] = existing
        } else {
            out[pid] = usage
        }
    }

    /// The pid in an `IOUserClientCreator` string: `"pid 413, WindowServer"`.
    public static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let pid = pid_t(digits) else { return nil }
        return pid
    }

    /// Sum one client's `AppUsage` entries. Entries with no submission count
    /// as a context but contribute no time.
    public static func usage(pid: pid_t, appUsage: [[String: Any]]) -> GPUClientUsage {
        var total: UInt64 = 0
        var latest: UInt64 = 0
        for entry in appUsage {
            if let time = Self.unsigned(entry["accumulatedGPUTime"]) { total &+= time }
            if let submitted = Self.unsigned(entry["lastSubmittedTime"]) {
                latest = max(latest, submitted)
            }
        }
        return GPUClientUsage(
            pid: pid, gpuTimeNanos: total, lastSubmittedNanos: latest,
            contextCount: max(1, appUsage.count))
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        switch value {
        case let n as UInt64: return n
        case let n as Int64: return n >= 0 ? UInt64(n) : nil
        case let n as Int: return n >= 0 ? UInt64(n) : nil
        case let n as NSNumber: return n.int64Value >= 0 ? n.uint64Value : nil
        default: return nil
        }
    }

    /// Nanoseconds now on the clock `lastSubmittedNanos` uses.
    public static func machNanosNow() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// The wall-clock moment of a mach-absolute nanosecond timestamp, or nil
    /// for 0 (never submitted) or a value ahead of the clock.
    public static func date(
        fromMachNanos nanos: UInt64, now: Date = Date(), machNow: UInt64 = machNanosNow()
    ) -> Date? {
        guard nanos > 0, nanos <= machNow else { return nil }
        return now.addingTimeInterval(-Double(machNow - nanos) / 1_000_000_000)
    }
}
