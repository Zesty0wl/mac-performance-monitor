import MacPerfMonitorCore
import SwiftUI

struct DiskChart: View {
    let read: LiveColumn
    let write: LiveColumn
    var xDomain: ClosedRange<Date>? = nil
    var yDomain: ClosedRange<Double>? = nil
    var showsTimeAxis = false

    /// Pixel columns in the plot, which is how many buckets the line is
    /// averaged into; the axis is fitted to that same line.
    @State private var plotColumns = LiveTrend.buckets

    /// Matches the `leftGutter` passed to `TrendChart` below.
    private static let leftGutter: CGFloat = 56

    init(
        points: [SystemHistoryPoint], xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil, showsTimeAxis: Bool = false
    ) {
        self.init(
            read: LiveColumn(
                points, value: { $0.diskReadBytesPerSec },
                high: { $0.effectivePeaks.diskReadBytesPerSec }),
            write: LiveColumn(
                points, value: { $0.diskWriteBytesPerSec },
                high: { $0.effectivePeaks.diskWriteBytesPerSec }),
            xDomain: xDomain, yDomain: yDomain, showsTimeAxis: showsTimeAxis)
    }

    /// The live Dashboard path: zero-copy columns of the window.
    init(
        window: SystemHistoryWindow, xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil, showsTimeAxis: Bool = false
    ) {
        self.init(
            read: LiveColumn(window, .diskReadBytesPerSec, peak: .diskReadPeak),
            write: LiveColumn(window, .diskWriteBytesPerSec, peak: .diskWritePeak),
            xDomain: xDomain, yDomain: yDomain, showsTimeAxis: showsTimeAxis)
    }

    private init(
        read: LiveColumn, write: LiveColumn, xDomain: ClosedRange<Date>?,
        yDomain: ClosedRange<Double>?, showsTimeAxis: Bool
    ) {
        self.read = read
        self.write = write
        self.xDomain = xDomain
        self.yDomain = yDomain
        self.showsTimeAxis = showsTimeAxis
    }

    private var accessibilitySummary: String {
        guard let latestRead = read.lastValue, let latestWrite = write.lastValue else {
            return t("No data yet.")
        }
        let peak = max(read.range?.max ?? 0, write.range?.max ?? 0)
        if peak < 1 { return t("No physical disk activity over the shown window.") }
        return t(
            "Currently %1$@ read, %2$@ write. Peak %3$@ over the shown window.",
            ByteFormat.rate(latestRead), ByteFormat.rate(latestWrite), ByteFormat.rate(peak))
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: LiveTrend.allPoints(read), color: DiskStyle.read),
                TrendSeries(
                    points: LiveTrend.allPoints(write), color: DiskStyle.write, lineWidth: 1.8),
            ],
            xDomain: xDomain,
            yDomain: yDomain
                ?? Self.fittedDomain([read, write], xDomain: xDomain, columns: plotColumns),
            yFormat: Self.axisLabel,
            showsTimeAxis: showsTimeAxis,
            leftGutter: Self.leftGutter
        )
        .onGeometryChange(for: Int.self) {
            max(1, Int(($0.size.width - Self.leftGutter).rounded(.up)))
        } action: {
            plotColumns = $0
        }
        .accessibilityLabel("Physical disk throughput trend")
        .accessibilityValue(accessibilitySummary)
    }

    /// A gridline label: "300 MB/s" for a round step, "1.5 GB/s" otherwise.
    static func axisLabel(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        var scaled = value
        while scaled >= 1024 { scaled /= 1024 }
        let whole = abs(scaled - scaled.rounded()) < 0.05
        return ByteFormat.rate(value, fractionDigits: whole ? 0 : 1)
    }

    /// The smallest axis top, so a disk ticking over at a few KB/s draws a
    /// quiet floor rather than a mountain range of noise (chart rule 5).
    static let minimumTop: Double = 1024 * 1024

    /// Zero up to a round binary step above the solid line: the tallest point
    /// of the line `TrendRenderer.drawSeries` draws inside the window (each
    /// column's mean, then the same trailing average). A copy sustained at
    /// 85 MB/s with a few one-second bursts to 350 MB/s fills the plot, and
    /// the bursts show in the soft band behind the line, running off the top,
    /// as they do on the other live charts. Sizing the axis to the tallest
    /// single sample left that copy in the bottom fifth.
    static func fittedDomain(
        _ columns: [LiveColumn], xDomain: ClosedRange<Date>?, columns plotColumns: Int
    ) -> ClosedRange<Double> {
        var peak = 0.0
        for column in columns {
            guard let first = column.times.first, let last = column.times.last else { continue }
            let lo = xDomain?.lowerBound.timeIntervalSinceReferenceDate ?? first
            let hi = xDomain?.upperBound.timeIntervalSinceReferenceDate ?? last
            guard hi > lo else {
                peak = max(peak, column.values.last ?? 0)
                continue
            }
            let span = hi - lo
            let width = span / Double(max(1, plotColumns))
            let buckets = LiveStripBuckets.buckets(
                times: column.times, values: column.values, width: width,
                from: LiveStripBuckets.index(of: lo, width: width),
                through: LiveStripBuckets.index(of: hi, width: width),
                gapThreshold: ChartGap.threshold(
                    expectedSpacing: ChartGap.expectedSpacing(times: column.times)))
            let line = TrendRenderer.smoothed(
                buckets, seconds: TrendRenderer.smoothingSeconds(span: span), width: width,
                value: \.mean)
            for value in line where value.isFinite { peak = max(peak, value) }
        }
        return 0...max(LiveChartGeometry.binaryNiceCeiling(peak * 1.1), minimumTop)
    }
}
