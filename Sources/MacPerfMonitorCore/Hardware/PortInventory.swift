import Foundation

/// The Mac's physical ports as macOS's port drivers see them: what is plugged
/// into each one, what the link negotiated, what the cable's electronic marker
/// says it can carry, what the charger offers, and the port's own health
/// counters. Built from the `IOPort*` registry classes (macOS 14 and later on
/// Apple silicon) and readable without root. Every key involved is
/// undocumented, so every field is optional and a port that reports less just
/// shows less.
public struct PortInventory: Hashable, Sendable, Codable {
    public var ports: [HardwarePort]
    /// What the Mac is drawing from its charger right now, when one is
    /// connected.
    public var powerInput: PowerInput?

    public init(ports: [HardwarePort], powerInput: PowerInput?) {
        self.ports = ports
        self.powerInput = powerInput
    }

    /// The port the Mac is charging through: the one whose power source has a
    /// negotiated (winning) option.
    public var chargingPort: HardwarePort? {
        ports.first { $0.activePowerSource != nil }
    }
}

/// One physical port: a USB-C or Thunderbolt receptacle, MagSafe, HDMI, or the
/// SD card slot.
public struct HardwarePort: Hashable, Sendable, Codable, Identifiable {
    /// "USB-C@1", the same pairing the driver uses in "Port-USB-C@1".
    public var key: String
    /// The driver's port type name: "USB-C", "MagSafe 3", "HDMI", "SD Card".
    public var kind: String
    public var number: Int
    public var typeCode: Int?
    public var isConnected: Bool
    public var transportsSupported: [String] = []
    public var transportsActive: [String] = []
    public var transportsUnauthorized: [String] = []
    public var authorizationPending = false
    public var links: [PortLink] = []
    /// The device at the far end of the cable, from its USB Power Delivery
    /// identity (the SOP address).
    public var partner: PDIdentity?
    /// The cable's electronic marker (the SOP' address).
    public var cable: CableInfo?
    public var reportsActiveCable: Bool?
    public var reportsOpticalCable: Bool?
    public var powerSources: [PowerSource] = []
    public var overcurrentCount: Int?
    public var connectionCount: Int?
    public var liquidDetected: Bool?
    /// SD slot only.
    public var cardPresent: Bool?
    /// USB devices whose host port is this one, hubs included, in tree
    /// order (a hub before the devices behind it).
    public var devices: [PortUSBDevice] = []

    public var id: String { key }

    public init(key: String, kind: String, number: Int, isConnected: Bool) {
        self.key = key
        self.kind = kind
        self.number = number
        self.isConnected = isConnected
    }

    /// The power source the Mac negotiated a contract with on this port.
    public var activePowerSource: PowerSource? {
        powerSources.first { $0.winning != nil }
    }

    public func link(_ transport: String) -> PortLink? {
        links.first { $0.transport == transport }
    }

    /// Whether this receptacle can carry USB 3 or faster data.
    public var supportsSuperSpeed: Bool {
        transportsSupported.contains("USB3") || transportsSupported.contains("CIO")
    }
}

/// One transport the port can carry (USB 2, USB 3, DisplayPort, Thunderbolt /
/// USB4, SD) and what it negotiated.
public struct PortLink: Hashable, Sendable, Codable {
    /// The driver's transport name: "USB2", "USB3", "DisplayPort", "CIO", "SD".
    public var transport: String
    public var isActive: Bool
    /// "10 Gbps", "480 Mbps (High Speed)", "8.1 Gbps (HBR3)".
    public var rate: String?
    /// "USB 3.x", "Gen 2".
    public var generation: String?
    public var product: String?
    public var manufacturer: String?
    public var vendorID: Int?
    public var productID: Int?
    /// "Host", "Device", "Source".
    public var role: String?
    public var laneCount: Int?
    public var maxLaneCount: Int?
    public var tunneled: Bool?
    public var driverStatus: String?
    public var authorization: String?
    /// The accessory security setting this link was checked against, such as
    /// "Ask for New Accessories".
    public var accessoryPolicy: String?

    public init(transport: String, isActive: Bool) {
        self.transport = transport
        self.isActive = isActive
    }

