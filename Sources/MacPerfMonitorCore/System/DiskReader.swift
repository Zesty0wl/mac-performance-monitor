import DiskArbitration
import Foundation
import IOKit
import IOKit.storage

/// Reads physical disk activity from each `IOBlockStorageDriver` statistics
/// dictionary. The counters are public, unprivileged, and cheap enough for the
/// app's 1 Hz system tick. Device metadata is resolved once through Disk
/// Arbitration and cached for the lifetime of that registry entry.
public final class DiskReader {
    struct Counters: Sendable, Equatable {
        var registryEntryID: UInt64
        var bsdName: String
        var readBytes: UInt64
        var writeBytes: UInt64
        var readOperations: UInt64
        var writeOperations: UInt64
        var readTimeNanoseconds: UInt64
        var writeTimeNanoseconds: UInt64
        var readErrors: UInt64
        var writeErrors: UInt64
        var readRetries: UInt64
        var writeRetries: UInt64
    }

    struct Metadata: Sendable, Equatable {
        var model: String
        var protocolName: String?
        var sizeBytes: UInt64?
        var isInternal: Bool?
        var isRemovable: Bool
        var isVirtual: Bool
    }

    private struct Previous {
        var counters: Counters
        var timestamp: Date
    }

    private let counterSource: () -> [Counters]
    private let metadataSource: (String) -> Metadata?
    private var previous: [UInt64: Previous] = [:]
    private var metadata: [UInt64: Metadata] = [:]

    public convenience init() {
        let enumerator = BlockStorageEnumerator()
        self.init(counterSource: { enumerator.counters() }, metadataSource: Self.readMetadata)
    }

    init(
        counterSource: @escaping () -> [Counters],
        metadataSource: @escaping (String) -> Metadata?
    ) {
        self.counterSource = counterSource
        self.metadataSource = metadataSource
    }

    /// Returns a zero-rate first sample, then differences each surviving
    /// registry entry over its real elapsed interval. A newly attached device or
    /// a reset counter starts at zero instead of producing a since-boot spike.
    public func read(now: Date = Date()) -> DiskSample {
        let current = counterSource()
        var nextPrevious: [UInt64: Previous] = [:]
        var devices: [DiskDeviceSample] = []
        var readTimeDeltaTotal: UInt64 = 0
        var readOpsDeltaTotal: UInt64 = 0
        var writeTimeDeltaTotal: UInt64 = 0
        var writeOpsDeltaTotal: UInt64 = 0

        for counters in current {
            let details =
                metadata[counters.registryEntryID]
                ?? metadataSource(counters.bsdName)
                ?? Metadata(
                    model: counters.bsdName, protocolName: nil, sizeBytes: nil,
                    isInternal: nil, isRemovable: false, isVirtual: false)
            metadata[counters.registryEntryID] = details
            guard !details.isVirtual else { continue }

            let prior = previous[counters.registryEntryID]
            let interval = prior.map { now.timeIntervalSince($0.timestamp) } ?? 0
            let readBytes = rate(counters.readBytes, prior?.counters.readBytes, interval: interval)
            let writeBytes = rate(
                counters.writeBytes, prior?.counters.writeBytes, interval: interval)
            let readOperations = rate(
                counters.readOperations, prior?.counters.readOperations, interval: interval)
            let writeOperations = rate(
                counters.writeOperations, prior?.counters.writeOperations, interval: interval)

            let readTimeDelta = delta(
                counters.readTimeNanoseconds, prior?.counters.readTimeNanoseconds)
            let writeTimeDelta = delta(
                counters.writeTimeNanoseconds, prior?.counters.writeTimeNanoseconds)
            if let readTimeDelta,
                let ops = delta(
                    counters.readOperations, prior?.counters.readOperations)
            {
                readTimeDeltaTotal += readTimeDelta
                readOpsDeltaTotal += ops
            }
            if let writeTimeDelta,
                let ops = delta(
                    counters.writeOperations, prior?.counters.writeOperations)
            {
                writeTimeDeltaTotal += writeTimeDelta
                writeOpsDeltaTotal += ops
            }
            let utilization: Double? = {
                guard interval > 0, let readTimeDelta, let writeTimeDelta else { return nil }
                let busyNanoseconds = Double(readTimeDelta + writeTimeDelta)
                return min(100, busyNanoseconds / (interval * 1_000_000_000) * 100)
            }()

            devices.append(
                DiskDeviceSample(
                    registryEntryID: counters.registryEntryID,
                    bsdName: counters.bsdName,
                    model: details.model,
                    protocolName: details.protocolName,
                    sizeBytes: details.sizeBytes,
                    isInternal: details.isInternal,
                    isRemovable: details.isRemovable,
                    readBytesPerSec: readBytes,
                    writeBytesPerSec: writeBytes,
                    readOperationsPerSec: readOperations,
                    writeOperationsPerSec: writeOperations,
                    averageReadTimeMilliseconds: averageMilliseconds(
                        total: counters.readTimeNanoseconds,
                        previousTotal: prior?.counters.readTimeNanoseconds,
                        operations: counters.readOperations,
                        previousOperations: prior?.counters.readOperations),
                    averageWriteTimeMilliseconds: averageMilliseconds(
                        total: counters.writeTimeNanoseconds,
                        previousTotal: prior?.counters.writeTimeNanoseconds,
                        operations: counters.writeOperations,
                        previousOperations: prior?.counters.writeOperations),
                    readErrors: counters.readErrors,
                    writeErrors: counters.writeErrors,
                    readRetries: counters.readRetries,
                    writeRetries: counters.writeRetries,
                    utilizationPercent: utilization))
            nextPrevious[counters.registryEntryID] = Previous(counters: counters, timestamp: now)
        }

        previous = nextPrevious
        devices.sort {
            switch ($0.isInternal, $1.isInternal) {
            case (true, false), (true, nil): return true
            case (false, true), (nil, true): return false
            default: return $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
            }
        }
        return DiskSample(
            timestamp: now,
            readBytesPerSec: devices.reduce(0) { $0 + $1.readBytesPerSec },
            writeBytesPerSec: devices.reduce(0) { $0 + $1.writeBytesPerSec },
            readOperationsPerSec: devices.reduce(0) { $0 + $1.readOperationsPerSec },
            writeOperationsPerSec: devices.reduce(0) { $0 + $1.writeOperationsPerSec },
            readLatencyMs: latency(timeDelta: readTimeDeltaTotal, opsDelta: readOpsDeltaTotal),
            writeLatencyMs: latency(timeDelta: writeTimeDeltaTotal, opsDelta: writeOpsDeltaTotal),
            utilizationPercent: devices.compactMap(\.utilizationPercent).max(),
            devices: devices)
    }

