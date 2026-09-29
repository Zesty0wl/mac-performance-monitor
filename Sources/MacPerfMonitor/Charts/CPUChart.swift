import MacPerfMonitorCore
import SwiftUI

/// The total-CPU timeline: a 0–100% area chart of system CPU across all cores,
/// with the "busy" (60%) and "heavy" (85%) bands marked, tinted by the current
/// `CPULevel`. Drawn with the lightweight Canvas `TrendChart`. Plots
/// `SystemHistoryPoint.cpuLoad` (a 0...1 fraction) as a percentage.
struct CPUChart: View {
    /// CPU as a 0...100 percentage.
    let cpu: LiveColumn
    let currentLevel: CPULevel
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis: Bool = false

    init(
        points: [SystemHistoryPoint], currentLevel: CPULevel, xDomain: ClosedRange<Date>? = nil,
        showsTimeAxis: Bool = false
    ) {
        self.init(
            cpu: LiveColumn(points) { $0.cpuLoad * 100 }, currentLevel: currentLevel,
            xDomain: xDomain, showsTimeAxis: showsTimeAxis)
    }

    /// The live Dashboard path: a zero-copy column of the window, as a 0...1
    /// fraction (the chart scales it to a percentage).
    init(
        window: SystemHistoryWindow, currentLevel: CPULevel, xDomain: ClosedRange<Date>? = nil,
        showsTimeAxis: Bool = false
    ) {
        self.init(
            cpu: LiveColumn(window, .cpuLoad), currentLevel: currentLevel, xDomain: xDomain,
            showsTimeAxis: showsTimeAxis, scale: 100)
    }

    private init(
        cpu: LiveColumn, currentLevel: CPULevel, xDomain: ClosedRange<Date>?,
        showsTimeAxis: Bool, scale: Double = 1
    ) {
        self.cpu = cpu
        self.currentLevel = currentLevel
        self.xDomain = xDomain
        self.showsTimeAxis = showsTimeAxis
        self.scale = scale
    }

    /// Multiplier applied to the column's values before plotting.
    private let scale: Double

    private var accessibilitySummary: String {
        guard let latest = cpu.lastValue else { return t("No data yet.") }
        let range = cpu.range ?? (latest, latest)
        let lo = Int((range.min * scale).rounded())
        let hi = Int((range.max * scale).rounded())
        return t(
            "Currently %1$@ percent. Window range %2$@ to %3$@ percent.",
            String(Int((latest * scale).rounded())), String(lo), String(hi))
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: LiveTrend.allPoints(cpu).map {
                        scale == 1
                            ? $0
                            : TrendPoint(
                                date: $0.date, value: $0.value * scale,
                                high: $0.high.map { $0 * scale })
                    },
                    color: currentLevel.color)
            ],
            xDomain: xDomain,
            yDomain: 0...100,
            yTicks: [0, 60, 85, 100],
            rules: [
                TrendRule(value: 60, label: "Busy", color: .orange),
                TrendRule(value: 85, label: "Heavy", color: .red),
            ],
            showsTimeAxis: showsTimeAxis
        )
        .accessibilityLabel("Total CPU timeline")
        .accessibilityValue(accessibilitySummary)
    }
}
