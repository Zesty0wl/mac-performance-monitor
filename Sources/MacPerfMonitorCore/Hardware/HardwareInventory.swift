import Foundation

/// One area of the explorer and where its contents come from: `system_profiler`
/// data types (run in parallel, each in its own process), a native reader, or
/// both. `facts` pulls the typed figures the overview draws from out of the
/// raw `system_profiler` items.
public struct HardwareSectionSpec: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let dataTypes: [String]
    let native:
        (@Sendable (_ parentID: String, _ systemImage: String) -> HardwareNativeReaders.Result)?
    let facts: (@Sendable (_ itemsByType: [String: [[String: Any]]]) -> HardwareFacts)?
    /// A fallback data type used only when the primary ones come back empty
    /// (macOS 26 reports USB under `SPUSBHostDataType` and leaves the old
    /// `SPUSBDataType` empty; older systems the other way round).
    let fallbackDataTypes: [String]

    init(
        id: String, title: String, systemImage: String, dataTypes: [String] = [],
        fallbackDataTypes: [String] = [],
        native: (@Sendable (String, String) -> HardwareNativeReaders.Result)? = nil,
        facts: (@Sendable ([String: [[String: Any]]]) -> HardwareFacts)? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.dataTypes = dataTypes
        self.fallbackDataTypes = fallbackDataTypes
        self.native = native
        self.facts = facts
    }
}

/// Takes the inventory: every section, concurrently, reporting each as it
/// lands so a page can fill in progressively. Blocking; call off the main
/// thread. Nothing here runs on a timer: the explorer refreshes only when
/// asked.
public enum HardwareInventory {
    public static let specs: [HardwareSectionSpec] = [
        HardwareSectionSpec(
            id: "mac", title: "Mac", systemImage: "macbook", dataTypes: ["SPHardwareDataType"],
            native: { HardwareNativeReaders.identity(parentID: $0, systemImage: $1) }),
        HardwareSectionSpec(
            id: "processor", title: "Processor", systemImage: "cpu",
            native: { HardwareNativeReaders.processor(parentID: $0, systemImage: $1) }),
        HardwareSectionSpec(
            id: "graphics", title: "Graphics", systemImage: "square.grid.3x3.fill",
            native: { HardwareNativeReaders.graphics(parentID: $0, systemImage: $1) }),
        HardwareSectionSpec(
            id: "memory", title: "Memory", systemImage: "memorychip",
            dataTypes: ["SPMemoryDataType"],
            native: { HardwareNativeReaders.memory(parentID: $0, systemImage: $1) },
            facts: memoryFacts),
        HardwareSectionSpec(
            id: "displays", title: "Displays", systemImage: "display",
            dataTypes: ["SPDisplaysDataType"], facts: displayFacts),
        HardwareSectionSpec(
            id: "storage", title: "Storage", systemImage: "internaldrive",
            dataTypes: [
                "SPNVMeDataType", "SPSerialATADataType", "SPStorageDataType",
                "SPNetworkVolumeDataType",
            ], facts: storageFacts),
        HardwareSectionSpec(
            id: "power", title: "Power and battery", systemImage: "battery.100percent",
            dataTypes: ["SPPowerDataType"],
            native: { HardwareNativeReaders.battery(parentID: $0, systemImage: $1) }),
        HardwareSectionSpec(
            id: "sensors", title: "Sensors", systemImage: "thermometer.medium",
            native: { HardwareNativeReaders.sensors(parentID: $0, systemImage: $1) }),
        HardwareSectionSpec(
            id: "network", title: "Network", systemImage: "network",
            dataTypes: ["SPNetworkDataType", "SPEthernetDataType"]),
        HardwareSectionSpec(
            id: "wifi", title: "Wi-Fi", systemImage: "wifi",
            native: { HardwareNativeReaders.wifi(parentID: $0, systemImage: $1) }),
        HardwareSectionSpec(
            id: "bluetooth", title: "Bluetooth", systemImage: "antenna.radiowaves.left.and.right",
            dataTypes: ["SPBluetoothDataType"], facts: bluetoothFacts),
        HardwareSectionSpec(
            id: "usb", title: "USB", systemImage: "cable.connector",
            dataTypes: ["SPUSBHostDataType"], fallbackDataTypes: ["SPUSBDataType"], facts: usbFacts),
        HardwareSectionSpec(
            id: "thunderbolt", title: "Thunderbolt and USB4", systemImage: "bolt.horizontal",
            dataTypes: ["SPThunderboltDataType"], facts: thunderboltFacts),
        HardwareSectionSpec(
            id: "audio", title: "Audio", systemImage: "speaker.wave.2",
            dataTypes: ["SPAudioDataType"]),
        HardwareSectionSpec(
            id: "cameras", title: "Cameras", systemImage: "camera",
            dataTypes: ["SPCameraDataType"]),
        HardwareSectionSpec(
            id: "pci", title: "PCI", systemImage: "rectangle.connected.to.line.below",
            dataTypes: ["SPPCIDataType"]),
        HardwareSectionSpec(
            id: "peripherals", title: "Peripherals", systemImage: "keyboard",
            dataTypes: ["SPSPIDataType", "SPCardReaderDataType", "SPSmartCardsDataType"]),
        HardwareSectionSpec(
            id: "printers", title: "Printers and scanners", systemImage: "printer",
            dataTypes: ["SPPrintersDataType"]),
        HardwareSectionSpec(
            id: "security", title: "Security", systemImage: "lock.shield",
            dataTypes: ["SPiBridgeDataType", "SPSecureElementDataType"], facts: securityFacts),
        HardwareSectionSpec(
            id: "software", title: "Software", systemImage: "macwindow",
            dataTypes: ["SPSoftwareDataType"],
            native: { HardwareNativeReaders.software(parentID: $0, systemImage: $1) }),
    ]

