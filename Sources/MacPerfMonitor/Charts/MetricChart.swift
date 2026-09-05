import MacPerfMonitorCore
import SwiftUI

/// One point on a process-detail metric chart. `id` is the timestamp, which is
/// unique within a raw series (the table's primary key prevents duplicates).
struct MetricSample: Identifiable, Equatable {
    var date: Date
    var value: Double
    /// The stored peak behind a mean, for rows from the minute and hour tiers.
    var high: Double? = nil
    var id: Date { date }
}

/// A compact, reusable line chart for a single per-process metric (footprint,
/// CPU, file descriptors, disk throughput), drawn with the Canvas `TrendChart`.
/// The Y axis is formatted by the caller so each metric reads in its natural
/// units. Hovering or dragging over the plot scrubs the series, pinning a
/// marker and a value read-out at the nearest sample.
///
/// This was a Swift Charts view. With five of them in the inspector, each
/// 1 Hz update cost about 34 ms of main-thread time laying out marks; the
/// Canvas version draws the same series in well under a millisecond.
struct MetricChart: View, Equatable {
    let samples: [MetricSample]
    var tint: Color = .blue
    /// Floor for the Y domain's top, so a flat-at-zero series still renders a
    /// sensible axis rather than collapsing to a single line.
    var minTop: Double = 1
    /// Width in seconds of the window this chart represents (the selected range,
    /// for example 1800 for "30 min"). The downsampling bucket width is derived
    /// from this FIXED span, never from the data's own extent, so the buckets
    /// stay anchored to the clock as the live window advances. That is what
    /// keeps the chart from changing shape on every tick.
    var windowSeconds: TimeInterval = 30 * 60
    /// VoiceOver name for this chart, e.g. "Memory footprint". Supplied by the
    /// caller because only it knows which metric the series represents.
    var accessibilityTitle: String = "Trend"
    let yFormat: (Double) -> String

    /// Re-render (and so re-downsample) only when the data or framing actually
    /// change, not on the 1 s tick that re-renders the enclosing detail view
    /// while this chart's `samples` are unchanged. The series is append-only or
    /// fully reloaded, so count + endpoints uniquely identify it without an O(n)
    /// scan; `yFormat` (a closure) is excluded.
    static func == (lhs: MetricChart, rhs: MetricChart) -> Bool {
        lhs.windowSeconds == rhs.windowSeconds
            && lhs.tint == rhs.tint
            && lhs.minTop == rhs.minTop
            && lhs.samples.count == rhs.samples.count
            && lhs.samples.first == rhs.samples.first
            && lhs.samples.last == rhs.samples.last
    }

    /// The raw samples split into contiguous runs, broken wherever two samples
    /// are far enough apart to mean data is missing (the app was asleep, the
    /// process was briefly unreadable, or it was relaunched). The chart then
    /// reduces each run at draw time, a mean line inside a band of the
    /// extremes (docs/chart-rules.md), so nothing is thinned here.
    private var segments: [[MetricSample]] {
        Self.split(samples, gapThreshold: gapThreshold)
    }

    /// A gap is a jump well beyond the normal sampling cadence. Raw rows are
    /// change-gated, so a process's spacing is bimodal: ~1 s while it is changing,
    /// but up to a full heartbeat bucket (~60 s, the guaranteed idle cadence)
    /// while it sits flat. The median tracks the dense active spacing, so it would
    /// wrongly break the line across every idle heartbeat and scatter a flat
    /// process into dots. Use a high percentile instead, which tracks the idle
    /// heartbeat spacing, times a factor, with a floor comfortably above the
    /// default heartbeat, so an idle stretch stays a connected (flat) line and
    /// only a genuine hole (the Mac asleep, the app not running) reads as a gap.
    private var gapThreshold: TimeInterval {
        guard samples.count > 2 else { return .greatestFiniteMagnitude }
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(samples.count - 1)
        for i in 1..<samples.count {
            deltas.append(samples[i].date.timeIntervalSince(samples[i - 1].date))
        }
        deltas.sort()
        let p90 = deltas[min(deltas.count - 1, (deltas.count * 9) / 10)]
        return max(p90 * 3, 150)
    }

    /// Fixed trailing viewport anchored to the newest raw sample. Using the raw
    /// endpoint matters when the rightmost downsampling bucket's peak occurred
    /// earlier than its latest reading.
    private var xDomain: ClosedRange<Date> {
        let latest = samples.last?.date ?? .distantPast
        return latest.addingTimeInterval(-max(windowSeconds, 1))...latest
    }

    /// A spoken summary for VoiceOver: the latest value and the peak, formatted
    /// in the metric's own units via the caller-supplied `yFormat`.
    private var accessibilitySummary: String {
        guard let latest = samples.last?.value else { return t("No data yet.") }
        let peak = samples.map(\.value).max() ?? latest
        return t(
            "Currently %1$@. Peak %2$@ over the shown window.", yFormat(latest), yFormat(peak))
    }

    var body: some View {
        let segments = segments
        // Sit the tallest value near the top of the plot with a little headroom,
        // rather than crushing the data onto the floor or jamming the peak into
        // the ceiling. The floor only applies when the series is near zero.
        // Snapped to a nice value so the axis holds still between ticks.
        var peak = 0.0
        for segment in segments {
            for sample in segment where sample.value > peak { peak = sample.value }
        }
        let maxValue = LiveChartGeometry.niceCeiling(max(peak * 1.12, minTop))
        return TrendChart(
            // Each gap-free run is its own series so the line breaks, rather
            // than bridging a straight diagonal, wherever data is missing. The
            // runs are already split, so the chart must not split them again.
            series: segments.map { run in
                TrendSeries(
                    points: run.map { TrendPoint(date: $0.date, value: $0.value, high: $0.high) },
                    color: tint, filled: false, lineWidth: 1.8)
            },
            xDomain: xDomain,
            yDomain: 0...maxValue,
            yFormat: yFormat,
            showsTimeAxis: true,
            timeAxis: .ago,
            gapThreshold: .infinity,
            plotBorder: true,
            scrubbable: true,
            leftGutter: 52
        )
        .accessibilityLabel(t(accessibilityTitle))
        .accessibilityValue(accessibilitySummary)
        .reducedMotionAware()
    }

    /// Break a series into contiguous runs wherever two consecutive points are
    /// more than `gapThreshold` apart, so a stretch of missing data is left
    /// blank instead of being joined by a straight line across the hole.
    private static func split(
        _ samples: [MetricSample], gapThreshold: TimeInterval
    )
        -> [[MetricSample]]
    {
        guard !samples.isEmpty else { return [] }
        var segments: [[MetricSample]] = []
        var current: [MetricSample] = [samples[0]]
        for sample in samples.dropFirst() {
            if let last = current.last,
                sample.date.timeIntervalSince(last.date) > gapThreshold
            {
                segments.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
        }
        segments.append(current)
        return segments
    }
}
