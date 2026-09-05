import XCTest

@testable import MacPerfMonitorCore

final class LiveStripBucketsTests: XCTestCase {
    /// Samples every 0.25 s for 100 s from t = 1000, value = index.
    private func series() -> (times: [Double], values: [Double]) {
        var times: [Double] = []
        var values: [Double] = []
        for i in 0..<400 {
            times.append(1000 + Double(i) * 0.25)
            values.append(Double(i))
        }
        return (times, values)
    }

    func testBucketsAreAnchoredToAbsoluteTime() {
        let (t, v) = series()
        // Bucket width 2 s: bucket 500 covers [1000, 1002).
        let a = LiveStripBuckets.buckets(
            times: t[...], values: v[...], width: 2, from: 500, through: 549, gapThreshold: 30)
        let b = LiveStripBuckets.buckets(
            times: t[...], values: v[...], width: 2, from: 510, through: 520, gapThreshold: 30)
        XCTAssertEqual(a.count, 50)
        XCTAssertEqual(b.count, 11)
        // The same bucket reads the same whichever range asked for it.
        XCTAssertEqual(a[10], b[0])
        XCTAssertEqual(a[10].index, 510)
        XCTAssertEqual(a[10].minTime, 1020)
        XCTAssertEqual(a[10].minValue, 80)
        XCTAssertEqual(a[10].maxTime, 1021.75)
        XCTAssertEqual(a[10].maxValue, 87)
        XCTAssertEqual(LiveStripBuckets.index(of: 1021.75, width: 2), 510)
    }

    func testExtremesKeepTimeOrder() {
        let times: [Double] = [10, 11, 12, 13]
        let values: [Double] = [5, 9, 1, 5]
        let buckets = LiveStripBuckets.buckets(
            times: times[...], values: values[...], width: 10, from: 1, through: 1,
            gapThreshold: 30)
        XCTAssertEqual(buckets.count, 1)
        let points = buckets[0].orderedPoints
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].time, 11)
        XCTAssertEqual(points[0].value, 9)
        XCTAssertEqual(points[1].time, 12)
        XCTAssertEqual(points[1].value, 1)
    }

    func testSingleSampleBucketIsOnePoint() {
        let buckets = LiveStripBuckets.buckets(
            times: [20.5][...], values: [3][...], width: 10, from: 2, through: 2, gapThreshold: 30)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].orderedPoints.count, 1)
    }

    func testEmptyBucketsAreSkippedAndGapsFlagged() {
        // Samples at 0...9, a 60 s hole, then 70...79.
        var times: [Double] = []
        for i in 0..<10 { times.append(Double(i)) }
        for i in 70..<80 { times.append(Double(i)) }
        let values = times.map { $0 * 2 }
        let buckets = LiveStripBuckets.buckets(
            times: times[...], values: values[...], width: 5, from: 0, through: 20,
            gapThreshold: 30)
        XCTAssertEqual(buckets.map(\.index), [0, 1, 14, 15])
        XCTAssertEqual(buckets.map(\.gapBefore), [false, false, true, false])
    }

    func testSampleBeforeRangeInformsFirstGap() {
        let times: [Double] = [0, 100, 101]
        let values: [Double] = [1, 1, 1]
        let gapped = LiveStripBuckets.buckets(
            times: times[...], values: values[...], width: 10, from: 10, through: 10,
            gapThreshold: 30)
        XCTAssertEqual(gapped.count, 1)
        XCTAssertTrue(gapped[0].gapBefore)
        let close = LiveStripBuckets.buckets(
            times: [95, 100, 101][...], values: values[...], width: 10, from: 10, through: 10,
            gapThreshold: 30)
        XCTAssertFalse(close[0].gapBefore)
    }

    func testScaleAndRangeFiltering() {
        let (t, v) = series()
        let buckets = LiveStripBuckets.buckets(
            times: t[...], values: v[...], width: 2, from: 520, through: 521, gapThreshold: 30,
            scale: 100)
        XCTAssertEqual(buckets.map(\.index), [520, 521])
        XCTAssertEqual(buckets[0].minValue, 16000)
        // Bucket 521 covers [1042, 1044): samples 168...175.
        XCTAssertEqual(buckets[1].maxValue, 17500)
    }

    func testSlicesWithDifferentStartIndicesAlign() {
        // A trimmed window column (times[100...]) paired with a derived column
        // that starts at 0: values must be read by offset, not by index.
        let (t, v) = series()
        let times = t[100...]
        let derived = Array(v[100...])[...]
        let buckets = LiveStripBuckets.buckets(
            times: times, values: derived, width: 2, from: 512, through: 513, gapThreshold: 30)
        XCTAssertEqual(buckets.map(\.index), [512, 513])
        // The slice starts at sample 100 (t = 1025), inside bucket 512.
        XCTAssertEqual(buckets[0].minValue, 100)
        XCTAssertEqual(buckets[1].maxValue, 111)
    }

    func testRangeBeyondDataIsEmpty() {
        let (t, v) = series()
        XCTAssertTrue(
            LiveStripBuckets.buckets(
                times: t[...], values: v[...], width: 2, from: 900, through: 910,
                gapThreshold: 30
            ).isEmpty)
        XCTAssertTrue(
            LiveStripBuckets.buckets(
                times: t[...], values: v[...], width: 0, from: 0, through: 10, gapThreshold: 30
            ).isEmpty)
    }
    // MARK: Rule 2 and 3: a bucket carries its mean as well as its extremes

    func testBucketCarriesMeanAndCount() {
        let times: [Double] = [0, 1, 2, 3]
        let values: [Double] = [10, 20, 30, 40]
        let buckets = LiveStripBuckets.buckets(
            times: times[...], values: values[...], width: 10,
            from: 0, through: 0, gapThreshold: 100)
        XCTAssertEqual(buckets.count, 1)
        let bucket = try! XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.count, 4)
        XCTAssertEqual(bucket.mean, 25, accuracy: 0.0001)
        XCTAssertEqual(bucket.minValue, 10)
        XCTAssertEqual(bucket.maxValue, 40)
        XCTAssertTrue(bucket.isAggregate)
    }

    func testSingleSampleBucketIsNotAggregate() {
        let times: [Double] = [0]
        let values: [Double] = [42]
        let buckets = LiveStripBuckets.buckets(
            times: times[...], values: values[...], width: 10,
            from: 0, through: 0, gapThreshold: 100)
        let bucket = try! XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.mean, 42)
        XCTAssertEqual(bucket.count, 1)
        XCTAssertFalse(bucket.isAggregate, "one sample has no spread to band")
    }

    func testMeanIgnoresBucketBoundariesCorrectly() {
        // Two buckets of two samples each: means 15 and 35, not one mean of 25.
        let times: [Double] = [0, 1, 10, 11]
        let values: [Double] = [10, 20, 30, 40]
        let buckets = LiveStripBuckets.buckets(
            times: times[...], values: values[...], width: 10,
            from: 0, through: 1, gapThreshold: 100)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].mean, 15, accuracy: 0.0001)
        XCTAssertEqual(buckets[1].mean, 35, accuracy: 0.0001)
    }

    func testScaleAppliesToTheMeanToo() {
        let times: [Double] = [0, 1]
        let values: [Double] = [0.1, 0.3]
        let buckets = LiveStripBuckets.buckets(
            times: times[...], values: values[...], width: 10,
            from: 0, through: 0, gapThreshold: 100, scale: 100)
        let bucket = try! XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.mean, 20, accuracy: 0.0001)
    }

}
