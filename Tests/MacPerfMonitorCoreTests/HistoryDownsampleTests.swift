import XCTest

@testable import MacPerfMonitorCore

final class HistoryDownsampleTests: XCTestCase {
    /// The four disk-throughput scalars (and the earlier battery, CPU, and
    /// network fixes) must survive `chartDownsampled`. Before the disk
    /// carry-through, downsampled points defaulted those fields to 0 and the
    /// Disk tab's read/write trend collapsed to a flat zero on any range whose
    /// point count exceeded the cap, even though the raw and minute-tier rows
    /// carried the values.
    func testDownsamplePreservesDiskThroughput() throws {
        // ~400 samples at 2-second spacing inside a one-hour window: well past
        // the maxPoints cap, so chartDownsampled actually buckets them rather
        // than returning the input unchanged.
        let spacing: TimeInterval = 2
        let count = 400
        let span: TimeInterval = 3600
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [SystemHistoryPoint] = []
        points.reserveCapacity(count)
        for i in 0..<count {
            points.append(
                SystemHistoryPoint(
                    date: anchor.addingTimeInterval(Double(i) * spacing),
                    pressurePercent: 50,
                    appMemory: 0,
                    wired: 0,
                    compressed: 0,
                    cachedFiles: 0,
                    swapUsed: 0,
                    cpuLoad: 0.42,
                    batteryCharge: 0.87,
                    batteryPowerWatts: -3.5,
                    batteryHealthPercent: 99,
                    batteryTemperatureCelsius: 31.5,
                    networkInBytesPerSec: 2048,
                    networkOutBytesPerSec: 1024,
                    diskReadBytesPerSec: 5_242_880,
                    diskWriteBytesPerSec: 1_048_576,
                    diskReadOperationsPerSec: 12.5,
                    diskWriteOperationsPerSec: 6.25
                ))
        }

        let downsampled = points.chartDownsampled(span: span, to: 100)

        // Bucketing must actually happen: fewer points out than in.
        XCTAssertLessThan(downsampled.count, points.count, "series should be thinned")
        XCTAssertFalse(downsampled.isEmpty, "expected bucketed points")
        for point in downsampled {
            // The four disk scalars this fix carries through.
            XCTAssertEqual(point.diskReadBytesPerSec, 5_242_880, accuracy: 1.0)
            XCTAssertEqual(point.diskWriteBytesPerSec, 1_048_576, accuracy: 1.0)
            XCTAssertEqual(point.diskReadOperationsPerSec, 12.5, accuracy: 1e-6)
            XCTAssertEqual(point.diskWriteOperationsPerSec, 6.25, accuracy: 1e-6)
            // The earlier scalar-carry fixes (CPU, battery, network) must still
            // hold across every carried field, not just one per category, so a
            // future drop of any single carry line fails here too.
            XCTAssertEqual(point.cpuLoad, 0.42, accuracy: 1e-9)
            XCTAssertEqual(point.batteryCharge, 0.87, accuracy: 1e-9)
            XCTAssertEqual(point.batteryPowerWatts, -3.5, accuracy: 1e-9)
            XCTAssertEqual(point.batteryHealthPercent, 99, accuracy: 1e-9)
            XCTAssertEqual(point.batteryTemperatureCelsius, 31.5, accuracy: 1e-9)
            XCTAssertEqual(point.networkInBytesPerSec, 2048, accuracy: 1e-6)
            XCTAssertEqual(point.networkOutBytesPerSec, 1024, accuracy: 1e-6)
        }
    }

    /// The v12 optional detail fields have their own carry rules: nil-excluded
    /// means for latency and utilization (an idle tick must not drag a bucket's
    /// average toward zero), an all-nil bucket stays nil so charts draw a gap,
    /// and free space keeps the bucket's minimum, the low water mark.
    func testDownsampleCarriesOptionalDiskDetailWithNilRules() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [SystemHistoryPoint] = []
        for index in 0..<400 {
            var point = SystemHistoryPoint(
                date: anchor.addingTimeInterval(Double(index) * 2),
                pressurePercent: 10, appMemory: 1, wired: 1, compressed: 1,
                cachedFiles: 1, swapUsed: 1)
            // First half: alternate busy (2 ms, 40 percent) and idle (nil).
            // Second half: entirely idle, so those buckets must stay nil.
            if index < 200, index.isMultiple(of: 2) {
                point.diskReadLatencyMs = 2.0
                point.diskUtilizationPercent = 40
            }
            point.bootFreeBytes = UInt64(1_000_000 - index)
            point.bootTotalBytes = 2_000_000
            points.append(point)
        }

        let downsampled = points.chartDownsampled(span: 3600, to: 60)
        XCTAssertFalse(downsampled.isEmpty)

        let firstHalf = downsampled.filter {
            $0.date < anchor.addingTimeInterval(390)
        }
        let secondHalf = downsampled.filter {
            $0.date > anchor.addingTimeInterval(410)
        }
        XCTAssertFalse(firstHalf.isEmpty)
        XCTAssertFalse(secondHalf.isEmpty)
        for point in firstHalf {
            XCTAssertEqual(
                point.diskReadLatencyMs ?? -1, 2.0, accuracy: 1e-9,
                "idle ticks must not drag the busy mean toward zero")
            XCTAssertEqual(point.diskUtilizationPercent ?? -1, 40, accuracy: 1e-9)
        }
        for point in secondHalf {
            XCTAssertNil(point.diskReadLatencyMs, "an all-idle bucket must gap, not read 0 ms")
            XCTAssertNil(point.diskUtilizationPercent)
        }

        // Free space: each bucket keeps its minimum, and the series stays
        // monotonically nonincreasing across buckets for this fixture.
        let frees = downsampled.compactMap(\.bootFreeBytes)
        XCTAssertEqual(frees.count, downsampled.count)
        XCTAssertEqual(frees, frees.sorted(by: >))
        XCTAssertEqual(downsampled.last?.bootTotalBytes, 2_000_000)
    }
}
