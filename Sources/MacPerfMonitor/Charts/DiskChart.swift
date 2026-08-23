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
            read: LiveColumn(points) { $0.diskReadBytesPerSec },
            write: LiveColumn(points) { $0.diskWriteBytesPerSec },
            xDomain: xDomain, yDomain: yDomain, showsTimeAxis: showsTimeAxis)
    }

    /// The live Dashboard path: zero-copy columns of the window.
    init(
        window: SystemHistoryWindow, xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil, showsTimeAxis: Bool = false
    ) {
        self.init(
            read: LiveColumn(window, .diskReadBytesPerSec),
            write: LiveColumn(window, .diskWriteBytesPerSec),
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
            return "No data yet."
        }
        let peak = max(read.range?.max ?? 0, write.range?.max ?? 0)
        if peak < 1 { return "No physical disk activity over the shown window." }
        return
            "Currently \(ByteFormat.rate(latestRead)) read, \(ByteFormat.rate(latestWrite)) write. "
            + "Peak \(ByteFormat.rate(peak)) over the shown window."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: LiveTrend.points(read, xDomain: xDomain),
                    color: DiskStyle.read, filled: true),
                TrendSeries(
                    points: LiveTrend.points(write, xDomain: xDomain),
                    color: DiskStyle.write, filled: false, lineWidth: 1.8),
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