    /// "USB 3", "Thunderbolt / USB4", for people rather than drivers.
    public static func displayName(_ transport: String) -> String {
        switch transport {
        case "USB2": return "USB 2"
        case "USB3": return "USB 3"
        case "CIO": return "Thunderbolt / USB4"
        case "DisplayPort": return "DisplayPort"
        case "SD": return "SD"
        case "CC": return t("Configuration channel")
        default: return transport
        }
    }

    /// Manufacturer and product, without repeating a manufacturer the product
    /// name already starts with.
    public var deviceName: String? {
        guard let product, !product.isEmpty else { return nil }
        guard let manufacturer, !manufacturer.isEmpty,
            !product.localizedCaseInsensitiveContains(manufacturer)
        else { return product }
        return "\(manufacturer) \(product)"
    }
}

/// A USB Power Delivery identity: the Discover Identity answer a partner or a
/// cable gave, with the header decoded.
public struct PDIdentity: Hashable, Sendable, Codable {
    public var vendorID: Int?
    public var productID: Int?
    public var bcdDevice: Int?
    public var specRevision: Int?
    /// The driver's own description ("Passive Cable") when it gives one.
    public var productTypeDescription: String?
    /// The raw Vendor Defined Objects, ID header first.
    public var vdos: [UInt32] = []

    public init(vendorID: Int? = nil, productID: Int? = nil, vdos: [UInt32] = []) {
        self.vendorID = vendorID
        self.productID = productID
        self.vdos = vdos
    }

    public var idHeader: UInt32? { vdos.first }

    /// The UFP (upstream-facing, the partner as a device) product type field,
    /// bits 29 to 27 of the ID header.
    public var ufpProductType: Int? { idHeader.map { Int(($0 >> 27) & 0x7) } }
    /// The DFP (downstream-facing, the partner as a host or charger) product
    /// type field, bits 25 to 23.
    public var dfpProductType: Int? { idHeader.map { Int(($0 >> 23) & 0x7) } }

    /// What the partner says it is, in words. Charger first: a hub with a
    /// power input reports both and the charger role is the one people ask
    /// about.
    public var partnerKind: String? {
        if let description = productTypeDescription, !description.isEmpty {
            return description
        }
        switch dfpProductType {
        case 3: return t("Charger")
        case 2: return t("USB host")
        case 1: return t("USB hub")
        default: break
        }
        switch ufpProductType {
        case 1: return t("USB hub")
        case 2: return t("USB peripheral")
        case 3: return t("Power-only device")
        case 5: return t("Alternate mode adapter")
        default: return nil
        }
    }
}

/// The cable's electronic marker, decoded from its Cable VDO (USB PD 3.x,
/// section 6.4.4.3.1.6 for passive cables and 6.4.4.3.1.7 for active ones;
/// the fields this reads sit in the same bits in both).
public struct CableInfo: Hashable, Sendable, Codable {
    public enum Speed: Int, Sendable, Codable, CaseIterable {
        case usb2 = 0
        case gen1 = 1
        case gen2 = 2
        case gen3 = 3
        case gen4 = 4

        public var label: String {
            switch self {
            case .usb2: return "USB 2.0 (480 Mbps)"
            case .gen1: return "USB 3.2 Gen 1 (5 Gbps)"
            case .gen2: return t("USB 3.2 Gen 2 (10 Gbps), USB4 20 Gbps")
            case .gen3: return "USB4 Gen 3 (40 Gbps)"
            case .gen4: return "USB4 Gen 4 (80 Gbps)"
            }
        }

        public var shortLabel: String {
            switch self {
            case .usb2: return "480 Mbps"
            case .gen1: return "5 Gbps"
            case .gen2: return "10 Gbps"
            case .gen3: return "40 Gbps"
            case .gen4: return "80 Gbps"
            }
        }
    }

    public var identity: PDIdentity
    public var isActive: Bool
    public var speed: Speed?
    public var currentMilliAmps: Int?
    public var maxVolts: Int?
    public var eprCapable: Bool
    public var latencyCode: Int?
    public var isCaptive: Bool?

    public init(identity: PDIdentity, isActive: Bool) {
        self.identity = identity
        self.isActive = isActive
        self.eprCapable = false
    }

