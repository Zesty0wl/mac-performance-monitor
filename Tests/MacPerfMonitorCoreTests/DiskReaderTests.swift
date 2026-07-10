import XCTest

@testable import MacPerfMonitorCore

final class DiskReaderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstSampleIsZeroThenDifferencesCountersOverActualInterval() {
        var snapshots = [
            [counters(read: 1_000, write: 2_000, readOps: 10, writeOps: 20)],
            [
                counters(
                    read: 5_000, write: 8_000, readOps: 18, writeOps: 26,
                    readTime: 16_000_000, writeTime: 12_000_000)
            ],
        ]
        let reader = makeReader { snapshots.removeFirst() }

        let first = reader.read(now: t0)
        XCTAssertEqual(first.readBytesPerSec, 0)
        XCTAssertEqual(first.writeBytesPerSec, 0)

        let second = reader.read(now: t0.addingTimeInterval(2))
        XCTAssertEqual(second.readBytesPerSec, 2_000)
        XCTAssertEqual(second.writeBytesPerSec, 3_000)
        XCTAssertEqual(second.readOperationsPerSec, 4)
        XCTAssertEqual(second.writeOperationsPerSec, 3)
        XCTAssertEqual(second.devices[0].averageReadTimeMilliseconds, 2)
        XCTAssertEqual(second.devices[0].averageWriteTimeMilliseconds, 2)
    }

    func testCounterResetAndNewDeviceStartAtZero() {
        var snapshots = [
            [counters(id: 1, read: 10_000, write: 20_000)],
            [
                counters(id: 1, read: 100, write: 200),
                counters(id: 2, bsdName: "disk2", read: 50_000, write: 60_000),
            ],
        ]
        let reader = makeReader { snapshots.removeFirst() }
        _ = reader.read(now: t0)

        let sample = reader.read(now: t0.addingTimeInterval(1))
        XCTAssertEqual(sample.readBytesPerSec, 0)
        XCTAssertEqual(sample.writeBytesPerSec, 0)
        XCTAssertEqual(sample.devices.count, 2)
    }

    func testVirtualDevicesAreExcludedFromTotals() {
        let reader = DiskReader(
            counterSource: {
                [
                    self.counters(id: 1, read: 10_000, write: 20_000),
                    self.counters(id: 2, bsdName: "disk4", read: 30_000, write: 40_000),
                ]
            },
            metadataSource: { name in
                name == "disk4"
                    ? .init(
                        model: "Disk Image", protocolName: "Virtual Interface", sizeBytes: nil,
                        isInternal: nil, isRemovable: true, isVirtual: true)
                    : self.metadata()
            })
        _ = reader.read(now: t0)

        XCTAssertEqual(reader.read(now: t0.addingTimeInterval(1)).devices.map(\.bsdName), ["disk0"])
    }

    func testResetMakesNextSampleZero() {
        var value: UInt64 = 1_000
        let reader = makeReader { [self.counters(read: value, write: value)] }
        _ = reader.read(now: t0)
        value = 2_000
        XCTAssertEqual(reader.read(now: t0.addingTimeInterval(1)).readBytesPerSec, 1_000)
        reader.reset()
        value = 3_000
        XCTAssertEqual(reader.read(now: t0.addingTimeInterval(2)).readBytesPerSec, 0)
    }

    private func makeReader(_ source: @escaping () -> [DiskReader.Counters]) -> DiskReader {
        DiskReader(counterSource: source, metadataSource: { _ in self.metadata() })
    }

    private func metadata() -> DiskReader.Metadata {
        .init(
            model: "Test SSD", protocolName: "NVMe", sizeBytes: 500_000_000_000,
            isInternal: true, isRemovable: false, isVirtual: false)
    }

    private func counters(
        id: UInt64 = 1, bsdName: String = "disk0", read: UInt64, write: UInt64,
        readOps: UInt64 = 0, writeOps: UInt64 = 0, readTime: UInt64 = 0,
        writeTime: UInt64 = 0
    ) -> DiskReader.Counters {
        .init(
            registryEntryID: id, bsdName: bsdName,
            readBytes: read, writeBytes: write,
            readOperations: readOps, writeOperations: writeOps,
            readTimeNanoseconds: readTime, writeTimeNanoseconds: writeTime,
            readErrors: 0, writeErrors: 0, readRetries: 0, writeRetries: 0)
    }
}
