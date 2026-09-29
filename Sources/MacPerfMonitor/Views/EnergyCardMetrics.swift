import Foundation
import MacPerfMonitorCore
import SwiftUI

enum EnergyCardKind: String, CaseIterable, Identifiable {
    case charge, runtime, power, temperature, health, cycles
    var id: String { rawValue }
    var isLifetime: Bool { self == .health || self == .cycles }

    func title(_ battery: BatterySample) -> String {
        switch self {
        case .charge: return t("Charge")
        case .runtime: return battery.isCharging ? t("Time to full") : t("Estimated runtime")
        case .power: return t("Mac power draw")
        case .temperature: return t("Battery temperature")
        case .health: return t("Health")
        case .cycles: return t("Cycles")
        }
    }

    var color: Color {
        switch self {
        case .charge: return .green
        case .runtime: return .blue
        case .power: return .orange
        case .temperature: return .teal
        case .health: return .green
        case .cycles: return .indigo
        }
    }

    var unit: MetricUnit {
        switch self {
        case .charge, .health: return .percent
        case .runtime: return .minutes
        case .power: return .watts
        case .temperature: return .celsius
        case .cycles: return .count
        }
    }

    var explanation: MetricExplanation {
        switch self {
        case .charge:
            return MetricExplanation(
                meaning:
                    "The charge available now. Charging, battery use, and time on an adapter are different states, even when the percentage stays still.",
                calculation:
                    "macOS reports current charge relative to full-charge capacity. The chart keeps recorded gaps. Charge used since unplugging is shown only when that transition was observed."
            )
        case .runtime:
            return MetricExplanation(
                meaning:
                    "An estimate of how long this charge may last, not a promise. The estimate can change when your workload changes. While charging, the figure is time to full instead.",
                calculation:
                    "We prefer the macOS estimate. Otherwise, after at least three minutes of steady discharge, we divide remaining capacity by recent average current. Gaps, charging, and unstable load reset that estimate. Full-charge runtime assumes the same rate of use."
            )
        case .power:
            return MetricExplanation(
                meaning:
                    "Mac power draw is whole-machine consumption. Battery flow is separate: positive watts charge the battery; negative watts drain it. Adapter wattage is its rating, not measured draw.",
                calculation:
                    "Mac power comes from the system power sensor. Battery flow comes from battery voltage and current, with charging state supplying direction. Stored ranges preserve the mean and observed limits of available readings."
            )
        case .temperature:
            return MetricExplanation(
                meaning:
                    "The battery pack temperature, not the CPU or GPU temperature. Charging and sustained use can warm the battery. Missing readings are not zero degrees.",
                calculation:
                    "The battery controller supplies the temperature. The chart preserves recorded values and ranges. CPU temperature warning limits do not apply to this sensor."
            )
        case .health:
            return MetricExplanation(
                meaning:
                    "How much charge the battery can hold compared with its design capacity. Small changes can reflect calibration, not damage. The 80% line is a service reference, not a predicted failure date.",
                calculation:
                    "Full-charge capacity divided by design capacity. One record per battery per day supports month and year trends. A replacement battery starts a separate history. A 90-day change appears only when the recorded dates cover that comparison."
            )
        case .cycles:
            return MetricExplanation(
                meaning:
                    "A cycle is cumulative use of a full charge, not each time you plug in. The rated count is a wear reference; the battery does not suddenly stop working at that number.",
                calculation:
                    "The battery controller supplies the cycle total. Daily records make a step chart. Monthly increases need observations near both month boundaries; missing months are not zero cycles."
            )
        }
    }
}

enum BatteryLifetimeRange: String, CaseIterable, Identifiable {
    case month, quarter, halfYear, year, all
    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .month: return 30
        case .quarter: return 90
        case .halfYear: return 180
        case .year: return 365
        case .all: return nil
        }
    }

    var label: String {
        switch self {
        case .month: return t("30 days")
        case .quarter: return t("90 days")
        case .halfYear: return t("6 months")
        case .year: return t("1 year")
        case .all: return t("All recorded")
        }
    }
}

