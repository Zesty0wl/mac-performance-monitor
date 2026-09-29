import XCTest

@testable import MacPerfMonitorCore

final class ChartStatisticsTests: XCTestCase {
    private func reduce(
        _ times: [Double], _ values: [Double], lows: [Double]? = nil, highs: [Double]? = nil,
        weights: [Double]? = nil, durations: [Double]? = nil, width: Double = 10,
        range: ClosedRange<Double> = 0...100, gap: Double = 15, scale: Double = 1
    ) -> [ChartStatistics.Bucket] {
        ChartStatistics.buckets(
            times: times[...], values: values[...], lows: lows.map { $0[...] },
            highs: highs.map { $0[...] }, weights: weights.map { $0[...] },
            durations: durations.map { $0[...] }, width: width, range: range,
            gapThreshold: gap, scale: scale)
    }

    func testIntervalTableIsStableAtEveryDisplayWidth() {
        let cases: [(Double, Double)] = [
            (300, 5), (1800, 15), (3600, 30), (21600, 300),
            (86400, 900), (604800, 7200),
        ]
        for pixels in [240, 480, 960, 1920] {
            for (span, expected) in cases {
                // Pixels are deliberately not an input to the statistics API.
                let width = ChartStatistics.interval(span: span)
                XCTAssertEqual(width, expected, "viewport width: \(pixels)")
                XCTAssertLessThanOrEqual(span / width, 120)
            }
        }
    }

    func testIntervalRoundsUpToSourceGridMultiples() {
        XCTAssertEqual(ChartStatistics.interval(span: 300, minimum: 2), 6)
        XCTAssertEqual(ChartStatistics.interval(span: 300, minimum: 60), 60)
        XCTAssertEqual(ChartStatistics.interval(span: 21600, minimum: 120), 360)
        XCTAssertEqual(ChartStatistics.interval(span: 86400, minimum: 60), 900)
        XCTAssertEqual(ChartStatistics.interval(span: 86400, minimum: 3600), 3600)
        XCTAssertEqual(ChartStatistics.interval(span: 604800, minimum: 3600), 7200)
        for minimum in [1.0, 60, 120, 300, 3600] {
            let width = ChartStatistics.interval(span: 604800, minimum: minimum)
            XCTAssertEqual(width.truncatingRemainder(dividingBy: minimum), 0)
            XCTAssertGreaterThanOrEqual(width, minimum)
            XCTAssertLessThanOrEqual(604800 / width, 120)
        }
        let longSpan = 86400.0 * 1000
        let longWidth = ChartStatistics.interval(span: longSpan)
        XCTAssertTrue(longWidth.isFinite)
        XCTAssertGreaterThanOrEqual(longWidth, longSpan / 120)
    }

