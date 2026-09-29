import XCTest

@testable import MacPerfMonitorCore

final class SystemHistoryWindowTests: XCTestCase {
    private func point(
        _ t: TimeInterval, pressure: Double = 10, cpu: Double = 0.5
    ) -> SystemHistoryPoint {
        SystemHistoryPoint(
            date: Date(timeIntervalSince1970: t), pressurePercent: pressure, appMemory: UInt64(t),
            wired: 1, compressed: 2, cachedFiles: 3, swapUsed: 4, cpuLoad: cpu,
            networkInBytesPerSec: 5, networkOutBytesPerSec: 6, diskReadBytesPerSec: 7,
            diskWriteBytesPerSec: 8)
    }

    func testColumnsTrackAppendsAndTrimToTheSpan() {
        var w = SystemHistoryWindow(span: 10)
        for t in 0...25 { w.append(point(Double(t), pressure: Double(t))) }
        // Window (15, 25] plus the one pre-window sample at 14.
        XCTAssertEqual(w.count, 12)
        XCTAssertEqual(w.values(.pressurePercent).map { Int($0) }, Array(14...25))
        XCTAssertEqual(w.values(.appMemory).map { Int($0) }, Array(14...25))
        XCTAssertEqual(
            w.timestamps.map { Date(timeIntervalSinceReferenceDate: $0).timeIntervalSince1970 },
            (14...25).map(Double.init))
        XCTAssertEqual(w.latest?.pressurePercent, 25)
        XCTAssertEqual(w.oldestDate?.timeIntervalSince1970, 14)
    }

    func testStaleAppendsAreRejected() {
        var w = SystemHistoryWindow(span: 10)
        XCTAssertTrue(w.append(point(5)))
        XCTAssertFalse(w.append(point(5)))
        XCTAssertFalse(w.append(point(4)))
        XCTAssertEqual(w.count, 1)
    }

    func testReplaceAndPointsRoundTrip() {
        var w = SystemHistoryWindow(span: 100)
        let source = (0..<50).map { point(Double($0), pressure: Double($0) * 2, cpu: 0.25) }
        w.replace(source, span: 20)
        XCTAssertEqual(w.span, 20)
        let back = w.points()
        XCTAssertEqual(back.count, 22)
        XCTAssertEqual(back.first?.date.timeIntervalSince1970, 28)
        XCTAssertEqual(back.last, source.last)
        XCTAssertEqual(w.peak(.pressurePercent), 98)
    }

    func testCompactionKeepsEveryColumnAligned() {
        var w = SystemHistoryWindow(span: 50)
        for t in 0..<6000 { w.append(point(Double(t), pressure: Double(t % 100))) }
        XCTAssertEqual(w.count, 52)
        let times = w.timestamps.map {
            Date(timeIntervalSinceReferenceDate: $0).timeIntervalSince1970
        }
        let pressure = w.values(.pressurePercent)
        XCTAssertEqual(times.first, 5948)
        for (t, p) in zip(times, pressure) {
            XCTAssertEqual(p, Double(Int(t) % 100), "column stays aligned with timestamps")
        }
    }

    func testColumnarDecimationMatchesTheGenericOne() {
        var w = SystemHistoryWindow(span: 3600)
        for i in 0..<14400 {
            w.append(point(Double(i) * 0.25, pressure: 50 + 40 * sin(Double(i) / 9)))
        }
        let domain = w.xDomain!
        let generic = LiveSeriesDecimator.decimate(
            w.points(), buckets: 720, domain: domain, date: { $0.date },
            value: { $0.pressurePercent })
        let lo = domain.lowerBound.timeIntervalSinceReferenceDate
        let hi = domain.upperBound.timeIntervalSinceReferenceDate
        let columnar = LiveSeriesDecimator.decimate(
            times: w.timestamps, values: w.values(.pressurePercent), buckets: 720,
            domain: lo...hi)
        XCTAssertEqual(columnar.count, generic.count)
        for (a, b) in zip(columnar, generic) {
            XCTAssertEqual(a.value, b.value, accuracy: 1e-9)
            XCTAssertEqual(
                a.date.timeIntervalSinceReferenceDate, b.date.timeIntervalSinceReferenceDate,
                accuracy: 1e-6)
        }
        XCTAssertLessThanOrEqual(columnar.count, 1440)
    }

    // MARK: - Peak columns

