import XCTest

@testable import MacPerfMonitorCore

final class HardwareExplorerTests: XCTestCase {
    // MARK: - Labels

    func testKnownAndUnknownKeysReadAsEnglish() {
        XCTAssertEqual(
            HardwareLabel.label(forKey: "spdisplays_mtlgpufamilysupport"), "Metal support")
        XCTAssertEqual(HardwareLabel.label(forKey: "USBDeviceKeyLinkSpeed"), "Link speed")
        XCTAssertEqual(
            HardwareLabel.label(forKey: "controller_firmwareVersion"), "Firmware version")
        XCTAssertEqual(HardwareLabel.label(forKey: "sppower_battery_cycle_count"), "Cycle count")
        XCTAssertEqual(HardwareLabel.label(forKey: "_spdisplays_pixels"), "Pixels")
        XCTAssertEqual(HardwareLabel.label(forKey: "spnvme_trim_support"), "TRIM support")
        // Never seen before: prefix stripped, words split, acronyms fixed.
        XCTAssertEqual(HardwareLabel.label(forKey: "spfoo_link_width"), "Link width")
        XCTAssertEqual(
            HardwareLabel.label(forKey: "USBDeviceKeyFirmwareRevision"), "Firmware revision")
        XCTAssertEqual(HardwareLabel.label(forKey: "some_bsd_name_thing"), "Some BSD name thing")
        XCTAssertEqual(HardwareLabel.label(forKey: "device_serial_num"), "Serial number")
        XCTAssertEqual(HardwareLabel.title(forName: "hardware_overview"), "Hardware overview")
        XCTAssertEqual(
            HardwareLabel.title(forName: "thunderboltusb4_bus_2"), "Thunderbolt/USB4 bus 2")
        XCTAssertEqual(HardwareLabel.title(forName: "USB 3.1 Bus"), "USB 3.1 Bus")
    }

    func testValuesLoseReporterPrefixes() {
        XCTAssertEqual(HardwareLabel.value("spdisplays_yes", key: "x"), "Yes")
        XCTAssertEqual(
            HardwareLabel.value("spdisplays_built-in-liquid-retina-xdr", key: "x"),
            "Built-in Liquid Retina XDR")
        XCTAssertEqual(HardwareLabel.value("sppci_vendor_Apple", key: "x"), "Apple")
        XCTAssertEqual(HardwareLabel.value("coreaudio_device_type_hdmi", key: "x"), "HDMI")
        XCTAssertEqual(HardwareLabel.value("attrib_on", key: "x"), "On")
        XCTAssertEqual(
            HardwareLabel.value("receptacle_no_devices_connected", key: "x"), "No devices connected"
        )
        XCTAssertEqual(HardwareLabel.value("activation_lock_enabled", key: "x"), "Enabled")
        XCTAssertEqual(HardwareLabel.value("spdisplays_metal4", key: "x"), "Metal 4")
        XCTAssertEqual(HardwareLabel.value("TRUE", key: "x"), "Yes")
        XCTAssertEqual(HardwareLabel.value("no", key: "x"), "No")
        XCTAssertEqual(HardwareLabel.value("21.05\n", key: "x"), "21.05")
        XCTAssertNil(HardwareLabel.value("  ", key: "x"))
        // Prose passes through untouched.
        XCTAssertEqual(HardwareLabel.value("Apple M3 Pro", key: "x"), "Apple M3 Pro")
        XCTAssertEqual(HardwareLabel.value("Up to 40 Gb/s", key: "x"), "Up to 40 Gb/s")
        XCTAssertEqual(HardwareLabel.value("APPLE SSD AP0512Z", key: "x"), "APPLE SSD AP0512Z")
        XCTAssertEqual(HardwareLabel.value("0x1200003564fefb", key: "x"), "0x1200003564fefb")
    }