    public func reset() {
        previous.removeAll()
    }

    private func rate(_ current: UInt64, _ prior: UInt64?, interval: TimeInterval) -> Double {
        guard let prior, interval > 0, current >= prior else { return 0 }
        return Double(current - prior) / interval
    }

    /// Counter delta guarded the same way as `rate`: nil (not zero) without a
    /// prior sample or after a counter reset, so downstream averages skip the
    /// interval instead of folding in a bogus zero.
    private func delta(_ current: UInt64, _ prior: UInt64?) -> UInt64? {
        guard let prior, current >= prior else { return nil }
        return current - prior
    }

    /// Ops-weighted service time in milliseconds across every device that had a
    /// valid interval; nil when the interval saw zero completed operations.
    private func latency(timeDelta: UInt64, opsDelta: UInt64) -> Double? {
        guard opsDelta > 0 else { return nil }
        return Double(timeDelta) / Double(opsDelta) / 1_000_000
    }

    private func averageMilliseconds(
        total: UInt64, previousTotal: UInt64?, operations: UInt64,
        previousOperations: UInt64?
    ) -> Double? {
        guard let previousTotal, let previousOperations,
            total >= previousTotal, operations > previousOperations
        else { return nil }
        return Double(total - previousTotal) / Double(operations - previousOperations) / 1_000_000
    }

    /// One-shot enumeration plus read, for callers without a reader instance.
    static func readCounters() -> [Counters] {
        let enumerator = BlockStorageEnumerator()
        return enumerator.counters()
    }

