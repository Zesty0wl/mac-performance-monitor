import Foundation

/// Static hardware identity for one physical disk, harvested from the
/// IORegistry chain above its block storage driver. Every field is optional:
/// external and USB devices publish only a subset, and a missing value renders
/// as an omitted row, never a fabricated one. Keyed by the same driver registry
/// entry ID as `DiskDeviceSample`, so live activity and hardware detail join
/// trivially.
public struct DiskHardwareInfo: Sendable, Equatable, Identifiable {
    public var id: UInt64 { registryEntryID }
    public var registryEntryID: UInt64
    public var bsdName: String

    // Device Characteristics (IOBlockStorageDevice).
    public var vendorName: String?
    public var productName: String?
    public var productRevision: String?
    public var serialNumber: String?
    /// True when the device characteristics report "Solid State".
    public var isSolidState: Bool?

    // Protocol Characteristics: how the device is attached.
    public var interconnect: String?
    public var interconnectLocation: String?

    /// The whole media's preferred (physical) block size in bytes.
    public var physicalBlockSizeBytes: UInt64?

    // NVMe controller detail, nil for non-NVMe attachments.
    public var controllerClass: String?
    public var firmwareRevision: String?
    public var nandStatus: String?
    public var nvmeRevision: String?

    /// Registry entry IDs `NVMeSMARTReader` should try for this disk, in
    /// order. Empty when no NVMe controller was found above the device.
    public var smartCandidateIDs: [UInt64] = []
}
