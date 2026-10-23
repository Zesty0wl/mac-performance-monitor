import Foundation

/// A problem, or a limit worth knowing about, that a port's own data shows.
public struct PortFinding: Hashable, Sendable, Codable, Identifiable {
    public enum Severity: String, Hashable, Sendable, Codable {
        /// A limit or a likely improvement, not a fault.
        case notice
        /// Something is wrong or blocked.
        case warning
    }

    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String

    public init(id: String, severity: Severity, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

/// Plain-language checks over one port. Each one reads only what the port
/// reported, so a finding is never a guess about hardware the Mac cannot see;
/// where the data can only suggest a cause the wording says so.
public enum PortDiagnostics {
    /// The property group a port's findings sit in, so the detail page can
    /// draw them as a panel and keep them out of the table.
    public static var propertyGroup: String { t("Diagnostics") }

    /// Below this the Mac charges slowly and can drain under load.
    static let lowPowerMilliWatts = 30_000

    public static func findings(
        for port: HardwarePort, powerInput: PowerInput? = nil
    )
        -> [PortFinding]
    {
        var findings: [PortFinding] = []

        if let count = port.overcurrentCount, count > 0 {
            findings.append(
                PortFinding(
                    id: "overcurrent", severity: .warning,
                    title: count == 1
                        ? t("Overcurrent reported once")
                        : t("Overcurrent reported %@ times", "\(count)"),
                    detail: t(
                        "The port cut power because an accessory drew more current than it "
                            + "allows. If this keeps happening, try another cable or accessory "
                            + "and check the connector for damage.")))
        }

        if port.liquidDetected == true {
            findings.append(
                PortFinding(
                    id: "liquid", severity: .warning, title: t("Liquid or debris detected"),
                    detail: t(
                        "macOS sensed moisture or debris in this port and may limit what it "
                            + "carries. Unplug the cable and let the port dry before using it "
                            + "again.")))
        }

        if port.authorizationPending || !port.transportsUnauthorized.isEmpty {
            findings.append(
                PortFinding(
                    id: "approval", severity: .warning, title: t("Accessory waiting for approval"),
                    detail: t(
                        "macOS is blocking data from this accessory until you allow it. Look "
                            + "for the Allow Accessory prompt, or change the setting in System "
                            + "Settings > Privacy & Security.")))
        }

        if port.isConnected, port.supportsSuperSpeed, port.cable?.speed == .usb2 {
            findings.append(
                PortFinding(
                    id: "cable-usb2", severity: .notice, title: t("Cable carries USB 2 data only"),
                    detail: t(
                        "The cable's marker reports USB 2.0 (480 Mbps). That is fine for "
                            + "charging and keyboards; use a USB 3, USB4 or Thunderbolt cable "
                            + "for drives, docks and displays.")))
        }

        for device in port.devices where device.isBelowDeclaredSpeed {
            findings.append(
                PortFinding(
                    id: "slow-\(device.locationID ?? 0)-\(device.name)", severity: .warning,
                    title: t("%@ is running at USB 2 speed", device.name),
                    detail: t(
                        "It reports USB %1$@ support but connected at %2$@. A USB 2 cable, hub "
                            + "or adapter in between is the usual cause.",
                        device.usbVersion ?? "3", device.linkLabel ?? "USB 2")))
        }

        if let source = port.activePowerSource, let winning = source.winning {
            if !source.isUSBPD {
                findings.append(
                    PortFinding(
                        id: "no-pd", severity: .notice,
                        title: t("Charging without USB Power Delivery"),
                        detail: t(
                            "This charger did not negotiate USB Power Delivery, so the port "
                                + "takes 5 V at most (%@). Charging is slow; a USB-C charger "
                                + "with Power Delivery is much faster.",
                            winning.milliWatts.map { PortFormat.watts($0) } ?? "15 W")))
            } else if let offered = source.maxOfferedMilliWatts, offered < lowPowerMilliWatts {
                findings.append(
                    PortFinding(
                        id: "low-power", severity: .notice,
                        title: t("Low-power charger (%@)", PortFormat.watts(offered)),
                        detail: t(
                            "The charger offers %@ at most. The Mac charges slowly from it and "
                                + "can drain under heavy load.", PortFormat.watts(offered))))
            } else if let cableCurrent = port.cable?.currentMilliAmps, cableCurrent <= 3000,
                let amps = winning.maxMilliAmps, amps >= 2900,
                (winning.milliVolts ?? winning.maxMilliVolts ?? 0) >= 15_000
            {
                findings.append(
                    PortFinding(
                        id: "cable-caps-power", severity: .notice,
                        title: t("Cable limits charging to 60 W"),
                        detail: t(
                            "The cable is rated 3 A, so the charger can supply at most 60 W "
                                + "through it. If the charger is rated higher, a 5 A (100 W or "
                                + "240 W) cable lets the Mac draw more.")))
            }
        }

        return findings
    }
}

/// Explorer nodes and overview summaries for the Ports section.
enum PortNodes {
    static var findingsGroup: String { PortDiagnostics.propertyGroup }

    static func nodeID(for port: HardwarePort, parentID: String) -> String {
        let slug = port.key.lowercased()
            .replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return "\(parentID)/\(slug)"
    }

    static func systemImage(for port: HardwarePort) -> String {
        if port.kind.hasPrefix("MagSafe") { return "powerplug" }
        if port.kind == "HDMI" { return "tv" }
        if port.kind.hasPrefix("SD") { return "sdcard" }
        return "cable.connector"
    }

    /// "USB-C 2" when the Mac has several of a kind, "HDMI" when it has one.
    static func title(for port: HardwarePort, in inventory: PortInventory) -> String {
        let kind = port.kind == "SD Card" ? t("SD card slot") : port.kind
        let siblings = inventory.ports.filter { $0.kind == port.kind }.count
        return siblings > 1 ? "\(kind) \(port.number)" : kind
    }

    /// What is plugged in, in a few words.
    static func headline(for port: HardwarePort) -> String {
        guard port.isConnected else {
            return port.kind.hasPrefix("SD") ? t("No card") : t("Nothing connected")
        }
        if port.kind.hasPrefix("SD") { return t("Card inserted") }
        let named = ["CIO", "USB3", "USB2", "DisplayPort"].lazy
            .compactMap { port.link($0) }
            .first { $0.isActive && $0.deviceName != nil }
        if let name = named?.deviceName { return name }
        if port.activePowerSource != nil { return t("Charger") }
        if let kind = port.partner?.partnerKind { return kind }
        return t("Connected")
    }

    /// The fastest active data link, then any display link: "USB 3 10 Gbps,
    /// DisplayPort 8.1 Gbps (HBR3)".
    static func dataLine(for port: HardwarePort) -> String? {
        let active = port.links.filter { $0.isActive && $0.transport != "SD" }
        var parts: [String] = []
        if let usb = active.first(where: { ["CIO", "USB3", "USB2"].contains($0.transport) }) {
            parts.append(linkLabel(usb))
        }
        for display in active where display.transport == "DisplayPort" {
            parts.append(linkLabel(display))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func powerLine(for port: HardwarePort) -> String? {
        if let source = port.activePowerSource, let winning = source.winning {
            return t("Charging: %@", winning.label)
        }
        if let offered = port.powerSources.compactMap(\.maxOfferedMilliWatts).max(), offered > 0 {
            return t("Charger offers up to %@", PortFormat.watts(offered))
        }
        return nil
    }

    private static func linkLabel(_ link: PortLink) -> String {
        var text = PortLink.displayName(link.transport)
        if let rate = link.rate { text += " \(rate)" }
        return text
    }

    static func summaries(
        for inventory: PortInventory, parentID: String
    )
        -> [HardwareFacts.PortSummary]
    {
        inventory.ports.map { port in
            let charging = port.activePowerSource != nil
            var lines: [String] = []
            if let data = dataLine(for: port) { lines.append(data) }
            if let power = powerLine(for: port) {
                lines.append(power)
            }
            if let cable = port.cable, port.isConnected { lines.append(cable.summary) }
            if !port.devices.isEmpty {
                lines.append(
                    port.devices.count == 1
                        ? t("1 USB device") : t("%@ USB devices", "\(port.devices.count)"))
            }
            return HardwareFacts.PortSummary(
                nodeID: nodeID(for: port, parentID: parentID),
                title: title(for: port, in: inventory), systemImage: systemImage(for: port),
                isConnected: port.isConnected, headline: headline(for: port), lines: lines,
                findings: PortDiagnostics.findings(
                    for: port, powerInput: charging ? inventory.powerInput : nil),
                isCharging: charging)
        }
    }

    static func nodes(for inventory: PortInventory, parentID: String) -> [HardwareNode] {
        inventory.ports.map { port in
            let id = nodeID(for: port, parentID: parentID)
            let charging = port.activePowerSource != nil
            let input = charging ? inventory.powerInput : nil
            var properties: [HardwareProperty] = []

            let findings = PortDiagnostics.findings(for: port, powerInput: input)
            let group = findingsGroup
            if findings.isEmpty {
                properties.append(HardwareProperty("Result", t("No problems found"), group: group))
            }
            for finding in findings {
                properties.append(HardwareProperty(finding.title, finding.detail, group: group))
            }

            properties += statusProperties(port)
            properties += dataProperties(port)
            properties += partnerProperties(port)
            properties += cableProperties(port)
            properties += powerProperties(port, input: input)
            properties += healthProperties(port)

            let children = deviceTree(port.devices, portID: id)
            return HardwareNode(
                id: id, title: title(for: port, in: inventory), subtitle: headline(for: port),
                systemImage: systemImage(for: port), properties: properties, children: children)
        }
    }

    private static func statusProperties(_ port: HardwarePort) -> [HardwareProperty] {
        var properties: [HardwareProperty] = []
        properties.append(
            HardwareProperty("Status", port.isConnected ? t("Connected") : headline(for: port)))
        if port.isConnected {
            properties.append(HardwareProperty("Connected to", headline(for: port)))
        }
        let supported = port.transportsSupported.filter { $0 != "CC" }
        if !supported.isEmpty {
            properties.append(
                HardwareProperty(
                    "Supports", supported.map(PortLink.displayName).joined(separator: ", ")))
        }
        let active = port.transportsActive.filter { $0 != "CC" }
        if port.isConnected {
            properties.append(
                HardwareProperty(
                    "In use",
                    active.isEmpty
                        ? t("Power only") : active.map(PortLink.displayName).joined(separator: ", ")
                )
            )
        }
        if let count = port.connectionCount {
            properties.append(HardwareProperty("Connection count", "\(count)"))
        }
        return properties
    }

    private static func dataProperties(_ port: HardwarePort) -> [HardwareProperty] {
        let group = t("Data")
        var properties: [HardwareProperty] = []
        for link in port.links where link.isActive {
            var parts: [String] = []
            if let rate = link.rate { parts.append(rate) }
            if let generation = link.generation, link.transport != "USB2" {
                parts.append(generation)
            }
            if let lanes = link.laneCount, lanes > 0 {
                parts.append(lanes == 1 ? t("1 lane") : t("%@ lanes", "\(lanes)"))
            }
            if let role = link.role { parts.append(roleLabel(role)) }
            if link.tunneled == true { parts.append(t("tunnelled")) }
            if let name = link.deviceName { parts.append(name) }
            properties.append(
                HardwareProperty(
                    PortLink.displayName(link.transport),
                    parts.isEmpty ? t("Active") : parts.joined(separator: ", "), group: group))
        }
        if let policy = port.links.lazy.compactMap(\.accessoryPolicy).first {
            var value = policy
            if let status = port.links.first(where: { $0.accessoryPolicy != nil })?.authorization {
                value += " (\(status))"
            }
            properties.append(HardwareProperty("Accessory security", value, group: group))
        }
        return properties
    }

    /// The driver's data role names, for people.
    static func roleLabel(_ role: String) -> String {
        switch role {
        case "Host": return t("Mac is host")
        case "Device": return t("Mac is device")
        case "Source": return t("Mac is source")
        case "Sink": return t("Mac is sink")
        default: return role
        }
    }

    private static func partnerProperties(_ port: HardwarePort) -> [HardwareProperty] {
        guard port.isConnected, let partner = port.partner else { return [] }
        let group = t("Connected device")
        var properties: [HardwareProperty] = []
        if let kind = partner.partnerKind {
            properties.append(HardwareProperty("Type", kind, group: group))
        }
        if let vendor = partner.vendorID {
            properties.append(
                HardwareProperty("Vendor ID", PortFormat.vendor(vendor), group: group))
        }
        if let product = partner.productID {
            properties.append(
                HardwareProperty("Product ID", String(format: "0x%04X", product), group: group))
        }
        if let revision = partner.specRevision {
            properties.append(HardwareProperty("USB PD revision", "\(revision)", group: group))
        }
        return properties
    }

    private static func cableProperties(_ port: HardwarePort) -> [HardwareProperty] {
        guard port.isConnected else { return [] }
        let group = t("Cable")
        guard let cable = port.cable else {
            // Only a USB-C link that spoke Power Delivery would have read a
            // marker; elsewhere the absence says nothing.
            guard port.partner != nil else { return [] }
            return [
                HardwareProperty(
                    "Electronic marker",
                    t("Not reported. Unmarked USB-C cables carry 3 A (60 W) at most."),
                    group: group)
            ]
        }
        var properties: [HardwareProperty] = []
        var kind = cable.kindLabel
        if port.reportsOpticalCable == true { kind += ", " + t("optical") }
        properties.append(HardwareProperty("Type", kind, group: group))
        if let vendor = cable.identity.vendorID {
            properties.append(
                HardwareProperty("Vendor ID", PortFormat.vendor(vendor), group: group))
        }
        if let product = cable.identity.productID {
            properties.append(
                HardwareProperty("Product ID", String(format: "0x%04X", product), group: group))
        }
        if let speed = cable.speed {
            properties.append(HardwareProperty("Data speed", speed.label, group: group))
        }
        if let current = cable.currentMilliAmps {
            properties.append(
                HardwareProperty("Current rating", PortFormat.amps(current), group: group))
        }
        if let watts = cable.maxWatts {
            properties.append(
                HardwareProperty(
                    "Power rating",
                    cable.eprCapable
                        ? t("%@ W (Extended Power Range)", "\(watts)") : "\(watts) W",
                    group: group))
        }
        if let volts = cable.maxVolts {
            properties.append(HardwareProperty("Maximum voltage", "\(volts) V", group: group))
        }
        if let length = cable.approximateLength {
            properties.append(HardwareProperty("Length (from signal delay)", length, group: group))
        }
        if cable.isCaptive == true {
            properties.append(
                HardwareProperty("Plug", t("Captive (fixed to the device)"), group: group))
        }
        return properties
    }

    private static func powerProperties(
        _ port: HardwarePort, input: PowerInput?
    )
        -> [HardwareProperty]
    {
        guard !port.powerSources.isEmpty else { return [] }
        let group = t("Power")
        var properties: [HardwareProperty] = []
        if let source = port.activePowerSource, let winning = source.winning {
            properties.append(HardwareProperty("Source in use", source.displayName, group: group))
            properties.append(HardwareProperty("Negotiated", winning.label, group: group))
            if let label = input?.label {
                properties.append(HardwareProperty("Drawing now", label, group: group))
            }
            if let watts = input?.adapterWatts {
                var value = "\(watts) W"
                if let name = input?.adapterName { value += " (\(name))" }
                properties.append(HardwareProperty("Adapter rating", value, group: group))
            }
        }
        for source in port.powerSources where !source.options.isEmpty {
            properties.append(
                HardwareProperty(
                    t("%@ options", source.displayName),
                    source.options.map(\.label).joined(separator: "\n"), group: group))
        }
        return properties
    }

    private static func healthProperties(_ port: HardwarePort) -> [HardwareProperty] {
        let group = t("Health")
        var properties: [HardwareProperty] = []
        if let count = port.overcurrentCount {
            properties.append(HardwareProperty("Overcurrent events", "\(count)", group: group))
        }
        if let liquid = port.liquidDetected {
            properties.append(
                HardwareProperty(
                    "Liquid detection", liquid ? t("Detected") : t("None detected"), group: group))
        }
        return properties
    }

    /// The port's USB devices nested the way they are cabled: each hub holds
    /// what is plugged into it. A device whose hub is not in the list (or
    /// that has no location ID) sits at the top. Ids carry the location ID,
    /// so a selection survives a refresh and a replug into the same socket.
    static func deviceTree(_ devices: [PortUSBDevice], portID: String) -> [HardwareNode] {
        let locations = Set(devices.compactMap(\.locationID))
        func parent(of device: PortUSBDevice) -> Int? {
            var location = device.locationID
            while let current = location, let up = PortUSBDevice.parentLocation(of: current) {
                if locations.contains(up) { return up }
                location = up
            }
            return nil
        }
        let byParent = Dictionary(grouping: devices.indices) { parent(of: devices[$0]) }
        func nodes(under parentLocation: Int?) -> [HardwareNode] {
            (byParent[parentLocation] ?? []).map { index in
                let device = devices[index]
                let suffix = device.locationID.map { String(format: "%08X", $0) } ?? "i\(index)"
                var node = deviceNode(device, id: "\(portID)/usb/\(suffix)")
                if let location = device.locationID {
                    node.children = nodes(under: location)
                }
                return node
            }
        }
        return nodes(under: nil)
    }

    private static func deviceNode(_ device: PortUSBDevice, id: String) -> HardwareNode {
        var properties: [HardwareProperty] = []
        if let vendor = device.vendor {
            properties.append(HardwareProperty("Manufacturer", vendor))
        }
        if let vendorID = device.vendorID {
            properties.append(HardwareProperty("Vendor ID", String(format: "0x%04X", vendorID)))
        }
        if let productID = device.productID {
            properties.append(HardwareProperty("Product ID", String(format: "0x%04X", productID)))
        }
        if let version = device.usbVersion {
            properties.append(HardwareProperty("USB version", version))
        }
        if let release = device.bcdDevice {
            properties.append(
                HardwareProperty("Firmware version", String(format: "0x%04X", release)))
        }
        if let serial = device.serialNumber {
            properties.append(HardwareProperty("Serial number", serial))
        }
        if let link = device.linkLabel { properties.append(HardwareProperty("Link speed", link)) }
        if let power = device.powerAllocationMilliAmps {
            properties.append(HardwareProperty("Power allocated", "\(power) mA"))
        }
        if let location = device.locationID {
            properties.append(HardwareProperty("Location ID", String(format: "0x%08X", location)))
        }
        if device.isBelowDeclaredSpeed {
            properties.append(
                HardwareProperty("Speed check", t("Below the USB version it declares")))
        }
        var subtitle: [String] = []
        if let link = device.linkLabel { subtitle.append(link) }
        if let version = device.usbVersion { subtitle.append("USB \(version)") }
        return HardwareNode(
            id: id, title: device.name,
            subtitle: subtitle.isEmpty ? nil : subtitle.joined(separator: ", "),
            systemImage: device.isHub ? "point.3.connected.trianglepath.dotted" : "cable.connector",
            properties: properties)
    }
}
