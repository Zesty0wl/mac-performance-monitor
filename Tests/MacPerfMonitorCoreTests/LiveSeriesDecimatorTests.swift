import XCTest

@testable import MacPerfMonitorCore

final class LiveSeriesDecimatorTests: XCTestCase {
    private struct Sample {
        var t: TimeInterval
        var v: Double?
        var date: Date { Date(timeIntervalSince1970: t) }
    }

    private func domain(_ lo: TimeInterval, _ hi: TimeInterval) -> ClosedRange<Date> {
        Date(timeIntervalSince1970: lo)...Date(timeIntervalSince1970: hi)
    }

    func testSmallSeriesPassesThroughUnchanged() {
        let samples = (0..<10).map { Sample(t: Double($0), v: Double($0)) }
        let out = LiveSeriesDecimator.decimate(
            samples, buckets: 5, domain: domain(0, 10), date: \.date, value: \.v)
        XCTAssertEqual(out.map(\.value), samples.map { $0.v! })
    }

    func testOutputIsBoundedByTwicetheBucketCount() {
        let samples = (0..<14400).map { Sample(t: Double($0) * 0.25, v: sin(Double($0) / 7)) }
        let out = LiveSeriesDecimator.decimate(
            samples, buckets: 720, domain: domain(0, 3600), date: \.date, value: \.v)
        XCTAssertLessThanOrEqual(out.count, 1440)
        XCTAssertGreaterThan(out.count, 700)
    }

    func testSpikesSurviveAndOrderIsChronological() {
        var samples = (0..<4000).map { Sample(t: Double($0), v: 10) }
        samples[1234].v = 99  // a single-sample spike
        samples[2345].v = -5  // a single-sample trough
        let out = LiveSeriesDecimator.decimate(
            samples, buckets: 100, domain: domain(0, 4000), date: \.date, value: \.v)
        XCTAssertTrue(out.contains { $0.value == 99 && $0.date == samples[1234].date })
        XCTAssertTrue(out.contains { $0.value == -5 && $0.date == samples[2345].date })
        for i in 1..<out.count {
            XCTAssertLessThanOrEqual(out[i - 1].date, out[i].date)
        }
    }

    func testMinAndMaxKeepTheirTimeOrderWithinABucket() {
        // One bucket: low first, then high. The output must be [low, high].
        var samples = (0..<50).map { Sample(t: Double($0), v: 5) }
        samples[10].v = 1
        samples[30].v = 9
        let out = LiveSeriesDecimator.decimate(
            samples, buckets: 1, domain: domain(0, 50), date: \.date, value: \.v)
        XCTAssertEqual(out.map(\.value), [1, 9])

        // Reverse the order and the output follows.
        samples[10].v = 9
        samples[30].v = 1
        let reversed = LiveSeriesDecimator.decimate(
            samples, buckets: 1, domain: domain(0, 50), date: \.date, value: \.v)
        XCTAssertEqual(reversed.map(\.value), [9, 1])
    }

    func testNilValuesAreSkippedSoGapsStayGaps() {
        var samples = (0..<1000).map { Sample(t: Double($0), v: 1) }
        for i in 400..<600 { samples[i].v = nil }
        let out = LiveSeriesDecimator.decimate(
            samples, buckets: 100, domain: domain(0, 1000), date: \.date, value: \.v)
        XCTAssertFalse(
            out.contains {
                $0.date.timeIntervalSince1970 >= 400 && $0.date.timeIntervalSince1970 < 600
            })
        XCTAssertFalse(out.isEmpty)
    }

    func testSamplesOutsideTheDomainLandInEdgeBuckets() {
        let samples = (0..<1000).map { Sample(t: Double($0), v: Double($0)) }
        let out = LiveSeriesDecimator.decimate(
            samples, buckets: 10, domain: domain(500, 900), date: \.date, value: \.v)
        XCTAssertEqual(out.first?.value, 0, "everything before the window shares the first bucket")
        XCTAssertEqual(out.last?.value, 999, "everything after it shares the last bucket")
        XCTAssertLessThanOrEqual(out.count, 20)
    }
}
