import XCTest

@testable import MacPerfMonitorCore

final class BatteryChargeStatusTests: XCTestCase {
    /// `/Library/Preferences/com.apple.powerd.charging.plist` from a MacBook
    /// Pro on macOS 27.2, held at 80 % by Optimised Battery Charging.
    static let optimizedPlist = Data(
        base64Encoded: """
            YnBsaXN0MDDSAQIDBF8QD2Jvb3RTZXNzaW9uVVVJRFhwb2xpY2llc18QJDJCMEZGOTQ0LURCMDMtNDdENS1CNkU0LUU1QUZDN0U0\
            NzZENk8RAjFicGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFy\
            Y2hpdmVy0QgJVHJvb3SAAagLDBIkJSkvM1UkbnVsbNINDg8RWk5TLm9iamVjdHNWJGNsYXNzoRCAAoAH2RMUFQ4WFxgZGhscHR4f\
            IB8fI1ZyZWFzb25Vb3duZXJYc29jbGltaXRVZHJhaW5adGVybWluYXRlZF5ub0NoYXJnZVRvRnVsbF1pc0VuZE9mQ2hhcmdlVXRv\
            a2VugAMRqPUQUIAGCQgJCYAEXxAUb3B0aW1pemVkQ2hhcmdlTGltaXTSJg4nKFxOUy51dWlkYnl0ZXNPEBA6jW8uh+NL7LC7tXGM\
            fdJ0gAXSKissLVokY2xhc3NuYW1lWCRjbGFzc2VzVk5TVVVJRKIsLlhOU09iamVjdNIqKzAxXxAQQ2hhcmdlQ3RybFBvbGljeaIy\
            Ll8QEENoYXJnZUN0cmxQb2xpY3nSKis0NV5OU011dGFibGVBcnJheaM0Ni5XTlNBcnJheQAIABEAGgAkACkAMgA3AEkATABRAFMA\
            XABiAGcAcgB5AHsAfQB/AJIAmQCfAKgArgC5AMgA1gDcAN4A4QDjAOUA5gDnAOgA6QDrAQIBBwEUAScBKQEuATkBQgFJAUwBVQFa\
            AW0BcAGDAYgBlwGbAAAAAAAAAgEAAAAAAAAANwAAAAAAAAAAAAAAAAAAAaMACAANAB8AKABPAAAAAAAAAgEAAAAAAAAABQAAAAAA\
            AAAAAAAAAAAAAoQ=
            """)!
    static let boot = "2B0FF944-DB03-47D5-B6E4-E5AFC7E476D6"

    // MARK: - Charge hold file

    func testParsesOptimizedChargingHold() {
        let hold = ChargeHoldReader.parse(Self.optimizedPlist, bootSession: Self.boot)
        XCTAssertEqual(
            hold,
            ChargeHold(
                reason: .optimizedCharging, policyName: "optimizedChargeLimit", limitPercent: 80))
        // The boot session is compared without regard to case.
        XCTAssertNotNil(
            ChargeHoldReader.parse(Self.optimizedPlist, bootSession: Self.boot.lowercased()))
    }

