import MacPerfMonitorCore
import SwiftUI

struct DiskChart: View {
    let points: [SystemHistoryPoint]
    var showsTimeAxis = false

    private var accessibilitySummary: String {
        guard let latest = points.last else { return "No data yet." }
        let peak = points.map { max($0.diskReadBytesPerSec, $0.diskWriteBytesPerSec) }.max() ?? 0
        if peak < 1 { return "No physical disk activity over the shown window." }
        return
            "Currently \(ByteFormat.rate(latest.diskReadBytesPerSec)) read, "
            + "\(ByteFormat.rate(latest.diskWriteBytesPerSec)) write. "
            + "Peak \(ByteFormat.rate(peak)) over the shown window."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: points.map {
                        TrendPoint(date: $0.date, value: $0.diskReadBytesPerSec)
                    },
                    color: DiskStyle.read, filled: true),
                TrendSeries(
                    points: points.map {
                        TrendPoint(date: $0.date, value: $0.diskWriteBytesPerSec)
                    },
                    color: DiskStyle.write, filled: false, lineWidth: 1.8),
            ],
            yFormat: { ByteFormat.rate(max($0, 0)) },
            showsTimeAxis: showsTimeAxis
        )
        .accessibilityLabel("Physical disk throughput trend")
        .accessibilityValue(accessibilitySummary)
    }
}