enum EnergyCardMetrics {
    static func card(
        _ kind: EnergyCardKind, battery: BatterySample, history: [BatteryHistoryPoint],
        daily: [BatteryDailyPoint], window: HistoryWindow, now: Date
    ) -> MetricCardData {
        let point = BatteryHistoryPoint(sample: battery)
        let value: String
        var detail: String?
        switch kind {
        case .charge:
            value = point.values[.charge].map(MetricUnit.percent.format) ?? t("Not reported")
            detail =
                battery.isCharging
                ? t("charging") : (battery.isOnAC ? t("On adapter") : t("On battery"))
        case .runtime:
            if battery.isCharging {
                value = point.values[.timeToFull].map(MetricUnit.minutes.format) ?? t("Calculating")
            } else if battery.isOnAC {
                value = t("On adapter")
            } else {
                value =
                    point.values[.runtime].map { "~" + MetricUnit.minutes.format($0) }
                    ?? t("Calculating")
                detail =
                    point.estimateSource == .recentUse
                    ? t("Recent use") : (point.estimateSource == .macOS ? "macOS" : nil)
            }
        case .power:
            value = point.values[.power].map(MetricUnit.watts.format) ?? t("Not reported")
            if let flow = point.values[.flow] {
                detail = t("%@ battery", String(format: "%+.1f W", flow))
            }
        case .temperature:
            value = point.values[.temperature].map(MetricUnit.celsius.format) ?? t("Not reported")
        case .health:
            value =
                battery.healthPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
                .map(MetricUnit.percent.format) ?? t("Not reported")
            if let change = change(daily, days: 90, now: now, value: { $0.healthPercent }) {
                detail = t("%@ pp / 90d", String(format: "%+.1f", change))
            }
        case .cycles:
            value =
                battery.cycleCount.flatMap { $0 >= 0 ? $0 : nil }
                .map { MetricUnit.count.format(Double($0)) } ?? t("Not reported")
            if let change = change(
                daily, days: 30, now: now, value: { $0.cycleCount.map(Double.init) }), change >= 0
            {
                detail = t("+%@ / 30d", MetricUnit.count.format(change))
            }
        }
        let lifetimeRange: BatteryLifetimeRange = kind == .health ? .quarter : .year
        let chart =
            kind.isLifetime
            ? lifetimeChart(kind, daily: daily, range: lifetimeRange, now: now)
            : sessionChart(kind, history: history, battery: battery, window: window, now: now)
        return MetricCardData(
            label: kind.title(battery), value: value, tint: kind.color, unit: kind.unit,
            detail: detail, help: t("Click for details."), explanation: kind.explanation,
            statisticsModel: chart, timeDomain: chart.xDomain,
            context: kind.isLifetime ? lifetimeRange.label : window.label, expandedLabels: true)
    }

    static func sessionChart(
        _ kind: EnergyCardKind, history: [BatteryHistoryPoint], battery: BatterySample,
        window: HistoryWindow, now: Date, domain: ClosedRange<Date>? = nil
    ) -> TrendModel {
        let metrics: [(BatteryHistoryMetric, String, Color)]
        switch kind {
        case .charge: metrics = [(.charge, t("Charge"), .green)]
        case .runtime:
            metrics = [
                (.runtime, t("Estimated runtime"), .blue),
                (.timeToFull, t("Time to full"), .orange),
            ]
        case .power:
            metrics = [(.power, t("Mac power draw"), .orange), (.flow, t("Battery flow"), .blue)]
        case .temperature: metrics = [(.temperature, t("Battery temperature"), .teal)]
        case .health, .cycles: metrics = []
        }
        var model = baseModel(unit: kind.unit, title: kind.title(battery))
        let domain = domain ?? now.addingTimeInterval(-window.seconds)...now
        let points = history.filter {
            $0.date <= domain.upperBound
                && $0.date.addingTimeInterval($0.duration) >= domain.lowerBound
        }
        model.xDomain = domain
        let sourceWidth = points.map(\.duration).max() ?? 0
        model.statisticsInterval = ChartStatistics.interval(
            span: max(1, domain.upperBound.timeIntervalSince(domain.lowerBound)),
            minimum: sourceWidth)
        model.gapThreshold = max(30, SamplerModel.configuredHighResInterval() * 3)
        model.series = metrics.map { metric, name, color in
            return TrendSurfaceSeries(
                column: sessionColumn(
                    metric, points: points,
                    batteryID: BatteryIdentity.identifier(for: battery.serialNumber)),
                color: color, name: name)
        }
        if kind == .charge { model.yDomain = 0...100 }
        if kind == .temperature {
            let values = model.series.flatMap { Array($0.column.values) }.filter(\.isFinite)
            if let low = values.min(), let high = values.max() {
                model.yDomain = ChartDomain.fitted(
                    min: low, max: high, minimumSpan: 10, padding: 2, floor: 0)
            }
        }
        if kind == .power {
            let values = model.series.flatMap {
                Array($0.column.lows ?? []) + Array($0.column.highs ?? [])
            }.filter(\.isFinite)
            model.yDomain = min(0, (values.min() ?? 0) * 1.1)...max(1, (values.max() ?? 1) * 1.1)
        }
        return model
    }

