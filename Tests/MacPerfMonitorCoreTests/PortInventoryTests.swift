import XCTest

@testable import MacPerfMonitorCore

final class PortInventoryTests: XCTestCase {
    // MARK: - Fixture

    /// Records as an M3 Pro MacBook Pro on macOS 27 reports them, trimmed to
    /// the keys the parser reads: an Anker hub on USB-C 1 passing through a
    /// 96 W charger and driving a BenQ display, over a 5 A passive cable.
    private static func vdo(_ bytes: [UInt8]) -> Data { Data(bytes) }

    private static func port(
        _ kind: String, _ number: Int, type: Int, connected: Bool,
        supported: [String] = ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
        active: [String] = [], extra: [String: Any] = [:]
    ) -> [String: Any] {
        var record: [String: Any] = [
            "PortTypeDescription": kind, "PortNumber": number, "PortType": type,
            "ConnectionActive": connected, "TransportsSupported": supported,
            "TransportsActive": active, "TransportsUnauthorized": [String](),
            "UserAuthorizationPending": false, "Overcurrent Count": 0, "ConnectionCount": 0,
            "LDCM_LiquidDetected": false, "ActiveCable": false, "OpticalCable": false,
        ]
        record.merge(extra) { $1 }
        return record
    }

    private static func parent(_ kind: String, _ number: Int) -> [String: Any] {
        ["ParentPortTypeDescription": kind, "ParentPortNumber": number]
    }

    private static func fixture() -> PortRegistryRecords {
        var records = PortRegistryRecords()
        records.ports = [
            port("MagSafe 3", 1, type: 17, connected: false, supported: []),
            port("USB-C", 2, type: 2, connected: false),
            port(
                "USB-C", 1, type: 2, connected: true,
                active: ["CC", "USB3", "USB2", "DisplayPort"],
                extra: ["ConnectionCount": 1]),
            port("HDMI", 1, type: 6, connected: false, supported: ["DisplayPort"]),
            port(
                "SD Card", 1, type: 11, connected: false, supported: ["SD"],
                extra: ["Card Present": false]),
        ]
        records.transports = [
            parent("USB-C", 1).merging([
                "TransportTypeDescription": "USB3", "Active": true,
                "DataRateDescription": "10 Gbps", "GenerationDescription": "USB 3.x",
                "SuperSpeedSignalingDescription": "Gen 2", "Product": "USB3.1 Hub",
                "Manufacturer": "Anker", "DataRoleDescription": "Host",
                "TRM_ProfileDescription": "Ask for New Accessories",
                "AuthorizationStatusDescription": "Policy Authorized",
            ]) { $1 },
            parent("USB-C", 1).merging([
                "TransportTypeDescription": "USB2", "Active": true,
                "DataRateDescription": "480 Mbps (High Speed)", "Product": "USB2.0 Hub",
                "Manufacturer": "Anker",
            ]) { $1 },
            parent("USB-C", 1).merging([
                "TransportTypeDescription": "DisplayPort", "Active": true,
                "LinkRateDescription": "8.1 Gbps (HBR3)", "ProductName": "BenQ MA320U",
                "ManufacturerName": "BNQ", "LaneCount": 2, "MaxLaneCount": 2,
                "RoleDescription": "Source",
            ]) { $1 },
            parent("USB-C", 1).merging(["TransportTypeDescription": "CC", "Active": true]) {
                $1
            },
            parent("HDMI", 1).merging([
                "TransportTypeDescription": "DisplayPort", "Active": false,
                "LinkRateDescription": "No Link",
            ]) { $1 },
        ]
        records.components = [
            parent("USB-C", 1).merging([
                "AddressDescription": "SOP", "Vendor ID": 8457, "Product ID": 259,
                "Specification Revision": 3,
                "Metadata": [
                    "VDOs": [
                        vdo([0x09, 0x21, 0x40, 0x54]), vdo([0x8a, 0x03, 0x00, 0x00]),
                        vdo([0x01, 0x00, 0x03, 0x01]), vdo([0x51, 0x00, 0x80, 0x44]),
                    ],
                    "bcdDevice": 1,
                ],
            ]) { $1 },
            parent("USB-C", 1).merging([
                "AddressDescription": "SOP'", "Vendor ID": 10522, "Product ID": 33928,
                "Product Type Description": "Passive Cable",
                "Metadata": [
                    "VDOs": [
                        vdo([0x1a, 0x29, 0x00, 0x18]), vdo([0x00, 0x00, 0x00, 0x00]),
                        vdo([0x00, 0x00, 0x88, 0x84]), vdo([0x42, 0x20, 0x08, 0x00]),
                    ]
                ],
            ]) { $1 },
        ]
        let fixed: (Int, Int, Int) -> [String: Any] = { volts, amps, watts in
            [
                "Class": "IOPortFeaturePowerSourceOptionFixed", "Voltage (mV)": volts,
                "Max Current (mA)": amps, "Max Power (mW)": watts,
            ]
        }
        records.powerSources = [
            parent("USB-C", 1).merging([
                "PowerSourceName": "Brick ID",
                "PowerSourceOptions": [fixed(5000, 500, 2500)],
                // The driver's negative priority, as an unsigned 64-bit value.
                "Priority": NSNumber(value: UInt64(18_446_744_073_709_551_116)),
            ]) { $1 },
            parent("USB-C", 1).merging([
                "PowerSourceName": "USB-PD",
                "PowerSourceOptions": [
                    fixed(5000, 3000, 15000), fixed(9000, 3000, 27000),
                    fixed(15000, 3000, 45000), fixed(20000, 4800, 96000),
                ],
                "WinningPowerSourceOption": fixed(20000, 4800, 96000),
            ]) { $1 },
            parent("USB-C", 1).merging([
                "PowerSourceName": "TypeC", "PowerSourceOptions": [fixed(5000, 3000, 15000)],
            ]) { $1 },
        ]
        let path = "IOService:/AppleARMPE/arm-io@10F00000/hpm0@C/Port-USB-C@1"
        records.usbDevices = [
            [
                "USB Product Name": "USB3.1 Hub", "USB Vendor Name": "Anker", "idVendor": 8457,
                "idProduct": 2082, "Device Speed": 4, "UsbLinkSpeed": 10_000_000_000,
                "bcdUSB": 0x0320, "bDeviceClass": 9, "locationID": 0x0010_0000,
                PortRegistryRecords.usbIOPortKey: path,
            ],
            [
                "USB Product Name": "OBSBOT Meet 2", "idVendor": 13668, "Device Speed": 2,
                "UsbLinkSpeed": 480_000_000, "bcdUSB": 0x0200, "bDeviceClass": 239,
                "locationID": 0x0012_0000, PortRegistryRecords.usbIOPortKey: path,
            ],
            // Not on the fixture Mac: a USB 3 drive held back to USB 2.
            [
                "USB Product Name": "Portable SSD", "idVendor": 0x04E8, "Device Speed": 2,
                "UsbLinkSpeed": 480_000_000, "bcdUSB": 0x0320, "bDeviceClass": 0,
                "UsbPowerSinkAllocation": 900, "locationID": 0x0013_0000,
                "USB Serial Number": "S6XN1234", "bcdDevice": 0x0194,
                PortRegistryRecords.usbIOPortKey: path,
            ],
            // A device on a controller with no port path is left out.
            ["USB Product Name": "Internal", "Device Speed": 1],
        ]
        records.battery = [
            "ExternalConnected": true,
            "PowerTelemetryData": [
                "SystemVoltageIn": 20153, "SystemCurrentIn": 457, "SystemPowerIn": 9213,
            ],
            "AdapterDetails": ["Watts": 96],
        ]
        return records
    }

