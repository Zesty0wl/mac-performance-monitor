import MacPerfMonitorCore
import SwiftUI

/// The battery charge timeline: a 0 to 100 percent area chart with the "low"
/// (20 percent) and "full" (80 percent) marks, tinted by the current
/// `BatteryLevel`. A direct sibling of `CPUChart` and `PressureChart`, drawn
/// with the same `TrendChart` so it follows the chart rules with the rest of
/// the app. Plots `SystemHistoryPoint.batteryCharge`; the line's slope already
/// shows whether the battery was charging or discharging. Charge is a calm,
/// slow series, so it keeps its fill (docs/chart-rules.md, rule 9).
struct BatteryChart: View {
    let points: [SystemHistoryPoint]
    let currentLevel: BatteryLevel
    var xDomain: ClosedRange<Date>? = nil

    private var chargePoints: [TrendPoint] {
        points.map { TrendPoint(date: $0.date, value: $0.batteryCharge) }
    }

    private var accessibilitySummary: String {
        guard let latest = points.last?.batteryCharge else { return t("No data yet.") }
        let values = points.map(\.batteryCharge)
        let lo = Int((values.min() ?? latest).rounded())
        let hi = Int((values.max() ?? latest).rounded())
        return t(
            "Currently %1$@ percent. Window range %2$@ to %3$@ percent.",
            String(Int(latest.rounded())), String(lo), String(hi))
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: chargePoints, color: currentLevel.color, filled: true)
            ],
            xDomain: xDomain,
            yDomain: 0...100,
            yTicks: [0, 20, 50, 80, 100],
            rules: [
                TrendRule(value: 20, label: "Low", color: .red),
                TrendRule(value: 80, label: "80%", color: .green),
            ],
            showsTimeAxis: true
        )
        .accessibilityLabel("Battery charge timeline")
        .accessibilityValue(accessibilitySummary)
    }
}