    func testIgnoresPolicyFromEarlierBoot() {
        XCTAssertNil(
            ChargeHoldReader.parse(
                Self.optimizedPlist, bootSession: "00000000-0000-0000-0000-000000000000"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(ChargeHoldReader.parse(Data("nope".utf8), bootSession: nil))
        let empty = try! PropertyListSerialization.data(
            fromPropertyList: ["bootSessionUUID": Self.boot], format: .binary, options: 0)
        XCTAssertNil(ChargeHoldReader.parse(empty, bootSession: Self.boot))
    }

    func testReasonNames() {
        XCTAssertEqual(ChargeHold.reason(forPolicy: "optimizedChargeLimit"), .optimizedCharging)
        XCTAssertEqual(ChargeHold.reason(forPolicy: "userChargeLimit"), .chargeLimit)
        XCTAssertEqual(ChargeHold.reason(forPolicy: "cleanEnergy"), .other)
    }

    func testLiveFileIfPresent() {
        // Whatever this Mac has, reading it must not crash; a hold is below 100.
        if let hold = ChargeHoldReader.read() {
            XCTAssertTrue((1..<100).contains(hold.limitPercent))
        }
    }

    // MARK: - Status

    private let hold = ChargeHold(
        reason: .optimizedCharging, policyName: "optimizedChargeLimit", limitPercent: 80)

    private func sample(
        charge: Double, onAC: Bool, charging: Bool = false, milliAmps: Int = 0,
        hold: ChargeHold? = nil
    ) -> BatterySample {
        var sample = BatterySample(
            timestamp: Date(), isPresent: true, chargePercent: charge, isCharging: charging,
            isOnAC: onAC, amperageMilliAmps: milliAmps, voltageMilliVolts: 12_000,
            maxCapacitymAh: 6_000)
        sample.powerWatts = Double(abs(milliAmps)) * 12 / 1000
        sample.chargeHold = hold
        return sample
    }

    func testOnBatteryPrefersOwnEstimate() {
        var battery = sample(charge: 60, onAC: false, milliAmps: -1_000)
        battery.timeToEmptyMinutes = 200
        XCTAssertEqual(BatteryChargeStatus(battery), .onBattery(minutesLeft: 200))
        battery.runtimeEstimate = .init(
            minutesRemaining: 185, fullChargeMinutes: nil, source: .recentUse)
        XCTAssertEqual(BatteryChargeStatus(battery), .onBattery(minutesLeft: 185))
        battery.runtimeEstimate = nil
        battery.timeToEmptyMinutes = nil
        XCTAssertEqual(BatteryChargeStatus(battery), .onBattery(minutesLeft: nil))
    }

    func testChargingToFullUsesMacOSEstimate() {
        var battery = sample(charge: 50, onAC: true, charging: true, milliAmps: 3_000)
        battery.timeToFullMinutes = 70
        XCTAssertEqual(BatteryChargeStatus(battery), .charging(targetPercent: 100, minutes: 70))
    }

    func testChargingTowardsHoldEstimatesToTheLimit() {
        // 30 points of 6,000 mAh at 3,000 mA: 1,800 mAh in 36 minutes.
        let battery = sample(charge: 50, onAC: true, charging: true, milliAmps: 3_000, hold: hold)
        XCTAssertEqual(BatteryChargeStatus(battery), .charging(targetPercent: 80, minutes: 36))
        // Past the limit (a hold that came later), charging aims for full.
        let above = sample(charge: 85, onAC: true, charging: true, milliAmps: 3_000, hold: hold)
        XCTAssertEqual(BatteryChargeStatus(above), .charging(targetPercent: 100, minutes: nil))
    }

    func testHeldAtLimit() {
        XCTAssertEqual(
            BatteryChargeStatus(sample(charge: 80, onAC: true, hold: hold)), .onHold(hold))
        XCTAssertEqual(
            BatteryChargeStatus(sample(charge: 79, onAC: true, hold: hold)), .onHold(hold))
        // Easing down to the limit from above still reads as the hold.
        XCTAssertEqual(
            BatteryChargeStatus(sample(charge: 90, onAC: true, milliAmps: -800, hold: hold)),
            .onHold(hold))
        // Far below the limit and not charging is not the hold's doing.
        XCTAssertEqual(
            BatteryChargeStatus(sample(charge: 40, onAC: true, hold: hold)), .notCharging)
    }

    func testPluggedInWithoutHold() {
        XCTAssertEqual(BatteryChargeStatus(sample(charge: 100, onAC: true)), .charged)
        var settled = sample(charge: 96, onAC: true)
        settled.isFullyCharged = true
        XCTAssertEqual(BatteryChargeStatus(settled), .charged)
        XCTAssertEqual(BatteryChargeStatus(sample(charge: 60, onAC: true)), .notCharging)
        // A small adapter under load: the battery makes up the rest.
        XCTAssertEqual(
            BatteryChargeStatus(sample(charge: 60, onAC: true, milliAmps: -500)),
            .adapterShortfall(batteryWatts: 6))
        // Gauge noise is not a shortfall.
        XCTAssertEqual(
            BatteryChargeStatus(sample(charge: 100, onAC: true, milliAmps: -30)), .charged)
    }

    // MARK: - Power flow

    private func system(
        load: Double, battery: Double = 0, charging: Bool = false, present: Bool = true
    ) -> SystemSample {
        SystemSample(
            timestamp: Date(), totalRAM: 0, free: 0, active: 0, inactive: 0, wired: 0,
            speculative: 0, compressed: 0, appMemory: 0, cachedFiles: 0, swapTotal: 0,
            swapUsed: 0, pressureLevel: .normal, pressurePercent: 0, pageIns: 0, pageOuts: 0,
            compressions: 0, decompressions: 0, batteryPresent: present,
            batteryPowerWatts: battery, batterySystemPowerWatts: load,
            batteryIsCharging: charging)
    }

    private func assertBands(
        _ flow: BatteryPowerFlow, adapter: Double?, battery: (Double, Double)?,
        charging: (Double, Double)?, line: UInt = #line
    ) {
        func check(_ value: Double?, _ expected: Double?, _ name: String) {
            if let expected {
                XCTAssertEqual(value ?? .nan, expected, accuracy: 0.001, name, line: line)
            } else {
                XCTAssertTrue(value?.isNaN ?? true, "\(name) should be absent", line: line)
            }
        }
        check(flow.adapterTop.last, adapter, "adapter")
        check(flow.batteryFloor.last, battery?.0, "battery floor")
        check(flow.batteryTop.last, battery?.1, "battery top")
        check(flow.chargingFloor.last, charging?.0, "charging floor")
        check(flow.chargingTop.last, charging?.1, "charging top")
    }

    func testFlowOnAdapterHeld() {
        let flow = BatteryPowerFlow([system(load: 20.7, battery: 0.2)])
        assertBands(flow, adapter: 20.7, battery: nil, charging: nil)
        XCTAssertEqual(flow.peak, 20.7, accuracy: 0.001)
        XCTAssertEqual(flow.latest.fromAdapter, 20.7, accuracy: 0.001)
        XCTAssertEqual(flow.latest.fromBattery, 0)
    }

    func testFlowCharging() {
        let flow = BatteryPowerFlow([system(load: 15, battery: 40, charging: true)])
        assertBands(flow, adapter: 15, battery: nil, charging: (15, 55))
        XCTAssertEqual(flow.peak, 55, accuracy: 0.001)
        XCTAssertEqual(flow.latest.intoBattery, 40, accuracy: 0.001)
    }

    func testFlowOnBatteryIgnoresMeasurementGap() {
        // The SMC load and the gauge's discharge differ slightly on battery;
        // that is not adapter power.
        let flow = BatteryPowerFlow([system(load: 12.4, battery: 12.0)])
        assertBands(flow, adapter: nil, battery: (0, 12.4), charging: nil)
        XCTAssertEqual(flow.latest.fromBattery, 12.4, accuracy: 0.001)
    }

    func testFlowAdapterShortfall() {
        let flow = BatteryPowerFlow([system(load: 40, battery: 10)])
        assertBands(flow, adapter: 30, battery: (30, 40), charging: nil)
    }

    func testFlowWithoutSystemTelemetry() {
        // An Intel Mac on battery: the discharge is the load.
        assertBands(
            BatteryPowerFlow([system(load: 0, battery: 9)]), adapter: nil, battery: (0, 9),
            charging: nil)
        // On the adapter with an idle battery there is nothing to draw.
        XCTAssertTrue(BatteryPowerFlow([system(load: 0, battery: 0.1)]).isEmpty)
        // A desktop has no battery figures to stack.
        assertBands(
            BatteryPowerFlow([system(load: 30, battery: 5, present: false)]), adapter: 30,
            battery: nil, charging: nil)
    }
}
