import MacPerfMonitorCore
import SwiftUI

struct DiskIOPSChart: View {
    let points: [SystemHistoryPoint]
    var showsTimeAxis = false

    private var accessibilitySummary: String {
        guard let latest = points.last else { return "No data yet." }
        let peak =
            points.map {
                max($0.diskReadOperationsPerSec, $0.diskWriteOperationsPerSec)
            }.max() ?? 0
        return
            "Currently \(Int(latest.diskReadOperationsPerSec)) read and "
            + "\(Int(latest.diskWriteOperationsPerSec)) write operations per second. "
            + "Peak \(Int(peak)) over the shown window."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: points.map {
                        TrendPoint(date: $0.date, value: $0.diskReadOperationsPerSec)
                    },
                    color: DiskStyle.read, filled: true),
                TrendSeries(
                    points: points.map {
                        TrendPoint(date: $0.date, value: $0.diskWriteOperationsPerSec)
                    },
                    color: DiskStyle.write, filled: false, lineWidth: 1.8),
            ],
            yFormat: { "\(Int(max($0, 0)))" },
            showsTimeAxis: showsTimeAxis
        )
        .accessibilityLabel("Disk operations per second trend")
        .accessibilityValue(accessibilitySummary)
    }
}