    public static func spec(withID id: String) -> HardwareSectionSpec? {
        specs.first { $0.id == id }
    }

    /// Every section, at most `maxConcurrent` at a time, each handed to
    /// `progress` as it completes (on the thread that captured it).
    public static func capture(
        runner: SystemProfilerRunning = SystemProfilerRunner(), maxConcurrent: Int = 6,
        progress: (@Sendable (HardwareSection) -> Void)? = nil
    ) -> HardwareSnapshot {
        let specs = self.specs
        let gate = DispatchSemaphore(value: max(1, maxConcurrent))
        let lock = NSLock()
        var results: [String: HardwareSection] = [:]
        DispatchQueue.concurrentPerform(iterations: specs.count) { index in
            gate.wait()
            let section = capture(specs[index], runner: runner)
            gate.signal()
            lock.lock()
            results[section.id] = section
            lock.unlock()
            progress?(section)
        }
        let ordered = specs.compactMap { results[$0.id] }
        return HardwareSnapshot(sections: ordered, capturedAt: Date())
    }

    /// One section: native nodes first, then each data type's items.
    public static func capture(
        _ spec: HardwareSectionSpec, runner: SystemProfilerRunning
    ) -> HardwareSection {
        let start = Date()
        // `spec.title` stays the canonical English name (used as a stable
        // identifier); only the node/section title shown in the UI is
        // translated, and it is translated fresh on every capture so a
        // language switch takes effect on the next Refresh.
        var root = HardwareNode(id: spec.id, title: t(spec.title), systemImage: spec.systemImage)
        var facts = HardwareFacts()
        var notes: [String] = []

        if let native = spec.native {
            let result = native(spec.id, spec.systemImage)
            root.children += result.nodes
            facts.merge(result.facts)
        }

        var itemsByType: [String: [[String: Any]]] = [:]
        var produced = false
        for dataType in spec.dataTypes {
            guard let items = runner.items(for: dataType) else {
                notes.append(t("%@ did not report", dataType))
                continue
            }
            itemsByType[dataType] = items
            if !items.isEmpty { produced = true }
            root.children += SystemProfilerNodes.nodes(
                from: items, parentID: spec.id, dataType: dataType, systemImage: spec.systemImage)
        }
        if !produced {
            for dataType in spec.fallbackDataTypes {
                guard let items = runner.items(for: dataType), !items.isEmpty else { continue }
                itemsByType[dataType] = items
                root.children += SystemProfilerNodes.nodes(
                    from: items, parentID: spec.id, dataType: dataType,
                    systemImage: spec.systemImage)
            }
        }
        if let extract = spec.facts { facts.merge(extract(itemsByType)) }

        return HardwareSection(
            id: spec.id, title: t(spec.title), systemImage: spec.systemImage, root: root,
            note: notes.isEmpty ? nil : notes.joined(separator: "; "), facts: facts,
            captureSeconds: Date().timeIntervalSince(start))
    }

    // MARK: - Facts from system_profiler items

    @Sendable static func memoryFacts(_ items: [String: [[String: Any]]]) -> HardwareFacts {
        var facts = HardwareFacts()
        if let first = items["SPMemoryDataType"]?.first {
            var parts: [String] = []
            if let type = first["dimm_type"] as? String { parts.append(type) }
            if let maker = first["dimm_manufacturer"] as? String { parts.append(maker) }
            if !parts.isEmpty { facts.memoryType = parts.joined(separator: ", ") }
        }
        return facts
    }

