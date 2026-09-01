import Foundation

/// Runs `system_profiler -json` for one data type. A protocol so the parser
/// can be fed fixture JSON in tests and so a section can be captured without
/// spawning anything.
public protocol SystemProfilerRunning: Sendable {
    /// The items under the data type's key, nil when the tool failed, timed
    /// out, or produced nothing parseable.
    func items(for dataType: String) -> [[String: Any]]?
}

/// The real thing: `/usr/sbin/system_profiler -json -timeout N <type>`, one
/// process per data type so the slow reporters (Bluetooth, displays, the
/// storage walk) run side by side and a hung one cannot hold up the rest.
public struct SystemProfilerRunner: SystemProfilerRunning {
    public var timeoutSeconds: Int

    public init(timeoutSeconds: Int = 25) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func items(for dataType: String) -> [[String: Any]]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-timeout", "\(timeoutSeconds)", dataType]
        process.qualityOfService = .utility
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain before waiting: a full pipe would block the child forever.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Self.parse(data, dataType: dataType)
    }

    public static func parse(_ data: Data, dataType: String) -> [[String: Any]]? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root[dataType] as? [[String: Any]]
        else { return nil }
        return items
    }
}

/// Converts `system_profiler` items into explorer nodes. The JSON is a
/// generic tree: every item has a `_name`, scalar keys become properties,
/// `_items` and other arrays of records become children, and nested records
/// (a volume's `physical_drive`, a service's `IPv4` block) become grouped
/// properties of the same node so they read in place and search with it.
public enum SystemProfilerNodes {
    /// Keys whose value, when present, makes a good subtitle, in preference
    /// order.
    static let subtitleKeys: [String] = [
        "sppci_model", "device_model", "spdisplays_display_type", "_spdisplays_resolution",
        "USBDeviceKeyVendorName", "controller_chipset", "device_minorType",
        "coreaudio_device_manufacturer", "spcamera_model-id", "medium_type", "file_system",
        "hardware", "spethernet_product_name", "device_name_key", "chip_type", "os_version",
        "dimm_type", "size", "physical_memory", "sppower_ac_charger_watts", "ibridge_secure_boot",
        "se_os_version", "controller_transport", "coreaudio_device_transport", "f_manufacturer",
        "spnetworkvolume_mntfromname", "uri", "spcardreader_vendor-id", "Driver",
    ]

    /// Raw keys that are the item's identity or structure, never properties.
    static let structuralKeys: Set<String> = ["_name", "_items", "_properties"]

    public static func nodes(
        from items: [[String: Any]], parentID: String, dataType: String, systemImage: String
    ) -> [HardwareNode] {
        items.enumerated().map { index, item in
            node(
                from: item, id: "\(parentID)/\(dataType)/\(index)", dataType: dataType,
                systemImage: systemImage, fallbackTitle: t("Item %@", "\(index + 1)"))
        }
    }

    public static func node(
        from item: [String: Any], id: String, dataType: String, systemImage: String,
        fallbackTitle: String
    ) -> HardwareNode {
        var node = HardwareNode(id: id, title: fallbackTitle, systemImage: systemImage)
        if let name = item["_name"] as? String, !name.isEmpty {
            node.title = HardwareLabel.title(forName: name)
        }
        if let itemsRaw = item["_items"] as? [[String: Any]] {
            node.children += itemsRaw.enumerated().map { index, child in
                self.node(
                    from: child, id: "\(id)/\(index)", dataType: dataType, systemImage: systemImage,
                    fallbackTitle: t("Item %@", "\(index + 1)"))
            }
        }
        var childOffset = node.children.count
        for key in sortedKeys(of: item) where !structuralKeys.contains(key) {
            let value = item[key]
            let label = HardwareLabel.label(forKey: key == dataType ? key : key)
            switch value {
            case let record as [String: Any]:
                add(
                    record: record, label: label, key: key, to: &node, childIDBase: id,
                    childOffset: &childOffset, dataType: dataType, systemImage: systemImage)
            case let records as [[String: Any]]:
                node.children += children(
                    from: records, label: label, idBase: "\(id)/\(childOffset)", dataType: dataType,
                    systemImage: systemImage)
                childOffset += 1
            default:
                if let value, let text = HardwareLabel.value(value, key: key) {
                    node.properties.append(HardwareProperty(label, text))
                }
            }
        }
        node.subtitle = subtitle(for: item)
        return node
    }

