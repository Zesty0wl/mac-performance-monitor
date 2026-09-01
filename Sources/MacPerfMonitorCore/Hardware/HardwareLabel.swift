import Foundation

/// Turns `system_profiler`'s raw keys and enum-like values into the labels
/// System Information shows ("spdisplays_mtlgpufamilysupport" into "Metal
/// support", "spdisplays_built-in-liquid-retina-xdr" into "Built-in Liquid
/// Retina XDR"). Known keys have exact labels; unknown ones fall back to a
/// rule that strips the reporter prefix, splits the words, and fixes the
/// acronyms, so a key this table has never seen still reads as English.
public enum HardwareLabel {
    // MARK: - Keys

    public static func label(forKey key: String) -> String {
        // `keyOverrides` holds the canonical English label; translating here
        // catches every call site across the native readers and the
        // system_profiler walk without wrapping each one. The fallback below is
        // deliberately left untranslated: it only fires for a key this table has
        // never seen, so there is no bounded set of strings to translate, and
        // degrading to readable English beats showing a raw key.
        if let known = keyOverrides[key] { return t(known) }
        var stem = key
        while stem.hasPrefix("_") { stem.removeFirst() }
        var stripped = false
        for prefix in keyPrefixes where stem.hasPrefix(prefix) {
            stem.removeFirst(prefix.count)
            stripped = true
            break
        }
        if !stripped, let generic = reporterPrefix(of: stem) {
            stem.removeFirst(generic.count)
        }
        if stem.isEmpty { stem = key }
        for suffix in ["_key", "_tag"] where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
        }
        return sentence(words(in: stem))
    }

    /// An item's `_name` when it is a key-like token ("hardware_overview")
    /// rather than a real name ("USB 3.1 Bus").
    public static func title(forName name: String) -> String {
        if let known = nameOverrides[name] { return known }
        guard isKeyLike(name) else { return name }
        return sentence(words(in: name))
    }

    // MARK: - Values

    /// A value as the explorer shows it. Numbers are formatted by what the key
    /// says they are (bytes, hertz, watts); enum-like strings lose their
    /// reporter prefix and read as words; real strings pass through.
    public static func value(_ raw: Any, key: String) -> String? {
        switch raw {
        case let string as String:
            return value(string, key: key)
        case let number as NSNumber:
            // JSON booleans arrive as CFBoolean; a plain 0 or 1 is a number
            // (a sleep timer of 0 minutes is "Never", not "No").
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "Yes" : "No"
            }
            return value(number: number, key: key)
        case let strings as [String]:
            let cleaned = strings.map { value($0, key: key) ?? $0 }.filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
        default:
            return nil
        }
    }

    public static func value(_ raw: String, key: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let known = valueOverrides[trimmed] { return known }
        switch trimmed.lowercased() {
        case "true", "yes": return "Yes"
        case "false", "no": return "No"
        default: break
        }
        guard isKeyLike(trimmed) else { return trimmed }
        var stem = trimmed
        for prefix in valuePrefixes where stem.lowercased().hasPrefix(prefix) {
            stem.removeFirst(prefix.count)
            break
        }
        if let known = valueOverrides[stem] { return known }
        // An enum-like value is all lowercase ("built-in", "full-duplex"); a
        // chipset name or lot code with capitals ("BCM_4388") is an identifier
        // and must not be re-cased.
        if stem.contains(where: \.isUppercase) { return stem }
        if stem.hasSuffix("_enabled") { return "Enabled" }
        if stem.hasSuffix("_disabled") { return "Disabled" }
        let parts = words(in: stem)
        guard !parts.isEmpty else { return trimmed }
        return titleCase(parts)
    }

    private static func value(number: NSNumber, key: String) -> String {
        let lower = key.lowercased()
        if lower.hasSuffix("_in_bytes") || lower.hasSuffix("bytes") {
            let bytes = number.uint64Value
            return "\(ByteFormat.string(bytes, fractionDigits: 2)) (\(grouped(number)) bytes)"
        }
        if lower.hasSuffix("srate") || lower.hasSuffix("sample_rate") {
            return "\(grouped(number)) Hz"
        }
        if lower.hasSuffix("watts") { return "\(number) W" }
        if lower.contains("timer") {
            let minutes = number.intValue
            return minutes == 0 ? "Never" : "\(minutes) min"
        }
        if lower.contains("percent") || lower.contains("state_of_charge") {
            return "\(number)%"
        }
        if lower.hasSuffix("_duration") { return "\(number) s" }
        let double = number.doubleValue
        if double == double.rounded(), abs(double) >= 10_000 { return grouped(number) }
        return number.stringValue
    }

    private static func grouped(_ number: NSNumber) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: number) ?? number.stringValue
    }

    // MARK: - Word rules

    /// Lowercase with underscores or hyphens, optionally digits: a token, not
    /// prose. "Apple M3 Pro" and "Up to 40 Gb/s" are never key-like.
    static func isKeyLike(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        guard text.contains("_") || text.contains("-") || text.lowercased().hasPrefix("sp")
        else { return false }
        return text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// The "spusb_" / "spfoo_" reporter prefix at the start of a key, when
    /// the table above does not already name it.
    static func reporterPrefix(of stem: String) -> String? {
        guard let underscore = stem.firstIndex(of: "_") else { return nil }
        let head = stem[..<underscore]
        guard head.count > 2, head.hasPrefix("sp"),
            head.allSatisfy({ $0.isLetter && $0.isLowercase })
        else { return nil }
        return String(stem[...underscore])
    }

    /// Split on underscores, hyphens, and camelCase boundaries.
    static func words(in stem: String) -> [String] {
        var parts: [String] = []
        for chunk in stem.split(whereSeparator: { $0 == "_" || $0 == "-" }) {
            parts.append(contentsOf: splitCamel(String(chunk)))
        }
        return parts.filter { !$0.isEmpty }
    }

    private static func splitCamel(_ chunk: String) -> [String] {
        var words: [String] = []
        var current = ""
        let scalars = Array(chunk)
        for (index, char) in scalars.enumerated() {
            if index > 0, char.isUppercase {
                let previous = scalars[index - 1]
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                // "LinkSpeed" splits at S; "ProductID" keeps ID together;
                // "USBDevice" splits before the D that starts "Device".
                if previous.isLowercase || (previous.isUppercase && next?.isLowercase == true) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(char)
        }
        words.append(current)
        return words
    }

    /// "Serial number": first word capitalised, the rest lowercase, acronyms
    /// and expansions applied.
    static func sentence(_ parts: [String]) -> String {
        let expanded = parts.flatMap { expand($0) }
        return expanded.enumerated().map { index, word in
            let lower = word.lowercased()
            if let acronym = acronyms[lower] { return acronym }
            if index == 0 { return lower.prefix(1).uppercased() + lower.dropFirst() }
            return lower
        }.joined(separator: " ")
    }

    /// "Built In Liquid Retina XDR": every word capitalised, for enum values.
    static func titleCase(_ parts: [String]) -> String {
        parts.flatMap { expand($0) }.map { word in
            let lower = word.lowercased()
            if let acronym = acronyms[lower] { return acronym }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private static func expand(_ word: String) -> [String] {
        if let expansion = expansions[word.lowercased()] {
            return expansion.split(separator: " ").map(String.init)
        }
        // "metal4" -> "metal 4", "usb3" -> "usb 3", but "8k" and "3024x1964" stay.
        if let digitStart = word.firstIndex(where: \.isNumber), digitStart != word.startIndex,
            word[word.index(before: digitStart)].isLetter,
            word[digitStart...].allSatisfy(\.isNumber)
        {
            return [String(word[..<digitStart]), String(word[digitStart...])]
        }
        return [word]
    }

    // MARK: - Tables

    static let keyPrefixes: [String] = [
        "USBDeviceKey", "USBKey", "spdisplays_", "sppci_", "sppower_battery_",
        "sppower_ac_charger_", "sppower_", "spnvme_", "spusb_", "spethernet_", "spcamera_",
        "spairport_", "spcardreader_", "spnetworkvolume_", "spnetwork_", "coreaudio_device_",
        "coreaudio_", "spaudio_", "spbluetooth_", "controller_", "device_", "dimm_", "ibridge_sb_",
        "ibridge_", "spthunderbolt_", "spsmartcard_", "spprinters_", "spsoftware_", "sphardware_",
    ]

    static let valuePrefixes: [String] = [
        "spdisplays_", "sppci_vendor_", "sppci_", "coreaudio_device_type_", "coreaudio_",
        "spaudio_", "attrib_", "receptacle_", "spnvme_", "spusb_", "sppower_", "spairport_",
        "spnetwork_", "spethernet_", "spcamera_", "spbluetooth_", "spstorage_",
    ]

    static let acronyms: [String: String] = [
        "usb": "USB", "hdmi": "HDMI", "xdr": "XDR", "uhd": "UHD", "pci": "PCI", "pcie": "PCIe",
        "nvme": "NVMe", "ssd": "SSD", "hd": "HD", "id": "ID", "uuid": "UUID", "udid": "UDID",
        "mac": "MAC", "dhcp": "DHCP", "dns": "DNS", "ip": "IP", "ipv4": "IPv4", "ipv6": "IPv6",
        "ble": "BLE", "bsd": "BSD", "apfs": "APFS", "smart": "S.M.A.R.T.", "trim": "TRIM",
        "lcd": "LCD", "led": "LED", "ac": "AC", "ups": "UPS", "rom": "ROM", "os": "OS",
        "cpu": "CPU", "gpu": "GPU", "ane": "ANE", "ssv": "SSV", "sip": "SIP", "mdm": "MDM",
        "avb": "AVB", "mcs": "MCS", "phy": "PHY", "rssi": "RSSI", "wow": "WoW", "pcb": "PCB",
        "url": "URL", "uri": "URI", "uvc": "UVC", "lan": "LAN", "wan": "WAN", "ppd": "PPD",
        "cups": "CUPS", "airprint": "AirPrint", "ctrr": "CTRR", "kext": "kext", "guid": "GUID",
        "ftp": "FTP", "http": "HTTP", "https": "HTTPS", "rtsp": "RTSP", "socks": "SOCKS",
        "arp": "ARP", "vm": "VM", "ssid": "SSID", "bssid": "BSSID", "wpa": "WPA", "wpa2": "WPA2",
        "wpa3": "WPA3", "wep": "WEP", "ghz": "GHz", "mhz": "MHz", "tb": "TB", "gb": "GB",
        "mb": "MB", "kb": "KB", "usb4": "USB4", "thunderbolt": "Thunderbolt", "wifi": "Wi-Fi",
        "airdrop": "AirDrop", "autounlock": "Auto Unlock", "corewlan": "CoreWLAN",
        "corewlankit": "CoreWLANKit", "iphone": "iPhone", "ipad": "iPad", "macos": "macOS",
        "ios": "iOS", "lpddr5": "LPDDR5", "lpddr4": "LPDDR4", "lpddr5x": "LPDDR5X", "ddr5": "DDR5",
        "hfp": "HFP", "a2dp": "A2DP", "avrcp": "AVRCP", "hid": "HID", "gatt": "GATT",
        "lea": "LEA", "aacp": "AACP", "iop": "IOP", "apple": "Apple", "intel": "Intel",
        "amd": "AMD", "nvidia": "NVIDIA", "benq": "BenQ", "lg": "LG", "isc": "ISC", "efi": "EFI",
        "jpeg": "JPEG", "pdf": "PDF", "urf": "URF", "ps": "PS", "xhci": "xHCI",
        "thunderbolt/usb4": "Thunderbolt/USB4",
    ]

    static let expansions: [String: String] = [
        "num": "number", "srate": "sample rate", "fw": "firmware", "hw": "hardware",
        "mw": "middleware", "ver": "version", "addr": "address", "mfg": "manufacturer",
        "hwconfig": "hardware configuration", "mtlgpufamilysupport": "metal support",
        "ndrvs": "displays", "pixelresolution": "pixel resolution", "sb": "secure boot",
        "ctl": "controller", "se": "secure element", "plt": "platform", "prod": "production",
        "stfw": "ST firmware", "mtfw": "MT firmware", "iocontent": "content",
        "fsmtnonname": "mount point", "fstypename": "file system", "mntfromname": "mounted from",
        "automounted": "automounted", "caps": "capabilities", "corewlan": "CoreWLAN",
        "phymode": "PHY mode", "phymodes": "PHY modes", "thunderboltusb4": "Thunderbolt/USB4",
        "spbattery": "battery", "vendorid": "vendor ID", "productid": "product ID",
        "builtin": "built-in", "xhci": "xHCI", "ibridge": "iBridge",
    ]

    static let keyOverrides: [String: String] = [
        // Hardware overview
        "machine_model": "Model identifier", "machine_name": "Model",
        "model_number": "Model number",
        "chip_type": "Chip", "number_processors": "Processors", "physical_memory": "Memory",
        "platform_UUID": "Hardware UUID", "provisioning_UDID": "Provisioning UDID",
        "serial_number": "Serial number", "boot_rom_version": "Boot ROM version",
        "os_loader_version": "OS loader version", "activation_lock_status": "Activation Lock",
        "cpu_type": "Processor", "current_processor_speed": "Processor speed",
        "packages": "Processor packages", "l2_cache_core": "L2 cache (per core)",
        "l3_cache": "L3 cache", "SMC_version_system": "SMC version",
        // Memory
        "dimm_manufacturer": "Manufacturer", "dimm_type": "Type", "SPMemoryDataType": "Size",
        "dimm_size": "Size", "dimm_speed": "Speed", "dimm_status": "Status",
        "dimm_part_number": "Part number", "dimm_serial_number": "Serial number",
        // Displays
        "_spdisplays_pixels": "Pixels", "_spdisplays_resolution": "Resolution",
        "spdisplays_resolution": "UI looks like", "spdisplays_pixelresolution": "Pixel resolution",
        "_spdisplays_displayID": "Display ID", "_spdisplays_display-product-id": "Product ID",
        "_spdisplays_display-vendor-id": "Vendor ID",
        "_spdisplays_display-serial-number": "Serial number",
        "_spdisplays_display-week": "Manufacture week",
        "_spdisplays_display-year": "Manufacture year",
        "spdisplays_ambient_brightness": "Automatically adjust brightness",
        "spdisplays_connection_type": "Connection type", "spdisplays_display_type": "Display type",
        "spdisplays_main": "Main display", "spdisplays_mirror": "Mirror",
        "spdisplays_online": "Online", "spdisplays_rotation": "Rotation",
        "spdisplays_mtlgpufamilysupport": "Metal support", "spdisplays_vendor": "Vendor",
        "spdisplays_ndrvs": "Displays", "spdisplays_depth": "Colour depth",
        "spdisplays_dynamic_range": "Dynamic range", "spdisplays_display_serial": "Serial number",
        "spdisplays_virtualdevice": "Virtual device", "spdisplays_vram": "VRAM",
        "sppci_bus": "Bus", "sppci_cores": "Total number of cores", "sppci_device_type": "Type",
        "sppci_model": "Chipset model", "sppci_vendor_id": "Vendor ID",
        "sppci_device_id": "Device ID",
        "sppci_revision_id": "Revision ID", "sppci_link_width": "Link width",
        "sppci_link_speed": "Link speed", "sppci_slot": "Slot",
        "sppci_subsystem_id": "Subsystem ID",
        "sppci_subsystem_vendor_id": "Subsystem vendor ID", "sppci_name": "Name",
        // Power
        "sppower_battery_cycle_count": "Cycle count", "sppower_battery_health": "Condition",
        "sppower_battery_health_maximum_capacity": "Maximum capacity",
        "sppower_battery_state_of_charge": "State of charge",
        "sppower_battery_fully_charged": "Fully charged", "sppower_battery_is_charging": "Charging",
        "sppower_battery_at_warn_level": "At warning level",
        "sppower_battery_charger_connected": "Charger connected",
        "sppower_ac_charger_watts": "Wattage", "sppower_ac_charger_family": "Family",
        "sppower_ac_charger_ID": "ID", "sppower_ac_charger_name": "Name",
        "sppower_ac_charger_manufacturer": "Manufacturer",
        "sppower_ac_charger_serial_number": "Serial number",
        "sppower_ac_charger_firmware_version": "Firmware version",
        "sppower_ac_charger_hardware_version": "Hardware version",
        "sppower_battery_device_name": "Gas gauge",
        "sppower_battery_firmware_version":
            "Firmware version",
        "sppower_battery_hardware_revision": "Hardware revision",
        "sppower_battery_cell_revision": "Cell revision",
        "sppower_battery_pack_lot_code": "Pack lot code",
        "sppower_battery_pcb_lot_code":
            "PCB lot code",
        "sppower_battery_serial_number": "Serial number",
        "sppower_battery_manufacturer":
            "Manufacturer",
        "sppower_battery_manufacture_date": "Manufacture date",
        "sppower_battery_current_capacity": "Current capacity",
        "sppower_battery_max_capacity": "Full charge capacity",
        "sppower_battery_current_amperage": "Amperage",
        "sppower_battery_current_voltage": "Voltage",
        "sppower_ups_installed": "UPS installed", "sppower_battery_charge_info": "Charge",
        "sppower_battery_health_info": "Health", "sppower_battery_model_info": "Model",
        "sppower_battery_installed": "Battery installed",
        "Current Power Source": "Current power source", "Disk Sleep Timer": "Disk sleep",
        "Display Sleep Timer": "Display sleep", "System Sleep Timer": "System sleep",
        "Hibernate Mode": "Hibernate mode", "LowPowerMode": "Low Power Mode",
        "PrioritizeNetworkReachabilityOverSleep": "Prioritise network reachability over sleep",
        "ReduceBrightness": "Reduce brightness on battery",
        "Sleep On Power Button":
            "Sleep on power button",
        "Wake On LAN": "Wake on LAN", "Wake On AC Change": "Wake on AC change",
        "AutoPowerOff Enabled": "Auto power off", "AutoPowerOff Delay": "Auto power off delay",
        "DarkWakeBackgroundTasks": "Dark wake background tasks",
        "Standby Enabled": "Standby", "Standby Delay": "Standby delay",
        "Standby Delay High": "Standby delay (high charge)",
        "Standby Delay Low":
            "Standby delay (low charge)",
        "High Standby Threshold": "High standby threshold",
        "TCPKeepAlivePref":
            "TCP keep-alive",
        "GPUSwitch": "GPU switching",
        // Storage
        "bsd_name": "BSD name", "file_system": "File system", "free_space_in_bytes": "Free",
        "size_in_bytes": "Capacity", "mount_point": "Mount point", "volume_uuid": "Volume UUID",
        "writable": "Writable", "ignore_ownership": "Ignore ownership",
        "physical_drive": "Physical drive", "device_name": "Device name",
        "media_name": "Media name",
        "medium_type": "Medium type", "partition_map_type": "Partition map", "protocol": "Protocol",
        "smart_status": "S.M.A.R.T. status", "is_internal_disk": "Internal",
        "device_model": "Model", "device_revision": "Revision", "device_serial": "Serial number",
        "detachable_drive": "Detachable", "removable_media": "Removable media",
        "spnvme_trim_support": "TRIM support", "iocontent": "Content", "size": "Size",
        "spsata_ncq": "Native command queuing", "spsata_ncq_depth": "Queue depth",
        "spsata_link_speed": "Link speed", "spsata_negotiated_link_speed": "Negotiated link speed",
        "spsata_medium_type": "Medium type",
        "spsata_physical_interconnect": "Physical interconnect",
        "spsata_vendor": "Vendor", "spsata_product": "Product", "spsata_revision": "Revision",
        "spsata_serial": "Serial number",
        // USB
        "USBDeviceKeyLinkSpeed": "Link speed", "USBDeviceKeyProductID": "Product ID",
        "USBDeviceKeyVendorID": "Vendor ID", "USBDeviceKeyVendorName": "Vendor",
        "USBDeviceKeySerialNumber": "Serial number", "USBDeviceKeyProductVersion": "Version",
        "USBDeviceKeyPowerAllocation": "Power allocation", "USBKeyHardwareType": "Hardware type",
        "USBKeyLocationID": "Location ID", "Driver": "Driver",
        "vendor_id": "Vendor ID", "product_id": "Product ID", "bcd_device": "Version",
        "location_id": "Location ID", "bus_power": "Bus power available",
        "bus_power_used": "Bus power used", "extra_current_used": "Extra current used",
        "device_speed": "Speed", "manufacturer": "Manufacturer", "serial_num": "Serial number",
        "host_controller": "Host controller", "pci_device": "PCI device ID",
        "pci_revision": "PCI revision", "pci_vendor": "PCI vendor ID",
        // Thunderbolt
        "device_name_key": "Device", "domain_uuid_key": "Domain UUID",
        "route_string_key": "Route string", "switch_uid_key": "Switch UID",
        "vendor_name_key": "Vendor", "current_speed_key": "Speed", "link_status_key": "Link status",
        "receptacle_id_key": "Receptacle", "receptacle_status_key": "Status",
        "receptacle_1_tag": "Port", "receptacle_upstream_ambiguous_tag": "Upstream port",
        "device_id_key": "Device ID", "vendor_id_key": "Vendor ID", "mode_key": "Mode",
        "switch_version_key": "Switch version", "link_width_key": "Link width",
        "cable_serial_number_key": "Cable serial number",
        "cable_firmware_version_key":
            "Cable firmware version",
        "port_micro_firmware_version_key": "Port firmware version",
        // Bluetooth
        "controller_address": "Address", "controller_chipset": "Chipset",
        "controller_discoverable": "Discoverable", "controller_firmwareVersion": "Firmware version",
        "controller_productID": "Product ID", "controller_state": "State",
        "controller_supportedServices": "Supported services", "controller_transport": "Transport",
        "controller_vendorID": "Vendor ID", "controller_properties": "Controller",
        "device_connected": "Connected", "device_not_connected": "Not connected",
        "device_address": "Address", "device_firmwareVersion": "Firmware version",
        "device_minorType": "Type", "device_productID": "Product ID",
        "device_vendorID": "Vendor ID",
        "device_services": "Services", "device_rssi": "RSSI",
        "device_serialNumber": "Serial number",
        "device_serialNumberLeft": "Serial number (left)",
        "device_serialNumberRight":
            "Serial number (right)",
        "device_caseVersion": "Case version", "device_batteryLevelMain": "Battery",
        "device_batteryLevelLeft": "Battery (left)", "device_batteryLevelRight": "Battery (right)",
        "device_batteryLevelCase": "Battery (case)", "device_isConfigured": "Configured",
        "device_isPaired": "Paired", "device_majorType": "Class",
        // Audio
        "coreaudio_device_manufacturer": "Manufacturer", "coreaudio_device_input": "Input channels",
        "coreaudio_device_output": "Output channels", "coreaudio_device_srate": "Sample rate",
        "coreaudio_device_transport": "Transport", "coreaudio_input_source": "Input source",
        "coreaudio_output_source": "Output source",
        "coreaudio_default_audio_input_device": "Default input device",
        "coreaudio_default_audio_output_device": "Default output device",
        "coreaudio_default_audio_system_device": "Default system output device",
        // Cameras
        "spcamera_model-id": "Model ID", "spcamera_unique-id": "Unique ID",
        // Network
        "hardware": "Hardware", "interface": "Interface", "type": "Type",
        "ip_address": "IP addresses", "spnetwork_service_order": "Service order",
        "MAC Address": "MAC address", "MediaOptions": "Media options",
        "MediaSubType": "Media subtype",
        "ConfigMethod": "Configuration", "ServerAddresses": "Servers", "DomainName": "Domain",
        "Addresses": "Addresses", "SubnetMasks": "Subnet masks", "Router": "Router",
        "NetworkSignature": "Network signature", "ConfirmedInterfaceName": "Confirmed interface",
        "InterfaceName": "Interface", "ARPResolvedHardwareAddress": "ARP resolved hardware address",
        "ARPResolvedIPAddress": "ARP resolved IP address", "AdditionalRoutes": "Additional routes",
        "DestinationAddress": "Destination", "SubnetMask": "Subnet mask",
        "dhcp_domain_name": "Domain", "dhcp_domain_name_servers": "DNS servers",
        "dhcp_lease_duration": "Lease duration", "dhcp_message_type": "Message type",
        "dhcp_routers": "Routers", "dhcp_server_identifier": "Server",
        "dhcp_subnet_mask":
            "Subnet mask",
        "ExceptionsList": "Exceptions", "ExcludeSimpleHostnames": "Exclude simple hostnames",
        "FTPPassive": "FTP passive mode", "ProxyAutoConfigEnable": "Auto proxy configuration",
        "ProxyAutoDiscoveryEnable": "Auto proxy discovery", "HTTPEnable": "HTTP proxy",
        "HTTPSEnable": "HTTPS proxy", "FTPEnable": "FTP proxy", "SOCKSEnable": "SOCKS proxy",
        "RTSPEnable": "RTSP proxy", "GopherEnable": "Gopher proxy",
        "OverridePrimary":
            "Override primary",
        "spethernet_BSD_Device_Name": "BSD name", "spethernet_mac_address": "MAC address",
        "spethernet_product_name": "Product", "spethernet_vendor_name": "Vendor",
        "spethernet_avb_support": "AVB support", "spethernet_bus": "Bus",
        "spethernet_driver":
            "Driver",
        "spethernet_product-id": "Product ID", "spethernet_vendor-id": "Vendor ID",
        "spethernet_usb_device_speed": "USB speed", "spethernet_device-id": "Device ID",
        "spethernet_subsystem-id": "Subsystem ID",
        "spethernet_subsystem_vendor-id":
            "Subsystem vendor ID",
        "spethernet_revision-id": "Revision ID", "spethernet_link-width": "Link width",
        "spethernet_link-speed": "Link speed",
        // Security
        "ibridge_boot_uuid": "Boot UUID", "ibridge_build": "Build",
        "ibridge_extra_boot_policies": "Extra boot policies",
        "ibridge_model_identifier_top": "Model identifier",
        "ibridge_sb_boot_args":
            "Boot arguments",
        "ibridge_sb_ctrr": "Kernel CTRR", "ibridge_sb_device_mdm": "Device MDM",
        "ibridge_sb_manual_mdm": "Manual MDM", "ibridge_sb_other_kext": "User-approved kexts",
        "ibridge_sb_sip": "System Integrity Protection", "ibridge_sb_ssv": "Signed system volume",
        "ibridge_secure_boot": "Secure boot",
        "ctl_fw": "Controller firmware", "ctl_hw": "Controller hardware",
        "ctl_info":
            "Controller info",
        "ctl_mw": "Controller middleware", "se_device": "Device", "se_fw": "Firmware",
        "se_hw": "Hardware", "se_id": "ID", "se_in_restricted_mode": "Restricted mode",
        "se_info": "Info", "se_os_id": "OS ID", "se_os_version": "OS version", "se_plt": "Platform",
        "se_prod_signed": "Production signed",
        // Software
        "boot_mode": "Boot mode", "boot_volume": "Boot volume", "kernel_version": "Kernel",
        "local_host_name": "Computer name", "os_version": "System version",
        "secure_vm": "Secure virtual memory", "system_integrity": "System Integrity Protection",
        "uptime": "Time since boot", "user_name": "User",
        // SPI / card readers / network volumes
        "a_product_id": "Product ID", "b_vendor_id": "Vendor ID",
        "c_stfw_version":
            "ST firmware version",
        "d_serial_num": "Serial number", "f_manufacturer": "Manufacturer",
        "g_location_id":
            "Location ID",
        "h_mtfw_version": "MT firmware version", "i_hardware_id": "Hardware ID",
        "spcardreader_device-id": "Device ID", "spcardreader_link-speed": "Link speed",
        "spcardreader_link-width": "Link width", "spcardreader_revision-id": "Revision ID",
        "spcardreader_subsystem_vendor-id": "Subsystem vendor ID",
        "spcardreader_subsystem-id":
            "Subsystem ID",
        "spcardreader_vendor-id": "Vendor ID",
        "spnetworkvolume_automounted": "Automounted", "spnetworkvolume_fsmtnonname": "Mount point",
        "spnetworkvolume_fstypename": "File system", "spnetworkvolume_mntfromname": "Mounted from",
        // Printers
        "airprintversion": "AirPrint version", "creationDate": "Created",
        "cupsversion":
            "CUPS version",
        "driverversion": "Driver version", "ppdfileversion": "PPD file version",
        "printercommands": "Printer commands", "printerfirmwareversion": "Printer firmware version",
        "printerpdes": "PDEs", "printersharing": "Sharing", "printserver": "Print server",
        "psversion": "PostScript version", "scannerappbundlepath": "Scanner app bundle",
        "scannerapppath": "Scanner app", "scannerappversion": "Scanner app version",
        "scannerUUID": "Scanner UUID", "urfversion": "URF version", "cups filters": "CUPS filters",
        "Fax Support": "Fax support", "default": "Default printer", "shared": "Shared",
    ]

    static let nameOverrides: [String: String] = [
        "hardware_overview": "Hardware overview", "os_overview": "Operating system",
        "spbattery_information": "Battery", "sppower_information": "Power settings",
        "sppower_hwconfig_information": "Hardware configuration",
        "sppower_ac_charger_information": "Power adapter", "spairport_information": "Wi-Fi",
        "spairport_software_information": "Software versions",
        "spairport_airport_interfaces": "Interfaces",
        "spairport_current_network_information": "Current network",
        "spairport_airport_other_local_wireless_networks": "Other local networks",
        "spusb_bus": "USB bus", "coreaudio_device": "Audio device",
    ]

    static let valueOverrides: [String: String] = [
        "built-in-liquid-retina-xdr": "Built-in Liquid Retina XDR",
        "built-in-liquid-retina": "Built-in Liquid Retina", "built-in-retina": "Built-in Retina",
        "built-in-retina-lcd": "Built-in Retina LCD", "built-in": "Built-in", "builtin": "Built-in",
        "8k-uhd": "8K UHD", "4k-uhd": "4K UHD", "internal": "Internal", "external": "External",
        "normal_boot": "Normal", "safe_boot": "Safe mode", "recovery_boot": "Recovery",
        "no_devices_connected": "No devices connected", "devices_connected": "Devices connected",
        "unknown_partition_map_type": "Unknown", "guid_partition_map_type": "GUID partition map",
        "apple_partition_map_type": "Apple partition map",
        "master_boot_record_partition_map_type":
            "Master boot record",
        "spdisplays_yes": "Yes", "spdisplays_no": "No", "spdisplays_off": "Off",
        "spdisplays_on": "On", "spdisplays_supported": "Supported",
        "spdisplays_unsupported":
            "Not supported",
        "spdisplays_internal": "Internal", "spdisplays_builtin": "Built-in",
        "spdisplays_gpu": "GPU", "spdisplays_metal4": "Metal 4", "spdisplays_metal3": "Metal 3",
        "spdisplays_displayport_dongletype_dp": "DisplayPort",
        "spdisplays_displayport":
            "DisplayPort",
        "spdisplays_hdmi": "HDMI", "spdisplays_thunderbolt": "Thunderbolt",
        "spdisplays_usb_c": "USB-C", "spdisplays_dvi": "DVI",
        "sppci_vendor_Apple": "Apple", "sppci_vendor_intel": "Intel", "sppci_vendor_amd": "AMD",
        "sppci_vendor_nvidia": "NVIDIA", "spdisplays_builtin_device": "Built-in",
        "spdisplays_pcie_device": "PCIe", "spdisplays_egpu": "External GPU",
        "attrib_on": "On", "attrib_off": "Off", "attrib_yes": "Yes", "attrib_no": "No",
        "receptacle_no_devices_connected": "No devices connected",
        "receptacle_connected": "Device connected",
        "receptacle_no_device_connected":
            "No devices connected",
        "activation_lock_enabled": "Enabled", "activation_lock_disabled": "Disabled",
        "integrity_enabled": "Enabled", "integrity_disabled": "Disabled",
        "secure_vm_enabled": "Enabled", "secure_vm_disabled": "Disabled",
        "coreaudio_device_type_hdmi": "HDMI", "coreaudio_device_type_builtin": "Built-in",
        "coreaudio_device_type_usb": "USB", "coreaudio_device_type_bluetooth": "Bluetooth",
        "coreaudio_device_type_bluetoothle": "Bluetooth LE",
        "coreaudio_device_type_displayport":
            "DisplayPort",
        "coreaudio_device_type_thunderbolt": "Thunderbolt",
        "coreaudio_device_type_virtual":
            "Virtual",
        "coreaudio_device_type_aggregate": "Aggregate", "coreaudio_device_type_unknown": "Unknown",
        "coreaudio_device_type_continuity_capture": "Continuity Camera",
        "coreaudio_device_type_airplay": "AirPlay", "coreaudio_device_type_pci": "PCI",
        "coreaudio_device_type_firewire": "FireWire", "coreaudio_device_type_avb": "AVB",
        "spaudio_default": "Default", "spaudio_yes": "Yes", "spaudio_no": "No",
        "spnetwork_yes": "Yes", "spnetwork_no": "No", "ssd": "SSD", "rotational": "Rotational",
        "hdd": "HDD", "apple_fabric": "Apple Fabric", "usb": "USB", "pci-express": "PCI Express",
        "sata": "SATA", "thunderbolt": "Thunderbolt",
    ]
}