    /// The most the cable carries: its current rating at 20 V, or at 48 V for
    /// an Extended Power Range cable (the 240 W class).
    public var maxWatts: Int? {
        guard let currentMilliAmps else { return nil }
        let volts = eprCapable ? 48 : 20
        return currentMilliAmps * volts / 1000
    }

    /// The signal delay the marker reports, as the length it implies (about
    /// 1 m per 10 ns): "about 1 m" for code 1 up to "over 7 m" for code 8.
    public var approximateLength: String? {
        guard let latencyCode, (1...8).contains(latencyCode) else { return nil }
        return latencyCode == 8 ? t("Over 7 m") : t("About %@ m", "\(latencyCode)")
    }

    /// Decode a Cable VDO (the fourth VDO in a cable's Discover Identity).
    public static func decode(
        cableVDO vdo: UInt32, identity: PDIdentity, isActive: Bool
    )
        -> CableInfo
    {
        var cable = CableInfo(identity: identity, isActive: isActive)
        cable.speed = Speed(rawValue: Int(vdo & 0x7))
        switch (vdo >> 5) & 0x3 {
        case 1: cable.currentMilliAmps = 3000
        case 2: cable.currentMilliAmps = 5000
        default: cable.currentMilliAmps = nil
        }
        // 00b 20 V, 01b 30 V, 10b 40 V, 11b 50 V (PD 3.1).
        cable.maxVolts = [20, 30, 40, 50][Int((vdo >> 9) & 0x3)]
        cable.latencyCode = Int((vdo >> 13) & 0xF)
        cable.eprCapable = (vdo >> 17) & 0x1 == 1
        switch (vdo >> 18) & 0x3 {
        case 2: cable.isCaptive = false
        case 3: cable.isCaptive = true
        default: cable.isCaptive = nil
        }
        return cable
    }

    /// One line for summaries: "Passive cable, 5 A (100 W), 10 Gbps".
    public var summary: String {
        var parts: [String] = [kindLabel]
        if let currentMilliAmps, let maxWatts {
            parts.append(t("%1$@ A (%2$@ W)", "\(currentMilliAmps / 1000)", "\(maxWatts)"))
        }
        if let speed { parts.append(speed.shortLabel) }
        return parts.joined(separator: ", ")
    }

    public var kindLabel: String {
        isActive ? t("Active cable") : t("Passive cable")
    }
}

/// One way the port can be powered (the driver lists USB-PD, Type-C current
/// and Apple's Brick ID separately) and the options it offered.
public struct PowerSource: Hashable, Sendable, Codable {
    /// "USB-PD", "TypeC", "Brick ID".
    public var name: String
    public var options: [PowerOption]
    /// The option the Mac chose, when this source is the one in use.
    public var winning: PowerOption?

    public init(name: String, options: [PowerOption], winning: PowerOption?) {
        self.name = name
        self.options = options
        self.winning = winning
    }

    public var isUSBPD: Bool { name == "USB-PD" }

    public var displayName: String {
        switch name {
        case "USB-PD": return "USB Power Delivery"
        case "TypeC": return t("USB-C current")
        case "Brick ID": return t("Apple adapter ID")
        default: return name
        }
    }

    /// The biggest option offered, in milliwatts.
    public var maxOfferedMilliWatts: Int? {
        options.compactMap(\.milliWatts).max()
    }
}

/// One power profile a charger offers: a fixed voltage, or a programmable
/// range, with its current limit.
public struct PowerOption: Hashable, Sendable, Codable {
    /// "Fixed", "PPS", "AVS" or whatever the driver's class suffix says.
    public var kind: String
    public var milliVolts: Int?
    public var minMilliVolts: Int?
    public var maxMilliVolts: Int?
    public var maxMilliAmps: Int?
    public var maxMilliWatts: Int?

    public init(
        kind: String, milliVolts: Int? = nil, minMilliVolts: Int? = nil,
        maxMilliVolts: Int? = nil, maxMilliAmps: Int? = nil, maxMilliWatts: Int? = nil
    ) {
        self.kind = kind
        self.milliVolts = milliVolts
        self.minMilliVolts = minMilliVolts
        self.maxMilliVolts = maxMilliVolts
        self.maxMilliAmps = maxMilliAmps
        self.maxMilliWatts = maxMilliWatts
    }

