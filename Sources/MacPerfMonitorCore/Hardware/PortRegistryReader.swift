import Foundation
import IOKit

/// Reads the registry records a `PortInventory` is built from. Every class
/// here is published to unprivileged processes; one read is a few
/// milliseconds, and nothing runs unless asked.
public enum PortRegistryReader {
    public static func inventory() -> PortInventory {
        PortInventoryParser.inventory(from: records())
    }

    static func records() -> PortRegistryRecords {
        var records = PortRegistryRecords()
        records.ports = dictionaries(matching: "IOPort")
        records.transports = dictionaries(matching: "IOPortTransportState")
        records.components = dictionaries(matching: "IOPortTransportComponent")
        records.powerSources = dictionaries(matching: "IOPortFeaturePowerSource")
        records.usbDevices = usbDevices()
        records.battery = batteryPowerKeys()
        return records
    }

    /// Whether the port drivers publish any USB receptacle (Apple silicon
    /// on recent macOS); without them the Ports section has nothing to say
    /// about USB and the USB bus tree stays.
    public static func reportsPorts() -> Bool {
        dictionaries(matching: "IOPort").contains {
            ($0["PortTypeDescription"] as? String)?.hasPrefix("USB") == true
        }
    }

    /// Just the live power figures, for a card that follows them.
    public static func powerInput() -> PowerInput? {
        PortInventoryParser.powerInput(from: batteryPowerKeys())
    }

    /// The properties of every entry of `className` (and its subclasses).
    static func dictionaries(matching className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let properties = properties(of: service) { out.append(properties) }
        }
        return out
    }

    /// Every USB device, each tagged with the `UsbIOPort` path of the host
    /// port above it: the root ports of each controller carry that path, so
    /// a device behind any number of hubs finds its receptacle by searching
    /// its parents.
    static func usbDevices() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard var record = properties(of: service) else { continue }
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            if let path = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "UsbIOPort" as CFString, kCFAllocatorDefault, options)
                as? String
            {
                record[PortRegistryRecords.usbIOPortKey] = path
            }
            out.append(record)
        }
        return out
    }

    /// The three `AppleSmartBattery` keys the power input comes from, read
    /// one by one rather than copying the whole (large) property table.
    static func batteryPowerKeys() -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var out: [String: Any] = [:]
        for key in ["ExternalConnected", "PowerTelemetryData", "AdapterDetails"] {
            if let value = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            {
                out[key] = value
            }
        }
        return out
    }

    private static func properties(of service: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard
            IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
                == KERN_SUCCESS
        else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }
}

/// Calls back shortly after anything is plugged into or pulled out of a
/// port: a USB device, a Power Delivery partner or cable, a charger, a
/// display link. Kernel notifications, so it costs nothing while nothing
/// changes; a burst of events (a dock brings up a dozen entries) settles into
/// one callback.
public final class PortChangeMonitor {
    /// The classes whose arrival or departure means the ports changed.
    static let watchedClasses = [
        "IOUSBHostDevice", "IOPortTransportState", "IOPortTransportComponent",
        "IOPortFeaturePowerSource",
    ]

    private let settle: TimeInterval
    private let onChange: () -> Void
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?

    /// `onChange` runs on the main queue, `settle` seconds after the last
    /// event of a burst.
    public init(settle: TimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.settle = settle
        self.onChange = onChange
    }

    deinit { stop() }

    public var isRunning: Bool { notifyPort != nil }

    /// Start watching. Must be called on the main thread.
    public func start() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return
        }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<PortChangeMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // Draining re-arms the notification; the entries themselves are
            // not needed, the inventory is re-read as a whole.
            var changed = false
            while case let service = IOIteratorNext(iterator), service != 0 {
                IOObjectRelease(service)
                changed = true
            }
            if changed { monitor.scheduleChange() }
        }
        for className in Self.watchedClasses {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let status = IOServiceAddMatchingNotification(
                    port, type, IOServiceMatching(className), callback, context, &iterator)
                guard status == KERN_SUCCESS else { continue }
                // The first-match iterator starts full of what already
                // exists; drain it without reporting a change.
                while case let service = IOIteratorNext(iterator), service != 0 {
                    IOObjectRelease(service)
                }
                iterators.append(iterator)
            }
        }
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators.removeAll()
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }
}
