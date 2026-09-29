import Charts
import MacPerfMonitorCore
import SwiftUI

struct EnergyMetricSnapshot: Identifiable {
    let id = UUID()
    var kind: EnergyCardKind
    var battery: BatterySample
    var history: [BatteryHistoryPoint]
    var daily: [BatteryDailyPoint]
    var window: HistoryWindow
    var capturedAt: Date
    var historyUnavailable = false
    var dailyUnavailable = false
}

struct EnergyMetricCards: View {
    @ObservedObject var history: EnergyHistoryModel
    let battery: BatterySample
    let window: HistoryWindow
    var sampler: SamplerModel?
    @State private var detail: EnergyMetricSnapshot?

    var body: some View {
        let now = battery.timestamp
        let daily = EnergyCardMetrics.dailyIncludingCurrent(history.daily, battery: battery)
        let kinds: [EnergyCardKind] = battery.isPresent ? EnergyCardKind.allCases : [.power]
        let cards = kinds.map {
            EnergyCardMetrics.card(
                $0, battery: battery, history: history.history, daily: daily, window: window,
                now: now)
        }
        MetricCardsRow(
            cards: cards,
            onSelect: { card in
                guard let kind = kinds.first(where: { $0.title(battery) == card.label }) else {
                    return
                }
                detail = EnergyMetricSnapshot(
                    kind: kind, battery: battery, history: history.history, daily: daily,
                    window: window, capturedAt: now, historyUnavailable: history.historyUnavailable,
                    dailyUnavailable: history.dailyUnavailable)
            }
        )
        .sheet(item: $detail) { snapshot in
            EnergyMetricDetailSheet(snapshot: snapshot, sampler: sampler)
        }
    }
}

struct EnergyMetricDetailSheet: View {
    let snapshot: EnergyMetricSnapshot
    var sampler: SamplerModel?
    @Environment(\.dismiss) private var dismiss
    @State private var window: HistoryWindow
    @State private var lifetimeRange: BatteryLifetimeRange
    @State private var history: [BatteryHistoryPoint]
    @State private var loading = false
    @State private var unavailable: Bool
    @State private var generation = 0
    @State private var sinceUnplugging = false

    init(snapshot: EnergyMetricSnapshot, sampler: SamplerModel? = nil) {
        self.snapshot = snapshot
        self.sampler = sampler
        _window = State(initialValue: snapshot.window)
        _lifetimeRange = State(initialValue: snapshot.kind == .health ? .quarter : .year)
        _history = State(initialValue: snapshot.history)
        _unavailable = State(
            initialValue: snapshot.kind.isLifetime
                ? snapshot.dailyUnavailable : snapshot.historyUnavailable)
    }

    private var chart: TrendModel {
        snapshot.kind.isLifetime
            ? EnergyCardMetrics.lifetimeChart(
                snapshot.kind, daily: snapshot.daily, range: lifetimeRange, now: snapshot.capturedAt
            )
            : EnergyCardMetrics.sessionChart(
                snapshot.kind, history: history, battery: snapshot.battery, window: window,
                now: snapshot.capturedAt, domain: sessionDomain)
    }

    private var sessionDomain: ClosedRange<Date>? {
        guard sinceUnplugging, let first = EnergyCardMetrics.unpluggedSession(history)?.first else {
            return nil
        }
        return first.date...snapshot.capturedAt
    }

