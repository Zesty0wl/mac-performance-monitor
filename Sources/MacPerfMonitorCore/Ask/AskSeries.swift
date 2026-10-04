import Foundation

/// Summary statistics of one metric over recorded points. Aggregate buckets
/// weigh by the time they cover, raw samples count once each, and the peak
/// reads a bucket's stored maximum so an hour-long mean still shows its spike.
struct AskSeries {
    let mean: Double
    let peak: Double
    let peakDate: Date
    let latest: Double
    /// Weighted share of the period spent at or above `busyThreshold`.
    let busyShare: Double
    let count: Int

    init?(
        _ points: [SystemHistoryPoint], busyThreshold: Double = .infinity,
        value: (SystemHistoryPoint) -> Double?, peak: ((SystemHistoryPeaks) -> Double?)? = nil
    ) {
        var weightedSum = 0.0
        var totalWeight = 0.0
        var busyWeight = 0.0
        var best = -Double.infinity
        var bestDate = Date.distantPast
        var last: Double?
        var count = 0
        for point in points {
            guard let v = value(point), v.isFinite else { continue }
            let weight = point.bucketDuration > 0 ? point.bucketDuration : 1
            weightedSum += v * weight
            totalWeight += weight
            if v >= busyThreshold { busyWeight += weight }
            let top =
                peak.flatMap { $0(point.effectivePeaks) }.flatMap { $0.isFinite ? $0 : nil } ?? v
            if top > best {
                best = top
                bestDate = point.date
            }
            last = v
            count += 1
        }
        guard count > 0, totalWeight > 0, let last else { return nil }
        mean = weightedSum / totalWeight
        self.peak = max(best, mean)
        peakDate = bestDate
        latest = last
        busyShare = busyWeight / totalWeight
        self.count = count
    }

    /// Median of per-point values, for "what is normal" from a week of hours.
    static func median(
        _ points: [SystemHistoryPoint], value: (SystemHistoryPoint) -> Double?
    )
        -> Double?
    {
        let values = points.compactMap(value).filter(\.isFinite).sorted()
        guard values.count >= 12 else { return nil }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }
}

/// Everyday wording for numbers, shared by every area so the same kind of
/// figure always reads the same way.
enum AskWords {
    static func percent(_ value: Double) -> String {
        t("%lld%%", Int64(value.rounded()))
    }

    static func share(_ fraction: Double) -> String {
        switch fraction {
        case ..<0.05: return t("almost none of the time")
        case ..<0.2: return t("a little of the time")
        case ..<0.4: return t("about a third of the time")
        case ..<0.6: return t("about half the time")
        case ..<0.85: return t("most of the time")
        default: return t("nearly all the time")
        }
    }

    /// "about twice as much as usual", or nil when the difference is too small
    /// to be worth saying.
    static func comparedWithNormal(_ value: Double, normal: Double, floor: Double) -> String? {
        let base = max(normal, floor)
        let ratio = value / base
        switch ratio {
        case ..<0.5: return t("well below usual")
        case ..<1.4: return nil
        case ..<1.8: return t("higher than usual")
        case ..<2.5: return t("about twice as much as usual")
        case ..<3.5: return t("about three times as much as usual")
        default: return t("far more than usual")
        }
    }

    static func time(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(
                LocalizationTable.currentLocale))
    }

    /// "the last hour", "10:00 to 11:00", "yesterday": how the period reads.
    static func period(_ start: Date, _ end: Date, now: Date) -> String {
        let span = end.timeIntervalSince(start)
        if abs(end.timeIntervalSince(now)) < 120 {
            switch span {
            case ..<(20 * 60): return t("the last %lld minutes", Int64((span / 60).rounded()))
            case ..<(90 * 60): return t("the last hour")
            case ..<(36 * 3600): return t("the last %lld hours", Int64((span / 3600).rounded()))
            default: return t("the last %lld days", Int64((span / 86400).rounded()))
            }
        }
        return t("%1$@ to %2$@", time(start), time(end))
    }

    static func minutes(_ seconds: Double) -> String {
        let minutes = Int64((seconds / 60).rounded())
        if minutes < 90 { return t("%lld minutes", max(1, minutes)) }
        return t("%lld hours", Int64((seconds / 3600).rounded()))
    }
}

/// The period wording, for the app layer's prompts and headers.
public enum AskFormatting {
    /// The locale the app is displaying, which the model should answer in.
    public static var locale: Locale { LocalizationTable.currentLocale }

    public static func period(_ start: Date, _ end: Date, now: Date) -> String {
        AskWords.period(start, end, now: now)
    }
}