    /// The statistics dictionary of one block storage driver as counters.
    fileprivate static func counters(
        registryEntryID: UInt64, bsdName: String, stats: [String: Any]
    ) -> Counters {
        Counters(
            registryEntryID: registryEntryID,
            bsdName: bsdName,
            readBytes: number(stats, kIOBlockStorageDriverStatisticsBytesReadKey),
            writeBytes: number(stats, kIOBlockStorageDriverStatisticsBytesWrittenKey),
            readOperations: number(stats, kIOBlockStorageDriverStatisticsReadsKey),
            writeOperations: number(stats, kIOBlockStorageDriverStatisticsWritesKey),
            readTimeNanoseconds: number(stats, kIOBlockStorageDriverStatisticsTotalReadTimeKey),
            writeTimeNanoseconds: number(stats, kIOBlockStorageDriverStatisticsTotalWriteTimeKey),
            readErrors: number(stats, kIOBlockStorageDriverStatisticsReadErrorsKey),
            writeErrors: number(stats, kIOBlockStorageDriverStatisticsWriteErrorsKey),
            readRetries: number(stats, kIOBlockStorageDriverStatisticsReadRetriesKey),
            writeRetries: number(stats, kIOBlockStorageDriverStatisticsWriteRetriesKey))
    }

    /// Internal (not private) so `DiskInfoReader` walks the identical chain and
    /// the two readers can never disagree about which media a driver owns.
    static func immediateWholeMedia(of driver: io_registry_entry_t) -> io_registry_entry_t? {
        var iterator: io_iterator_t = 0
        guard
            IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var child = IOIteratorNext(iterator)
        while child != 0 {
            if IOObjectConformsTo(child, kIOMediaClass) != 0,
                IOKitProperty.bool(child, "Whole") == true
            {
                return child
            }
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return nil
    }

    private static func readMetadata(bsdName: String) -> Metadata? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
            let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
            let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }

        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String ?? bsdName
        let protocolName = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let path = description[kDADiskDescriptionDevicePathKey as String] as? String ?? ""
        return Metadata(
            model: model,
            protocolName: protocolName,
            sizeBytes: (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?
                .uint64Value,
            isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
            isRemovable: description[kDADiskDescriptionMediaRemovableKey as String] as? Bool
                ?? false,
            isVirtual: model == "Disk Image" || protocolName == "Virtual Interface"
                || path.contains("IOHDIXController"))
    }

    private static func number(_ dictionary: [String: Any], _ key: String) -> UInt64 {
        (dictionary[key] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Enumerates the `IOBlockStorageDriver` services once every few seconds and
/// keeps their registry handles, so the per-tick read is one statistics
/// property fetch per disk rather than a fresh matching-services walk plus a
/// child iteration per driver. At the 4 Hz system tick the walk was about half
/// of the tick's cost. A disk that disappears makes its property read fail,
/// which forces a re-enumeration on the next read, so hot-plug still works
/// within one tick. Not thread-safe on its own; the sampler owns one and reads
/// it from a single queue.
final class BlockStorageEnumerator {
    private struct Entry {
        let driver: io_registry_entry_t
        let bsdName: String
        let registryEntryID: UInt64
    }

    private var entries: [Entry] = []
    private var lastEnumeration: TimeInterval = -.infinity
    private let refreshInterval: TimeInterval

    init(refreshInterval: TimeInterval = 5) {
        self.refreshInterval = refreshInterval
    }

    deinit { releaseEntries() }

    func counters() -> [DiskReader.Counters] {
        let now = TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
        if now - lastEnumeration >= refreshInterval {
            enumerate()
            lastEnumeration = now
        }
        var result: [DiskReader.Counters] = []
        result.reserveCapacity(entries.count)
        var stale = false
        for entry in entries {
            guard
                let stats = IOKitProperty.dictionary(
                    entry.driver, kIOBlockStorageDriverStatisticsKey)
            else {
                stale = true
                continue
            }
            result.append(
                DiskReader.counters(
                    registryEntryID: entry.registryEntryID, bsdName: entry.bsdName, stats: stats))
        }
        if stale {
            // A device went away: drop the handles and re-enumerate next read.
            releaseEntries()
            lastEnumeration = -.infinity
        }
        return result
    }

    private func enumerate() {
        releaseEntries()
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass), &iterator)
                == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        var driver = IOIteratorNext(iterator)
        while driver != 0 {
            var kept = false
            if let media = DiskReader.immediateWholeMedia(of: driver) {
                defer { IOObjectRelease(media) }
                if let bsdName = IOKitProperty.string(media, "BSD Name") {
                    var entryID: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(driver, &entryID)
                    entries.append(
                        Entry(driver: driver, bsdName: bsdName, registryEntryID: entryID))
                    kept = true
                }
            }
            if !kept { IOObjectRelease(driver) }
            driver = IOIteratorNext(iterator)
        }
    }

    private func releaseEntries() {
        for entry in entries { IOObjectRelease(entry.driver) }
        entries.removeAll()
    }
}