    func testInvalidIntervalsReturnZero() {
        for span in [0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertEqual(ChartStatistics.interval(span: span), 0)
        }
        for minimum in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertEqual(ChartStatistics.interval(span: 300, minimum: minimum), 0)
        }
    }

    func testEpochAnchorsAndNegativeTimesUseFloorNotTruncation() {
        let epoch = 1_800_000_000.0
        let positive = reduce(
            [epoch + 1, epoch + 9, epoch + 10], [2, 4, 8],
            range: epoch...(epoch + 20))
        XCTAssertEqual(positive.map(\.index), [180_000_000, 180_000_001])
        XCTAssertEqual(positive.map(\.start), [epoch, epoch + 10])
        XCTAssertEqual(positive.map(\.end), [epoch + 10, epoch + 20])
        let negative = reduce([-10, -0.5, 0], [2, 4, 8], range: -10...10)
        XCTAssertEqual(negative.map(\.index), [-1, 0])
        XCTAssertEqual(negative.map(\.start), [-10, 0])
        XCTAssertEqual(negative.map(\.end), [0, 10])
    }

    func testUnequalStoredCountsWeightBothBucketsAndSummary() throws {
        let buckets = reduce(
            [1, 2, 11], [10, 50, 100], lows: [8, 30, 70], highs: [12, 90, 130],
            weights: [1, 3, 6])
        XCTAssertEqual(buckets.count, 2)
        let first = try XCTUnwrap(buckets.first)
        XCTAssertEqual(first.mean, 40)
        XCTAssertEqual(first.weightedSum, 160)
        XCTAssertEqual(first.weight, 4)
        XCTAssertEqual(first.sampleCount, 4)
        XCTAssertEqual(first.minimum, 8)
        XCTAssertEqual(first.maximum, 90)
        XCTAssertFalse(first.hasUnknownWeight)
        let summary = try XCTUnwrap(ChartStatistics.summary(buckets))
        XCTAssertEqual(summary.mean, 76, "not the unweighted mean of bucket means, 70")
        XCTAssertEqual(summary.minimum, 8)
        XCTAssertEqual(summary.maximum, 130)
        XCTAssertEqual(summary.sampleCount, 10)
        XCTAssertFalse(summary.hasUnknownWeight)
    }

    func testTrueStoredExtremaAreNotExtremaOfMeans() throws {
        let bucket = try XCTUnwrap(
            reduce(
                [0, 60], [40, 50], lows: [2, 30], highs: [95, 80],
                weights: [30, 10], durations: [60, 60], width: 300
            ).first)
        XCTAssertEqual(bucket.mean, 42.5)
        XCTAssertEqual(bucket.minimum, 2)
        XCTAssertEqual(bucket.maximum, 95)
        XCTAssertEqual(bucket.sampleCount, 40)
        XCTAssertEqual(bucket.sourceResolution, 60)
        XCTAssertEqual(bucket.firstTime, 0)
        XCTAssertEqual(bucket.lastTime, 120)
    }

    func testRawDefaultsUseUnitWeightsAndObservedExtrema() throws {
        let bucket = try XCTUnwrap(reduce([1, 2, 3], [10, 40, 10]).first)
        XCTAssertEqual(bucket.mean, 20)
        XCTAssertEqual(bucket.minimum, 10)
        XCTAssertEqual(bucket.maximum, 40)
        XCTAssertEqual(bucket.weight, 3)
        XCTAssertEqual(bucket.weightedSum, 60)
        XCTAssertEqual(bucket.sampleCount, 3)
        XCTAssertEqual(bucket.sourceResolution, 0)
        XCTAssertFalse(bucket.hasUnknownWeight)
    }

    func testLegacyUnknownWeightIsExplicitlyApproximate() throws {
        let buckets = reduce([1, 2, 11], [10, 50, 100], weights: [1, .nan, 6])
        let first = try XCTUnwrap(buckets.first)
        XCTAssertEqual(first.mean, 30)
        XCTAssertEqual(first.weight, 2)
        XCTAssertEqual(first.weightedSum, 60)
        XCTAssertNil(first.sampleCount)
        XCTAssertTrue(first.hasUnknownWeight)
        let summary = try XCTUnwrap(ChartStatistics.summary(buckets))
        XCTAssertEqual(summary.mean, 82.5)
        XCTAssertNil(summary.sampleCount)
        XCTAssertTrue(summary.hasUnknownWeight)
        XCTAssertEqual(summary.minimum, 10)
        XCTAssertEqual(summary.maximum, 100)
    }

    func testUnknownExtremaPropagateIndependentlyThroughSummary() throws {
        let buckets = reduce(
            [1, 2, 11], [20, 40, 60], lows: [10, .nan, 50], highs: [30, 70, .nan],
            weights: [1, 3, 2])
        let first = try XCTUnwrap(buckets.first)
        XCTAssertNil(first.minimum, "one known mean with a lost minimum poisons that bound")
        XCTAssertEqual(first.maximum, 70)
        let last = try XCTUnwrap(buckets.last)
        XCTAssertEqual(last.minimum, 50)
        XCTAssertNil(last.maximum)
        let summary = try XCTUnwrap(ChartStatistics.summary(buckets))
        XCTAssertNil(summary.minimum)
        XCTAssertNil(summary.maximum)
        XCTAssertEqual(summary.sampleCount, 6)
        XCTAssertFalse(summary.hasUnknownWeight, "unknown extrema do not make counts unknown")
        XCTAssertEqual(summary.mean, 260.0 / 6, accuracy: 1e-12)
    }

    func testUnknownBoundsOnMissingOrIgnoredRowsDoNotPoisonStatistics() throws {
        let buckets = reduce(
            [1, 2, 3, 4], [10, 999, .nan, 20], lows: [8, .nan, .nan, 18],
            highs: [12, .nan, .nan, 22], weights: [1, 0, 0, 1])
        XCTAssertEqual(buckets.map(\.index), [0, 0])
        XCTAssertEqual(buckets.map(\.gapBefore), [false, true])
        let summary = try XCTUnwrap(ChartStatistics.summary(buckets))
        XCTAssertEqual(summary.mean, 15)
        XCTAssertEqual(summary.minimum, 8)
        XCTAssertEqual(summary.maximum, 22)
        XCTAssertEqual(summary.sampleCount, 2)
    }

    func testEveryNonfiniteValueBreaksBothSidesInsideTheSameInterval() throws {
        let buckets = reduce(
            [1, 2, 3, 4, 5, 6, 7], [10, .nan, 20, .infinity, 30, -.infinity, 40])
        XCTAssertEqual(buckets.map(\.index), [0, 0, 0, 0])
        XCTAssertEqual(buckets.map(\.gapBefore), [false, true, true, true])
        XCTAssertEqual(buckets.map(\.mean), [10, 20, 30, 40])
        XCTAssertEqual(buckets.map(\.firstTime), [1, 3, 5, 7])
        XCTAssertEqual(buckets.map(\.lastTime), [1, 3, 5, 7])
        for time in [2.0, 4, 6] {
            XCTAssertNil(ChartStatistics.selection(at: time, in: buckets, tolerance: 100))
        }
        let summary = try XCTUnwrap(ChartStatistics.summary(buckets))
        XCTAssertEqual(summary.mean, 25)
        XCTAssertEqual(summary.sampleCount, 4)
    }

    func testLeadingAndTrailingMissingReadingsRemainSelectionBoundaries() throws {
        let buckets = reduce([1, 2, 3], [.nan, 20, .nan])
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertTrue(bucket.gapBefore)
        XCTAssertEqual(bucket.firstTime, 2)
        XCTAssertEqual(bucket.lastTime, 2)
        XCTAssertNil(ChartStatistics.selection(at: 1, in: buckets, tolerance: 100))
        XCTAssertNil(ChartStatistics.selection(at: 3, in: buckets, tolerance: 100))
        XCTAssertNil(ChartStatistics.selection(at: 5, in: buckets, tolerance: 100))
        XCTAssertEqual(ChartStatistics.selection(at: 2, in: buckets, tolerance: 0), bucket)
    }

    func testExplicitMissingCapsAggregateCoverageEvenWithoutAFollowingValue() throws {
        let buckets = reduce([0, 30], [10, .nan], durations: [60, 0], width: 60)
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.end, 60)
        XCTAssertEqual(bucket.lastTime, 30)
        XCTAssertEqual(bucket.sourceResolution, 60, "the source resolution is not shortened")
        XCTAssertEqual(ChartStatistics.selection(at: 29, in: buckets, tolerance: 0), bucket)
        XCTAssertNil(ChartStatistics.selection(at: 30, in: buckets, tolerance: 100))
        XCTAssertNil(ChartStatistics.selection(at: 45, in: buckets, tolerance: 100))
    }

    func testMissingAggregateCoverageCannotBeSelectedFromEitherSide() {
        let buckets = reduce(
            [0, 60, 120], [10, .nan, 30], weights: [30, 0, 30],
            durations: [60, 60, 60], width: 300, range: 0...180)
        XCTAssertEqual(buckets.map(\.index), [0, 0])
        XCTAssertEqual(buckets.map(\.gapBefore), [false, true])
        XCTAssertNil(ChartStatistics.selection(at: 60, in: buckets, tolerance: 1000))
        XCTAssertNil(ChartStatistics.selection(at: 90, in: buckets, tolerance: 1000))
        XCTAssertEqual(ChartStatistics.selection(at: 120, in: buckets, tolerance: 0)?.mean, 30)
    }

    func testLargeTimeGapSplitsOneIntervalAndCannotBeCrossedByTolerance() {
        let buckets = reduce([1, 80], [10, 20], width: 100, gap: 15)
        XCTAssertEqual(buckets.map(\.index), [0, 0])
        XCTAssertEqual(buckets.map(\.gapBefore), [false, true])
        for time in [2.0, 20, 50, 79] {
            XCTAssertNil(ChartStatistics.selection(at: time, in: buckets, tolerance: 1000))
        }
        XCTAssertEqual(ChartStatistics.selection(at: 1, in: buckets, tolerance: 0)?.mean, 10)
        XCTAssertEqual(ChartStatistics.selection(at: 80, in: buckets, tolerance: 0)?.mean, 20)
    }

    func testEmptyIntervalsAreNotFilledOrSelectedFromNeighbors() {
        let buckets = reduce([1, 21], [10, 20], width: 5, gap: 100)
        XCTAssertEqual(buckets.map(\.index), [0, 4])
        for time in [5.0, 9, 10, 15, 19] {
            XCTAssertNil(ChartStatistics.selection(at: time, in: buckets, tolerance: 1000))
        }
        XCTAssertNil(ChartStatistics.selection(at: -1, in: buckets, tolerance: 1000))
        XCTAssertNil(ChartStatistics.selection(at: 25, in: buckets, tolerance: 1000))
    }

    func testSelectionUsesMeasuredPortionRatherThanNominalEmptyEdges() throws {
        let buckets = reduce([13, 16], [10, 20])
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.start, 10)
        XCTAssertEqual(bucket.end, 20)
        XCTAssertNil(ChartStatistics.selection(at: 10, in: buckets, tolerance: 1))
        XCTAssertNil(ChartStatistics.selection(at: 19, in: buckets, tolerance: 1))
        for time in [12.0, 13, 15, 16, 17] {
            XCTAssertEqual(ChartStatistics.selection(at: time, in: buckets, tolerance: 1), bucket)
        }
        XCTAssertNil(ChartStatistics.selection(at: 20, in: buckets, tolerance: 100))
        let adjacent = reduce([9, 11], [10, 20])
        XCTAssertEqual(ChartStatistics.selection(at: 10, in: adjacent, tolerance: 1)?.index, 1)
    }

    func testNominalEndDoesNotFutureDateAnOpenBucketsMeasuredPortion() throws {
        let buckets = reduce([31, 32], [10, 20], width: 30, range: 0...32)
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.end, 60, "the fixed geometry must not follow the latest sample")
        XCTAssertEqual(bucket.lastTime, 32)
        XCTAssertEqual(min(bucket.end, bucket.lastTime), 32)
        XCTAssertNil(ChartStatistics.selection(at: 59, in: buckets, tolerance: 1))
    }

    func testPartialRangeStatisticsExcludeBothOutsideRows() throws {
        let buckets = reduce([0, 2, 3, 9], [-1000, 20, 40, 1000], range: 2...3)
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.start, 0)
        XCTAssertEqual(bucket.end, 10)
        XCTAssertEqual(bucket.firstTime, 2)
        XCTAssertEqual(bucket.lastTime, 3)
        XCTAssertEqual(bucket.mean, 30)
        XCTAssertEqual(bucket.minimum, 20)
        XCTAssertEqual(bucket.maximum, 40)
        XCTAssertEqual(bucket.sampleCount, 2)
        XCTAssertEqual(ChartStatistics.summary(buckets)?.mean, 30)
    }

    func testRangeIsInclusiveWhileNominalIntervalsAreHalfOpen() {
        let buckets = reduce([0, 10, 20, 30], [-1000, 10, 20, 1000], range: 10...20)
        XCTAssertEqual(buckets.map(\.index), [1, 2])
        XCTAssertEqual(buckets.map(\.mean), [10, 20])
        XCTAssertEqual(ChartStatistics.summary(buckets)?.sampleCount, 2)
        XCTAssertEqual(ChartStatistics.summary(buckets)?.mean, 15)
        XCTAssertEqual(reduce([10], [42], range: 10...10).first?.mean, 42)
    }

    func testPartialRedrawsMatchAllCompleteBinsIncludingGapMetadata() {
        let times: [Double] = [0, 1, 10, 11, 12, 20, 21, 25, 31, 40, 45, 70, 71]
        let values: [Double] = [1, 2, 10, .nan, 12, 20, 21, .nan, 31, 40, .nan, 70, 71]
        let full = reduce(times, values, range: 0...79, gap: 5)
        for index in Set(full.map(\.index)).sorted() {
            let start = Double(index) * 10
            // A ClosedRange ending just before the next start selects one
            // entire half-open bin, with no sample from the following bin.
            let partial = reduce(times, values, range: start...(start + 10).nextDown, gap: 5)
            XCTAssertEqual(partial, full.filter { $0.index == index })
        }
    }

    func testOutsideMissingContextCapsCoverageWithoutContributingToStatistics() throws {
        let times: [Double] = [0, 30, 31]
        let values: [Double] = [10, .nan, 1000]
        let full = reduce(times, values, durations: [60, 0, 0], width: 60)
        let partial = reduce(times, values, durations: [60, 0, 0], width: 60, range: 0...20)
        XCTAssertEqual(partial, Array(full.prefix(1)))
        let bucket = try XCTUnwrap(partial.first)
        XCTAssertEqual(bucket.lastTime, 30)
        XCTAssertEqual(bucket.sampleCount, 1)
        XCTAssertEqual(bucket.mean, 10)
        XCTAssertNil(ChartStatistics.selection(at: 30, in: partial, tolerance: 100))
    }

    func testAppendingSamplesChangesOnlyTheOpenInterval() {
        let times: [Double] = [0, 1, 5, 6, 10]
        let values: [Double] = [0, 4, 10, 30, 100]
        let before = reduce(times, values, width: 5)
        let appended = reduce(times + [11], values + [200], width: 5)
        XCTAssertEqual(Array(before.dropLast()), Array(appended.dropLast()))
        XCTAssertEqual(before.last?.mean, 100)
        XCTAssertEqual(appended.last?.mean, 150)
        XCTAssertEqual(before.last?.end, appended.last?.end)
        let nextInterval = reduce(times + [11, 15], values + [200, 300], width: 5)
        XCTAssertEqual(appended, Array(nextInterval.dropLast()))
    }

    func testEveryColumnCanHaveADifferentTrimmedSliceIndex() {
        let times: [Double] = [-2, -1, 0, 60, 62, 64]
        let values: [Double] = [-1, 10, 20, 30, 40]
        let lows: [Double] = [8, 15, 29, 35]
        let highs: [Double] = [-6, -5, -4, -3, -2, -1, 12, 25, 31, 45]
        let weights: [Double] = [-4, -3, -2, -1, 2, 3, 1, 1]
        let durations: [Double] = [-3, -2, -1, 60, 0, 0, 0]
        let sliced = ChartStatistics.buckets(
            times: times[2...], values: values[1...], lows: lows[...], highs: highs[6...],
            weights: weights[4...], durations: durations[3...], width: 120,
            range: 0...119, gapThreshold: 15)
        let aligned = reduce(
            [0, 60, 62, 64], [10, 20, 30, 40], lows: [8, 15, 29, 35], highs: [12, 25, 31, 45],
            weights: [2, 3, 1, 1], durations: [60, 0, 0, 0], width: 120, range: 0...119)
        XCTAssertEqual(sliced, aligned)
        XCTAssertEqual(sliced.first?.sampleCount, 7)
        XCTAssertEqual(sliced.first?.minimum, 8)
        XCTAssertEqual(sliced.first?.maximum, 45)
    }

    func testMinuteAndRawMixUsesPreviousRowCoverageNotGlobalCoarsestCadence() throws {
        let buckets = reduce(
            [0, 60, 120, 122, 170, 180], [10, 20, 30, 50, 70, 90],
            lows: [2, 15, 30, 50, 70, 80], highs: [18, 25, 30, 50, 70, 100],
            weights: [30, 10, 1, 1, 1, 20], durations: [60, 60, 0, 0, 0, 60],
            width: 300, range: 0...300, gap: 15)
        XCTAssertEqual(buckets.map(\.index), [0, 0])
        XCTAssertEqual(buckets.map(\.gapBefore), [false, true])
        XCTAssertEqual(buckets.map(\.sampleCount), [42, 21])
        XCTAssertEqual(buckets.map(\.lastTime), [122, 240])
        XCTAssertEqual(buckets.map(\.sourceResolution), [60, 60])
        let first = try XCTUnwrap(buckets.first)
        XCTAssertEqual(first.mean, 580.0 / 42, accuracy: 1e-12)
        XCTAssertNil(ChartStatistics.selection(at: 140, in: buckets, tolerance: 1000))
        XCTAssertEqual(ChartStatistics.summary(buckets)?.sampleCount, 63)
    }

    func testMixedSourcePartialRedrawReadsPredecessorCoverageWithoutItsStatistics() {
        let times: [Double] = [0, 60, 120, 121, 170, 180]
        let values: [Double] = [10, 20, 30, 40, 50, 60]
        let weights: [Double] = [30, 30, 1, 1, 1, 1]
        let durations: [Double] = [60, 60, 0, 0, 0, 0]
        let full = reduce(
            times, values, weights: weights, durations: durations, width: 60, range: 0...239)
        let partial = reduce(
            times, values, weights: weights, durations: durations, width: 60,
            range: 120...180.0.nextDown)
        XCTAssertEqual(partial, full.filter { $0.index == 2 })
        XCTAssertEqual(partial.map(\.gapBefore), [false, true])
        XCTAssertEqual(partial.map(\.sourceResolution), [0, 0])
        XCTAssertEqual(ChartStatistics.summary(partial)?.sampleCount, 3)
        XCTAssertEqual(ChartStatistics.summary(partial)?.mean, 40)
    }

    func testHourCoverageDoesNotLegitimizeAnOutageInTheRawTail() {
        let buckets = reduce(
            [0, 3600, 3660, 3662, 3900], [10, 20, 30, 40, 50],
            durations: [3600, 60, 0, 0, 0], width: 7200, range: 0...7200, gap: 15)
        XCTAssertEqual(buckets.map(\.gapBefore), [false, true])
        XCTAssertEqual(buckets.map(\.lastTime), [3662, 3900])
        XCTAssertEqual(buckets.map(\.sourceResolution), [3600, 0])
        XCTAssertNil(ChartStatistics.selection(at: 3800, in: buckets, tolerance: 3600))
    }

    func testSourceCoarserThanRequestedBinIsKeptWholeAndFlagged() throws {
        let buckets = reduce(
            [0], [50], lows: [10], highs: [90], weights: [30], durations: [60],
            width: 5, range: 0...20)
        XCTAssertEqual(buckets.count, 1, "never fabricate twelve five-second observations")
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.start, 0)
        XCTAssertEqual(bucket.end, 5)
        XCTAssertEqual(bucket.firstTime, 0)
        XCTAssertEqual(bucket.lastTime, 60)
        XCTAssertEqual(bucket.sourceResolution, 60)
        XCTAssertEqual(bucket.sampleCount, 30, "the source row is not prorated to the range")
        XCTAssertEqual(bucket.mean, 50)
        XCTAssertNil(ChartStatistics.selection(at: 10, in: buckets, tolerance: 100))
        XCTAssertTrue(
            reduce(
                [0], [50], weights: [30], durations: [60], width: 5, range: 1...20
            ).isEmpty,
            "overlapping support does not include a source row whose timestamp is outside range")
    }

    func testSparseGPUReadingsRemainMissingWhileCPUHasAllSamples() throws {
        let times = (0..<30).map { Double($0) }
        let cpu = [Double](repeating: 50, count: times.count)
        let gpu = (0..<30).map { [0, 1, 20, 21].contains($0) ? 40.0 : Double.nan }
        let gpuWeights = gpu.map { $0.isFinite ? 1.0 : 0.0 }
        let cpuBuckets = reduce(times, cpu, width: 5)
        let gpuBuckets = reduce(times, gpu, weights: gpuWeights, width: 5)
        XCTAssertEqual(cpuBuckets.count, 6)
        XCTAssertTrue(cpuBuckets.allSatisfy { !$0.gapBefore })
        XCTAssertEqual(gpuBuckets.map(\.index), [0, 4])
        XCTAssertEqual(gpuBuckets.map(\.gapBefore), [false, true])
        let cpuSummary = try XCTUnwrap(ChartStatistics.summary(cpuBuckets))
        let gpuSummary = try XCTUnwrap(ChartStatistics.summary(gpuBuckets))
        XCTAssertEqual(cpuSummary.sampleCount, 30)
        XCTAssertEqual(gpuSummary.sampleCount, 4)
        XCTAssertEqual(gpuSummary.mean, 40, "missing GPU readings are not zero readings")
        XCTAssertNil(ChartStatistics.selection(at: 2, in: gpuBuckets, tolerance: 100))
        XCTAssertNotNil(ChartStatistics.selection(at: 2, in: cpuBuckets, tolerance: 0))
        XCTAssertNil(ChartStatistics.selection(at: 12, in: gpuBuckets, tolerance: 100))
    }

    func testZeroWeightsSkipFiniteRowsButCannotBridgeAnUnmeasuredGap() throws {
        let ordinary = reduce([0, 5, 10], [10, 999, 20], weights: [1, 0, 1], width: 30)
        let bucket = try XCTUnwrap(ordinary.first)
        XCTAssertEqual(ordinary.count, 1)
        XCTAssertEqual(bucket.mean, 15)
        XCTAssertEqual(bucket.sampleCount, 2)
        XCTAssertEqual(bucket.firstTime, 0)
        XCTAssertEqual(bucket.lastTime, 10)
        let gapped = reduce([0, 8, 16], [10, 999, 20], weights: [1, 0, 1], width: 30, gap: 10)
        XCTAssertEqual(gapped.map(\.gapBefore), [false, true])
        let partial = reduce(
            [0, 8, 16], [10, 999, 20], weights: [1, 0, 1], width: 10, range: 10...19, gap: 10)
        XCTAssertEqual(partial.first?.gapBefore, true, "context skips zero-weight rows too")
    }

    func testFractionalWeightsAndCountOverflowNeverInventIntegerCounts() throws {
        let fractional = try XCTUnwrap(reduce([1, 2], [10, 30], weights: [0.5, 1.5]).first)
        XCTAssertEqual(fractional.mean, 25)
        XCTAssertEqual(fractional.weight, 2)
        XCTAssertNil(fractional.sampleCount)
        XCTAssertFalse(fractional.hasUnknownWeight, "the fractional weights themselves are known")
        let large = Double(Int.max / 2)
        let overflow = try XCTUnwrap(reduce([1, 2], [1, 1], weights: [large, large]).first)
        XCTAssertEqual(overflow.mean, 1)
        XCTAssertNil(overflow.sampleCount)
        XCTAssertFalse(overflow.hasUnknownWeight)
    }

    func testScaleAppliesToWeightedMeansAndSwapsExtremaForNegativeFactors() throws {
        let positive = try XCTUnwrap(
            reduce(
                [1, 2], [0.1, 0.3], lows: [0.05, 0.2], highs: [0.2, 0.6],
                weights: [1, 3], scale: 100
            ).first)
        XCTAssertEqual(positive.mean, 25, accuracy: 1e-12)
        XCTAssertEqual(positive.minimum, 5)
        XCTAssertEqual(positive.maximum, 60)
        XCTAssertEqual(positive.sampleCount, 4)
        let negative = try XCTUnwrap(
            reduce(
                [1, 2], [0.1, 0.3], lows: [0.05, 0.2], highs: [0.2, 0.6],
                weights: [1, 3], scale: -100
            ).first)
        XCTAssertEqual(negative.mean, -25, accuracy: 1e-12)
        XCTAssertEqual(negative.minimum, -60)
        XCTAssertEqual(negative.maximum, -5)
        let unknown = try XCTUnwrap(
            reduce(
                [1], [10], lows: [.nan], highs: [20], scale: -2
            ).first)
        XCTAssertEqual(unknown.minimum, -40)
        XCTAssertNil(unknown.maximum)
        let zero = reduce([1, 2, 3], [10, .nan, 30], lows: [.nan, .nan, 20], scale: 0)
        XCTAssertEqual(zero.map(\.mean), [0, 0])
        XCTAssertEqual(zero.map(\.gapBefore), [false, true])
        XCTAssertNil(zero.first?.minimum, "zero scaling does not invent missing metadata")
    }

    func testIsolatedSpikeRemainsTheTrueMaximumNotAPercentile() throws {
        let times = (0..<100).map { Double($0) }
        var values = [Double](repeating: 0, count: 100)
        values[50] = 100
        let bucket = try XCTUnwrap(reduce(times, values, width: 100).first)
        XCTAssertEqual(bucket.mean, 1)
        XCTAssertEqual(bucket.minimum, 0)
        XCTAssertEqual(bucket.maximum, 100)
        XCTAssertEqual(bucket.sampleCount, 100)
    }

    func testEmptyMissingAndOutOfRangeInputsHaveNoStatistics() {
        XCTAssertTrue(reduce([], []).isEmpty)
        XCTAssertTrue(reduce([1, 2], [.nan, .infinity]).isEmpty)
        XCTAssertTrue(reduce([1, 2], [10, 20], weights: [0, 0]).isEmpty)
        XCTAssertTrue(reduce([1, 2], [10, 20], range: 50...60).isEmpty)
        XCTAssertNil(ChartStatistics.summary([]))
        XCTAssertNil(ChartStatistics.selection(at: 1, in: [], tolerance: 100))
    }

    func testInvalidScalarArgumentsAndColumnLengthsReturnNoBuckets() {
        for width in [0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertTrue(reduce([1], [10], width: width).isEmpty)
        }
        for gap in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertTrue(reduce([1], [10], gap: gap).isEmpty)
        }
        for scale in [Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(reduce([1], [10], scale: scale).isEmpty)
        }
        XCTAssertTrue(reduce([1], [10], range: -Double.infinity...10).isEmpty)
        XCTAssertTrue(reduce([1], [10], range: 0...Double.infinity).isEmpty)
        XCTAssertTrue(reduce([1, 2], [10]).isEmpty)
        XCTAssertTrue(reduce([1], [10], lows: []).isEmpty)
        XCTAssertTrue(reduce([1], [10], highs: []).isEmpty)
        XCTAssertTrue(reduce([1], [10], weights: []).isEmpty)
        XCTAssertTrue(reduce([1], [10], durations: []).isEmpty)
    }

    func testInvalidInspectedTimesMetadataAndArithmeticDoNotTrap() {
        for time in [Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(reduce([time], [10]).isEmpty)
        }
        XCTAssertTrue(reduce([1, 3, 2, 4], [10, 20, 30, 40]).isEmpty)
        for duration in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertTrue(reduce([1], [10], durations: [duration]).isEmpty)
        }
        for weight in [-1.0, .infinity, -.infinity] {
            XCTAssertTrue(reduce([1], [10], weights: [weight]).isEmpty)
        }
        XCTAssertTrue(reduce([1], [10], width: Double.leastNonzeroMagnitude).isEmpty)
        let large = Double.greatestFiniteMagnitude
        XCTAssertTrue(reduce([1], [large], scale: 2).isEmpty)
        XCTAssertTrue(reduce([1], [large], weights: [2]).isEmpty)
        XCTAssertTrue(reduce([1, 2], [large, large]).isEmpty)
        XCTAssertTrue(reduce([1, 2], [0, 0], weights: [large, large]).isEmpty)
        let separate = reduce([1, 11], [large, large])
        XCTAssertEqual(separate.count, 2)
        XCTAssertNil(
            ChartStatistics.summary(separate), "overflow must not produce an infinite mean")
    }

    func testNonfiniteExtremaAreUnknownRatherThanNonfiniteOutput() throws {
        let bucket = try XCTUnwrap(
            reduce(
                [1, 2], [10, 20], lows: [-.infinity, 10], highs: [20, .infinity]
            ).first)
        XCTAssertNil(bucket.minimum)
        XCTAssertNil(bucket.maximum)
        XCTAssertTrue(bucket.mean.isFinite)
    }

    func testInvalidSelectionArgumentsReturnNil() {
        let buckets = reduce([1], [10])
        for time in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(ChartStatistics.selection(at: time, in: buckets, tolerance: 1))
        }
        for tolerance in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertNil(ChartStatistics.selection(at: 1, in: buckets, tolerance: tolerance))
        }
    }
}
