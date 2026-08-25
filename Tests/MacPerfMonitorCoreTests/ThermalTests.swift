import XCTest

@testable import MacPerfMonitorCore

final class ThermalTests: XCTestCase {
    // MARK: - Key classification

    func testDieKeysClassifyByPrefix() {
        XCTAssertEqual(SMCReader.domain(forKeyName: "Tp05"), .cpuDie)
        XCTAssertEqual(SMCReader.domain(forKeyName: "Tp1K"), .cpuDie)
        XCTAssertEqual(SMCReader.domain(forKeyName: "Te0S"), .cpuDie)
        XCTAssertEqual(SMCReader.domain(forKeyName: "Tg0D"), .gpuDie)
        XCTAssertEqual(SMCReader.domain(forKeyName: "Tg1l"), .gpuDie)
        XCTAssertEqual(SMCReader.domain(forKeyName: "TH0x"), .ssd)
    }

    /// TV* keys are voltage rails, not die sensors. The SMC enumerates keys
    /// sorted with uppercase before lowercase, so a TV-accepting discovery
    /// with a 12-key cap filled every slot with voltage rails on M3 Pro and
    /// the reported "die temperature" never included a die sensor.
    func testVoltageRailKeysAreExcluded() {
        for name in ["TVA0", "TVD0", "TVHE", "TVHF", "TVS0", "TVSx", "TVMD"] {
            XCTAssertNil(SMCReader.domain(forKeyName: name), name)
        }
    }

    /// Case is load-bearing: TG0* (uppercase) keys are battery-adjacent ioft
    /// readings, TE*/TP* style names are not die sensors, and Th*/Ts* are
    /// board and skin sensors.
    func testNonDieFamiliesAreExcluded() {
        for name in [
            "TG0B", "TG0V", "TED0", "TFD0", "TB0T", "TW0P", "Ta04", "TaLP",
            "Th00", "Ts0P", "Tz11", "TCMz", "Tf16", "TR0Z", "F0Ac", "#KEY",
        ] {
            XCTAssertNil(SMCReader.domain(forKeyName: name), name)
        }
    }

    // MARK: - Plausibility gates

    /// Discovery is strict: calibration offset pairs (0.00 / -3.10), dead
    /// zones, and sub-ambient voltage readings must never become sampled keys.
    func testDiscoveryGateRejectsJunk() {
        for value in [0.0, -3.10, 0.01, 2.63, 9.9, 10.0, 110.0, 130.0] {
            XCTAssertFalse(SMCReader.isPlausibleDiscoveryTemperature(value), "\(value)")
        }
        for value in [10.1, 24.2, 35.0, 53.2, 109.9] {
            XCTAssertTrue(SMCReader.isPlausibleDiscoveryTemperature(value), "\(value)")
        }
    }

    /// Read time is lenient: a known-good key in a cold room still reports,
    /// while a failed read (0) and garbage stay excluded.
    func testReadingGateAllowsColdButNotGarbage() {
        XCTAssertTrue(SMCReader.isPlausibleReading(5.0))
        XCTAssertTrue(SMCReader.isPlausibleReading(105.0))
        XCTAssertFalse(SMCReader.isPlausibleReading(0.0))
        XCTAssertFalse(SMCReader.isPlausibleReading(0.5))
        XCTAssertFalse(SMCReader.isPlausibleReading(130.0))
        XCTAssertFalse(SMCReader.isPlausibleReading(-3.10))
    }

    // MARK: - Value decoding

    func testDecodeFloat() {
        let bits = Float(42.5).bitPattern
        let bytes = [
            UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff),
            UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff),
        ]
        XCTAssertEqual(SMCReader.decode(type: "flt ", bytes: bytes), 42.5)
        XCTAssertNil(SMCReader.decode(type: "flt ", bytes: [0, 0]))
    }

    /// ioft is 64-bit little-endian fixed point with 16 fraction bits:
    /// 0x183000 / 65536 = 24.1875.
    func testDecodeIOFloat() {
        let bytes: [UInt8] = [0x00, 0x30, 0x18, 0, 0, 0, 0, 0]
        XCTAssertEqual(SMCReader.decode(type: "ioft", bytes: bytes), 24.1875)
        XCTAssertNil(SMCReader.decode(type: "ioft", bytes: [0x00, 0x30, 0x18]))
    }

    func testDecodeIntegersAndUnknown() {
        XCTAssertEqual(SMCReader.decode(type: "ui16", bytes: [0x96, 0x00]), 38400)
        XCTAssertEqual(SMCReader.decode(type: "ui8 ", bytes: [9]), 9)
        XCTAssertNil(SMCReader.decode(type: "hex_", bytes: [0x01]))
        XCTAssertNil(SMCReader.decode(type: "ui16", bytes: [0x01]))
    }

    func testFourCCRoundTrip() {
        XCTAssertEqual(SMCReader.toString(SMCReader.fourCC("F0Ac")), "F0Ac")
        XCTAssertEqual(SMCReader.fourCC("#KEY"), 0x234B_4559)
    }

    // MARK: - Sample convenience

    func testPrimaryFanIsTheFastest() {
        var sample = ThermalSample()
        XCTAssertNil(sample.primaryFanRPM)
        sample.fans = [
            FanSample(rpm: 2317, maxRPM: 6800),
            FanSample(rpm: 3100, maxRPM: nil),
        ]
        XCTAssertEqual(sample.primaryFanRPM, 3100)
        XCTAssertEqual(sample.primaryFanMaxRPM, 6800)
    }

    // MARK: - Live hardware (tolerates VMs with no SMC)

    /// The reader must never crash, and anything it reports must be sane.
    /// On CI virtual machines the AppleSMC service is absent or empty, so a
    /// nil sample is a pass.
    func testSMCReaderIsSafeAndConsistent() {
        let reader = SMCReader()
        guard let sample = reader.read(now: Date()) else { return }
        if let max = sample.cpuDieMaxC {
            XCTAssertTrue(SMCReader.isPlausibleReading(max))
            if let avg = sample.cpuDieAvgC {
                XCTAssertLessThanOrEqual(avg, max)
                XCTAssertTrue(SMCReader.isPlausibleReading(avg))
            }
        }
        if let gpu = sample.gpuDieMaxC { XCTAssertTrue(SMCReader.isPlausibleReading(gpu)) }
        if let ssd = sample.ssdMaxC { XCTAssertTrue(SMCReader.isPlausibleReading(ssd)) }
        for fan in sample.fans {
            XCTAssertGreaterThanOrEqual(fan.rpm, 0)
            XCTAssertLessThan(fan.rpm, 20000)
            if let maxRPM = fan.maxRPM { XCTAssertGreaterThan(maxRPM, 0) }
        }
        // The throttle must serve the cached sample for an immediate re-read.
        XCTAssertEqual(reader.read(now: Date()), sample)
    }
}
