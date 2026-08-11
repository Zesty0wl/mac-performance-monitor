import MacPerfMonitorCore
import SwiftUI

/// A compact network-throughput trend: download as a filled teal band, upload as
/// an orange line over it. Bytes-per-second on the Y axis, in human rate units.
/// Drawn with the lightweight Canvas `TrendChart`.
struct NetworkChart: View {
    let points: [SystemHistoryPoint]
    var showsTimeAxis: Bool = false

    private var accessibilitySummary: String {
        guard let latest = points.last else { return "No data yet." }
        let peak =
            points.map {
                Swift.max($0.networkInBytesPerSec, $0.networkOutBytesPerSec)
            }.max() ?? 0
        if peak < 1 { return "No network traffic over the shown window." }
        return
            "Currently \(ByteFormat.rate(latest.networkInBytesPerSec)) down, "
            + "\(ByteFormat.rate(latest.networkOutBytesPerSec)) up. "
            + "Peak \(ByteFormat.rate(peak)) over the shown window."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: points.map {
                        TrendPoint(date: $0.date, value: $0.networkInBytesPerSec)
                    },
                    color: NetworkStyle.download, filled: true),
                TrendSeries(
                    points: points.map {
                        TrendPoint(date: $0.date, value: $0.networkOutBytesPerSec)
                    },
                    color: NetworkStyle.upload, filled: false, lineWidth: 1.8),
            ],
            yFormat: { ByteFormat.rate(max($0, 0)) },
            showsTimeAxis: showsTimeAxis,
            leftGutter: 56
        )
        .accessibilityLabel("Network throughput trend")
        .accessibilityValue(accessibilitySummary)
    }
}