    /// A nested record becomes a group of properties; any arrays of records
    /// inside it become children titled after it.
    private static func add(
        record: [String: Any], label: String, key: String, to node: inout HardwareNode,
        childIDBase: String, childOffset: inout Int, dataType: String, systemImage: String
    ) {
        for innerKey in sortedKeys(of: record) where !structuralKeys.contains(innerKey) {
            let innerValue = record[innerKey]
            let innerLabel = HardwareLabel.label(forKey: innerKey)
            switch innerValue {
            case let nested as [String: Any]:
                // Two levels deep (a charger's details inside the power block):
                // flatten with a combined group name.
                var scratch = HardwareNode(id: "", title: "", systemImage: systemImage)
                var scratchOffset = 0
                add(
                    record: nested, label: innerLabel, key: innerKey, to: &scratch,
                    childIDBase: "\(childIDBase)/\(childOffset)", childOffset: &scratchOffset,
                    dataType: dataType, systemImage: systemImage)
                node.properties += scratch.properties.map {
                    HardwareProperty(
                        $0.label, $0.value, group: "\(label): \($0.group ?? innerLabel)")
                }
                node.children += scratch.children
            case let records as [[String: Any]]:
                node.children += children(
                    from: records, label: "\(label): \(innerLabel)",
                    idBase: "\(childIDBase)/\(childOffset)", dataType: dataType,
                    systemImage: systemImage)
                childOffset += 1
            default:
                if let innerValue, let text = HardwareLabel.value(innerValue, key: innerKey) {
                    node.properties.append(HardwareProperty(innerLabel, text, group: label))
                }
            }
        }
    }

    /// An array of records: each with a `_name` is an item; a single-key record
    /// whose value is a record (Bluetooth's `{"MX Master 3": {...}}`) is named
    /// by that key; anything else is numbered after the array's label.
    private static func children(
        from records: [[String: Any]], label: String, idBase: String, dataType: String,
        systemImage: String
    ) -> [HardwareNode] {
        records.enumerated().map { index, record in
            let childID = "\(idBase)/\(index)"
            if record["_name"] == nil, record.count == 1, let key = record.keys.first,
                let inner = record[key] as? [String: Any]
            {
                var child = node(
                    from: inner, id: childID, dataType: dataType, systemImage: systemImage,
                    fallbackTitle: key)
                child.title = key
                if child.subtitle == nil { child.subtitle = label }
                return child
            }
            var child = node(
                from: record, id: childID, dataType: dataType, systemImage: systemImage,
                fallbackTitle: records.count == 1
                    ? label : t("%1$@ %2$@", label, "\(index + 1)"))
            if child.subtitle == nil, record["_name"] != nil { child.subtitle = label }
            return child
        }
    }

    private static func subtitle(for item: [String: Any]) -> String? {
        for key in subtitleKeys {
            if let raw = item[key], let text = HardwareLabel.value(raw, key: key), !text.isEmpty,
                text != (item["_name"] as? String)
            {
                return text
            }
        }
        return nil
    }

    /// Identity first (model, vendor, type, serial, version), then the rest in
    /// label order, so a node's most telling facts lead.
    static func sortedKeys(of record: [String: Any]) -> [String] {
        record.keys.sorted { lhs, rhs in
            let lp = priority(of: lhs)
            let rp = priority(of: rhs)
            if lp != rp { return lp < rp }
            return HardwareLabel.label(forKey: lhs)
                .localizedCaseInsensitiveCompare(HardwareLabel.label(forKey: rhs))
                == .orderedAscending
        }
    }

    private static func priority(of key: String) -> Int {
        let lower = key.lowercased()
        let leading = [
            "model", "chip", "product", "vendor", "manufacturer", "type", "name", "serial",
            "version", "firmware", "size", "capacity", "resolution", "speed", "state", "status",
            "health", "cycle",
        ]
        for (index, stem) in leading.enumerated() where lower.contains(stem) { return index }
        if lower.hasPrefix("_") { return 40 }
        return 50
    }
}