    func testPeakColumnsMirrorRawSamplesAndCarryStoredPeaks() {
        var window = SystemHistoryWindow(span: 3600)
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        let raw = SystemHistoryPoint(
            date: base, pressurePercent: 20, appMemory: 1, wired: 1, compressed: 1, cachedFiles: 1,
            swapUsed: 0, cpuLoad: 0.3, networkInBytesPerSec: 10, diskWriteBytesPerSec: 4)
        window.append(raw)
        var stored = SystemHistoryPoint(
            date: base.addingTimeInterval(60), pressurePercent: 30, appMemory: 1, wired: 1,
            compressed: 1, cachedFiles: 1, swapUsed: 0, cpuLoad: 0.2, networkInBytesPerSec: 2)
        stored.peaks = SystemHistoryPeaks(
            pressurePercent: 80, cpuLoad: 0.9, networkInBytesPerSec: 50, networkOutBytesPerSec: 6,
            diskReadBytesPerSec: 7, diskWriteBytesPerSec: 8)
        window.append(stored)

        XCTAssertEqual(Array(window.values(.cpuLoad)), [0.3, 0.2], "the line column is the mean")
        XCTAssertEqual(
            Array(window.values(.cpuLoadPeak)), [0.3, 0.9],
            "a raw sample's peak is itself; a stored row's is its bucket peak")
        XCTAssertEqual(Array(window.values(.pressurePercentPeak)), [20, 80])
        XCTAssertEqual(Array(window.values(.networkInPeak)), [10, 50])
        XCTAssertEqual(Array(window.values(.diskWritePeak)), [4, 8])
        XCTAssertEqual(Array(window.values(.gpuUtilizationPeak)), [0, 0])
    }

    func testLoadAverageColumnsFollowThePointAndItsPeak() {
        var window = SystemHistoryWindow(span: 3600)
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        window.append(
            SystemHistoryPoint(
                date: base, pressurePercent: 1, appMemory: 1, wired: 1, compressed: 1,
                cachedFiles: 1, swapUsed: 0, loadAverage1: 3, loadAverage5: 2, loadAverage15: 1))
        var stored = SystemHistoryPoint(
            date: base.addingTimeInterval(60), pressurePercent: 1, appMemory: 1, wired: 1,
            compressed: 1, cachedFiles: 1, swapUsed: 0, loadAverage1: 4, loadAverage5: 3,
            loadAverage15: 2)
        stored.peaks = SystemHistoryPeaks(
            pressurePercent: 1, cpuLoad: 0, networkInBytesPerSec: 0, networkOutBytesPerSec: 0,
            diskReadBytesPerSec: 0, diskWriteBytesPerSec: 0, loadAverage1: 9)
        window.append(stored)
        XCTAssertEqual(Array(window.values(.loadAverage1)), [3, 4])
        XCTAssertEqual(Array(window.values(.loadAverage5)), [2, 3])
        XCTAssertEqual(Array(window.values(.loadAverage15)), [1, 2])
        XCTAssertEqual(Array(window.values(.loadAverage1Peak)), [3, 9])
        XCTAssertEqual(window.points().map(\.loadAverage1), [3, 4])
    }