    // MARK: - Parsing

    func testPortsParseAndSortUSBCFirst() {
        let inventory = PortInventoryParser.inventory(from: Self.fixture())
        XCTAssertEqual(
            inventory.ports.map(\.key),
            ["USB-C@1", "USB-C@2", "MagSafe 3@1", "HDMI@1", "SD Card@1"])
        let port = inventory.ports[0]
        XCTAssertTrue(port.isConnected)
        XCTAssertTrue(port.supportsSuperSpeed)
        XCTAssertEqual(port.connectionCount, 1)
        // CC is plumbing, not a data link.
        XCTAssertEqual(port.links.map(\.transport), ["USB3", "USB2", "DisplayPort"])
        XCTAssertEqual(port.link("USB3")?.generation, "USB 3.x Gen 2")
        XCTAssertEqual(port.link("USB3")?.deviceName, "Anker USB3.1 Hub")
        XCTAssertEqual(port.link("DisplayPort")?.laneCount, 2)
        XCTAssertEqual(port.link("DisplayPort")?.deviceName, "BenQ MA320U")
        XCTAssertEqual(port.devices.map(\.name), ["USB3.1 Hub", "OBSBOT Meet 2", "Portable SSD"])
        XCTAssertFalse(inventory.ports[1].isConnected)
        XCTAssertEqual(inventory.ports[3].links.first?.isActive, false)
    }

