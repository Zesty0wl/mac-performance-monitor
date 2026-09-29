import IOKit
import XCTest

@testable import MacPerfMonitorCore

/// These tests exercise the real reader against a read-only in-memory SMC.
/// No hardware, clock waits or database access are needed.
final class SMCReaderTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSMC(gpu: Float = 0) -> FakeSMC {
        FakeSMC(values: [
            "Tp05": .float(44), "Te0S": .float(40), "Tg0D": .float(gpu),
        ])
    }

    // MARK: - Discovery policy

    func testRecognizedDieKeysDependOnMetadataNotTheirFirstValue() {
        for name in ["Tp05", "Te0S", "Tg0D", "Tg1l"] {
            for (type, size) in [("flt ", 4), ("ioft", 8), ("ui16", 2), ("ui8 ", 1)] {
                XCTAssertEqual(
                    SMCReader.discoveryPolicy(name: name, type: type, dataSize: size),
                    .retainCandidate, "\(name) \(type)")
            }
        }
    }

    func testCalibrationAndNonDieKeysDoNotGetTheDieRetentionPolicy() {
        for name in ["Ta04", "Ta05", "Ta0C", "Ta0D"] {
            XCTAssertEqual(
                SMCReader.discoveryPolicy(name: name, type: "flt ", dataSize: 4), .ignore)
        }
        for name in ["TVHE", "TVMD", "TG0B", "TP05", "TE0S", "Tf16", "Tz11", "TB0T"] {
            XCTAssertEqual(
                SMCReader.discoveryPolicy(name: name, type: "flt ", dataSize: 4),
                .requirePlausibleValue, name)
            XCTAssertFalse(SMCReader.isDieGroup(SMCReader.sensorGroup(forKeyName: name)), name)
        }
    }

    func testDiscoveryRejectsUnsupportedOrMalformedMetadata() {
        for size in [-1, 0, 1, 3, 5, 8, 32, 33] {
            XCTAssertEqual(
                SMCReader.discoveryPolicy(name: "Tg0D", type: "flt ", dataSize: size), .ignore)
        }
        for type in ["hex_", "ui32", "flag", "flt"] {
            XCTAssertEqual(
                SMCReader.discoveryPolicy(name: "Tg0D", type: type, dataSize: 4), .ignore)
        }
        for name in ["Tg", "Tg000", "F0Ac", "VG0D"] {
            XCTAssertEqual(
                SMCReader.discoveryPolicy(name: name, type: "flt ", dataSize: 4), .ignore)
        }
    }

    // MARK: - Retention and honest missing values

    func testZeroAtDiscoveryCanRecoverWithoutBackfillingLaterMissingReadings() throws {
        let smc = makeSMC()
        let reader = SMCReader(transport: smc.call)
        let first = try XCTUnwrap(reader.read(now: anchor))
        XCTAssertEqual(first.cpuDieMaxC, 44)
        XCTAssertNil(first.gpuDieMaxC)

        smc.values["Tg0D"] = .float(43)
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(5))?.gpuDieMaxC, 43)
        smc.values["Tg0D"] = .float(0)
        XCTAssertNil(reader.read(now: anchor.addingTimeInterval(10))?.gpuDieMaxC)
        // The throttle can cache a missing sample, but not revive the old 43 C.
        XCTAssertNil(reader.read(now: anchor.addingTimeInterval(11))?.gpuDieMaxC)

        smc.values["Tg0D"] = .float(53)
        smc.readFailures.insert("Tg0D")
        let unavailable = try XCTUnwrap(reader.read(now: anchor.addingTimeInterval(15)))
        XCTAssertEqual(unavailable.cpuDieMaxC, 44)
        XCTAssertNil(unavailable.gpuDieMaxC)
        smc.readFailures.remove("Tg0D")
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(20))?.gpuDieMaxC, 53)
        XCTAssertEqual(smc.infoCalls["#KEY"], 1)
    }

    func testUnavailableFirstPayloadStillRetainsDecodableDieKey() {
        let smc = makeSMC(gpu: 47)
        smc.readFailures.insert("Tg0D")
        let reader = SMCReader(transport: smc.call)
        XCTAssertNil(reader.read(now: anchor)?.gpuDieMaxC)
        smc.readFailures.remove("Tg0D")
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(5))?.gpuDieMaxC, 47)
        XCTAssertEqual(smc.infoCalls["#KEY"], 1)
    }

    func testZeroCandidateIsRetainedEvenWhenAnotherGPUKeyAlreadyWorks() {
        let smc = makeSMC(gpu: 45)
        smc.values["Tg1l"] = .float(0)
        let reader = SMCReader(transport: smc.call)
        XCTAssertEqual(reader.read(now: anchor)?.gpuDieMaxC, 45)
        smc.values["Tg0D"] = .float(0)
        smc.values["Tg1l"] = .float(54)
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(5))?.gpuDieMaxC, 54)
        XCTAssertEqual(smc.infoCalls["#KEY"], 1)
    }

    func testEveryDieReadRevalidatesTemperatureWithoutSubstitutes() {
        let smc = makeSMC(gpu: 45)
        smc.values["TVHE"] = .float(80)
        smc.values["TG0B"] = .float(30)
        let reader = SMCReader(transport: smc.call)
        XCTAssertEqual(reader.read(now: anchor)?.gpuDieMaxC, 45)
        let invalid: [Float] = [0, 1, -3.1, 130, .nan, .infinity, -.infinity]
        for (index, value) in invalid.enumerated() {
            smc.values["Tg0D"] = .float(value)
            let sample = reader.read(now: anchor.addingTimeInterval(Double(index + 1) * 5))
            XCTAssertEqual(sample?.cpuDieMaxC, 44)
            XCTAssertNil(sample?.gpuDieMaxC, "\(value)")
        }
    }

    func testInventorySharesRetentionAndExcludesCalibrationEvenIfPlausible() {
        let smc = makeSMC()
        smc.values["Ta04"] = .float(45)
        smc.values["TVHE"] = .float(80)
        let reader = SMCReader(transport: smc.call)
        let first = reader.sensorInventory()
        XCTAssertFalse(first.sensors.contains { $0.key == "Tg0D" || $0.key == "Ta04" })
        XCTAssertEqual(first.sensors.first { $0.key == "TVHE" }?.group, SMCReader.groupVoltageRails)

        smc.values["Tg0D"] = .float(46)
        let next = reader.sensorInventory()
        XCTAssertEqual(next.sensors.first { $0.key == "Tg0D" }?.celsius, 46)
        XCTAssertEqual(next.sensors.first { $0.key == "Tg0D" }?.group, SMCReader.groupGPU)
        XCTAssertFalse(next.sensors.contains { $0.key == "Ta04" })
        XCTAssertEqual(smc.infoCalls["#KEY"], 1)
    }

    // MARK: - Bounded discovery recovery

    func testMissingDomainIsRediscoveredAtMostOncePerFiveMinutes() {
        let smc = makeSMC()
        smc.values.removeValue(forKey: "Tg0D")
        let reader = SMCReader(transport: smc.call)
        XCTAssertNil(reader.read(now: anchor)?.gpuDieMaxC)
        smc.values["Tg0D"] = .float(48)
        XCTAssertEqual(SMCReader.discoveryRetryInterval, 300)
        for seconds in [5.0, 30, 120, 299] {
            XCTAssertNil(reader.read(now: anchor.addingTimeInterval(seconds))?.gpuDieMaxC)
        }
        XCTAssertEqual(smc.infoCalls["#KEY"], 1)
        // Keep sampling calls outside the existing five-second read throttle.
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(304))?.gpuDieMaxC, 48)
        XCTAssertEqual(smc.infoCalls["#KEY"], 2)
    }

    func testMetadataFailureRetriesEvenWhenEveryDieDomainHasAnotherKey() {
        let smc = makeSMC(gpu: 40)
        smc.values["Tg1l"] = .float(55)
        smc.infoFailures.insert("Tg1l")
        let reader = SMCReader(transport: smc.call)
        XCTAssertEqual(reader.read(now: anchor)?.gpuDieMaxC, 40)
        smc.infoFailures.remove("Tg1l")
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(295))?.gpuDieMaxC, 40)
        XCTAssertEqual(smc.infoCalls["#KEY"], 1)
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(300))?.gpuDieMaxC, 55)
        XCTAssertEqual(smc.infoCalls["#KEY"], 2)
    }

    func testPartialEnumerationIsRetriedWithoutLosingDiscoveredKeys() throws {
        let smc = makeSMC(gpu: 40)
        smc.values["Tg1l"] = .float(55)
        let missingIndex = try XCTUnwrap(smc.values.keys.sorted().firstIndex(of: "Tg1l"))
        smc.indexFailures.insert(UInt32(missingIndex))
        let reader = SMCReader(transport: smc.call)
        XCTAssertEqual(reader.read(now: anchor)?.gpuDieMaxC, 40)

        smc.indexFailures.removeAll()
        smc.infoFailures.insert("#KEY")
        let failedRescan = reader.read(now: anchor.addingTimeInterval(300))
        XCTAssertEqual(failedRescan?.cpuDieMaxC, 44)
        XCTAssertEqual(failedRescan?.gpuDieMaxC, 40)
        smc.infoFailures.remove("#KEY")
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(595))?.gpuDieMaxC, 40)
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(600))?.gpuDieMaxC, 55)
        XCTAssertEqual(smc.infoCalls["#KEY"], 3)
    }

    func testFailedInitialKeyCountDoesNotCacheEmptyDiscoveryForever() {
        let smc = makeSMC(gpu: 42)
        smc.infoFailures.insert("#KEY")
        let reader = SMCReader(transport: smc.call)
        XCTAssertNil(reader.read(now: anchor)?.gpuDieMaxC)
        smc.infoFailures.remove("#KEY")
        XCTAssertNil(reader.read(now: anchor.addingTimeInterval(295))?.gpuDieMaxC)
        XCTAssertEqual(smc.infoCalls["#KEY"], 1)
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(300))?.gpuDieMaxC, 42)
        XCTAssertEqual(smc.infoCalls["#KEY"], 2)
    }

    func testRetainedButUnavailableKeysDoNotTriggerFullRescans() {
        let smc = makeSMC()
        let reader = SMCReader(transport: smc.call)
        for seconds in [0.0, 5, 300, 600, 3600] {
            XCTAssertNil(reader.read(now: anchor.addingTimeInterval(seconds))?.gpuDieMaxC)
        }
        XCTAssertEqual(smc.infoCalls["#KEY"], 1)
        XCTAssertEqual(smc.indexCalls, smc.values.count)
    }

    // MARK: - Transport and payload validation

    func testTransportErrorsDoNotBecomeZeroValuedSuccesses() {
        for command in [UInt8(8), UInt8(9), UInt8(5)] {
            let smc = makeSMC(gpu: 42)
            let reader = SMCReader(transport: { input, output, size in
                // Mimic a failed IOKit call leaving output.result and bytes zero.
                if input.data8 == command { return kIOReturnError }
                return smc.call(&input, &output, &size)
            })
            if command == 8 {
                XCTAssertNil(reader.keyAtIndex(0))
            } else {
                XCTAssertNil(reader.readFloat(SMCReader.fourCC("Tg0D")), "command \(command)")
            }
        }
    }

    func testTruncatedOrOversizedResponsesAreUnavailableEvenWithValidBytes() {
        for outputSize in [0, 40, 79, 81] {
            for command in [UInt8(8), UInt8(9), UInt8(5)] {
                let smc = makeSMC(gpu: 42)
                let reader = SMCReader(transport: { input, output, size in
                    let result = smc.call(&input, &output, &size)
                    if input.data8 == command { size = outputSize }
                    return result
                })
                if command == 8 {
                    XCTAssertNil(reader.keyAtIndex(0))
                } else {
                    XCTAssertNil(reader.readFloat(SMCReader.fourCC("Tg0D")))
                }
            }
        }
    }

    func testSMCErrorResultIsUnavailableDespiteSuccessfulTransport() {
        for command in [UInt8(8), UInt8(9), UInt8(5)] {
            let smc = makeSMC(gpu: 42)
            let reader = SMCReader(transport: { input, output, size in
                let result = smc.call(&input, &output, &size)
                if input.data8 == command { output.result = 0x84 }
                return result
            })
            if command == 8 {
                XCTAssertNil(reader.keyAtIndex(0))
            } else {
                XCTAssertNil(reader.readFloat(SMCReader.fourCC("Tg0D")))
            }
        }
    }

    func testInvalidPayloadBoundsAreRejectedBeforeReadingBytes() {
        for size in [0, 33] {
            let smc = makeSMC()
            smc.values["Tg0D"] = FakeSMC.Value(
                type: "flt ", bytes: Array(repeating: 0, count: size))
            let reader = SMCReader(transport: smc.call)
            XCTAssertNil(reader.readFloat(SMCReader.fourCC("Tg0D")))
            XCTAssertNil(smc.readCalls["Tg0D"])
        }
    }

    func testScalarMetadataIsRevalidatedAfterDiscovery() {
        let smc = makeSMC(gpu: 42)
        let reader = SMCReader(transport: smc.call)
        XCTAssertEqual(reader.read(now: anchor)?.gpuDieMaxC, 42)
        smc.values["Tg0D"] = FakeSMC.Value(
            type: "flt ", bytes: FakeSMC.Value.float(42).bytes + [0])
        XCTAssertNil(reader.read(now: anchor.addingTimeInterval(5))?.gpuDieMaxC)
        smc.values["Tg0D"] = .float(43)
        XCTAssertEqual(reader.read(now: anchor.addingTimeInterval(10))?.gpuDieMaxC, 43)
    }

    func testFailedFanReadIsNotReportedAsFansOff() {
        let smc = makeSMC(gpu: 42)
        smc.values["FNum"] = FakeSMC.Value(type: "ui8 ", bytes: [1])
        smc.values["F0Ac"] = .float(2400)
        smc.values["F0Mx"] = .float(6800)
        smc.readFailures.insert("F0Ac")
        let reader = SMCReader(transport: smc.call)
        XCTAssertEqual(reader.read(now: anchor)?.fans, [])
        smc.readFailures.remove("F0Ac")
        smc.values["F0Ac"] = .float(0)
        XCTAssertEqual(
            reader.read(now: anchor.addingTimeInterval(5))?.fans,
            [FanSample(rpm: 0, maxRPM: 6800)])
    }

    func testSMCProtocolLayoutRemainsCompatibleWithTheKernel() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.bytes), 48)
    }

    // MARK: - Scalar decoding

    func testDecodeRejectsNonFiniteFloatsButPreservesMeasuredZero() {
        let nonFinite: [Float] = [.nan, .infinity, -.infinity]
        for value in nonFinite {
            XCTAssertNil(SMCReader.decode(type: "flt ", bytes: FakeSMC.Value.float(value).bytes))
        }
        XCTAssertEqual(SMCReader.decode(type: "flt ", bytes: [0, 0, 0, 0]), 0)
        XCTAssertFalse(SMCReader.isPlausibleReading(0))
    }

    func testDecodeRejectsMalformedScalarLengths() {
        for (type, size) in [("flt ", 4), ("ioft", 8), ("ui16", 2), ("ui8 ", 1)] {
            for count in Array(0..<size) + [size + 1, 32] {
                XCTAssertNil(
                    SMCReader.decode(type: type, bytes: Array(repeating: 0, count: count)),
                    "\(type) length \(count)")
            }
            XCTAssertEqual(SMCReader.decode(type: type, bytes: Array(repeating: 0, count: size)), 0)
        }
    }
}

