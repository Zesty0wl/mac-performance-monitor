// SPDX-License-Identifier: MIT
import XCTest

@testable import MacPerfMonitor
@testable import MacPerfMonitorCore

/// The Disk page's throughput axis fits the average line, so a steady copy
/// fills the plot and the brief bursts run off the top in the soft band.
@MainActor
final class DiskChartScaleTests: XCTestCase {
    private let mb = 1024.0 * 1024

    /// An hour at the sampler's 1.7 s spacing: a steady write, with a
    /// one-sample burst every 20 samples (about every half minute).
    private func copyHour(steady: Double, burst: Double) -> [SystemHistoryPoint] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Typed and split up: as one expression, the macOS 15 toolchain gives
        // up type-checking it.
        return (0..<2118).map { (i: Int) -> SystemHistoryPoint in
            let date: Date = start.addingTimeInterval(Double(i) * 1.7)
            let read: Double = i % 400 == 200 ? burst : 0.2 * mb
            let write: Double = i % 20 == 10 ? burst : steady
            return SystemHistoryPoint(
                date: date, pressurePercent: 0, appMemory: 0, wired: 0, compressed: 0,
                cachedFiles: 0, swapUsed: 0, diskReadBytesPerSec: read,
                diskWriteBytesPerSec: write)
        }
    }

    private func domain(_ points: [SystemHistoryPoint]) -> ClosedRange<Double> {
        let chart = DiskChart(points: points)
        let domain = (points.first!.date)...(points.last!.date)
        return DiskChart.fittedDomain([chart.read, chart.write], xDomain: domain, columns: 900)
    }

    func testSteadyCopyFillsThePlotDespiteBursts() {
        let fitted = domain(copyHour(steady: 85 * mb, burst: 380 * mb))
        // Sized to the tallest sample this was 400 MB/s, leaving the copy in
        // the bottom fifth; fitted to the line the copy fills most of it.
        XCTAssertLessThanOrEqual(fitted.upperBound, 160 * mb)
        XCTAssertGreaterThan(fitted.upperBound, 85 * mb * 1.1)
    }

    func testOnlyTheVisibleWindowCounts() {
        var points = copyHour(steady: 5 * mb, burst: 5 * mb)
        let chart = DiskChart(points: points)
        let late = points[1000].date...points.last!.date
        points[10].diskWriteBytesPerSec = 900 * mb
        let busy = DiskChart(points: points)
        XCTAssertEqual(
            DiskChart.fittedDomain([busy.read, busy.write], xDomain: late, columns: 900),
            DiskChart.fittedDomain([chart.read, chart.write], xDomain: late, columns: 900))
    }

    func testIdleDiskKeepsAFloor() {
        XCTAssertEqual(domain(copyHour(steady: 2048, burst: 4096)).upperBound, mb)
    }

    func testAxisLabelsDropTheDecimalOnRoundSteps() {
        XCTAssertEqual(DiskChart.axisLabel(300 * mb), ByteFormat.rate(300 * mb, fractionDigits: 0))
        XCTAssertEqual(DiskChart.axisLabel(1.5 * 1024 * mb), ByteFormat.rate(1.5 * 1024 * mb))
    }
}
