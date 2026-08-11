import Foundation
import IOKit
import IOKit.storage

/// Reads static hardware identity for each physical disk from the registry
/// chain above its `IOBlockStorageDriver`: the block storage device's
/// characteristics dictionaries, the whole media's block size, and, when the
/// disk hangs off an NVMe controller, the controller's identity properties.
/// View-pulled by the Disk page at its slow poll cadence and cached per
/// registry entry, so it never touches the 1 Hz sampler path.
public final class DiskInfoReader {
    struct DeviceReadout: Sendable, Equatable {
        var registryEntryID: UInt64
        var bsdName: String
        var deviceCharacteristics: [String: String]
        var protocolCharacteristics: [String: String]
        var mediaPreferredBlockSize: UInt64?
        var controllerClass: String?
        var controllerProperties: [String: String]
        /// Registry entry IDs to try for the SMART plug-in, controller first.
        var smartCandidateIDs: [UInt64] = []
    }

    private let source: () -> [DeviceReadout]
    private var cache: [UInt64: DiskHardwareInfo] = [:]

    public convenience init() {
        self.init(source: Self.readDevices)
    }

    init(source: @escaping () -> [DeviceReadout]) {
        self.source = source
    }

    /// Hardware info keyed by the driver's registry entry ID (the same key
    /// `DiskDeviceSample.registryEntryID` carries). Cached per device for as
    /// long as the device stays in the registry; entries for vanished devices
    /// are dropped so an unplugged drive does not linger.
    public func read() -> [UInt64: DiskHardwareInfo] {
        let readouts = source()
        var next: [UInt64: DiskHardwareInfo] = [:]
        for readout in readouts {
            next[readout.registryEntryID] =
                cache[readout.registryEntryID] ?? Self.info(from: readout)
        }
        cache = next
        return next
    }

    public func reset() {
        cache.removeAll()
    }

    /// Pure mapping from a harvested readout to the public model, so the whole
    /// translation is testable against fixture dictionaries.
    static func info(from readout: DeviceReadout) -> DiskHardwareInfo {
        let device = readout.deviceCharacteristics
        let proto = readout.protocolCharacteristics
        let controller = readout.controllerProperties
        return DiskHardwareInfo(
            registryEntryID: readout.registryEntryID,
            bsdName: readout.bsdName,
            vendorName: nonEmpty(device["Vendor Name"]),
            productName: nonEmpty(device["Product Name"]),
            productRevision: nonEmpty(device["Product Revision Level"]),
            serialNumber: nonEmpty(device["Serial Number"] ?? controller["Serial Number"]),
            isSolidState: device["Medium Type"].map { $0 == "Solid State" },
            interconnect: nonEmpty(proto["Physical Interconnect"]),
            interconnectLocation: nonEmpty(proto["Physical Interconnect Location"]),
            physicalBlockSizeBytes: readout.mediaPreferredBlockSize,
            controllerClass: readout.controllerClass,
            firmwareRevision: nonEmpty(controller["Firmware Revision"]),
            nandStatus: nonEmpty(controller["AppleNANDStatus"]),
            nvmeRevision: nonEmpty(controller["NVMe Revision Supported"]),
            smartCandidateIDs: readout.smartCandidateIDs)
    }

    /// The registry publishes some identity strings as "" rather than omitting
    /// them (the internal SSD's vendor name, for one); treat empty as absent.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Real registry walk

    private static func readDevices() -> [DeviceReadout] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [DeviceReadout] = []
        var driver = IOIteratorNext(iterator)
        while driver != 0 {
            if let media = DiskReader.immediateWholeMedia(of: driver) {
                defer { IOObjectRelease(media) }
                if let bsdName = IOKitProperty.string(media, "BSD Name") {
                    var entryID: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(driver, &entryID)

                    var device: [String: String] = [:]
                    var proto: [String: String] = [:]
                    var storageDeviceID: UInt64?
                    var storageDevice: io_registry_entry_t = 0
                    if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &storageDevice)
                        == KERN_SUCCESS, storageDevice != 0
                    {
                        defer { IOObjectRelease(storageDevice) }
                        device = stringValues(
                            IOKitProperty.dictionary(storageDevice, "Device Characteristics"))
                        proto = stringValues(
                            IOKitProperty.dictionary(storageDevice, "Protocol Characteristics"))
                        var id: UInt64 = 0
                        if IORegistryEntryGetRegistryEntryID(storageDevice, &id) == KERN_SUCCESS {
                            storageDeviceID = id
                        }
                    }

                    var controllerClass: String?
                    var controllerProperties: [String: String] = [:]
                    var smartCandidates: [UInt64] = []
                    if let controller = IOKitProperty.firstParent(
                        of: driver, conformingTo: "IONVMeController")
                    {
                        defer { IOObjectRelease(controller) }
                        controllerClass = className(of: controller)
                        for key in [
                            "Firmware Revision", "Serial Number", "Model Number",
                            "AppleNANDStatus", "NVMe Revision Supported",
                        ] {
                            controllerProperties[key] = IOKitProperty.string(controller, key)
                        }
                        // Which entry vends the SMART plug-in varies by macOS
                        // release: try the controller first, then the block
                        // storage device between driver and controller.
                        var id: UInt64 = 0
                        if IORegistryEntryGetRegistryEntryID(controller, &id) == KERN_SUCCESS {
                            smartCandidates.append(id)
                        }
                        if let storageDeviceID {
                            smartCandidates.append(storageDeviceID)
                        }
                    }

                    result.append(
                        DeviceReadout(
                            registryEntryID: entryID,
                            bsdName: bsdName,
                            deviceCharacteristics: device,
                            protocolCharacteristics: proto,
                            mediaPreferredBlockSize: IOKitProperty.number(
                                media, "Preferred Block Size"),
                            controllerClass: controllerClass,
                            controllerProperties: controllerProperties,
                            smartCandidateIDs: smartCandidates))
                }
            }
            IOObjectRelease(driver)
            driver = IOIteratorNext(iterator)
        }
        return result
    }

    private static func stringValues(_ dictionary: [String: Any]?) -> [String: String] {
        guard let dictionary else { return [:] }
        return dictionary.compactMapValues { $0 as? String }
    }

    private static func className(of entry: io_registry_entry_t) -> String? {
        var name = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        guard IOObjectGetClass(entry, &name) == KERN_SUCCESS else { return nil }
        return String(cString: name)
    }
}