private final class FakeSMC {
    struct Value {
        var type: String
        var bytes: [UInt8]

        static func float(_ value: Float) -> Value {
            let bits = value.bitPattern
            return Value(
                type: "flt ",
                bytes: [
                    UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff),
                    UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff),
                ])
        }
    }

    var values: [String: Value]
    var infoFailures: Set<String> = []
    var readFailures: Set<String> = []
    var indexFailures: Set<UInt32> = []
    var infoCalls: [String: Int] = [:]
    var readCalls: [String: Int] = [:]
    var indexCalls = 0

    init(values: [String: Value]) {
        self.values = values
    }

    func call(
        _ input: inout SMCParamStruct, _ output: inout SMCParamStruct, _ outputSize: inout Int
    ) -> kern_return_t {
        outputSize = MemoryLayout<SMCParamStruct>.stride
        let name = SMCReader.toString(input.key)
        switch input.data8 {
        case 8:
            indexCalls += 1
            if indexFailures.contains(input.data32) { return kIOReturnError }
            let names = values.keys.sorted()
            guard Int(input.data32) < names.count else {
                output.result = 0x84
                return kIOReturnSuccess
            }
            output.key = SMCReader.fourCC(names[Int(input.data32)])
        case 9:
            infoCalls[name, default: 0] += 1
            if infoFailures.contains(name) { return kIOReturnError }
            guard let value = value(for: name) else {
                output.result = 0x84
                return kIOReturnSuccess
            }
            output.keyInfo.dataType = SMCReader.fourCC(value.type)
            output.keyInfo.dataSize = UInt32(value.bytes.count)
        case 5:
            readCalls[name, default: 0] += 1
            if readFailures.contains(name) { return kIOReturnError }
            guard let value = value(for: name) else {
                output.result = 0x84
                return kIOReturnSuccess
            }
            withUnsafeMutableBytes(of: &output.bytes) { destination in
                for (index, byte) in value.bytes.prefix(destination.count).enumerated() {
                    destination[index] = byte
                }
            }
        default:
            XCTFail("The reader issued a non-read SMC command: \(input.data8)")
            return kIOReturnError
        }
        return kIOReturnSuccess
    }

    private func value(for name: String) -> Value? {
        guard name == "#KEY" else { return values[name] }
        let count = UInt32(values.count)
        return Value(
            type: "ui32",
            bytes: [
                UInt8(count >> 24 & 0xff), UInt8(count >> 16 & 0xff),
                UInt8(count >> 8 & 0xff), UInt8(count & 0xff),
            ])
    }
}
