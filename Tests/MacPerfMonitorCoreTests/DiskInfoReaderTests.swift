import XCTest

@testable import MacPerfMonitorCore

final class DiskInfoReaderTests: XCTestCase {
    func testMapsInternalNVMeReadout() {
        let info = DiskInfoReader.info(
            from: .init(
                registryEntryID: 7,
                bsdName: "disk0",
                deviceCharacteristics: [
                    "Vendor Name": "",
                    "Product Name": "APPLE SSD AP0512Z",
                    "Product Revision Level": "561.100.",
                    "Serial Number": "0ba0",
                    "Medium Type": "Solid State",
                ],
                protocolCharacteristics: [
                    "Physical Interconnect": "Apple Fabric",
                    "Physical Interconnect Location": "Internal",
                ],
                mediaPreferredBlockSize: 4096,
                controllerClass: "AppleANS3NVMeController",
                controllerProperties: [
                    "Firmware Revision": "561.100.",
                    "AppleNANDStatus": "Ready",
                    "NVMe Revision Supported": "1.10",
                ]))

        XCTAssertEqual(info.registryEntryID, 7)
        XCTAssertNil(info.vendorName, "empty registry strings must read as absent")
        XCTAssertEqual(info.productName, "APPLE SSD AP0512Z")
        XCTAssertEqual(info.isSolidState, true)
        XCTAssertEqual(info.interconnect, "Apple Fabric")
        XCTAssertEqual(info.physicalBlockSizeBytes, 4096)
        XCTAssertEqual(info.controllerClass, "AppleANS3NVMeController")
        XCTAssertEqual(info.firmwareRevision, "561.100.")
        XCTAssertEqual(info.nandStatus, "Ready")
        XCTAssertEqual(info.nvmeRevision, "1.10")
    }

    func testAllNilExternalUSBShapeSurvives() {
        let info = DiskInfoReader.info(
            from: .init(
                registryEntryID: 9, bsdName: "disk5",
                deviceCharacteristics: [:], protocolCharacteristics: [:],
                mediaPreferredBlockSize: nil, controllerClass: nil, controllerProperties: [:]))
        XCTAssertEqual(info.bsdName, "disk5")
        XCTAssertNil(info.productName)
        XCTAssertNil(info.isSolidState)
        XCTAssertNil(info.controllerClass)
        XCTAssertNil(info.serialNumber)
    }

    func testSerialFallsBackToControllerWhenDeviceOmitsIt() {
        let info = DiskInfoReader.info(
            from: .init(
                registryEntryID: 1, bsdName: "disk0",
                deviceCharacteristics: [:], protocolCharacteristics: [:],
                mediaPreferredBlockSize: nil, controllerClass: "IONVMeController",
                controllerProperties: ["Serial Number": "ctrl-serial"]))
        XCTAssertEqual(info.serialNumber, "ctrl-serial")
    }

    func testCachesPerDeviceAndDropsVanishedDevices() {
        var readouts = [
            DiskInfoReader.DeviceReadout(
                registryEntryID: 1, bsdName: "disk0",
                deviceCharacteristics: ["Product Name": "First"],
                protocolCharacteristics: [:], mediaPreferredBlockSize: nil,
                controllerClass: nil, controllerProperties: [:])
        ]
        let reader = DiskInfoReader(source: { readouts })

        XCTAssertEqual(reader.read()[1]?.productName, "First")

        // Same registry ID with changed data: the cache must win (identity is
        // stable while the entry lives, so re-harvesting is wasted work).
        readouts[0].deviceCharacteristics["Product Name"] = "Changed"
        XCTAssertEqual(reader.read()[1]?.productName, "First")

        // A new registry ID replaces the vanished one.
        readouts = [
            .init(
                registryEntryID: 2, bsdName: "disk6",
                deviceCharacteristics: ["Product Name": "External"],
                protocolCharacteristics: [:], mediaPreferredBlockSize: nil,
                controllerClass: nil, controllerProperties: [:])
        ]
        let after = reader.read()
        XCTAssertNil(after[1])
        XCTAssertEqual(after[2]?.productName, "External")
    }

    func testLiveReadMatchesDiskReaderDeviceSet() {
        // Live smoke: hardware entries must exist for exactly the devices the
        // activity reader reports, and the internal SSD (when present) should
        // carry a product name. Passes on any Mac, including one with no NVMe.
        let hardware = DiskInfoReader().read()
        let devices = DiskReader().read(now: Date()).devices
        for device in devices {
            guard let info = hardware[device.registryEntryID] else {
                XCTFail("no hardware info for \(device.bsdName)")
                continue
            }
            XCTAssertEqual(info.bsdName, device.bsdName)
        }
    }
}