    /// The option's power, given or worked out from volts and amps.
    public var milliWatts: Int? {
        if let maxMilliWatts { return maxMilliWatts }
        guard let amps = maxMilliAmps, let volts = milliVolts ?? maxMilliVolts else { return nil }
        return volts * amps / 1000
    }

    /// "20 V, 4.8 A (96 W)" or "3.3 to 21 V, 3 A (PPS)".
    public var label: String {
        var parts: [String] = []
        if let milliVolts {
            parts.append(PortFormat.volts(milliVolts))
        } else if let minMilliVolts, let maxMilliVolts {
            parts.append(
                t("%1$@ to %2$@", PortFormat.volts(minMilliVolts), PortFormat.volts(maxMilliVolts)))
        }
        if let maxMilliAmps { parts.append(PortFormat.amps(maxMilliAmps)) }
        var text = parts.joined(separator: ", ")
        if let milliWatts { text += " (\(PortFormat.watts(milliWatts)))" }
        if kind != "Fixed" { text += " \(kind)" }
        return text
    }
}

/// What the Mac is drawing through its charger right now, from the SMC's
/// power telemetry. One figure for the whole Mac, so it belongs to whichever
/// port is charging.
public struct PowerInput: Hashable, Sendable, Codable {
    public var milliVolts: Int?
    public var milliAmps: Int?
    public var milliWatts: Int?
    public var adapterWatts: Int?
    public var adapterName: String?

    public init(
        milliVolts: Int? = nil, milliAmps: Int? = nil, milliWatts: Int? = nil,
        adapterWatts: Int? = nil, adapterName: String? = nil
    ) {
        self.milliVolts = milliVolts
        self.milliAmps = milliAmps
        self.milliWatts = milliWatts
        self.adapterWatts = adapterWatts
        self.adapterName = adapterName
    }

    /// "9.2 W".
    public var wattsLabel: String? {
        milliWatts.map { PortFormat.watts($0, fractionDigits: 1) }
    }

    /// "9.2 W (20.15 V, 0.46 A)".
    public var label: String? {
        guard let milliWatts else { return nil }
        var text = PortFormat.watts(milliWatts, fractionDigits: 1)
        if let milliVolts, let milliAmps {
            text +=
                " (\(PortFormat.volts(milliVolts, fractionDigits: 2)), "
                + "\(PortFormat.amps(milliAmps, fractionDigits: 2)))"
        }
        return text
    }
}

/// A USB device and the port it hangs off.
public struct PortUSBDevice: Hashable, Sendable, Codable {
    public var name: String
    public var vendor: String?
    public var vendorID: Int?
    public var productID: Int?
    /// The `Device Speed` code: 0 low, 1 full, 2 high, 3 SuperSpeed, 4 and
    /// up SuperSpeed+.
    public var speedCode: Int?
    public var linkBitsPerSecond: Int?
    /// The device descriptor's USB version, BCD (0x0320 is USB 3.2).
    public var bcdUSB: Int?
    public var deviceClass: Int?
    public var powerAllocationMilliAmps: Int?
    public var locationID: Int?
    public var serialNumber: String?
    /// The device's own release number, BCD (0x0194).
    public var bcdDevice: Int?

    public init(name: String) {
        self.name = name
    }

    /// The location ID of the hub this device hangs off. A location ID is
    /// the bus in the top byte, then one nibble per tier naming the port at
    /// that tier (0x00141100 is root port 1, hub port 4, hub port 1, port 1),
    /// so the parent is this one with its last port nibble cleared. Nil at
    /// the root of the bus.
    public static func parentLocation(of location: Int) -> Int? {
        for shift in stride(from: 0, to: 24, by: 4) where (location >> shift) & 0xF != 0 {
            let parent = location & ~(0xF << shift)
            return parent & 0x00FF_FFFF == 0 ? nil : parent
        }
        return nil
    }

    public var isHub: Bool { deviceClass == 9 }

