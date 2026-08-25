import MacPerfMonitorCore
import SwiftUI

/// Shared colors for the thermal surfaces, so the Energy tab and any future
/// menu bar panel tell the same story.
enum ThermalStyle {
    static let cpu = Color.orange
    static let gpu = Color.red
    static let fan = Color.teal
}

/// CPU and GPU die temperature over the selected window. The thermal fields
/// are optional (nil marks a tick that did not read the SMC), so each series
/// carries only the points that have a value: `TrendChart`'s gap splitting
/// leaves unsampled stretches blank instead of drawing a misleading 0 degree
/// floor. On aggregate ranges the points already carry the bucket max, so the
/// line is "how hot did it get", never a smoothed average.
struct TemperatureChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false

    private var cpuPoints: [TrendPoint] {
        points.compactMap { point in
            point.cpuDieC.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var gpuPoints: [TrendPoint] {
        points.compactMap { point in
            point.gpuDieC.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var accessibilitySummary: String {
        guard let cpu = cpuPoints.last else {
            return "No temperature samples in the shown window."
        }
        var parts = [String(format: "CPU die %.0f degrees", cpu.value)]
        if let gpu = gpuPoints.last {
            parts.append(String(format: "GPU die %.0f degrees", gpu.value))
        }
        if let peak = cpuPoints.map(\.value).max() {
            parts.append(String(format: "window peak %.0f degrees", peak))
        }
        return "Latest " + parts.joined(separator: ", ") + "."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: cpuPoints, color: ThermalStyle.cpu, filled: true),
                TrendSeries(
                    points: gpuPoints, color: ThermalStyle.gpu, filled: false, lineWidth: 1.8),
            ],
            xDomain: xDomain,
            yDomain: temperatureDomain,
            yFormat: { String(format: "%.0f°C", $0) },
            showsTimeAxis: showsTimeAxis
        )
        .accessibilityLabel("Die temperature trend")
        .accessibilityValue(accessibilitySummary)
    }

    /// A stable floor-to-headroom domain: starting the axis at 0 wastes half
    /// the plot (die sensors never read near 0), while a tight auto-fit makes
    /// idle noise look dramatic. 20 to a rounded-up peak keeps small wiggles
    /// small and real spikes visible.
    private var temperatureDomain: ClosedRange<Double>? {
        let values = cpuPoints.map(\.value) + gpuPoints.map(\.value)
        guard let peak = values.max() else { return nil }
        let top = max(60, (peak / 10).rounded(.up) * 10 + 10)
        return 20...top
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
            return "No fan samples in the shown window."
        }
        if latest.value == 0 { return "Fans currently off." }
        return String(format: "Fans currently %.0f rpm.", latest.value)
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: fanPoints, color: ThermalStyle.fan, filled: true)
            ],
            xDomain: xDomain,
            yFormat: { String(format: "%.0f rpm", max($0, 0)) },
            showsTimeAxis: showsTimeAxis,
            leftGutter: 56
        )
        .accessibilityLabel("Fan speed trend")
        .accessibilityValue(accessibilitySummary)
    }
}
