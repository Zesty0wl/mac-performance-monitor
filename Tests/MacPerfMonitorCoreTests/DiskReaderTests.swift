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

    func testUtilizationDerivesFromBusyTimeDeltas() {
        // 40 ms read busy + 10 ms write busy over a 1 s interval = 5 percent.
        var snapshots = [
            [counters(read: 0, write: 0, readOps: 0, writeOps: 0)],
            [
                counters(
                    read: 1_000, write: 1_000, readOps: 10, writeOps: 10,
                    readTime: 40_000_000, writeTime: 10_000_000)
            ],
        ]
        let reader = makeReader { snapshots.removeFirst() }

        let first = reader.read(now: t0)
        XCTAssertNil(first.devices[0].utilizationPercent)
        XCTAssertNil(first.utilizationPercent)

        let second = reader.read(now: t0.addingTimeInterval(1))
        XCTAssertEqual(second.devices[0].utilizationPercent ?? -1, 5, accuracy: 0.001)
        XCTAssertEqual(second.utilizationPercent ?? -1, 5, accuracy: 0.001)
    }

    func testUtilizationIsCappedAtOneHundredAndSystemTakesBusiestDevice() {
        // Device 1 reports more busy time than wall clock (overlapping queued
        // IO does this); device 2 is 20 percent busy. System = max = 100.
        var snapshots = [
            [
                counters(id: 1, read: 0, write: 0),
                counters(id: 2, bsdName: "disk2", read: 0, write: 0),
            ],
            [
                counters(
                    id: 1, read: 1, write: 1, readOps: 1, writeOps: 1,
                    readTime: 900_000_000, writeTime: 700_000_000),
                counters(
                    id: 2, bsdName: "disk2", read: 1, write: 1, readOps: 1, writeOps: 1,
                    readTime: 100_000_000, writeTime: 100_000_000),
            ],
        ]
        let reader = makeReader { snapshots.removeFirst() }
        _ = reader.read(now: t0)

        let sample = reader.read(now: t0.addingTimeInterval(1))
        XCTAssertEqual(sample.devices.map { $0.utilizationPercent ?? -1 }, [100, 20])
        XCTAssertEqual(sample.utilizationPercent, 100)
    }

    func testSystemLatencyIsOpsWeightedAcrossDevices() {
        // Device 1: 90 read ops at 1 ms. Device 2: 10 read ops at 11 ms.
        // Ops-weighted mean = (90*1 + 10*11) / 100 = 2 ms.
        var snapshots = [
            [
                counters(id: 1, read: 0, write: 0),
                counters(id: 2, bsdName: "disk2", read: 0, write: 0),
            ],
            [
                counters(id: 1, read: 1, write: 0, readOps: 90, readTime: 90_000_000),
                counters(
                    id: 2, bsdName: "disk2", read: 1, write: 0, readOps: 10,
                    readTime: 110_000_000),
            ],
        ]
        let reader = makeReader { snapshots.removeFirst() }
        _ = reader.read(now: t0)

        let sample = reader.read(now: t0.addingTimeInterval(1))
        XCTAssertEqual(sample.readLatencyMs ?? -1, 2, accuracy: 0.001)
        XCTAssertNil(sample.writeLatencyMs, "zero write ops must yield nil, not 0 ms")
    }

    func testLatencyAndUtilizationAreNilAfterCounterReset() {
        // A reset counter (current below prior) must not fabricate a huge delta.
        var snapshots = [
            [counters(read: 0, write: 0, readOps: 100, readTime: 500_000_000)],
            [counters(read: 1, write: 0, readOps: 10, readTime: 40_000_000)],
        ]
        let reader = makeReader { snapshots.removeFirst() }
        _ = reader.read(now: t0)

        let sample = reader.read(now: t0.addingTimeInterval(1))
        XCTAssertNil(sample.readLatencyMs)
        XCTAssertNil(sample.devices[0].utilizationPercent)
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