    /// "3.2" from 0x0320.
    public var usbVersion: String? {
        guard let bcdUSB else { return nil }
        let major = (bcdUSB >> 8) & 0xFF
        let minor = (bcdUSB >> 4) & 0xF
        return "\(major).\(minor)"
    }

    /// Declares USB 3 or later but enumerated at USB 2 speed or below.
    public var isBelowDeclaredSpeed: Bool {
        guard let bcdUSB, let speedCode else { return false }
        return bcdUSB >= 0x0300 && speedCode <= 2
    }

    /// "480 Mbps", "10 Gbps".
    public var linkLabel: String? {
        guard let bps = linkBitsPerSecond, bps > 0 else { return nil }
        if bps >= 1_000_000_000 {
            let gbps = Double(bps) / 1_000_000_000
            return gbps == gbps.rounded()
                ? "\(Int(gbps)) Gbps"
                : String(format: "%.1f Gbps", locale: LocalizationTable.currentLocale, gbps)
        }
        let mbps = Double(bps) / 1_000_000
        return mbps == mbps.rounded()
            ? "\(Int(mbps)) Mbps"
            : String(format: "%.1f Mbps", locale: LocalizationTable.currentLocale, mbps)
    }
}

// MARK: - Formatting

enum PortFormat {
    static func volts(_ milliVolts: Int, fractionDigits: Int? = nil) -> String {
        number(Double(milliVolts) / 1000, fractionDigits: fractionDigits) + " V"
    }

    static func amps(_ milliAmps: Int, fractionDigits: Int? = nil) -> String {
        number(Double(milliAmps) / 1000, fractionDigits: fractionDigits) + " A"
    }

    static func watts(_ milliWatts: Int, fractionDigits: Int? = nil) -> String {
        number(Double(milliWatts) / 1000, fractionDigits: fractionDigits) + " W"
    }

    /// Whole numbers print bare ("20"), others with as few digits as they
    /// need ("4.8", "0.46"), unless `fractionDigits` fixes the count.
    static func number(_ value: Double, fractionDigits: Int?) -> String {
        let digits: Int
        if let fractionDigits {
            digits = fractionDigits
        } else if value == value.rounded() {
            digits = 0
        } else if (value * 10) == (value * 10).rounded() {
            digits = 1
        } else {
            digits = 2
        }
        return String(
            format: "%.\(digits)f", locale: LocalizationTable.currentLocale, value)
    }

    /// "0x291A (Anker)" or "0x1234".
    static func vendor(_ id: Int) -> String {
        let hex = String(format: "0x%04X", id)
        guard let name = USBVendorNames.name(for: id) else { return hex }
        return "\(hex) (\(name))"
    }
}

/// A short list of USB vendor IDs that turn up on cables, chargers, hubs and
/// docks. Only used to label raw IDs from USB-PD identities, which carry no
/// name of their own; anything not listed shows as the bare hex ID.
enum USBVendorNames {
    static func name(for id: Int) -> String? { table[id] }

    private static let table: [Int: String] = [
        0x03F0: "HP",
        0x0451: "Texas Instruments",
        0x045E: "Microsoft",
        0x046D: "Logitech",
        0x04E8: "Samsung",
        0x050D: "Belkin",
        0x054C: "Sony",
        0x05AC: "Apple",
        0x05C6: "Qualcomm",
        0x05E3: "Genesys Logic",
        0x0B05: "ASUS",
        0x0B95: "ASIX",
        0x0BDA: "Realtek",
        0x0E8D: "MediaTek",
        0x12D1: "Huawei",
        0x1532: "Razer",
        0x174C: "ASMedia",
        0x17EF: "Lenovo",
        0x18D1: "Google",
        0x1A86: "QinHeng",
        0x1B21: "ASMedia",
        0x2109: "VIA Labs",
        0x2717: "Xiaomi",
        0x291A: "Anker",
        0x413C: "Dell",
        0x8087: "Intel",
    ]
}

// MARK: - Parsing