    @Sendable static func displayFacts(_ items: [String: [[String: Any]]]) -> HardwareFacts {
        var facts = HardwareFacts()
        var displays: [HardwareFacts.Display] = []
        for gpu in items["SPDisplaysDataType"] ?? [] {
            if facts.gpuCores == nil, let cores = gpu["sppci_cores"] as? String,
                let count = Int(cores)
            {
                facts.gpuCores = count
            }
            if facts.metalSupport == nil,
                let metal = gpu["spdisplays_mtlgpufamilysupport"] as? String
            {
                facts.metalSupport = HardwareLabel.value(
                    metal, key: "spdisplays_mtlgpufamilysupport")
            }
            for display in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
                let name = display["_name"] as? String ?? t("Display")
                let pixels = (display["_spdisplays_pixels"] as? String).flatMap(parseDimensions)
                displays.append(
                    HardwareFacts.Display(
                        name: name, pixelWidth: pixels?.width ?? 0,
                        pixelHeight: pixels?.height ?? 0,
                        resolution: display["_spdisplays_resolution"] as? String,
                        isMain: (display["spdisplays_main"] as? String) == "spdisplays_yes",
                        isBuiltIn: (display["spdisplays_connection_type"] as? String)
                            == "spdisplays_internal"))
            }
        }
        if !displays.isEmpty { facts.displays = displays }
        return facts
    }

    /// "3600 x 2250" into its two numbers.
    static func parseDimensions(_ text: String) -> (width: Int, height: Int)? {
        let parts = text.lowercased().split(separator: "x").map {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 2, let width = parts[0], let height = parts[1] else { return nil }
        return (width, height)
    }

    @Sendable static func storageFacts(_ items: [String: [[String: Any]]]) -> HardwareFacts {
        var facts = HardwareFacts()
        var volumes: [HardwareFacts.Volume] = []
        for volume in items["SPStorageDataType"] ?? [] {
            guard let capacity = (volume["size_in_bytes"] as? NSNumber)?.uint64Value else {
                continue
            }
            let drive = volume["physical_drive"] as? [String: Any]
            volumes.append(
                HardwareFacts.Volume(
                    name: volume["_name"] as? String ?? t("Volume"),
                    mountPoint: volume["mount_point"] as? String, capacityBytes: capacity,
                    freeBytes: (volume["free_space_in_bytes"] as? NSNumber)?.uint64Value,
                    isInternal: (drive?["is_internal_disk"] as? String).map { $0 == "yes" }))
        }
        if !volumes.isEmpty { facts.volumes = volumes }
        return facts
    }

    @Sendable static func bluetoothFacts(_ items: [String: [[String: Any]]]) -> HardwareFacts {
        var facts = HardwareFacts()
        guard let first = items["SPBluetoothDataType"]?.first else { return facts }
        var parts: [String] = []
        if let controller = first["controller_properties"] as? [String: Any] {
            if let chipset = controller["controller_chipset"] as? String { parts.append(chipset) }
            if let state = controller["controller_state"] as? String {
                parts.append(HardwareLabel.value(state, key: "controller_state") ?? state)
            }
        }
        let connected = (first["device_connected"] as? [[String: Any]])?.count ?? 0
        parts.append(t("%@ connected", "\(connected)"))
        facts.bluetoothSummary = parts.joined(separator: ", ")
        return facts
    }

    @Sendable static func usbFacts(_ items: [String: [[String: Any]]]) -> HardwareFacts {
        var facts = HardwareFacts()
        func count(_ records: [[String: Any]]) -> Int {
            records.reduce(0) { total, record in
                let isDevice =
                    record["USBDeviceKeyVendorID"] != nil || record["vendor_id"] != nil
                return total + (isDevice ? 1 : 0)
                    + count(record["_items"] as? [[String: Any]] ?? [])
            }
        }
        let host = items["SPUSBHostDataType"] ?? []
        let legacy = items["SPUSBDataType"] ?? []
        facts.usbDeviceCount = count(host) + count(legacy)
        return facts
    }

    @Sendable static func thunderboltFacts(_ items: [String: [[String: Any]]]) -> HardwareFacts {
        var facts = HardwareFacts()
        let buses = items["SPThunderboltDataType"] ?? []
        guard !buses.isEmpty else { return facts }
        facts.thunderboltPortCount = buses.reduce(0) { total, bus in
            total + bus.keys.filter { $0.hasPrefix("receptacle_") && $0.hasSuffix("_tag") }.count
        }
        return facts
    }

    @Sendable static func securityFacts(_ items: [String: [[String: Any]]]) -> HardwareFacts {
        var facts = HardwareFacts()
        if let bridge = items["SPiBridgeDataType"]?.first,
            let secure = bridge["ibridge_secure_boot"] as? String
        {
            facts.secureBoot = secure
        }
        return facts
    }
}
