import MacPerfMonitorCore
import SwiftUI

struct DiskChart: View {
    let read: LiveColumn
    let write: LiveColumn
    var xDomain: ClosedRange<Date>? = nil
    var yDomain: ClosedRange<Double>? = nil
    var showsTimeAxis = false

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
            yDomain: yDomain,
            yFormat: { ByteFormat.rate(max($0, 0)) },
            showsTimeAxis: showsTimeAxis,
            leftGutter: 56
        )
        .accessibilityLabel("Physical disk throughput trend")
        .accessibilityValue(accessibilitySummary)
    }
}