/// The raw registry records a port inventory is built from, one dictionary
/// per registry entry. Kept separate from the IOKit reads so the parsing can
/// be tested against captured records.
struct PortRegistryRecords {
    /// `IOPort` entries (the receptacles).
    var ports: [[String: Any]] = []
    /// `IOPortTransportState` entries (USB2, USB3, DisplayPort, CIO, CC, SD).
    var transports: [[String: Any]] = []
    /// `IOPortTransportComponent` entries (the SOP partner and SOP' cable).
    var components: [[String: Any]] = []
    /// `IOPortFeaturePowerSource` entries.
    var powerSources: [[String: Any]] = []
    /// `IOUSBHostDevice` entries, each with `usbIOPortKey` added naming the
    /// host port it hangs off.
    var usbDevices: [[String: Any]] = []
    /// The `AppleSmartBattery` keys the power input comes from.
    var battery: [String: Any]?

    static let usbIOPortKey = "_UsbIOPort"
}

enum PortInventoryParser {
    static func inventory(from records: PortRegistryRecords) -> PortInventory {
        var ports: [HardwarePort] = []
        for record in records.ports {
            guard let kind = record["PortTypeDescription"] as? String,
                let number = int(record["PortNumber"])
            else { continue }
            var port = HardwarePort(
                key: "\(kind)@\(number)", kind: kind, number: number,
                isConnected: bool(record["ConnectionActive"]) ?? false)
            port.typeCode = int(record["PortType"])
            port.transportsSupported = record["TransportsSupported"] as? [String] ?? []
            port.transportsActive = record["TransportsActive"] as? [String] ?? []
            port.transportsUnauthorized = record["TransportsUnauthorized"] as? [String] ?? []
            port.authorizationPending =
                (bool(record["UserAuthorizationPending"]) ?? false)
                || (bool(record["AuthorizationPending"]) ?? false)
            port.reportsActiveCable = bool(record["ActiveCable"])
            port.reportsOpticalCable = bool(record["OpticalCable"])
            port.overcurrentCount = int(record["Overcurrent Count"])
            port.connectionCount = int(record["ConnectionCount"])
            port.liquidDetected = bool(record["LDCM_LiquidDetected"])
            port.cardPresent = bool(record["Card Present"])
            if port.kind == "SD Card", port.cardPresent == true { port.isConnected = true }
            ports.append(port)
        }

        func index(_ record: [String: Any]) -> Int? {
            guard let kind = record["ParentPortTypeDescription"] as? String,
                let number = int(record["ParentPortNumber"])
            else { return nil }
            return ports.firstIndex { $0.key == "\(kind)@\(number)" }
        }

        for record in records.transports {
            guard let i = index(record), let link = link(from: record), link.transport != "CC"
            else { continue }
            ports[i].links.append(link)
        }
        for i in ports.indices {
            ports[i].links.sort { order($0.transport) < order($1.transport) }
        }

        for record in records.components {
            guard let i = index(record) else { continue }
            let address =
                record["AddressDescription"] as? String ?? record["ComponentName"] as? String
            let identity = pdIdentity(from: record)
            if address == "SOP" {
                ports[i].partner = identity
            } else if address == "SOP'" {
                ports[i].cable = cable(from: identity)
            }
        }

        for record in records.powerSources {
            guard let i = index(record), let source = powerSource(from: record) else { continue }
            ports[i].powerSources.append(source)
        }
        for i in ports.indices {
            // The one in use first, then the richest.
            ports[i].powerSources.sort {
                ($0.winning != nil ? 0 : 1, -($0.maxOfferedMilliWatts ?? 0))
                    < ($1.winning != nil ? 0 : 1, -($1.maxOfferedMilliWatts ?? 0))
            }
        }

        for record in records.usbDevices {
            guard let path = record[PortRegistryRecords.usbIOPortKey] as? String,
                let last = path.split(separator: "/").last
            else { continue }
            var key = String(last)
            if key.hasPrefix("Port-") { key.removeFirst("Port-".count) }
            guard let i = ports.firstIndex(where: { $0.key == key }) else { continue }
            ports[i].devices.append(usbDevice(from: record))
        }
        // Location IDs encode the path through the hubs a nibble per tier,
        // so sorting by them lists a hub just before what hangs off it.
        for i in ports.indices {
            ports[i].devices.sort { ($0.locationID ?? 0) < ($1.locationID ?? 0) }
        }

        ports.sort { lhs, rhs in
            let l = (kindOrder(lhs.kind), lhs.number)
            let r = (kindOrder(rhs.kind), rhs.number)
            return l < r
        }
        return PortInventory(ports: ports, powerInput: powerInput(from: records.battery))
    }