    func testNumbersFormatByKey() {
        let bytes = HardwareLabel.value(NSNumber(value: 494_384_795_648), key: "size_in_bytes")
        XCTAssertEqual(bytes, "460.43 GB (494,384,795,648 bytes)")
        XCTAssertEqual(
            HardwareLabel.value(NSNumber(value: 48000), key: "coreaudio_device_srate"), "48,000 Hz")
        XCTAssertEqual(HardwareLabel.value(NSNumber(value: 10), key: "Disk Sleep Timer"), "10 min")
        XCTAssertEqual(HardwareLabel.value(NSNumber(value: 0), key: "System Sleep Timer"), "Never")
        XCTAssertEqual(
            HardwareLabel.value(NSNumber(value: 100), key: "sppower_battery_state_of_charge"),
            "100%")
        XCTAssertEqual(HardwareLabel.value(NSNumber(value: 2), key: "coreaudio_device_output"), "2")
        XCTAssertEqual(
            HardwareLabel.value(["full-duplex", "spnetwork_yes"], key: "MediaOptions"),
            "Full Duplex, Yes")
        XCTAssertNil(HardwareLabel.value([String](), key: "MediaOptions"))
    }

    // MARK: - system_profiler parsing

    private static let fixture = """
        {
          "SPDisplaysDataType" : [
            {
              "_name" : "Apple M3 Pro",
              "spdisplays_mtlgpufamilysupport" : "spdisplays_metal4",
              "spdisplays_ndrvs" : [
                {
                  "_name" : "Color LCD",
                  "_spdisplays_pixels" : "3600 x 2250",
                  "_spdisplays_resolution" : "1800 x 1125 @ 120.00Hz",
                  "spdisplays_connection_type" : "spdisplays_internal",
                  "spdisplays_display_type" : "spdisplays_built-in-liquid-retina-xdr",
                  "spdisplays_main" : "spdisplays_yes"
                },
                {
                  "_name" : "BenQ MA320U",
                  "_spdisplays_pixels" : "7680 x 4320",
                  "_spdisplays_resolution" : "3840 x 2160 @ 60.00Hz",
                  "spdisplays_rotation" : "spdisplays_supported"
                }
              ],
              "spdisplays_vendor" : "sppci_vendor_Apple",
              "sppci_cores" : "14",
              "sppci_model" : "Apple M3 Pro"
            }
          ],
          "SPStorageDataType" : [
            {
              "_name" : "Macintosh HD - Data",
              "bsd_name" : "disk3s1",
              "file_system" : "APFS",
              "free_space_in_bytes" : 24946704384,
              "mount_point" : "/System/Volumes/Data",
              "physical_drive" : {
                "device_name" : "APPLE SSD AP0512Z",
                "is_internal_disk" : "yes",
                "medium_type" : "ssd",
                "smart_status" : "Verified"
              },
              "size_in_bytes" : 494384795648
            }
          ],
          "SPBluetoothDataType" : [
            {
              "controller_properties" : {
                "controller_address" : "80:A9:97:21:58:C1",
                "controller_chipset" : "BCM_4388",
                "controller_state" : "attrib_on"
              },
              "device_connected" : [
                { "MX Master 3" : { "device_address" : "F2:98:8E:17:38:D9", "device_minorType" : "Mouse" } }
              ],
              "device_not_connected" : [
                { "iPad" : { "device_address" : "34:31:8F:69:35:42" } }
              ]
            }
          ],
          "SPUSBHostDataType" : [
            { "_name" : "USB 3.1 Bus", "Driver" : "AppleT8122USBXHCI", "USBKeyLocationID" : "0x02000000" },
            {
              "_items" : [
                {
                  "_items" : [
                    {
                      "_name" : "USB 10/100/1000 LAN",
                      "USBDeviceKeyLinkSpeed" : "5 Gb/s",
                      "USBDeviceKeyVendorID" : "0x0bda",
                      "USBDeviceKeyVendorName" : "Realtek"
                    }
                  ],
                  "_name" : "USB3.1 Hub",
                  "USBDeviceKeyVendorID" : "0x2109",
                  "USBDeviceKeyVendorName" : "Anker"
                }
              ],
              "_name" : "USB 3.1 Bus",
              "Driver" : "AppleT8122USBXHCI"
            }
          ],
          "SPThunderboltDataType" : [
            { "_name" : "thunderboltusb4_bus_2", "receptacle_1_tag" : { "current_speed_key" : "Up to 40 Gb/s", "receptacle_status_key" : "receptacle_no_devices_connected" } },
            { "_name" : "thunderboltusb4_bus_1", "receptacle_1_tag" : { "current_speed_key" : "Up to 40 Gb/s" } }
          ]
        }
        """.data(using: .utf8)!

    private func items(_ type: String) -> [[String: Any]] {
        SystemProfilerRunner.parse(Self.fixture, dataType: type) ?? []
    }

