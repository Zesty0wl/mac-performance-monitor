import Foundation

/// Live physical block-device activity derived from IOKit's cumulative driver
/// counters. This is deliberately separate from per-process disk accounting:
/// device traffic and task-attributed traffic are related, but do not reconcile
/// exactly across filesystem caching, metadata, paging, and kernel work.
public struct DiskSample: Sendable, Equatable {
    public var timestamp: Date
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double
    public var readOperationsPerSec: Double
    public var writeOperationsPerSec: Double
    /// Ops-weighted average service time across all real devices this interval,
    /// nil when the interval saw zero operations: "no IO" must stay distinct
    /// from "0 ms" so history charts show a gap rather than a false fast disk.
    public var readLatencyMs: Double?
    public var writeLatencyMs: Double?
    /// Busiest device's share of the interval spent servicing IO, 0 to 100.
    /// The max (not the mean) so one saturated external drive reads as
    /// saturation. Nil on the first sample.
    public var utilizationPercent: Double?
    public var devices: [DiskDeviceSample]

    public init(
        timestamp: Date,
        readBytesPerSec: Double,
        writeBytesPerSec: Double,
        readOperationsPerSec: Double,
        writeOperationsPerSec: Double,
        readLatencyMs: Double? = nil,
        writeLatencyMs: Double? = nil,
        utilizationPercent: Double? = nil,
        devices: [DiskDeviceSample]
    ) {
        self.timestamp = timestamp
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
        self.readOperationsPerSec = readOperationsPerSec
        self.writeOperationsPerSec = writeOperationsPerSec
        self.readLatencyMs = readLatencyMs
        self.writeLatencyMs = writeLatencyMs
        self.utilizationPercent = utilizationPercent
        self.devices = devices
    }
}

/// One real internal or external disk. Virtual block devices such as mounted
/// disk images are excluded by `DiskReader` because their backing traffic is
/// already counted by the physical device underneath them.
public struct DiskDeviceSample: Sendable, Equatable, Identifiable {
    public var id: UInt64 { registryEntryID }
    public var registryEntryID: UInt64
    public var bsdName: String
    public var model: String
    public var protocolName: String?
    public var sizeBytes: UInt64?
    public var isInternal: Bool?
    public var isRemovable: Bool
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double
    public var readOperationsPerSec: Double
    public var writeOperationsPerSec: Double
    public var averageReadTimeMilliseconds: Double?
    public var averageWriteTimeMilliseconds: Double?
    public var readErrors: UInt64
    public var writeErrors: UInt64
    public var readRetries: UInt64
    public var writeRetries: UInt64
    /// Share of the interval this device spent servicing IO, 0 to 100, from the
    /// driver's total read plus write time deltas. Nil on the first sample or
    /// after a counter reset, matching the average-time convention above. The
    /// statistics dictionary has no queue-depth key, so busy time is the closest
    /// available saturation signal.
    public var utilizationPercent: Double? = nil
}
