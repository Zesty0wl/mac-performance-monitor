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

    static func statisticsModel(
        points: [SystemHistoryPoint], xDomain: ClosedRange<Date>?
    ) -> TrendModel {
        func column(
            reading: (SystemHistoryPoint) -> Double?, average: (SystemHistoryPoint) -> Double?,
            minimum: (SystemHistoryPoint) -> Double?, count: (SystemHistoryPoint) -> Int?
        ) -> LiveColumn {
            LiveColumn(
                times: points.map { $0.date.timeIntervalSinceReferenceDate }[...],
                values: points.map { point in
                    (point.bucketDuration > 0 ? average(point) : reading(point)) ?? .nan
                }[...],
                highs: points.map { reading($0) ?? .nan }[...],
                lows: points.map { point in
                    (point.bucketDuration > 0 ? minimum(point) : reading(point)) ?? .nan
                }[...],
                weights: points.map { point in
                    if point.bucketDuration == 0 { return reading(point) == nil ? 0 : 1 }
                    return count(point).map(Double.init) ?? .nan
                }[...],
                durations: points.map(\.bucketDuration)[...])
        }
        let cpu = column(
            reading: { $0.cpuDieC }, average: { $0.cpuDieAverageC },
            minimum: { $0.minima?.cpuDieC }, count: { $0.cpuDieSampleCount })
        let gpu = column(
            reading: { $0.gpuDieC }, average: { $0.gpuDieAverageC },
            minimum: { $0.minima?.gpuDieC }, count: { $0.gpuDieSampleCount })
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(column: cpu, color: ThermalStyle.cpu, name: t("CPU die")),
            TrendSurfaceSeries(column: gpu, color: ThermalStyle.gpu, name: t("GPU die")),
        ]
        model.xDomain = xDomain
        let source = points.map(\.bucketDuration).max() ?? 0
        let span = xDomain.map { $0.upperBound.timeIntervalSince($0.lowerBound) } ?? 300
        model.statisticsInterval = ChartStatistics.interval(span: span, minimum: source)
        model.gapThreshold = ChartGap.threshold(
            expectedSpacing: max(5, SamplerModel.configuredHighResInterval()))
        let bounds = [cpu, gpu].flatMap { column in
            Array(column.values) + Array(column.highs ?? []) + Array(column.lows ?? [])
        }.filter(\.isFinite)
        if let low = bounds.min(), let high = bounds.max() {
            model.yDomain = ChartDomain.fitted(
                min: low, max: high, minimumSpan: 30, padding: 5, floor: 0)
        } else {
            model.yDomain = 20...100
        }
        model.yFormat = { String(format: "%.1f°C", $0) }
        model.accessibilityLabel = "CPU and GPU die temperatures"
        model.accessibilityValue =
            "Average and observed temperature range. Missing sensor readings remain gaps."
        return model
    }

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
        chart
            .accessibilityLabel("Die temperature trend")
            .accessibilityValue(accessibilitySummary)
    }

    var chart: TrendChart {
        TrendChart(
            series: [
                TrendSeries(
                    points: cpuPoints, color: ThermalStyle.cpu, reduction: .maximum,
                    name: t("CPU die")),
                TrendSeries(
                    points: gpuPoints, color: ThermalStyle.gpu, lineWidth: 1.8,
                    reduction: .maximum, name: t("GPU die")),
            ],
            xDomain: xDomain,
            yDomain: temperatureDomain,
            yFormat: { String(format: "%.0f°C", $0) },
            showsTimeAxis: showsTimeAxis,
            gapThreshold: ChartGap.threshold(
                expectedSpacing: max(pointSpacing, SamplerModel.configuredHighResInterval())),
            scrubbable: true
        )
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
        chart
            .accessibilityLabel("Fan speed trend")
            .accessibilityValue(accessibilitySummary)
    }

    var chart: TrendChart {
        TrendChart(
            series: [
                TrendSeries(points: fanPoints, color: ThermalStyle.fan, reduction: .maximum)
            ],
            xDomain: xDomain,
            yFormat: { t("%@ rpm", String(format: "%.0f", max($0, 0))) },
            showsTimeAxis: showsTimeAxis,
            scrubbable: true,
            leftGutter: 56
        )
    }
}
