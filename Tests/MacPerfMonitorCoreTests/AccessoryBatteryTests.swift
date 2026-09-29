import XCTest

@testable import MacPerfMonitorCore

final class AccessoryBatteryTests: XCTestCase {
    private func report(_ records: [[String: Any]]) throws -> String {
        try records.map {
            let data = try PropertyListSerialization.data(
                fromPropertyList: $0, format: .xml, options: 0)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
    }

    private func accessory(_ changes: [String: Any] = [:]) -> [String: Any] {
        [
            "Type": "Accessory Source", "Name": "Mouse", "Accessory Identifier": "mouse",
            "Accessory Category": "Mouse", "Current Capacity": 20, "Max Capacity": 100,
        ].merging(changes) { _, value in value }
    }

    func testGroupsEarbudsAndCaseWithoutDuplicatingCombinedBattery() throws {
        let records: [[String: Any]] = [
            ["Type": "InternalBattery", "Name": "InternalBattery-0"],
            accessory(),
            accessory([
                "Name": "Headphones Case", "Accessory Identifier": "case",
                "Group Identifier": "headphones", "Part Identifier": "Case",
                "Accessory Category": "Audio Battery Case", "Current Capacity": 90,
                "Is Charging": false,
            ]),
            accessory([
                "Name": "Headphones", "Accessory Identifier": "headset",
                "Group Identifier": "headphones", "Part Identifier": "Combined",
                "Accessory Category": "Headset", "Current Capacity": 79,
                "Combined Parts": [
                    [
                        "Part Identifier": "Left", "Current Capacity": 79,
                        "Max Capacity": 100, "Is Charging": true,
                    ],
                    [
                        "Part Identifier": "Right", "Current Capacity": 80,
                        "Max Capacity": 100, "Is Charging": false,
                    ],
                ],
            ]),
        ]
        let devices = try XCTUnwrap(AccessoryBatteryReader.parse(try report(records)))
        XCTAssertEqual(devices.count, 2)
        let headphones = try XCTUnwrap(devices.first { $0.kind == .headphones })
        XCTAssertEqual(headphones.name, "Headphones")
        XCTAssertEqual(headphones.parts.map(\.component), [.left, .right, .chargingCase])
        XCTAssertEqual(headphones.parts.map(\.percent), [79, 80, 90])
        XCTAssertEqual(headphones.parts.map(\.isCharging), [true, false, false])
        let mouse = try XCTUnwrap(devices.first { $0.kind == .mouse })
        XCTAssertEqual(mouse.parts.first?.percent, 20)
        XCTAssertNil(mouse.parts.first?.isCharging)
    }

    func testChargingIsNeverInferredFromPercentageOrPowerSource() throws {
        let values: [Any] = ["true", 1, 0, "false"]
        for value in values {
            let devices = try XCTUnwrap(
                AccessoryBatteryReader.parse(
                    try report([
                        accessory([
                            "Current Capacity": 100, "Is Charging": value,
                            "Power Source State": "AC Power",
                        ])
                    ])))
            XCTAssertEqual(devices.first?.parts.first?.percent, 100)
            XCTAssertNil(devices.first?.parts.first?.isCharging)
        }
    }

    func testInvalidCapacityTypesAndValuesRemainUnknown() throws {
        let invalid: [Any] = [-1, 101, "50", true, Double.nan, Double.infinity, [50]]
        for value in invalid {
            let devices = try XCTUnwrap(
                AccessoryBatteryReader.parse(try report([accessory(["Current Capacity": value])])))
            XCTAssertEqual(devices.count, 1)
            XCTAssertNil(devices.first?.parts.first?.percent)
        }
        for maximum: Any in [0, -1, "100", true] {
            let devices = try XCTUnwrap(
                AccessoryBatteryReader.parse(try report([accessory(["Max Capacity": maximum])])))
            XCTAssertNil(devices.first?.parts.first?.percent)
        }
    }

    func testZeroChargeAndNonPercentageCapacitiesAreValid() throws {
        for (current, maximum, expected) in [(0, 100, 0), (25, 50, 50), (100, 100, 100)] {
            let devices = try XCTUnwrap(
                AccessoryBatteryReader.parse(
                    try report([accessory(["Current Capacity": current, "Max Capacity": maximum])])
                ))
            XCTAssertEqual(devices.first?.parts.first?.percent, expected)
        }
    }

    func testMissingIdentifiersAndChangedOptionalFieldsDoNotCrashOrMergeDevices() throws {
        var first = accessory(["Combined Parts": "new format", "Is Charging": ["unknown"]])
        first.removeValue(forKey: "Accessory Identifier")
        let second = first
        let devices = try XCTUnwrap(AccessoryBatteryReader.parse(try report([first, second])))
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(Set(devices.map(\.id)).count, 2)
        XCTAssertTrue(devices.allSatisfy { $0.parts.first?.percent == 20 })
        XCTAssertTrue(devices.allSatisfy { $0.parts.first?.isCharging == nil })
        XCTAssertTrue(devices.allSatisfy { !$0.hasStableIdentity })
    }

    func testExplicitConnectionStateIsPreservedWithoutInferringUnknown() throws {
        for connected in [true, false] {
            let source = try report([accessory(["Is Connected": connected])])
            let devices = try XCTUnwrap(AccessoryBatteryReader.parse(source))
            XCTAssertEqual(devices.first?.isConnected, connected)
            XCTAssertEqual(devices.first?.hasStableIdentity, true)
        }
        let devices = try XCTUnwrap(AccessoryBatteryReader.parse(try report([accessory()])))
        XCTAssertNil(devices.first?.isConnected)
    }

    func testMalformedTruncatedAndOversizedReportsAreUnavailable() throws {
        let valid = try report([accessory()])
        XCTAssertNil(AccessoryBatteryReader.parse(""))
        XCTAssertNil(AccessoryBatteryReader.parse("pmset: unknown option"))
        XCTAssertNil(AccessoryBatteryReader.parse(String(valid.dropLast(12))))
        XCTAssertNil(AccessoryBatteryReader.parse(valid + "<?xml broken"))
        XCTAssertNil(
            AccessoryBatteryReader.parse(
                String(repeating: "x", count: AccessoryBatteryReader.maximumReportBytes + 1)))
        XCTAssertNil(AccessoryBatteryReader.parse(String(repeating: valid, count: 129)))
    }

    func testAbsentAndNonAccessorySourcesProduceAnEmptySuccessfulRead() throws {
        let devices = try XCTUnwrap(
            AccessoryBatteryReader.parse(
                try report([
                    ["Type": "InternalBattery", "Name": "Mac"],
                    accessory(["Is Present": false]),
                    accessory(["Name": ["unexpected"]]),
                ])))
        XCTAssertTrue(devices.isEmpty)
    }

    func testLiveAccessoryReadWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MACPERF_ACCESSORY_LIVE"] == "1" else { return }
        let devices = try XCTUnwrap(AccessoryBatteryReader().read())
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
        for device in devices {
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertEqual(Set(device.parts.map(\.id)).count, device.parts.count)
            XCTAssertTrue(
                device.parts.allSatisfy { $0.percent.map { (0...100).contains($0) } ?? true })
        }
        print(
            "Accessory read: \(devices.count) devices, \(devices.flatMap(\.parts).count) batteries")
    }
}
