import MacPerfMonitorCore
import SwiftUI

/// A compact swap-usage trend. Bytes on the Y axis, formatted in human units.
/// Drawn with the lightweight Canvas `TrendChart`.
struct SwapChart: View {
    let swap: LiveColumn
    var xDomain: ClosedRange<Date>? = nil
    var yDomain: ClosedRange<Double>? = nil

    init(
        points: [SystemHistoryPoint], xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil
    ) {
        self.init(
            swap: LiveColumn(points) { Double($0.swapUsed) }, xDomain: xDomain, yDomain: yDomain)
    }

    init(
        window: SystemHistoryWindow, xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil
    ) {
        self.init(swap: LiveColumn(window, .swapUsed), xDomain: xDomain, yDomain: yDomain)
    }

    private init(swap: LiveColumn, xDomain: ClosedRange<Date>?, yDomain: ClosedRange<Double>?) {
        self.swap = swap
        self.xDomain = xDomain
        self.yDomain = yDomain
    }

    private var accessibilitySummary: String {
        guard let latest = swap.lastValue else { return t("No data yet.") }
        let peak = UInt64(max(swap.range?.max ?? latest, 0))
        if peak == 0 { return t("No swap in use over the shown window.") }
        return t(
            "Currently %1$@. Peak %2$@ over the shown window.",
            ByteFormat.string(UInt64(max(latest, 0))), ByteFormat.string(peak))
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: LiveTrend.points(swap, xDomain: xDomain),
                    color: .indigo, filled: true)
            ],
            xDomain: xDomain,
            yDomain: yDomain,
            yFormat: { ByteFormat.string(UInt64(max($0, 0))) }
        )
        .accessibilityLabel("Swap usage trend")
        .accessibilityValue(accessibilitySummary)
    }
}