    func testPartnerAndCableIdentitiesDecode() {
        let port = PortInventoryParser.inventory(from: Self.fixture()).ports[0]
        let partner = try! XCTUnwrap(port.partner)
        XCTAssertEqual(partner.vendorID, 8457)
        XCTAssertEqual(partner.idHeader, 0x5440_2109)
        XCTAssertEqual(partner.ufpProductType, 2)
        XCTAssertEqual(partner.partnerKind, "USB peripheral")
        XCTAssertEqual(partner.specRevision, 3)

        let cable = try! XCTUnwrap(port.cable)
        XCTAssertFalse(cable.isActive)
        XCTAssertEqual(cable.identity.vendorID, 0x291A)
        XCTAssertEqual(cable.speed, .gen2)
        XCTAssertEqual(cable.currentMilliAmps, 5000)
        XCTAssertEqual(cable.maxVolts, 20)
        XCTAssertFalse(cable.eprCapable)
        XCTAssertEqual(cable.maxWatts, 100)
        XCTAssertEqual(cable.latencyCode, 1)
        XCTAssertEqual(cable.isCaptive, false)
        XCTAssertEqual(cable.summary, "Passive cable, 5 A (100 W), 10 Gbps")
    }

    func testCableVDOFieldsDecode() {
        let identity = PDIdentity()
        // 240 W active cable: USB4 Gen 3, 5 A, 50 V, EPR, about 2 m, captive.
        var vdo: UInt32 = 3  // speed
        vdo |= 2 << 5  // 5 A
        vdo |= 3 << 9  // 50 V
        vdo |= 2 << 13  // latency
        vdo |= 1 << 17  // EPR
        vdo |= 3 << 18  // captive
        let cable = CableInfo.decode(cableVDO: vdo, identity: identity, isActive: true)
        XCTAssertEqual(cable.speed, .gen3)
        XCTAssertEqual(cable.currentMilliAmps, 5000)
        XCTAssertEqual(cable.maxVolts, 50)
        XCTAssertTrue(cable.eprCapable)
        XCTAssertEqual(cable.maxWatts, 240)
        XCTAssertEqual(cable.approximateLength, "About 2 m")
        XCTAssertEqual(cable.isCaptive, true)

        // A 3 A USB 2 charging cable.
        let basic = CableInfo.decode(cableVDO: 1 << 5, identity: identity, isActive: false)
        XCTAssertEqual(basic.speed, .usb2)
        XCTAssertEqual(basic.maxWatts, 60)
        XCTAssertNil(basic.approximateLength)
    }

    func testPowerSourcesAndInput() {
        let inventory = PortInventoryParser.inventory(from: Self.fixture())
        let port = inventory.ports[0]
        XCTAssertEqual(inventory.chargingPort?.key, "USB-C@1")
        // The one in use first, then by size.
        XCTAssertEqual(port.powerSources.map(\.name), ["USB-PD", "TypeC", "Brick ID"])
        let winning = try! XCTUnwrap(port.activePowerSource?.winning)
        XCTAssertEqual(winning.milliWatts, 96000)
        XCTAssertEqual(winning.label, "20 V, 4.8 A (96 W)")
        XCTAssertEqual(port.activePowerSource?.maxOfferedMilliWatts, 96000)

        let input = try! XCTUnwrap(inventory.powerInput)
        XCTAssertEqual(input.milliWatts, 9213)
        XCTAssertEqual(input.adapterWatts, 96)
        XCTAssertEqual(input.label, "9.2 W (20.15 V, 0.46 A)")

        XCTAssertNil(PortInventoryParser.powerInput(from: ["ExternalConnected": false]))
        XCTAssertNil(PortInventoryParser.powerInput(from: nil))
    }

    func testProgrammableOptionLabel() {
        let pps = PortInventoryParser.powerOption(from: [
            "Class": "IOPortFeaturePowerSourceOptionPPS", "Min Voltage (mV)": 3300,
            "Max Voltage (mV)": 21000, "Max Current (mA)": 3000,
        ])
        XCTAssertEqual(pps.kind, "PPS")
        XCTAssertEqual(pps.milliWatts, 63000)
        XCTAssertEqual(pps.label, "3.3 V to 21 V, 3 A (63 W) PPS")
    }

    func testDeviceSpeedCheck() {
        let devices = PortInventoryParser.inventory(from: Self.fixture()).ports[0].devices
        XCTAssertFalse(devices[0].isBelowDeclaredSpeed)
        XCTAssertFalse(devices[1].isBelowDeclaredSpeed)
        XCTAssertTrue(devices[2].isBelowDeclaredSpeed)
        XCTAssertEqual(devices[0].usbVersion, "3.2")
        XCTAssertEqual(devices[0].linkLabel, "10 Gbps")
        XCTAssertEqual(devices[2].linkLabel, "480 Mbps")
        XCTAssertTrue(devices[0].isHub)
    }