    private static func sessionColumn(
        _ metric: BatteryHistoryMetric, points: [BatteryHistoryPoint], batteryID: String?
    ) -> LiveColumn {
        var times: [Double] = []
        var values: [Double] = []
        var lows: [Double] = []
        var highs: [Double] = []
        var weights: [Double] = []
        var durations: [Double] = []
        for (index, point) in points.enumerated() {
            if index > 0, metric != .power,
                points[index - 1].batteryID != point.batteryID
                    || ((metric == .runtime || metric == .timeToFull)
                        && points[index - 1].state != point.state)
            {
                let previous = points[index - 1].date.timeIntervalSinceReferenceDate
                times.append(previous + (point.date.timeIntervalSinceReferenceDate - previous) / 2)
                values.append(.nan)
                lows.append(.nan)
                highs.append(.nan)
                weights.append(.nan)
                durations.append(0)
            }
            let sameBattery =
                metric == .power || point.batteryID == nil || batteryID == nil
                || point.batteryID == batteryID
            let validState =
                (metric != .runtime && metric != .fullRuntime && metric != .timeToFull)
                || point.state == (metric == .timeToFull ? .charging : .battery)
            times.append(point.date.timeIntervalSinceReferenceDate)
            values.append(sameBattery && validState ? point.values[metric] ?? .nan : .nan)
            lows.append(sameBattery && validState ? point.minima[metric] ?? .nan : .nan)
            highs.append(sameBattery && validState ? point.maxima[metric] ?? .nan : .nan)
            weights.append(point.counts[metric] ?? .nan)
            durations.append(point.duration)
        }
        return LiveColumn(
            times: times[...], values: values[...], highs: highs[...], lows: lows[...],
            weights: weights[...], durations: durations[...])
    }

    static func lifetimeChart(
        _ kind: EnergyCardKind, daily: [BatteryDailyPoint], range: BatteryLifetimeRange, now: Date
    ) -> TrendModel {
        let start =
            range.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
            ?? min(daily.first?.date ?? now, now.addingTimeInterval(-86_400))
        let points = daily.filter { $0.date >= start && $0.date <= now }
        var model = baseModel(unit: kind.unit, title: kind == .health ? t("Health") : t("Cycles"))
        model.xDomain = start...now
        model.gapThreshold = 2 * 86_400
        model.discrete = kind == .cycles
        model.statisticsInterval = kind == .health ? 86_400 : nil
        let values = points.map {
            kind == .health ? ($0.healthPercent ?? .nan) : ($0.cycleCount.map(Double.init) ?? .nan)
        }
        model.series = [
            TrendSurfaceSeries(
                column: LiveColumn(
                    times: points.map { $0.date.timeIntervalSinceReferenceDate }[...],
                    values: values[...],
                    weights: Array(repeating: 1.0, count: points.count)[...]), color: kind.color,
                band: false, name: kind == .health ? t("Health") : t("Cycles"))
        ]
        if kind == .health {
            model.yDomain = 0...100
            model.rules = [TrendRule(value: 80, label: t("Service reference"), color: .orange)]
        }
        return model
    }

    static func change(
        _ daily: [BatteryDailyPoint], days: Int, now: Date,
        value: (BatteryDailyPoint) -> Double?
    ) -> Double? {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        guard let first = daily.last(where: { $0.date <= cutoff }),
            cutoff.timeIntervalSince(first.date) <= 2 * 86_400,
            let last = daily.last, last.date <= now, now.timeIntervalSince(last.date) <= 2 * 86_400,
            let initial = value(first), let final = value(last)
        else { return nil }
        return final - initial
    }

    static func unpluggedSession(
        _ history: [BatteryHistoryPoint]
    ) -> ArraySlice<BatteryHistoryPoint>? {
        guard history.count >= 2, history.last?.state == .battery else { return nil }
        var start = history.count - 1
        while start > 0, history[start - 1].state == .battery,
            history[start - 1].batteryID == history[start].batteryID,
            history[start].date.timeIntervalSince(history[start - 1].date)
                <= max(30, history[start - 1].duration + 30)
        {
            start -= 1
        }
        guard start > 0,
            history[start - 1].state == .charging || history[start - 1].state == .adapter,
            history[start - 1].batteryID == history[start].batteryID,
            history[start].date.timeIntervalSince(history[start - 1].date)
                <= max(30, history[start - 1].duration + 30)
        else { return nil }
        return history[start...]
    }

    static func dailyIncludingCurrent(
        _ daily: [BatteryDailyPoint], battery: BatterySample
    ) -> [BatteryDailyPoint] {
        guard battery.isPresent, BatteryIdentity.identifier(for: battery.serialNumber) != nil else {
            return daily
        }
        var points = daily.filter {
            floor($0.date.timeIntervalSince1970 / 86_400)
                < floor(battery.timestamp.timeIntervalSince1970 / 86_400)
        }
        points.append(
            BatteryDailyPoint(
                date: battery.timestamp, healthPercent: battery.healthPercent,
                cycleCount: battery.cycleCount,
                fullCapacitymAh: battery.maxCapacitymAh,
                designCapacitymAh: battery.designCapacitymAh))
        return points
    }

    private static func baseModel(unit: MetricUnit, title: String) -> TrendModel {
        var model = TrendModel()
        model.showsTimeAxis = true
        model.plotBorder = true
        model.leftGutter = 62
        model.yFormat = unit.format
        model.detailFormat = unit.format
        model.accessibilityLabel = title
        return model
    }
}
