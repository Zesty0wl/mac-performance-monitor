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
}