    private func statisticalPoint(_ t: TimeInterval) -> SystemHistoryPoint {
        var stored = SystemHistoryPoint(
            date: Date(timeIntervalSince1970: t), pressurePercent: 50,
            appMemory: UInt64(t) + 5, wired: 10, compressed: 20, cachedFiles: 30,
            swapUsed: 40, cpuLoad: 0.5, loadAverage1: 2, loadAverage5: 1, loadAverage15: 0.5,
            batteryCharge: 80, batteryPowerWatts: 12, batteryHealthPercent: 95,
            batteryTemperatureCelsius: 29, networkInBytesPerSec: 10,
            networkOutBytesPerSec: 20, diskReadBytesPerSec: 30, diskWriteBytesPerSec: 40,
            diskReadOperationsPerSec: 5, diskWriteOperationsPerSec: 6,
            diskReadLatencyMs: 0.7, diskWriteLatencyMs: 0.9, diskUtilizationPercent: 25,
            bootFreeBytes: 12345, bootTotalBytes: 67890, gpuUtilization: 60,
            gpuPowerWatts: 7, anePowerWatts: 1.5, cpuDieC: 80, gpuDieC: 75,
            ssdTemperatureC: 35, fanRPM: 1200, thermalPressure: .serious,
            cpuPCoreDieC: 80, cpuECoreDieC: 63, airflowC: 35, skinC: 40, wirelessC: 38,
            voltageRailC: 52, otherSensorC: 81, sampleCount: Int(t) % 7 + 5,
            bucketDuration: Int(t).isMultiple(of: 2) ? 60 : 300,
            cpuDieAverageC: 65, gpuDieAverageC: 55, cpuDieSampleCount: 3, gpuDieSampleCount: 2)
        stored.minima = SystemHistoryPeaks(
            pressurePercent: 4, cpuLoad: 0.1, networkInBytesPerSec: 2,
            networkOutBytesPerSec: 3, diskReadBytesPerSec: 1, diskWriteBytesPerSec: 2,
            gpuUtilization: 30, loadAverage1: 0.5, appMemory: t, wired: 2,
            compressed: 3, cachedFiles: 4, swapUsed: 5, cpuDieC: 50, gpuDieC: 45)
        stored.peaks = SystemHistoryPeaks(
            pressurePercent: 90, cpuLoad: 0.9, networkInBytesPerSec: 50,
            networkOutBytesPerSec: 60, diskReadBytesPerSec: 70, diskWriteBytesPerSec: 80,
            gpuUtilization: 90, loadAverage1: 4, appMemory: t + 10, wired: 20,
            compressed: 30, cachedFiles: 40, swapUsed: 50, cpuDieC: 80, gpuDieC: 75)
        return stored
    }

    func testRangeAndWeightColumnsMirrorRawValuesAndStoredStatistics() {
        var window = SystemHistoryWindow(span: 3600)
        let raw = point(1000)
        let stored = statisticalPoint(1001)
        window.replace([raw, stored])
        let expected: [(SystemHistoryWindow.Column, [Double])] = [
            (.sampleCount, [1, Double(stored.sampleCount)]),
            (.bucketDuration, [0, 300]),
            (.pressurePercentMinimum, [10, 4]),
            (.cpuLoadMinimum, [0.5, 0.1]),
            (.networkInMinimum, [5, 2]),
            (.networkOutMinimum, [6, 3]),
            (.diskReadMinimum, [7, 1]),
            (.diskWriteMinimum, [8, 2]),
            (.appMemoryMinimum, [1000, 1001]),
            (.appMemoryPeak, [1000, 1011]),
            (.wiredMinimum, [1, 2]),
            (.wiredPeak, [1, 20]),
            (.compressedMinimum, [2, 3]),
            (.compressedPeak, [2, 30]),
            (.cachedFilesMinimum, [3, 4]),
            (.cachedFilesPeak, [3, 40]),
            (.swapUsedMinimum, [4, 5]),
            (.swapUsedPeak, [4, 50]),
            (.cpuDieC, [0, 80]),
        ]
        for (column, values) in expected {
            XCTAssertEqual(Array(window.values(column)), values, "\(column)")
        }
        for column in SystemHistoryWindow.Column.allCases {
            XCTAssertEqual(window.values(column).count, window.count, "\(column)")
        }
        XCTAssertEqual(
            window.points(), [raw, stored], "all optional fields and statistics survive")
    }

    func testLegacyUnknownExtremaAreNaNAndNeverMeanFallbacks() {
        var legacy = point(1000, pressure: 50)
        legacy.sampleCount = 23
        legacy.bucketDuration = 60
        legacy.cpuDieC = 80
        legacy.cpuDieAverageC = 65
        legacy.peaks = SystemHistoryPeaks(
            pressurePercent: 90, cpuLoad: 0.9, networkInBytesPerSec: 50,
            networkOutBytesPerSec: 60, diskReadBytesPerSec: 70, diskWriteBytesPerSec: 80)
        let raw = point(1001)
        var window = SystemHistoryWindow(span: 3600)
        window.replace([legacy, raw])

        let unknownColumns: [SystemHistoryWindow.Column] = [
            .pressurePercentMinimum, .cpuLoadMinimum, .networkInMinimum, .networkOutMinimum,
            .diskReadMinimum, .diskWriteMinimum, .appMemoryMinimum, .appMemoryPeak,
            .wiredMinimum, .wiredPeak, .compressedMinimum, .compressedPeak,
            .cachedFilesMinimum, .cachedFilesPeak, .swapUsedMinimum, .swapUsedPeak,
        ]
        for column in unknownColumns {
            let values = Array(window.values(column))
            XCTAssertTrue(values[0].isNaN, "\(column) is unknown, not the bucket mean")
            XCTAssertTrue(values[1].isFinite, "\(column) is known for the raw sample")
            XCTAssertNil(window.peak(column), "a known subset cannot claim the full window peak")
        }
        XCTAssertEqual(window.points(), [legacy, raw])
        XCTAssertEqual(Array(window.values(.sampleCount)), [23, 1])
        XCTAssertEqual(Array(window.values(.pressurePercentPeak)), [90, 10])
    }