    func testDisplaysBecomeNestedNodesWithReadableProperties() {
        let nodes = SystemProfilerNodes.nodes(
            from: items("SPDisplaysDataType"), parentID: "displays", dataType: "SPDisplaysDataType",
            systemImage: "display")
        XCTAssertEqual(nodes.count, 1)
        let gpu = nodes[0]
        XCTAssertEqual(gpu.title, "Apple M3 Pro")
        XCTAssertEqual(gpu.id, "displays/SPDisplaysDataType/0")
        XCTAssertTrue(gpu.properties.contains(HardwareProperty("Metal support", "Metal 4")))
        XCTAssertTrue(gpu.properties.contains(HardwareProperty("Vendor", "Apple")))
        XCTAssertTrue(gpu.properties.contains(HardwareProperty("Total number of cores", "14")))
        XCTAssertEqual(gpu.children.map(\.title), ["Color LCD", "BenQ MA320U"])
        let lcd = gpu.children[0]
        XCTAssertEqual(lcd.subtitle, "Built-in Liquid Retina XDR")
        XCTAssertTrue(lcd.properties.contains(HardwareProperty("Pixels", "3600 x 2250")))
        XCTAssertTrue(lcd.properties.contains(HardwareProperty("Main display", "Yes")))
        XCTAssertTrue(lcd.properties.contains(HardwareProperty("Connection type", "Internal")))
        XCTAssertTrue(
            gpu.children[1].properties.contains(HardwareProperty("Rotation", "Supported")))
        // Ids are unique across the tree.
        let ids = gpu.flattened().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testNestedRecordsBecomeGroupedProperties() {
        let nodes = SystemProfilerNodes.nodes(
            from: items("SPStorageDataType"), parentID: "storage", dataType: "SPStorageDataType",
            systemImage: "internaldrive")
        let volume = nodes[0]
        XCTAssertEqual(volume.title, "Macintosh HD - Data")
        XCTAssertEqual(volume.subtitle, "APFS")
        XCTAssertTrue(volume.children.isEmpty)
        XCTAssertEqual(volume.propertyGroups, [nil, "Physical drive"])
        let drive = volume.properties(in: "Physical drive")
        XCTAssertTrue(
            drive.contains(
                HardwareProperty("Device name", "APPLE SSD AP0512Z", group: "Physical drive")))
        XCTAssertTrue(
            drive.contains(HardwareProperty("Medium type", "SSD", group: "Physical drive")))
        XCTAssertTrue(drive.contains(HardwareProperty("Internal", "Yes", group: "Physical drive")))
        XCTAssertTrue(
            volume.properties.contains { $0.label == "Capacity" && $0.value.hasPrefix("460.43 GB") }
        )
    }

    func testSingleKeyRecordsAreNamedByTheirKey() {
        let nodes = SystemProfilerNodes.nodes(
            from: items("SPBluetoothDataType"), parentID: "bluetooth",
            dataType: "SPBluetoothDataType",
            systemImage: "b")
        let controller = nodes[0]
        XCTAssertEqual(controller.propertyGroups, ["Controller"])
        XCTAssertTrue(
            controller.properties.contains(
                HardwareProperty("Chipset", "BCM_4388", group: "Controller")))
        XCTAssertTrue(
            controller.properties.contains(HardwareProperty("State", "On", group: "Controller")))
        XCTAssertEqual(controller.children.map(\.title), ["MX Master 3", "iPad"])
        XCTAssertEqual(controller.children[0].subtitle, "Mouse")
        XCTAssertEqual(controller.children[1].subtitle, "Not connected")
        XCTAssertTrue(
            controller.children[0].properties.contains(
                HardwareProperty("Address", "F2:98:8E:17:38:D9")))
    }

    func testUSBTreeKeepsItsDepth() {
        let nodes = SystemProfilerNodes.nodes(
            from: items("SPUSBHostDataType"), parentID: "usb", dataType: "SPUSBHostDataType",
            systemImage: "u")
        XCTAssertEqual(nodes.count, 2)
        let bus = nodes[1]
        XCTAssertEqual(bus.children.count, 1)
        let hub = bus.children[0]
        XCTAssertEqual(hub.title, "USB3.1 Hub")
        XCTAssertEqual(hub.subtitle, "Anker")
        XCTAssertEqual(hub.children[0].title, "USB 10/100/1000 LAN")
        XCTAssertTrue(hub.children[0].properties.contains(HardwareProperty("Link speed", "5 Gb/s")))
        XCTAssertEqual(hub.children[0].path(to: hub.children[0].id)?.count, 1)
        XCTAssertEqual(
            bus.path(to: hub.children[0].id)?.map(\.title),
            ["USB 3.1 Bus", "USB3.1 Hub", "USB 10/100/1000 LAN"])
    }

    // MARK: - Sections, search, report

    private struct FixtureRunner: SystemProfilerRunning {
        func items(for dataType: String) -> [[String: Any]]? {
            if dataType == "SPUSBHostDataType" { return nil }
            if dataType == "SPUSBDataType" {
                return SystemProfilerRunner.parse(
                    HardwareExplorerTests.fixture, dataType: "SPUSBHostDataType")
            }
            return SystemProfilerRunner.parse(HardwareExplorerTests.fixture, dataType: dataType)
                ?? []
        }
    }

    func testSectionFallsBackWhenPrimaryTypeDoesNotReport() throws {
        let spec = try XCTUnwrap(HardwareInventory.spec(withID: "usb"))
        let section = HardwareInventory.capture(spec, runner: FixtureRunner())
        XCTAssertEqual(section.root.children.count, 2)
        XCTAssertEqual(section.note, "SPUSBHostDataType did not report")
        XCTAssertEqual(section.facts.usbDeviceCount, 2)
        XCTAssertEqual(section.root.children[1].id, "usb/SPUSBDataType/1")
    }

    func testSearchRanksTitlesAboveProperties() throws {
        let usb = HardwareInventory.capture(
            try XCTUnwrap(HardwareInventory.spec(withID: "usb")), runner: FixtureRunner())
        let displays = HardwareInventory.capture(
            try XCTUnwrap(HardwareInventory.spec(withID: "displays")), runner: FixtureRunner())
        let hits = HardwareSearch.results(in: [usb, displays], query: "realtek")
        XCTAssertEqual(hits.first?.node.title, "USB 10/100/1000 LAN")
        XCTAssertEqual(hits.first?.path, ["USB", "USB 3.1 Bus", "USB3.1 Hub"])
        XCTAssertTrue(hits.first?.matchedProperties.contains { $0.label == "Vendor" } ?? false)
        let byTitle = HardwareSearch.results(in: [usb, displays], query: "usb")
        XCTAssertEqual(byTitle.first?.node.id, "usb")
        XCTAssertTrue(byTitle.contains { $0.node.title == "USB3.1 Hub" })
        XCTAssertTrue(HardwareSearch.results(in: [usb, displays], query: "   ").isEmpty)
        let lcd = HardwareSearch.results(in: [usb, displays], query: "retina")
        XCTAssertEqual(lcd.first?.node.title, "Color LCD")
    }

    func testReportTextListsGroupsAndChildren() throws {
        let storage = HardwareInventory.capture(
            try XCTUnwrap(HardwareInventory.spec(withID: "storage")), runner: FixtureRunner())
        let snapshot = HardwareSnapshot(
            sections: [storage], capturedAt: Date(timeIntervalSince1970: 0))
        let text = HardwareReport.text(for: snapshot)
        XCTAssertTrue(text.contains("== Storage =="))
        XCTAssertTrue(text.contains("Macintosh HD - Data (APFS)"))
        XCTAssertTrue(text.contains("[Physical drive]"))
        XCTAssertTrue(text.contains("Device name: APPLE SSD AP0512Z"))
        let json = try HardwareReport.json(for: snapshot)
        let decoded = try JSONDecoder.hardware.decode(HardwareSnapshot.self, from: json)
        XCTAssertEqual(decoded, snapshot)
    }

    func testFactsFromProfilerItems() {
        let displays = HardwareInventory.displayFacts([
            "SPDisplaysDataType": items("SPDisplaysDataType")
        ])
        XCTAssertEqual(displays.gpuCores, 14)
        XCTAssertEqual(displays.metalSupport, "Metal 4")
        XCTAssertEqual(displays.displays?.count, 2)
        XCTAssertEqual(displays.displays?[0].pixelWidth, 3600)
        XCTAssertEqual(displays.displays?[0].isMain, true)
        XCTAssertEqual(displays.displays?[0].isBuiltIn, true)
        XCTAssertEqual(displays.displays?[1].isMain, false)
        let storage = HardwareInventory.storageFacts([
            "SPStorageDataType": items("SPStorageDataType")
        ])
        XCTAssertEqual(storage.volumes?.first?.capacityBytes, 494_384_795_648)
        XCTAssertEqual(storage.volumes?.first?.isInternal, true)
        let usb = HardwareInventory.usbFacts(["SPUSBHostDataType": items("SPUSBHostDataType")])
        XCTAssertEqual(usb.usbDeviceCount, 2)
        let tb = HardwareInventory.thunderboltFacts([
            "SPThunderboltDataType": items("SPThunderboltDataType")
        ])
        XCTAssertEqual(tb.thunderboltPortCount, 2)
        XCTAssertNil(HardwareInventory.parseDimensions("wide"))
        var merged = HardwareFacts()
        merged.merge(displays)
        merged.merge(storage)
        XCTAssertEqual(merged.gpuCores, 14)
        XCTAssertEqual(merged.volumes?.count, 1)
    }

    // MARK: - Native helpers

    func testUptimeAndByteHelpers() {
        let boot = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            HardwareNativeReaders.uptime(since: boot, now: boot.addingTimeInterval(90_061)),
            "1 day, 1 hour, 1 minute")
        XCTAssertEqual(
            HardwareNativeReaders.uptime(since: boot, now: boot.addingTimeInterval(120)),
            "2 minutes")
        XCTAssertEqual(HardwareNativeReaders.bytes(131_072), "128 KB")
        XCTAssertEqual(HardwareNativeReaders.bytes(16_777_216), "16 MB")
        XCTAssertEqual(HardwareNativeReaders.bytes(19_327_352_832), "18 GB")
    }