    static func link(from record: [String: Any]) -> PortLink? {
        guard let transport = record["TransportTypeDescription"] as? String else { return nil }
        var link = PortLink(transport: transport, isActive: bool(record["Active"]) ?? false)
        link.rate =
            nonEmpty(record["DataRateDescription"] as? String)
            ?? nonEmpty(record["LinkRateDescription"] as? String)
        if let generation = nonEmpty(record["GenerationDescription"] as? String) {
            if let signaling = nonEmpty(record["SuperSpeedSignalingDescription"] as? String) {
                link.generation = "\(generation) \(signaling)"
            } else {
                link.generation = generation
            }
        }
        link.product =
            nonEmpty(record["Product"] as? String) ?? nonEmpty(record["ProductName"] as? String)
        // USB links only: a display's `ManufacturerName` is its three-letter
        // EDID code ("BNQ"), which reads as noise beside "BenQ MA320U".
        link.manufacturer = nonEmpty(record["Manufacturer"] as? String)
        link.vendorID = int(record["Vendor ID"])
        link.productID = int(record["Product ID"]) ?? int(record["ProductID"])
        link.role =
            nonEmpty(record["DataRoleDescription"] as? String)
            ?? nonEmpty(record["RoleDescription"] as? String)
        link.laneCount = int(record["LaneCount"])
        link.maxLaneCount = int(record["MaxLaneCount"])
        link.tunneled = bool(record["Tunneled"])
        link.driverStatus = nonEmpty(record["DriverStatusDescription"] as? String)
        link.authorization = nonEmpty(record["AuthorizationStatusDescription"] as? String)
        link.accessoryPolicy = nonEmpty(record["TRM_ProfileDescription"] as? String)
        return link
    }

    static func pdIdentity(from record: [String: Any]) -> PDIdentity {
        let metadata = record["Metadata"] as? [String: Any] ?? [:]
        let vdos = (metadata["VDOs"] as? [Data] ?? []).compactMap(littleEndianWord)
        var identity = PDIdentity(
            vendorID: int(record["Vendor ID"]) ?? int(metadata["Vendor ID"]),
            productID: int(record["Product ID"]) ?? int(metadata["Product ID"]), vdos: vdos)
        identity.bcdDevice = int(metadata["bcdDevice"])
        identity.specRevision = int(record["Specification Revision"])
        identity.productTypeDescription =
            nonEmpty(record["Product Type Description"] as? String)
            ?? nonEmpty(metadata["Product Type Description"] as? String)
        return identity
    }

    /// A cable from its SOP' identity. The product type says passive (3) or
    /// active (4); the Cable VDO is the fourth VDO, after the ID header, the
    /// cert stat and the product VDO.
    static func cable(from identity: PDIdentity) -> CableInfo {
        let isActive =
            identity.ufpProductType == 4
            || identity.productTypeDescription?.localizedCaseInsensitiveContains("active") == true
        guard identity.vdos.count >= 4 else {
            return CableInfo(identity: identity, isActive: isActive)
        }
        return CableInfo.decode(cableVDO: identity.vdos[3], identity: identity, isActive: isActive)
    }

    static func powerSource(from record: [String: Any]) -> PowerSource? {
        guard let name = nonEmpty(record["PowerSourceName"] as? String) else { return nil }
        let options = (record["PowerSourceOptions"] as? [[String: Any]] ?? []).map(powerOption)
        let winning = (record["WinningPowerSourceOption"] as? [String: Any]).map(powerOption)
        return PowerSource(name: name, options: options, winning: winning)
    }