    func testLocationIDParents() {
        XCTAssertEqual(PortUSBDevice.parentLocation(of: 0x0014_1100), 0x0014_1000)
        XCTAssertEqual(PortUSBDevice.parentLocation(of: 0x0014_1000), 0x0014_0000)
        XCTAssertEqual(PortUSBDevice.parentLocation(of: 0x0014_0000), 0x0010_0000)
        XCTAssertNil(PortUSBDevice.parentLocation(of: 0x0010_0000))
        XCTAssertNil(PortUSBDevice.parentLocation(of: 0x0120_0000))
        XCTAssertEqual(PortUSBDevice.parentLocation(of: 0x0124_3000), 0x0124_0000)
    }

    func testDeviceTreeSkipsMissingHubs() {
        // A device whose immediate hub is absent attaches to the nearest
        // ancestor present; one with no location ID sits at the top.
        var root = PortUSBDevice(name: "Root hub")
        root.locationID = 0x0010_0000
        var deep = PortUSBDevice(name: "Deep")
        deep.locationID = 0x0014_1100
        let loose = PortUSBDevice(name: "Loose")
        let tree = PortNodes.deviceTree([root, deep, loose], portID: "p")
        XCTAssertEqual(tree.map(\.title), ["Root hub", "Loose"])
        XCTAssertEqual(tree[0].children.map(\.title), ["Deep"])
        XCTAssertEqual(tree[1].id, "p/usb/i2")
    }

    // MARK: - Findings

