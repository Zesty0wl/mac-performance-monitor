// SPDX-License-Identifier: MIT

import XCTest

@testable import MacPerfMonitorCore

final class ProcessTraceCodecTests: XCTestCase {
    private func sampleDocument(pointsPerProcess: Int = 200) -> ProcessTraceDocument {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func series(pid: Int32, name: String, base: UInt64) -> ProcessTraceSeries {
            var points: [ProcessTracePoint] = []
            for i in 0..<pointsPerProcess {
                points.append(
                    ProcessTracePoint(
                        t: start.timeIntervalSince1970 + Double(i) * 2,
                        footprint: base + UInt64(i) * 1024,
                        cpu: Double(i % 100),
                        fd: 10 + i % 7,
                        diskRead: UInt64(i) * 4096,
                        diskWritten: UInt64(i) * 2048,
                        net: Double(i % 50) * 1000))
            }
            return ProcessTraceSeries(
                pid: pid, startTime: start, name: name,
                executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
                bundleID: "com.example.\(name)", teamID: "ABCDE12345",
                architecture: "arm64", isTranslated: false, points: points)
        }
        return ProcessTraceDocument(
            generator: "Mac Performance Monitor 1.2.0 (127)",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_500),
            source: .init(osVersion: "macOS 15.5", machineModel: "MacBookPro18,3"),
            startDate: start,
            endDate: start.addingTimeInterval(Double(pointsPerProcess) * 2),
            resolutionSeconds: 2,
            processes: [
                series(pid: 1000, name: "Alpha", base: 100 * 1024 * 1024),
                series(pid: 2000, name: "Beta", base: 50 * 1024 * 1024),
            ])
    }

    func testRoundTripPreservesDocument() throws {
        let document = sampleDocument()
        let encoded = try ProcessTraceCodec.encode(document)
        let decoded = try ProcessTraceCodec.decode(encoded)
        XCTAssertEqual(decoded, document)
    }

    func testContainerCarriesMagicHeader() throws {
        let encoded = try ProcessTraceCodec.encode(sampleDocument(pointsPerProcess: 4))
        // "MPMT"
        XCTAssertEqual([UInt8](encoded.prefix(4)), [0x4D, 0x50, 0x4D, 0x54])
    }

    func testCompressionShrinksRepetitivePayload() throws {
        let document = sampleDocument(pointsPerProcess: 500)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let rawJSON = try encoder.encode(document)
        let container = try ProcessTraceCodec.encode(document)
        XCTAssertLessThan(
            container.count, rawJSON.count,
            "the compressed container should be smaller than the raw JSON")
    }

    func testDecodeRejectsShortData() {
        XCTAssertThrowsError(try ProcessTraceCodec.decode(Data([0x4D, 0x50]))) { error in
            XCTAssertEqual(error as? ProcessTraceError, .notATrace)
        }
    }

    func testDecodeRejectsWrongMagic() {
        var data = Data(repeating: 0, count: 64)
        data.replaceSubrange(0..<4, with: [0x00, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(try ProcessTraceCodec.decode(data)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .notATrace)
        }
    }

    func testDecodeRejectsUnsupportedOldContainerVersion() throws {
        var data = try ProcessTraceCodec.encode(sampleDocument(pointsPerProcess: 4))
        data[4] = 0
        XCTAssertThrowsError(try ProcessTraceCodec.decode(data)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .unsupportedContainerVersion(0))
        }
    }

    func testDecodeRejectsNonzeroReservedBytes() throws {
        var data = try ProcessTraceCodec.encode(sampleDocument(pointsPerProcess: 4))
        data[6] = 1
        XCTAssertThrowsError(try ProcessTraceCodec.decode(data)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .corruptPayload)
        }
    }

    func testDecodeRejectsCorruptPayload() {
        // Valid header, garbage payload that cannot be decompressed.
        var data = Data([0x4D, 0x50, 0x4D, 0x54, 0x01, 0x00, 0x00, 0x00])
        data.append(Data(repeating: 0xFF, count: 32))
        XCTAssertThrowsError(try ProcessTraceCodec.decode(data)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .corruptPayload)
        }
    }

    func testDecompressionStopsAtConfiguredOutputLimit() throws {
        let expanded = Data(repeating: 0x41, count: 128 * 1024)
        let compressed = try (expanded as NSData).compressed(using: .zlib) as Data

        XCTAssertThrowsError(
            try ProcessTraceCodec.decompressZlib(compressed, maximumOutputSize: 1024)
        ) { error in
            XCTAssertEqual(error as? ProcessTraceError, .traceTooLarge)
        }
    }

    func testEncodeRejectsUnsupportedFormatVersion() {
        var document = sampleDocument(pointsPerProcess: 4)
        document.formatVersion = 0
        XCTAssertThrowsError(try ProcessTraceCodec.encode(document)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .unsupportedFormatVersion(0))
        }
    }

    func testEncodeRejectsUnorderedPoints() {
        var document = sampleDocument(pointsPerProcess: 4)
        document.processes[0].points.swapAt(1, 2)
        XCTAssertThrowsError(try ProcessTraceCodec.encode(document)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .corruptPayload)
        }
    }

    func testEncodeRejectsDuplicateProcessIdentities() {
        var document = sampleDocument(pointsPerProcess: 4)
        document.processes.append(document.processes[0])
        XCTAssertThrowsError(try ProcessTraceCodec.encode(document)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .corruptPayload)
        }
    }

    func testEncodeRejectsNonfiniteMetric() {
        var document = sampleDocument(pointsPerProcess: 4)
        document.processes[0].points[0].cpu = .infinity
        XCTAssertThrowsError(try ProcessTraceCodec.encode(document)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .corruptPayload)
        }
    }

    func testEncodeRejectsMetricThatWouldOverflowChartScale() {
        var document = sampleDocument(pointsPerProcess: 4)
        document.processes[0].points[0].cpu = .greatestFiniteMagnitude
        XCTAssertThrowsError(try ProcessTraceCodec.encode(document)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .corruptPayload)
        }
    }

    func testEncodeRejectsPointOutsideDeclaredWindow() {
        var document = sampleDocument(pointsPerProcess: 4)
        document.processes[0].points[0].t =
            document.startDate.addingTimeInterval(-1).timeIntervalSince1970
        XCTAssertThrowsError(try ProcessTraceCodec.encode(document)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .corruptPayload)
        }
    }

    func testEncodeRejectsNonfiniteDerivedDiskRate() {
        var document = sampleDocument(pointsPerProcess: 2)
        document.processes[0].points[0].t = document.startDate.timeIntervalSince1970
        document.processes[0].points[0].diskRead = 0
        document.processes[0].points[0].diskWritten = 0
        document.processes[0].points[1].t = document.startDate.timeIntervalSince1970.nextUp
        document.processes[0].points[1].diskRead = UInt64.max
        document.processes[0].points[1].diskWritten = 0
        XCTAssertThrowsError(try ProcessTraceCodec.encode(document)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .corruptPayload)
        }
    }

    func testDecodeContentsRejectsOversizedFileBeforeReadingIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ProcessTraceCodec.maximumContainerBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try ProcessTraceCodec.decode(contentsOf: url)) { error in
            XCTAssertEqual(error as? ProcessTraceError, .traceTooLarge)
        }
    }

    func testHistoryPointBridgeRoundTrips() {
        let point = ProcessHistoryPoint(
            date: Date(timeIntervalSince1970: 1_700_000_042),
            footprint: 123_456_789,
            cpuPercent: 42.5,
            fdTotal: 37,
            diskRead: 9_000_000,
            diskWritten: 4_500_000,
            networkBytesPerSec: 2048)
        let bridged = ProcessTracePoint(point).historyPoint
        XCTAssertEqual(bridged, point)
    }

    func testEmptyDocumentRoundTrips() throws {
        let document = ProcessTraceDocument(
            generator: "test",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .init(osVersion: "macOS 15.5"),
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            resolutionSeconds: 60,
            processes: [])
        let decoded = try ProcessTraceCodec.decode(try ProcessTraceCodec.encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.totalPointCount, 0)
    }

    func testLargeIntegerValuesSurviveExactly() throws {
        // Footprint and cumulative disk counters are UInt64; a share must not
        // lose a single byte to a floating-point round-trip.
        let point = ProcessTracePoint(
            t: 1_700_000_000,
            footprint: UInt64.max - 7,
            cpu: 99.999,
            fd: Int.max,
            diskRead: 9_223_372_036_854_775_807,
            diskWritten: UInt64.max,
            net: 1_234_567.89)
        let document = ProcessTraceDocument(
            generator: "test",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .init(osVersion: "macOS 15.5"),
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_002),
            resolutionSeconds: 2,
            processes: [
                ProcessTraceSeries(
                    pid: 42, startTime: Date(timeIntervalSince1970: 1_699_999_000),
                    name: "Huge", points: [point])
            ])
        let decoded = try ProcessTraceCodec.decode(try ProcessTraceCodec.encode(document))
        let out = try XCTUnwrap(decoded.processes.first?.points.first)
        XCTAssertEqual(out.footprint, UInt64.max - 7)
        XCTAssertEqual(out.diskWritten, UInt64.max)
        XCTAssertEqual(out.diskRead, 9_223_372_036_854_775_807)
        XCTAssertEqual(out.fd, Int.max)
    }
}