    /// The real inventory, end to end, when asked for (`MPM_LIVE_HARDWARE=1`):
    /// spawns system_profiler per data type, so it is not part of the quick run.
    func testLiveInventoryCapturesEverySection() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MPM_LIVE_HARDWARE"] == "1",
            "set MPM_LIVE_HARDWARE=1 to run the live capture")
        let start = Date()
        let snapshot = HardwareInventory.capture()
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(snapshot.sections.map(\.id), HardwareInventory.specs.map(\.id))
        for section in snapshot.sections {
            let count = section.root.descendantCount
            print(
                String(
                    format: "  %-14@ %4d nodes %5.2f s  %@", section.id, count,
                    section.captureSeconds, section.note ?? ""))
        }
        print(String(format: "  total %.2f s", seconds))
        let facts = snapshot.facts
        XCTAssertNotNil(facts.chipName)
        XCTAssertNotNil(facts.memoryBytes)
        XCTAssertNotNil(facts.performanceCores)
        XCTAssertNotNil(facts.gpuCores)
        XCTAssertNotNil(facts.osVersion)
        XCTAssertFalse(snapshot.sections.first { $0.id == "processor" }?.isEmpty ?? true)
        XCTAssertFalse(snapshot.sections.first { $0.id == "storage" }?.isEmpty ?? true)
        let ids = snapshot.sections.flatMap { $0.root.flattened().map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count, "node ids must be unique")
        // A value that slipped through un-humanised shows up as a reporter prefix.
        let leaked = snapshot.sections.flatMap { $0.root.flattened() }
            .flatMap(\.properties)
            .filter {
                $0.value.hasPrefix("sp") && $0.value.contains("_")
                    && $0.value == $0.value.lowercased()
            }
        XCTAssertTrue(leaked.isEmpty, "\(leaked.prefix(8))")
    }

    func testSysctlWalkFindsTheOptionalFeatures() {
        #if arch(arm64)
        let names = HardwareNativeReaders.sysctlNames(under: "hw.optional")
        XCTAssertTrue(names.contains("hw.optional.arm64"), "\(names.prefix(5))")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("hw.optional.") })
        let features = HardwareNativeReaders.isaFeatures()
        XCTAssertTrue(features.contains { $0.name == "FEAT_LSE" && $0.supported })
        XCTAssertEqual(features.first?.name.hasPrefix("FEAT_"), true)
        #endif
    }
}

extension JSONDecoder {
    fileprivate static var hardware: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
