// SPDX-License-Identifier: MIT
import XCTest

@testable import MacPerfMonitorCore

final class MemoryUsageTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024

    func testReadsAsAShareOfRAMWhileEverythingFits() {
        // The case that read 0 before: a 128 GiB Mac with 88 GiB in use and
        // nothing compressed or swapped.
        let bytes = MemoryUsage.bytes(
            appMemory: 80 * gib, wired: 8 * gib, compressed: 0, compressorStored: 0)
        XCTAssertEqual(bytes, 88 * gib)
        XCTAssertEqual(
            MemoryUsage.percent(bytes: bytes, totalRAM: 128 * gib), 68.75, accuracy: 1e-9)
        XCTAssertEqual(
            PressureIndex.compute(
                level: .normal, compressed: 0, swapUsed: 0, totalRAM: 128 * gib), 0)
    }

    func testCompressedMemoryCountsAtItsOriginalSize() {
        // 2 GiB of RAM holding 6 GiB of squeezed pages counts as the 6 GiB the
        // apps asked for, not the 2 GiB it occupies.
        let bytes = MemoryUsage.bytes(
            appMemory: 8 * gib, wired: 2 * gib, compressed: 2 * gib, compressorStored: 6 * gib)
        XCTAssertEqual(bytes, 16 * gib)
    }

    func testGoesPastOneHundredWhenAppsNeedMoreThanTheMacHas() {
        // A 16 GiB Mac whose apps hold 24 GiB: 13 GiB sit in the compressor
        // (some of it in swap), squeezed into 4 GiB of RAM.
        let bytes = MemoryUsage.bytes(
            appMemory: 8 * gib, wired: 3 * gib, compressed: 4 * gib, compressorStored: 13 * gib)
        XCTAssertEqual(MemoryUsage.percent(bytes: bytes, totalRAM: 16 * gib), 150, accuracy: 1e-9)
    }

    func testFallsBackToTheCompressorFootprintWithoutTheOriginalSize() {
        let bytes = MemoryUsage.bytes(
            appMemory: 8 * gib, wired: 2 * gib, compressed: 3 * gib, compressorStored: nil)
        XCTAssertEqual(bytes, 13 * gib)
    }

    func testUnknownRAMReadsZero() {
        XCTAssertEqual(MemoryUsage.percent(bytes: 8 * gib, totalRAM: 0), 0)
    }

    func testSystemSampleCountsTheStoredSizeWhenItHasOne() {
        var sample = Make.system(
            timestamp: Date(), totalRAM: 16 * gib, compressed: 4 * gib, pressure: .warning,
            appMemory: 8 * gib, wired: 3 * gib)
        // A sample read back from history has no stored size: (8 + 3 + 4) / 16.
        XCTAssertNil(sample.compressorStoredBytes)
        XCTAssertEqual(sample.memoryUsageBytes, 15 * gib)
        XCTAssertEqual(sample.memoryUsagePercent, 93.75, accuracy: 1e-9)
        sample.compressorStoredBytes = 13 * gib
        XCTAssertEqual(sample.memoryUsageBytes, 24 * gib)
        XCTAssertEqual(sample.memoryUsagePercent, 150, accuracy: 1e-9)
    }

    func testDecodesSamplesEncodedBeforeTheStoredSizeExisted() throws {
        var sample = Make.system(timestamp: Date(timeIntervalSince1970: 0))
        sample.compressorStoredBytes = 5 * gib
        let encoded = try JSONEncoder().encode(sample)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "compressorStoredBytes"))
        let older = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SystemSample.self, from: older)
        XCTAssertNil(decoded.compressorStoredBytes)
        XCTAssertEqual(decoded.memoryUsageBytes, sample.appMemory + sample.wired)
    }
}
