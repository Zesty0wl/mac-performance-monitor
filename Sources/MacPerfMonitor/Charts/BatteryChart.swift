import Charts
import MacPerfMonitorCore
import SwiftUI

/// The battery charge timeline: a 0–100% area chart, with the "low" (20%) and
/// "full" (80%) bands marked, tinted by the current `BatteryLevel`. A direct
/// sibling of `CPUChart`/`PressureChart` so the dashboards read the same way.
/// Plots `SystemHistoryPoint.batteryCharge`; the line's slope already shows
/// whether the battery was charging or discharging.
struct BatteryChart: View {
    let points: [SystemHistoryPoint]
    let currentLevel: BatteryLevel
    var xDomain: ClosedRange<Date>? = nil

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
        Chart {
            RuleMark(y: .value("Low", 20))
                .foregroundStyle(.red.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("Low").font(.caption2).foregroundStyle(.red)
                }
            RuleMark(y: .value("Full", 80))
                .foregroundStyle(.green.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("80%").font(.caption2).foregroundStyle(.green)
                }

            ForEach(Array(points.splitIntoSegments().enumerated()), id: \.offset) {
                segIdx, segment in
                ForEach(segment) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("Charge", point.batteryCharge),
                        series: .value("Segment", segIdx)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [
                                currentLevel.color.opacity(0.45), currentLevel.color.opacity(0.04),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Charge", point.batteryCharge),
                        series: .value("Segment", segIdx)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(currentLevel.color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartXScale(domain: resolvedXDomain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 20, 50, 80, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)") }
                }
            }
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Battery charge timeline")
        .accessibilityValue(accessibilitySummary)
        .reducedMotionAware()
    }

    private var resolvedXDomain: ClosedRange<Date> {
        if let xDomain { return xDomain }
        let first = points.first?.date ?? .distantPast
        let last = points.last?.date ?? first.addingTimeInterval(1)
        return first < last ? first...last : first.addingTimeInterval(-1)...last
    }
}
