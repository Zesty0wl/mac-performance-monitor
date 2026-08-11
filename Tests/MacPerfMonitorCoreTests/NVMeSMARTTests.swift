import XCTest

@testable import MacPerfMonitorCore

final class NVMeSMARTTests: XCTestCase {
    func testParsesFixtureLogPage() {
        var blob = [UInt8](repeating: 0, count: 512)
        blob[0] = 0b0000_0100  // critical warning: media degraded
        put16(&blob, at: 1, 310)  // Kelvin -> 36.85 C
        blob[3] = 98  // available spare
        blob[4] = 10  // spare threshold
        blob[5] = 3  // percentage used
        put64(&blob, at: 32, 11_000)  // data units read
        put64(&blob, at: 40, 1)  // high half of the 128-bit counter, ignored
        put64(&blob, at: 48, 7_000)  // data units written
        put64(&blob, at: 64, 123_456)  // host read commands
        put64(&blob, at: 80, 654_321)  // host write commands
        put64(&blob, at: 96, 42)  // controller busy minutes
        put64(&blob, at: 112, 500)  // power cycles
        put64(&blob, at: 128, 1_234)  // power on hours
        put64(&blob, at: 144, 7)  // unsafe shutdowns
        put64(&blob, at: 160, 2)  // media errors
        put64(&blob, at: 176, 9)  // error log entries

        guard let snapshot = NVMeSMARTReader.parse(Data(blob)) else {
            return XCTFail("fixture must parse")
        }
        XCTAssertEqual(snapshot.criticalWarning, 4)
        XCTAssertFalse(snapshot.isHealthy)
        XCTAssertEqual(snapshot.temperatureCelsius ?? -1, 36.85, accuracy: 0.001)
        XCTAssertEqual(snapshot.availableSparePercent, 98)
        XCTAssertEqual(snapshot.spareThresholdPercent, 10)
        XCTAssertEqual(snapshot.percentageUsed, 3)
        XCTAssertEqual(snapshot.dataUnitsRead, 11_000, "high 64 bits must not bleed in")
        XCTAssertEqual(snapshot.dataUnitsWritten, 7_000)
        XCTAssertEqual(snapshot.hostReadCommands, 123_456)
        XCTAssertEqual(snapshot.hostWriteCommands, 654_321)
        XCTAssertEqual(snapshot.controllerBusyTimeMinutes, 42)
        XCTAssertEqual(snapshot.powerCycles, 500)
        XCTAssertEqual(snapshot.powerOnHours, 1_234)
        XCTAssertEqual(snapshot.unsafeShutdowns, 7)
        XCTAssertEqual(snapshot.mediaErrors, 2)
        XCTAssertEqual(snapshot.errorLogEntries, 9)
        XCTAssertEqual(snapshot.bytesRead, 11_000 * 512_000)
        XCTAssertEqual(snapshot.bytesWritten, 7_000 * 512_000)
    }

    func testZeroTemperatureReadsAsUnknown() {
        let blob = [UInt8](repeating: 0, count: 512)
        let snapshot = NVMeSMARTReader.parse(Data(blob))
        XCTAssertNil(snapshot?.temperatureCelsius)
        XCTAssertEqual(snapshot?.isHealthy, true)
    }

    func testShortInputReturnsNil() {
        XCTAssertNil(NVMeSMARTReader.parse(Data()))
        XCTAssertNil(NVMeSMARTReader.parse(Data(repeating: 0xFF, count: 511)))
    }

    func testParseHonorsDataSlices() {
        // A Data slice whose startIndex is nonzero must decode identically;
        // Data indexing is absolute, the classic trap.
        var blob = [UInt8](repeating: 0, count: 520)
        blob[8] = 1  // critical warning once sliced
        put16(&blob, at: 9, 300)
        let sliced = Data(blob)[8...]
        let snapshot = NVMeSMARTReader.parse(sliced)
        XCTAssertEqual(snapshot?.criticalWarning, 1)
        XCTAssertEqual(snapshot?.temperatureCelsius ?? -1, 26.85, accuracy: 0.001)
    }

    func testLifetimeBytesSaturateInsteadOfTrapping() {
        XCTAssertEqual(NVMeSMARTSnapshot.bytes(fromDataUnits: .max), .max)
        XCTAssertEqual(NVMeSMARTSnapshot.bytes(fromDataUnits: 2), 1_024_000)
    }

    func testLiveReadIsNilOrPlausible() {
        // Live smoke: on a Mac with a readable internal NVMe drive we get real
        // figures; on anything else we get nil. Both are correct.
        let hardware = DiskInfoReader().read()
        let reader = NVMeSMARTReader()
        for info in hardware.values where !info.smartCandidateIDs.isEmpty {
            guard let smart = reader.read(candidateRegistryEntryIDs: info.smartCandidateIDs)
            else { continue }
            if let temperature = smart.temperatureCelsius {
                XCTAssertGreaterThan(temperature, -20)
                XCTAssertLessThan(temperature, 120)
            }
            XCTAssertLessThan(smart.powerOnHours, 500_000)
            XCTAssertGreaterThan(smart.dataUnitsWritten, 0)
        }
    }

    private func put16(_ blob: inout [UInt8], at offset: Int, _ value: UInt16) {
        blob[offset] = UInt8(value & 0xFF)
        blob[offset + 1] = UInt8(value >> 8)
    }

    private func put64(_ blob: inout [UInt8], at offset: Int, _ value: UInt64) {
        for byte in 0..<8 {
            blob[offset + byte] = UInt8((value >> (8 * byte)) & 0xFF)
        }
    }
}