    var body: some View {
        let card = EnergyCardMetrics.card(
            snapshot.kind, battery: snapshot.battery, history: history, daily: snapshot.daily,
            window: window, now: snapshot.capturedAt)
        let chart = chart
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.label).font(.title2.weight(.semibold))
                    Text(card.value ?? t("Not reported"))
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                Spacer()
                Text("Snapshot, not live").font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.kind.isLifetime {
                Picker("Range", selection: $lifetimeRange) {
                    ForEach(BatteryLifetimeRange.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            } else {
                Picker("Range", selection: $window) {
                    ForEach(HistoryWindow.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            }
            if snapshot.kind == .charge || snapshot.kind == .runtime {
                Toggle("Since unplugging", isOn: $sinceUnplugging)
                    .toggleStyle(.checkbox)
                    .disabled(EnergyCardMetrics.unpluggedSession(history) == nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(snapshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if unavailable {
                        Text("History unavailable; showing the captured readings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if chart.series.contains(where: { $0.column.values.contains(where: \.isFinite) }
                    ) {
                        TrendSnapshotChart(model: chart)
                            .frame(height: 260)
                            .chartReloading(loading)
                        if !snapshot.kind.isLifetime {
                            TrendStatisticsCaption(model: chart)
                        }
                    } else {
                        Text("No recorded history for this range.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    details
                    if snapshot.kind == .runtime,
                        let forecast = EnergyChargeForecast.make(
                            snapshot, history: history, window: window, domain: sessionDomain)
                    {
                        EnergyChargeForecastView(forecast: forecast)
                    }
                    if !snapshot.kind.isLifetime {
                        TrendStatisticsSummary(model: chart)
                    }
                    Text("What it means").font(.headline)
                    Text(snapshot.kind.explanation.meaning)
                        .font(.callout).foregroundStyle(.secondary)
                    Text("How it's calculated").font(.headline)
                    Text(snapshot.kind.explanation.calculation)
                        .font(.callout).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            width: 760,
            height: min(780, max(480, (NSScreen.main?.visibleFrame.height ?? 900) - 120))
        )
        .onChange(of: window) {
            sinceUnplugging = false
            reload()
        }
    }

    @ViewBuilder private var details: some View {
        switch snapshot.kind {
        case .charge:
            if let session = EnergyCardMetrics.unpluggedSession(history),
                let first = session.first, let last = session.last,
                let initial = first.values[.charge], let final = last.values[.charge]
            {
                LabeledContent(
                    t("Used since unplugging"),
                    value: t(
                        "%@ percentage points", String(format: "%.1f", max(0, initial - final))))
            }
            powerPeriods
        case .runtime:
            if let estimate = snapshot.battery.runtimeEstimate {
                LabeledContent(
                    t("Estimate source"),
                    value: estimate.source == .macOS ? "macOS" : t("Recent use"))
                if let full = estimate.fullChargeMinutes {
                    LabeledContent(
                        t("Full charge at this rate"), value: "~" + MetricUnit.minutes.format(full))
                }
            }
            powerPeriods
        case .power:
            if let adapter = snapshot.battery.adapterWatts {
                LabeledContent(t("Adapter rating"), value: MetricUnit.watts.format(Double(adapter)))
            }
        case .temperature:
            powerPeriods
        case .health:
            if let full = snapshot.battery.maxCapacitymAh {
                LabeledContent(t("Full-charge capacity"), value: t("%@ mAh", full.formatted()))
            }
            if let design = snapshot.battery.designCapacitymAh {
                LabeledContent(t("Design capacity"), value: t("%@ mAh", design.formatted()))
            }
            if let first = snapshot.daily.first {
                LabeledContent(
                    t("History begins"),
                    value: first.date.formatted(date: .abbreviated, time: .omitted))
            }
        case .cycles:
            LabeledContent(
                t("Rated cycle reference"), value: BatteryView.ratedCycleCount.formatted())
            Text("Monthly cycle increases").font(.headline)
            ForEach(monthlyCycles, id: \.date) { month in
                LabeledContent(
                    month.date.formatted(.dateTime.month(.wide).year()),
                    value: month.value.map(MetricUnit.count.format) ?? t("Not enough history"))
            }
        }
    }

    private var monthlyCycles: [(date: Date, value: Double?)] {
        let calendar = Calendar.current
        guard let current = calendar.dateInterval(of: .month, for: snapshot.capturedAt)?.start
        else { return [] }
        return (0..<12).compactMap { index in
            guard let start = calendar.date(byAdding: .month, value: -index, to: current),
                let monthEnd = calendar.date(byAdding: .month, value: 1, to: start)
            else { return nil }
            let end = min(monthEnd, snapshot.capturedAt)
            let before = snapshot.daily.last { $0.date <= start }
            let after = snapshot.daily.last { $0.date <= end }
            var value: Double?
            if let before, let after, start.timeIntervalSince(before.date) <= 2 * 86_400,
                end.timeIntervalSince(after.date) <= 2 * 86_400,
                let first = before.cycleCount, let last = after.cycleCount, last >= first
            {
                value = Double(last - first)
            }
            return (date: start, value: value)
        }
    }

    private var powerPeriods: some View {
        let changes = history.enumerated().filter { index, point in
            point.state != nil && (index == 0 || history[index - 1].state != point.state)
        }.suffix(8)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Power states").font(.headline)
            ForEach(Array(changes), id: \.offset) { _, point in
                LabeledContent(
                    point.date.formatted(date: .abbreviated, time: .shortened),
                    value: stateLabel(point.state))
            }
        }
    }

    private func stateLabel(_ state: BatteryHistoryPoint.PowerState?) -> String {
        switch state {
        case .battery: return t("On battery")
        case .charging: return t("Charging")
        case .adapter, .noBattery: return t("On adapter")
        case nil: return t("Not reported")
        }
    }

    private func reload() {
        guard let sampler else { return }
        generation += 1
        let request = generation
        loading = true
        sampler.loadBatteryHistory(window, now: snapshot.capturedAt) { result in
            guard request == generation else { return }
            loading = false
            switch result {
            case .success(let points):
                let last = points.last?.date ?? .distantPast
                history =
                    points
                    + snapshot.history.filter { $0.date > last && $0.date <= snapshot.capturedAt }
                unavailable = false
            case .failure: unavailable = true
            }
        }
    }
}

struct EnergyChargeForecast {
    var observed: [TrendPoint]
    var start: TrendPoint
    var end: TrendPoint

    static func make(
        _ snapshot: EnergyMetricSnapshot, history: [BatteryHistoryPoint]? = nil,
        window: HistoryWindow? = nil, domain: ClosedRange<Date>? = nil
    ) -> EnergyChargeForecast? {
        let battery = snapshot.battery
        guard battery.isPresent, !battery.isOnAC, !battery.isCharging,
            let estimate = battery.runtimeEstimate, estimate.minutesRemaining.isFinite,
            estimate.minutesRemaining > 0, estimate.minutesRemaining <= 10_080,
            battery.chargePercent.isFinite, (0...100).contains(battery.chargePercent)
        else { return nil }
        let chart = EnergyCardMetrics.sessionChart(
            .charge, history: history ?? snapshot.history, battery: battery,
            window: window ?? snapshot.window, now: snapshot.capturedAt, domain: domain)
        guard let column = chart.series.first?.column, let domain = chart.xDomain else {
            return nil
        }
        return EnergyChargeForecast(
            observed: LiveTrend.points(column, xDomain: domain, buckets: 360),
            start: TrendPoint(date: battery.timestamp, value: battery.chargePercent),
            end: TrendPoint(
                date: battery.timestamp.addingTimeInterval(estimate.minutesRemaining * 60), value: 0
            ))
    }
}

private struct EnergyChargeForecastView: View {
    let forecast: EnergyChargeForecast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Charge projection").font(.headline)
            Chart {
                ForEach(Array(forecast.observed.enumerated()), id: \.offset) { _, point in
                    if point.value.isFinite {
                        PointMark(x: .value("Time", point.date), y: .value("Charge", point.value))
                            .foregroundStyle(.green).symbolSize(4)
                    }
                }
                ForEach([forecast.start, forecast.end], id: \.date) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Charge", point.value))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                        .interpolationMethod(.linear)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text(MetricUnit.percent.format(percent))
                        }
                    }
                }
            }
            .frame(height: 190)
            HStack {
                Label("Recorded charge", systemImage: "circle.fill").foregroundStyle(.green)
                Label("Forecast", systemImage: "line.diagonal").foregroundStyle(.blue)
            }.font(.caption)
            Text("Dashed line: an estimate if the current rate of use continues.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