    func testWidthlessLegacyAndSingletonAggregatesDoNotInventRawExtrema() {
        var widthless = point(1)
        widthless.peaks = SystemHistoryPeaks(
            pressurePercent: 90, cpuLoad: 0.9, networkInBytesPerSec: 50,
            networkOutBytesPerSec: 60, diskReadBytesPerSec: 70, diskWriteBytesPerSec: 80)
        var singleton = point(2)
        singleton.bucketDuration = 60
        var counted = point(3)
        counted.sampleCount = 3
        var window = SystemHistoryWindow(span: 3600)
        window.replace([widthless, singleton, counted])
        XCTAssertTrue(window.values(.pressurePercentMinimum).allSatisfy { $0.isNaN })
        XCTAssertTrue(window.values(.appMemoryPeak).allSatisfy { $0.isNaN })
        XCTAssertEqual(window.points(), [widthless, singleton, counted])
    }

    func testTrimmedReplacePreservesAllFieldsAndExactMemoryBytes() {
        var source = (0..<50).map { statisticalPoint(Double($0)) }
        // These cannot round-trip through Double chart columns, and UInt64.max
        // would even trap if converted back from its rounded Double value.
        source[48].appMemory = UInt64.max
        source[48].wired = (UInt64(1) << 53) + 1
        source[48].swapUsed = UInt64.max - 1
        source[49].cpuDieC = nil
        source[49].cpuDieAverageC = nil
        source[49].cpuDieSampleCount = 0
        source[49].gpuDieSampleCount = nil
        var window = SystemHistoryWindow(span: 100)
        window.replace(source, span: 20)
        XCTAssertEqual(window.points(), Array(source.suffix(22)))
        XCTAssertEqual(window.latest, source.last)
        XCTAssertEqual(
            Array(window.values(.sampleCount)), source.suffix(22).map { Double($0.sampleCount) })
        XCTAssertEqual(
            Array(window.values(.bucketDuration)), source.suffix(22).map(\.bucketDuration))
    }

    func testCompactionAndReplacementKeepStatisticsAlignedAndClearMetadata() {
        var window = SystemHistoryWindow(span: 50)
        for t in 0..<6000 { window.append(statisticalPoint(Double(t))) }
        let expected = (5948..<6000).map { statisticalPoint(Double($0)) }
        XCTAssertEqual(window.points(), expected)
        XCTAssertEqual(Array(window.values(.sampleCount)), expected.map { Double($0.sampleCount) })
        XCTAssertEqual(Array(window.values(.bucketDuration)), expected.map(\.bucketDuration))
        XCTAssertEqual(Array(window.values(.appMemoryMinimum)), (5948..<6000).map(Double.init))
        XCTAssertEqual(Array(window.values(.appMemoryPeak)), (5958..<6010).map(Double.init))
        for column in SystemHistoryWindow.Column.allCases {
            XCTAssertEqual(window.values(column).count, window.count, "\(column)")
            XCTAssertEqual(window.values(column).startIndex, window.timestamps.startIndex)
        }

        let replacement = statisticalPoint(7000)
        window.replace([replacement], span: 20)
        XCTAssertEqual(window.points(), [replacement])
        XCTAssertEqual(Array(window.values(.sampleCount)), [Double(replacement.sampleCount)])
        window.replace([])
        XCTAssertTrue(window.isEmpty)
        XCTAssertTrue(window.points().isEmpty)
        XCTAssertNil(window.latest)
        XCTAssertNil(window.peak(.appMemoryPeak))
        for column in SystemHistoryWindow.Column.allCases {
            XCTAssertTrue(window.values(column).isEmpty, "\(column)")
        }
    }
}