    func testFixtureFindsOnlyTheSlowDrive() {
        let inventory = PortInventoryParser.inventory(from: Self.fixture())
        let findings = PortDiagnostics.findings(for: inventory.ports[0])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.severity, .warning)
        XCTAssertEqual(findings.first?.title, "Portable SSD is running at USB 2 speed")
        XCTAssertTrue(
            findings.first?.detail.contains("USB 3.2 support but connected at 480 Mbps") ?? false)
        for port in inventory.ports.dropFirst() {
            XCTAssertEqual(PortDiagnostics.findings(for: port), [], port.key)
        }
    }

    func testHealthFindings() {
        var port = HardwarePort(key: "USB-C@2", kind: "USB-C", number: 2, isConnected: true)
        port.overcurrentCount = 2
        port.liquidDetected = true
        port.transportsUnauthorized = ["USB3"]
        let ids = PortDiagnostics.findings(for: port).map(\.id)
        XCTAssertEqual(ids, ["overcurrent", "liquid", "approval"])
        XCTAssertEqual(
            PortDiagnostics.findings(for: port).first?.title, "Overcurrent reported 2 times")
        port.overcurrentCount = 1
        XCTAssertEqual(
            PortDiagnostics.findings(for: port).first?.title, "Overcurrent reported once")
    }

    func testCableFindings() {
        var port = HardwarePort(key: "USB-C@1", kind: "USB-C", number: 1, isConnected: true)
        port.transportsSupported = ["CC", "USB2", "USB3"]
        port.cable = CableInfo.decode(cableVDO: 1 << 5, identity: PDIdentity(), isActive: false)
        let full = PowerOption(
            kind: "Fixed", milliVolts: 20000, maxMilliAmps: 3000, maxMilliWatts: 60000)
        port.powerSources = [PowerSource(name: "USB-PD", options: [full], winning: full)]
        XCTAssertEqual(
            PortDiagnostics.findings(for: port).map(\.id), ["cable-usb2", "cable-caps-power"])

        // A USB 2-only receptacle has nothing to lose to the cable.
        port.transportsSupported = ["CC", "USB2"]
        XCTAssertEqual(PortDiagnostics.findings(for: port).map(\.id), ["cable-caps-power"])

        // A 5 A cable lifts the cap.
        port.cable?.currentMilliAmps = 5000
        XCTAssertEqual(PortDiagnostics.findings(for: port), [])
    }

    func testChargerFindings() {
        var port = HardwarePort(key: "USB-C@1", kind: "USB-C", number: 1, isConnected: true)
        let typeC = PowerOption(
            kind: "Fixed", milliVolts: 5000, maxMilliAmps: 3000, maxMilliWatts: 15000)
        port.powerSources = [PowerSource(name: "TypeC", options: [typeC], winning: typeC)]
        let noPD = PortDiagnostics.findings(for: port)
        XCTAssertEqual(noPD.map(\.id), ["no-pd"])
        XCTAssertTrue(noPD[0].detail.contains("15 W"))

        let small = PowerOption(
            kind: "Fixed", milliVolts: 9000, maxMilliAmps: 2220, maxMilliWatts: 20000)
        port.powerSources = [PowerSource(name: "USB-PD", options: [typeC, small], winning: small)]
        let low = PortDiagnostics.findings(for: port)
        XCTAssertEqual(low.map(\.id), ["low-power"])
        XCTAssertEqual(low[0].title, "Low-power charger (20 W)")
    }

    // MARK: - Nodes and summaries

    func testNodesAndSummaries() {
        let inventory = PortInventoryParser.inventory(from: Self.fixture())
        let nodes = PortNodes.nodes(for: inventory, parentID: "ports")
        XCTAssertEqual(
            nodes.map(\.id),
            [
                "ports/usb-c-1", "ports/usb-c-2", "ports/magsafe-3-1", "ports/hdmi-1",
                "ports/sd-card-1",
            ])
        XCTAssertEqual(
            nodes.map(\.title), ["USB-C 1", "USB-C 2", "MagSafe 3", "HDMI", "SD card slot"])
        let first = nodes[0]
        XCTAssertEqual(first.subtitle, "Anker USB3.1 Hub")
        // The camera and the drive hang off the hub.
        XCTAssertEqual(first.children.map(\.id), ["ports/usb-c-1/usb/00100000"])
        XCTAssertEqual(
            first.children[0].children.map(\.id),
            ["ports/usb-c-1/usb/00120000", "ports/usb-c-1/usb/00130000"])
        let drive = first.children[0].children[1]
        XCTAssertEqual(
            drive.properties.first { $0.label == "Serial number" }?.value, "S6XN1234")
        XCTAssertEqual(
            drive.properties.first { $0.label == "Firmware version" }?.value, "0x0194")
        func value(_ label: String, _ group: String?) -> String? {
            first.properties.first { $0.label == label && $0.group == group }?.value
        }
        XCTAssertEqual(value("Negotiated", "Power"), "20 V, 4.8 A (96 W)")
        XCTAssertEqual(value("Drawing now", "Power"), "9.2 W (20.15 V, 0.46 A)")
        XCTAssertEqual(value("Power rating", "Cable"), "100 W")
        XCTAssertEqual(value("Vendor ID", "Cable"), "0x291A (Anker)")
        XCTAssertEqual(
            value("USB 3", "Data"), "10 Gbps, USB 3.x Gen 2, Mac is host, Anker USB3.1 Hub")
        XCTAssertEqual(
            value("Accessory security", "Data"), "Ask for New Accessories (Policy Authorized)")
        XCTAssertEqual(
            value("Portable SSD is running at USB 2 speed", PortNodes.findingsGroup)?.isEmpty,
            false)
        XCTAssertEqual(
            nodes[1].properties.first { $0.group == PortNodes.findingsGroup }?.value,
            "No problems found")

        let summaries = PortNodes.summaries(for: inventory, parentID: "ports")
        XCTAssertEqual(summaries[0].nodeID, "ports/usb-c-1")
        XCTAssertTrue(summaries[0].isCharging)
        XCTAssertEqual(
            summaries[0].lines,
            [
                "USB 3 10 Gbps, DisplayPort 8.1 Gbps (HBR3)", "Charging: 20 V, 4.8 A (96 W)",
                "Passive cable, 5 A (100 W), 10 Gbps", "3 USB devices",
            ])
        XCTAssertEqual(summaries[1].headline, "Nothing connected")
        XCTAssertEqual(summaries[4].headline, "No card")
        XCTAssertFalse(summaries[1].isCharging)
    }

    // MARK: - Plug events

    func testChangeMonitorStartsAndStopsCleanly() {
        let monitor = PortChangeMonitor(settle: 0.1) {}
        XCTAssertFalse(monitor.isRunning)
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        // A second start is a no-op rather than a second set of watchers.
        monitor.start()
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
    }

    // MARK: - Live

    /// Reads this Mac's ports. Off by default (the result depends on what is
    /// plugged in); run with `MPM_LIVE_HARDWARE=1`.
    func testLiveInventory() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MPM_LIVE_HARDWARE"] == "1")
        let inventory = PortRegistryReader.inventory()
        let nodes = PortNodes.nodes(for: inventory, parentID: "ports")
        let root = HardwareNode(id: "ports", title: "Ports", systemImage: "", children: nodes)
        print(HardwareReport.text(for: root))
        XCTAssertFalse(inventory.ports.isEmpty)
    }
}
