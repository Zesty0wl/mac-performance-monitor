import MacPerfMonitorCore
import SwiftUI

/// The hero pressure-index timeline: a 0–100 area chart with the warning and
/// critical bands marked, tinted by the current pressure level. Drawn with the
/// lightweight Canvas `TrendChart` rather than Swift Charts.
struct PressureChart: View {
    let pressure: LiveColumn
    let currentLevel: PressureLevel
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis: Bool = false

    init(
        points: [SystemHistoryPoint], currentLevel: PressureLevel,
        xDomain: ClosedRange<Date>? = nil, showsTimeAxis: Bool = false
    ) {
        self.init(
            pressure: LiveColumn(points) { $0.pressurePercent }, currentLevel: currentLevel,
            xDomain: xDomain, showsTimeAxis: showsTimeAxis)
    }

    /// The live Dashboard path: a zero-copy column of the window.
    init(
        window: SystemHistoryWindow, currentLevel: PressureLevel,
        xDomain: ClosedRange<Date>? = nil, showsTimeAxis: Bool = false
    ) {
        self.init(
            pressure: LiveColumn(window, .pressurePercent), currentLevel: currentLevel,
            xDomain: xDomain, showsTimeAxis: showsTimeAxis)
    }

    private init(
        pressure: LiveColumn, currentLevel: PressureLevel, xDomain: ClosedRange<Date>?,
        showsTimeAxis: Bool
    ) {
        self.pressure = pressure
        self.currentLevel = currentLevel
        self.xDomain = xDomain
        self.showsTimeAxis = showsTimeAxis
    }

    private var accessibilitySummary: String {
        guard let latest = pressure.lastValue else { return t("No data yet.") }
        let range = pressure.range ?? (latest, latest)
        let lo = Int(range.min.rounded())
        let hi = Int(range.max.rounded())
        return t(
            "Currently %1$@ at %2$@ percent. Window range %3$@ to %4$@ percent.",
            currentLevel.label.lowercased(), String(Int(latest.rounded())), String(lo), String(hi))
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: LiveTrend.points(pressure, xDomain: xDomain),
                    color: currentLevel.color, filled: true)
            ],
            xDomain: xDomain,
            yDomain: 0...100,
            yTicks: [0, 34, 67, 100],
            rules: [
                TrendRule(value: 34, label: "Warning", color: .orange),
                TrendRule(value: 67, label: "Critical", color: .red),
            ],
            showsTimeAxis: showsTimeAxis
        )
        .accessibilityLabel("Memory pressure timeline")
        .accessibilityValue(accessibilitySummary)
    }
}
