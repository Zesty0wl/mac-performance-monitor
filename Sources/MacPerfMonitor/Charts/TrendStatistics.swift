import AppKit
import MacPerfMonitorCore
import SwiftUI

enum TrendStatistics {
    static func position(_ bucket: ChartStatistics.Bucket) -> Double {
        min(max((bucket.start + bucket.end) / 2, bucket.firstTime), bucket.lastTime)
    }

    static func buckets(_ series: TrendSurfaceSeries, model: TrendModel) -> [ChartStatistics.Bucket]
    {
        let (lower, upper) = TrendSurfaceView.timeBounds(model)
        guard upper >= lower else { return [] }
        let interval = model.statisticsInterval ?? ChartStatistics.interval(span: upper - lower)
        return series.column.statistics(
            width: interval, range: lower...upper,
            gapThreshold: model.gapThreshold ?? 30, scale: series.scale)
    }

    static func duration(_ seconds: Double) -> String {
        if seconds >= 3600 { return t("%@ hr", String(format: "%g", seconds / 3600)) }
        if seconds >= 60 { return t("%@ min", String(format: "%g", seconds / 60)) }
        return t("%@ s", String(format: "%g", seconds))
    }

    static func intervalText(start: Double, end: Double) -> String {
        let first = Date(timeIntervalSinceReferenceDate: start)
        let last = Date(timeIntervalSinceReferenceDate: end)
        let sameDay = Calendar.current.isDate(first, inSameDayAs: last)
        return t(
            "%1$@ to %2$@", first.formatted(date: .abbreviated, time: .standard),
            last.formatted(date: sameDay ? .omitted : .abbreviated, time: .standard))
    }

    static func value(_ value: Double?, model: TrendModel) -> String {
        guard let value, value.isFinite else { return t("Not recorded") }
        return (model.detailFormat ?? model.yFormat)(value)
    }

    static func hasUnknown(_ metadata: ArraySlice<Double>?, column: LiveColumn) -> Bool {
        guard let metadata else { return false }
        return zip(column.values, metadata).contains { value, bound in
            value.isFinite && !bound.isFinite
        }
    }
}

struct TrendSnapshotChart: NSViewRepresentable {
    let model: TrendModel
    var onActivate: (() -> Void)? = nil

    func makeNSView(context: Context) -> TrendSurfaceView {
        let surface = TrendSurfaceView()
        surface.scrubbable = true
        surface.onActivate = onActivate
        let feed = TrendFeed()
        feed.publish(model)
        surface.attach(feed)
        return surface
    }

    func updateNSView(_ view: TrendSurfaceView, context: Context) {
        view.onActivate = onActivate
        view.feed?.publish(model, replacingHistory: true)
    }

    static func dismantleNSView(_ view: TrendSurfaceView, coordinator: ()) {
        view.detach()
    }
}

struct TrendStatisticsCaption: View {
    let model: TrendModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { legend }
                VStack(alignment: .leading, spacing: 4) { legend }
            }
            if model.series.contains(where: { series in
                TrendStatistics.hasUnknown(series.column.lows, column: series.column)
                    || TrendStatistics.hasUnknown(series.column.highs, column: series.column)
            }) {
                Text("Missing bounds: shading stops at the recorded average.")
            }
            if model.series.contains(where: {
                TrendStatistics.hasUnknown($0.column.weights, column: $0.column)
            }) {
                Text(
                    "Some source sample counts are unknown. Averages for those intervals are approximate."
                )
            }
            if let note = model.statisticsNote { Text(note) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var legend: some View {
        HStack(spacing: 4) {
            Rectangle().fill(.secondary).frame(width: 16, height: 2)
            if let interval = model.statisticsInterval {
                Text(t("Average (%@)", TrendStatistics.duration(interval)))
                    .monospacedDigit()
            } else {
                Text("Average")
            }
        }
        HStack(spacing: 4) {
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 16, height: 8)
                .accessibilityHidden(true)
            Text("Recorded range")
        }
    }
}

struct TrendStatisticsSummary: View {
    let model: TrendModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(model.series.enumerated()), id: \.offset) { _, series in
                let buckets = TrendStatistics.buckets(series, model: model)
                let summary = ChartStatistics.summary(buckets)
                TrendStatisticsValues(
                    name: series.name.isEmpty ? model.accessibilityLabel : series.name,
                    color: series.color, mean: summary?.mean, minimum: summary?.minimum,
                    maximum: summary?.maximum, sampleCount: summary?.sampleCount,
                    approximate: summary?.hasUnknownWeight ?? false, model: model)
            }
        }
        .textSelection(.enabled)
    }
}

struct TrendHoverView: View {
    let model: TrendModel
    let time: Double

    var body: some View {
        let interval = model.statisticsInterval ?? 1
        let start = floor(time / interval) * interval
        let (windowStart, windowEnd) = TrendSurfaceView.timeBounds(model)
        VStack(alignment: .leading, spacing: 14) {
            Text(TrendStatistics.intervalText(start: start, end: start + interval))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(model.series.enumerated()), id: \.offset) { _, series in
                let buckets = series.column.statistics(
                    width: interval,
                    range: max(
                        start, windowStart)...max(
                            max(start, windowStart), min((start + interval).nextDown, windowEnd)),
                    gapThreshold: model.gapThreshold ?? 30, scale: series.scale)
                let selected = ChartStatistics.selection(
                    at: time, in: buckets, tolerance: min(interval, model.gapThreshold ?? 30))
                VStack(alignment: .leading, spacing: 5) {
                    TrendStatisticsValues(
                        name: series.name.isEmpty ? model.accessibilityLabel : series.name,
                        color: series.color, mean: selected?.mean, minimum: selected?.minimum,
                        maximum: selected?.maximum, sampleCount: selected?.sampleCount,
                        approximate: selected?.hasUnknownWeight ?? false, model: model)
                    if let selected {
                        Text(
                            selected.sourceResolution > 0
                                ? t(
                                    "Source resolution: %@",
                                    TrendStatistics.duration(selected.sourceResolution))
                                : t("Source: individual recorded samples")
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        if windowStart > start || windowEnd < start + interval {
                            Text("Partial interval at the window edge")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
    }
}

private struct TrendStatisticsValues: View {
    let name: String
    let color: Color
    let mean: Double?
    let minimum: Double?
    let maximum: Double?
    let sampleCount: Int?
    let approximate: Bool
    let model: TrendModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.callout.weight(.semibold))
            }
            if let mean {
                HStack(alignment: .top, spacing: 12) {
                    statistic(approximate ? "Approx. average" : "Average", value: mean)
                    statistic("Minimum", value: minimum)
                    statistic("Maximum", value: maximum)
                }
                Text(
                    sampleCount.map { t("%@ recorded samples", $0.formatted()) }
                        ?? t("Sample count not recorded")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("No reading in this interval")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statistic(_ title: LocalizedStringKey, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(TrendStatistics.value(value, model: model))
                .font(.callout.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
