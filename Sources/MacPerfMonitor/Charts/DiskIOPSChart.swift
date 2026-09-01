import MacPerfMonitorCore
import SwiftUI

struct DiskIOPSChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false

    private var accessibilitySummary: String {
        guard let latest = points.last else { return t("No data yet.") }
        let peak =
            points.map {
                max($0.diskReadOperationsPerSec, $0.diskWriteOperationsPerSec)
            }.max() ?? 0
        return t(
            "Currently %1$@ read and %2$@ write operations per second. Peak %3$@ over the shown window.",
            String(Int(latest.diskReadOperationsPerSec)),
            String(Int(latest.diskWriteOperationsPerSec)), String(Int(peak)))
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
            xDomain: xDomain,
            yFormat: { "\(Int(max($0, 0)))" },
            showsTimeAxis: showsTimeAxis
        )
        .accessibilityLabel("Disk operations per second trend")
        .accessibilityValue(accessibilitySummary)
    }
}
