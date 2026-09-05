import MacPerfMonitorCore
import SwiftUI

/// Shared colors for the thermal surfaces, so the Energy tab and the menu bar
/// panel tell the same story.
enum ThermalStyle {
    static let cpu = Color.orange
    static let gpu = Color.red
    static let fan = Color.teal
}

extension ThermalPressureState {
    /// Display tint keyed to macOS's verdict, never to a degree threshold: a
    /// hot number in green is a Mac working as designed; an orange or red one
    /// is macOS actually slowing work down.
    var color: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }
}

/// CPU and GPU die temperature over the selected window. The thermal fields
/// are optional (nil marks a tick that did not read the SMC), so each series
/// carries only the points that have a value: the chart's gap splitting
/// leaves unsampled stretches blank instead of drawing a misleading 0 degree
/// floor. The line follows each bucket's maximum, never a mean, because a
/// thermal spike is the event worth seeing, and the band behind it shows how
/// far the readings ranged below that (docs/chart-rules.md, rule 2). On the
/// stored ranges the rows already carry the bucket maximum.
struct TemperatureChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false

    private var cpuPoints: [TrendPoint] {
        points.compactMap { p in p.cpuDieC.map { TrendPoint(date: p.date, value: $0) } }
    }

    private var gpuPoints: [TrendPoint] {
        points.compactMap { p in p.gpuDieC.map { TrendPoint(date: p.date, value: $0) } }
    }

    /// The spacing of one drawn point, taken from the range being shown rather
    /// than from the data (which would move with every sample). It sizes the
    /// gap threshold: on the stored ranges a row a minute or an hour apart is
    /// still one series.
    private var pointSpacing: Double {
        guard let xDomain else { return 0 }
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        return span > 0 ? span / 120 : 0
    }

    private var accessibilitySummary: String {
        guard let cpu = cpuPoints.last else {
            return t("No temperature samples in the shown window.")
        }
        let peak = cpuPoints.map(\.value).max() ?? cpu.value
        let cpuValue = String(format: "%.0f", cpu.value)
        let peakValue = String(format: "%.0f", peak)
        if let gpu = gpuPoints.last {
            return t(
                "Latest CPU die %1$@ degrees, GPU die %2$@ degrees, window peak %3$@ degrees.",
                cpuValue, String(format: "%.0f", gpu.value), peakValue)
        }
        return t("Latest CPU die %1$@ degrees, window peak %2$@ degrees.", cpuValue, peakValue)
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: cpuPoints, color: ThermalStyle.cpu, reduction: .maximum),
                TrendSeries(
                    points: gpuPoints, color: ThermalStyle.gpu, lineWidth: 1.8,
                    reduction: .maximum),
            ],
            xDomain: xDomain,
            yDomain: temperatureDomain,
            yFormat: { String(format: "%.0f°C", $0) },
            showsTimeAxis: showsTimeAxis,
            gapThreshold: ChartGap.threshold(
                expectedSpacing: max(pointSpacing, SamplerModel.configuredHighResInterval()))
        )
        .accessibilityLabel("Die temperature trend")
        .accessibilityValue(accessibilitySummary)
    }

    /// Fit the readings rather than pinning the axis to a fixed 20 degrees and a
    /// rounded-up peak. That was safe but spent most of the plot on temperatures
    /// a die never reaches: sensors sitting between 60 and 90 drew a flat ribbon
    /// through the middle. The 30 degree minimum span is what stops the opposite
    /// problem, a degree of idle noise filling the chart.
    private var temperatureDomain: ClosedRange<Double>? {
        let values = cpuPoints.map(\.value) + gpuPoints.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return ChartDomain.fitted(min: lo, max: hi, minimumSpan: 30, padding: 5, floor: 0)
    }
}

/// Fan speed over the selected window, gap-aware like the temperature chart.
/// Fanless Macs simply never produce points, and the panel hides this chart.
struct FanChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false

    private var fanPoints: [TrendPoint] {
        points.compactMap { point in
            point.fanRPM.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var accessibilitySummary: String {
        guard let latest = fanPoints.last else {
            return t("No fan samples in the shown window.")
        }
        if latest.value == 0 { return t("Fans currently off.") }
        return t("Fans currently %@ rpm.", String(format: "%.0f", latest.value))
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: fanPoints, color: ThermalStyle.fan, reduction: .maximum)
            ],
            xDomain: xDomain,
            yFormat: { t("%@ rpm", String(format: "%.0f", max($0, 0))) },
            showsTimeAxis: showsTimeAxis,
            leftGutter: 56
        )
        .accessibilityLabel("Fan speed trend")
        .accessibilityValue(accessibilitySummary)
    }
}