    static func powerOption(from record: [String: Any]) -> PowerOption {
        var kind = record["Class"] as? String ?? "Fixed"
        if kind.hasPrefix("IOPortFeaturePowerSourceOption") {
            kind.removeFirst("IOPortFeaturePowerSourceOption".count)
        }
        if kind.isEmpty { kind = "Fixed" }
        var option = PowerOption(kind: kind)
        option.milliVolts = int(record["Voltage (mV)"])
        option.minMilliVolts =
            int(record["Min Voltage (mV)"]) ?? int(record["Minimum Voltage (mV)"])
        option.maxMilliVolts =
            int(record["Max Voltage (mV)"]) ?? int(record["Maximum Voltage (mV)"])
        option.maxMilliAmps = int(record["Max Current (mA)"])
        option.maxMilliWatts = int(record["Max Power (mW)"])
        return option
    }

    static func usbDevice(from record: [String: Any]) -> PortUSBDevice {
        // The k-prefixed strings are the device's own; the spelled-out keys
        // are registry-safe copies with "/" turned into "_".
        let name =
            nonEmpty(record["kUSBProductString"] as? String)
            ?? nonEmpty(record["USB Product Name"] as? String) ?? t("USB device")
        var device = PortUSBDevice(name: name)
        device.vendor =
            nonEmpty(record["kUSBVendorString"] as? String)
            ?? nonEmpty(record["USB Vendor Name"] as? String)
        device.vendorID = int(record["idVendor"])
        device.productID = int(record["idProduct"])
        device.speedCode = int(record["Device Speed"])
        device.linkBitsPerSecond = int(record["UsbLinkSpeed"])
        device.bcdUSB = int(record["bcdUSB"])
        device.deviceClass = int(record["bDeviceClass"])
        device.powerAllocationMilliAmps = int(record["UsbPowerSinkAllocation"])
        device.locationID = int(record["locationID"])
        device.serialNumber =
            nonEmpty(record["USB Serial Number"] as? String)
            ?? nonEmpty(record["kUSBSerialNumberString"] as? String)
        device.bcdDevice = int(record["bcdDevice"])
        return device
    }

    static func powerInput(from battery: [String: Any]?) -> PowerInput? {
        guard let battery, bool(battery["ExternalConnected"]) ?? true else { return nil }
        let telemetry = battery["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = battery["AdapterDetails"] as? [String: Any] ?? [:]
        var input = PowerInput()
        input.milliVolts = int(telemetry["SystemVoltageIn"]).flatMap { $0 > 0 ? $0 : nil }
        input.milliAmps = int(telemetry["SystemCurrentIn"]).flatMap { $0 >= 0 ? $0 : nil }
        input.milliWatts = int(telemetry["SystemPowerIn"]).flatMap { $0 >= 0 ? $0 : nil }
        input.adapterWatts = int(adapter["Watts"]).flatMap { $0 > 0 ? $0 : nil }
        input.adapterName =
            nonEmpty(adapter["Name"] as? String) ?? nonEmpty(adapter["Description"] as? String)
        guard input.milliWatts != nil || input.adapterWatts != nil else { return nil }
        return input
    }

    // MARK: Helpers

    /// A 32-bit VDO from the 4 bytes the driver stores, least significant
    /// first.
    static func littleEndianWord(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.prefix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// An integer from an NSNumber, rejecting values that only fit unsigned
    /// (the driver stores a few negative priorities as huge UInt64s).
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let unsigned = number.uint64Value
        guard unsigned <= UInt64(Int.max) else { return nil }
        return number.intValue
    }

    /// Booleans arrive as CFBoolean, but a few flags are plain 0/1 numbers.
    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        return value as? Bool
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }

    /// USB first, then video, then the rest.
    private static func order(_ transport: String) -> Int {
        ["CIO", "USB3", "USB2", "DisplayPort", "SD"].firstIndex(of: transport) ?? 9
    }

    /// USB-C first (Thunderbolt ports report as USB-C), then MagSafe, HDMI,
    /// the card slot, and anything new last.
    private static func kindOrder(_ kind: String) -> Int {
        if kind.hasPrefix("USB-C") || kind.hasPrefix("Thunderbolt") { return 0 }
        if kind.hasPrefix("USB") { return 1 }
        if kind.hasPrefix("MagSafe") { return 2 }
        if kind == "HDMI" { return 3 }
        if kind.hasPrefix("SD") { return 4 }
        return 5
    }
}
