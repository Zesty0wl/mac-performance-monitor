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
        self.init(counterSource: Self.readCounters, metadataSource: Self.readMetadata)
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
                    writeRetries: counters.writeRetries))
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
            devices: devices)
    }

    public func reset() {
        previous.removeAll()
    }

    private func rate(_ current: UInt64, _ prior: UInt64?, interval: TimeInterval) -> Double {
        guard let prior, interval > 0, current >= prior else { return 0 }
        return Double(current - prior) / interval
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

    private static func readCounters() -> [Counters] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [Counters] = []
        var driver = IOIteratorNext(iterator)
        while driver != 0 {
            if let media = immediateWholeMedia(of: driver) {
                defer { IOObjectRelease(media) }
                if let bsdName = stringProperty(media, "BSD Name"),
                    let stats = dictionaryProperty(driver, kIOBlockStorageDriverStatisticsKey)
                {
                    var entryID: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(driver, &entryID)
                    result.append(
                        Counters(
                            registryEntryID: entryID,
                            bsdName: bsdName,
                            readBytes: number(stats, kIOBlockStorageDriverStatisticsBytesReadKey),
                            writeBytes: number(
                                stats, kIOBlockStorageDriverStatisticsBytesWrittenKey),
                            readOperations: number(stats, kIOBlockStorageDriverStatisticsReadsKey),
                            writeOperations: number(
                                stats, kIOBlockStorageDriverStatisticsWritesKey),
                            readTimeNanoseconds: number(
                                stats, kIOBlockStorageDriverStatisticsTotalReadTimeKey),
                            writeTimeNanoseconds: number(
                                stats, kIOBlockStorageDriverStatisticsTotalWriteTimeKey),
                            readErrors: number(stats, kIOBlockStorageDriverStatisticsReadErrorsKey),
                            writeErrors: number(
                                stats, kIOBlockStorageDriverStatisticsWriteErrorsKey),
                            readRetries: number(
                                stats, kIOBlockStorageDriverStatisticsReadRetriesKey),
                            writeRetries: number(
                                stats, kIOBlockStorageDriverStatisticsWriteRetriesKey)))
                }
            }
            IOObjectRelease(driver)
            driver = IOIteratorNext(iterator)
        }
        return result
    }

    private static func immediateWholeMedia(of driver: io_registry_entry_t) -> io_registry_entry_t?
    {
        var iterator: io_iterator_t = 0
        guard
            IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var child = IOIteratorNext(iterator)
        while child != 0 {
            if IOObjectConformsTo(child, kIOMediaClass) != 0,
                boolProperty(child, "Whole") == true
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

    private static func dictionaryProperty(
        _ entry: io_registry_entry_t, _ key: String
    ) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func boolProperty(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private static func number(_ dictionary: [String: Any], _ key: String) -> UInt64 {
        (dictionary[key] as? NSNumber)?.uint64Value ?? 0
    }
}
