import Foundation

struct AlertGrowthWindow {
    struct Point: Sendable {
        var date: Date
        var value: Double
    }
    struct Trend {
        var start: Date
        var end: Date
        var baseline: Double
        var current: Double
        var slope: Double
        var growth: Double { current - baseline }
        var duration: TimeInterval { end.timeIntervalSince(start) }
        var evidence: AlertEvidence {
            AlertEvidence(start: start, end: end, baseline: baseline, current: current, rate: slope)
        }
    }

    private(set) var points: [Point] = []
    let retention: TimeInterval
    let bucket: TimeInterval

    init(retention: TimeInterval = 16 * 60, bucket: TimeInterval = 10) {
        self.retention = retention
        self.bucket = bucket
    }

    mutating func append(_ value: Double, at date: Date, maximumGap: TimeInterval) {
        guard value.isFinite, value >= 0, date.timeIntervalSince1970.isFinite else { return }
        if let last = points.last {
            guard date > last.date else { return }
            if date.timeIntervalSince(last.date) > maximumGap {
                points.removeAll(keepingCapacity: true)
            }
        }
        points.removeAll { date.timeIntervalSince($0.date) > retention }
        if let last = points.last,
            floor(last.date.timeIntervalSince1970 / bucket)
                == floor(date.timeIntervalSince1970 / bucket)
        {
            points[points.count - 1] = Point(date: date, value: value)
        } else {
            points.append(Point(date: date, value: value))
        }
    }

    mutating func reset() { points.removeAll(keepingCapacity: true) }

    func trend(seconds: TimeInterval, coverage: Double = 0.8) -> Trend? {
        guard let end = points.last else { return nil }
        let rows = points.filter { end.date.timeIntervalSince($0.date) <= seconds }
        guard rows.count >= 3, let first = rows.first,
            end.date.timeIntervalSince(first.date) >= seconds * coverage,
            let fit = LinearRegression.fit(
                rows.map { (x: $0.date.timeIntervalSince(first.date), y: $0.value) })
        else { return nil }
        return Trend(
            start: first.date, end: end.date, baseline: first.value, current: end.value,
            slope: fit.slope)
    }
}

final class SwapGrowthDetector {
    private var window = AlertGrowthWindow()
    private var quietChanges: [Double] = []
    private var lastNoiseSample = Date.distantPast
    private var pagingSince: Date?
    private var lastPagingDate: Date?
    private var growthSince: Date?
    private let gib = 1_073_741_824.0
    var isReady: Bool { window.trend(seconds: 300) != nil }

    func reset() {
        window.reset()
        pagingSince = nil
        lastPagingDate = nil
        growthSince = nil
    }

    func evaluate(_ sample: SystemSample, maximumGap: TimeInterval) -> AlertCondition? {
        let date = sample.timestamp
        window.append(Double(sample.swapUsed), at: date, maximumGap: maximumGap)
        let short = window.trend(seconds: 300)
        let medium = window.trend(seconds: 900)
        let recent = window.trend(seconds: 120)
        let fast = window.trend(seconds: 120)
        let floor = max(gib, Double(sample.totalRAM) * 0.03)
        let median = Self.median(quietChanges)
        let noise = Self.median(quietChanges.map { abs($0 - median) }) * 4
        let growthLimit = max(floor, noise)
        let growing =
            recent.map { $0.growth > growthLimit / 20 && $0.slope > growthLimit / 1200 } ?? false
        let shortRisk =
            short.map {
                $0.growth >= growthLimit * $0.duration / 300 && $0.slope >= growthLimit / 400
            } ?? false
        let mediumRisk =
            medium.map {
                $0.growth >= growthLimit * 2 * $0.duration / 900 && $0.slope >= growthLimit / 600
            } ?? false
        let fastRisk =
            fast.map {
                $0.growth >= max(2 * gib, Double(sample.totalRAM) * 0.1) && $0.slope > gib / 120
            } ?? false
        if let short, !shortRisk, !mediumRisk, !fastRisk, abs(short.growth) < floor,
            date.timeIntervalSince(lastNoiseSample) >= 60
        {
            quietChanges.append(short.growth)
            if quietChanges.count > 120 { quietChanges.removeFirst(quietChanges.count - 120) }
            lastNoiseSample = date
        }
        let paging =
            sample.swapInBytesPerSecond.map { $0 >= 8 * 1024 * 1024 } == true
            && sample.swapOutBytesPerSecond.map { $0 >= 8 * 1024 * 1024 } == true
            && sample.pressureSampleValid != false && sample.pressureLevel != .normal
        if let lastPagingDate, date.timeIntervalSince(lastPagingDate) > maximumGap {
            pagingSince = nil
        }
        lastPagingDate = date
        pagingSince = paging ? (pagingSince ?? date) : nil
        let pagingRisk = pagingSince.map { date.timeIntervalSince($0) >= 120 } ?? false
        let chosen = fastRisk ? fast : (shortRisk ? short : medium)
        if pagingRisk {
            let rate = (sample.swapInBytesPerSecond ?? 0) + (sample.swapOutBytesPerSecond ?? 0)
            return AlertCondition(
                Alert(
                    kind: .swap, title: t("Sustained swap activity"),
                    body: t(
                        "Swap activity is %@/s while memory pressure is elevated. Swap occupancy is %@.",
                        AlertText.bytes(rate), ByteFormat.string(sample.swapUsed)), date: date,
                    severity: sample.pressureLevel == .critical ? .critical : .warning,
                    evidence: AlertEvidence(
                        start: pagingSince!, end: date, baseline: Double(sample.swapUsed),
                        current: Double(sample.swapUsed), rate: rate, signal: "swapActivity")),
                recoveryDelay: 300, escalationDelta: growthLimit * 2)
        }
        if growing, (shortRisk || mediumRisk || fastRisk), let trend = chosen {
            growthSince = growthSince ?? date
            let confirmed = date.timeIntervalSince(growthSince!) >= (fastRisk ? 30 : 60)
            let severity: AlertSeverity =
                !confirmed
                ? .watching
                : (fastRisk
                    || (sample.pressureSampleValid != false && sample.pressureLevel == .critical)
                    ? .critical : .warning)
            return AlertCondition(
                Alert(
                    kind: .swap, title: t("Swap is growing rapidly"),
                    body: AlertText.growth(trend.evidence), date: date,
                    severity: severity, evidence: trend.evidence), recoveryDelay: 300,
                escalationDelta: growthLimit * 2)
        }
        growthSince = nil
        if growing, let short, short.growth >= growthLimit / 4 {
            return AlertCondition(
                Alert(
                    kind: .swap, title: t("Swap growth under observation"),
                    body: AlertText.growth(short.evidence), date: date, severity: .watching,
                    evidence: short.evidence), recoveryDelay: 300)
        }
        return nil
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

enum AlertText {
    static func bytes(_ value: Double) -> String {
        guard value.isFinite else { return t("Unavailable") }
        return ByteFormat.string(UInt64(min(max(0, value), Double(UInt64.max).nextDown)))
    }

    static func growth(_ evidence: AlertEvidence) -> String {
        t(
            "Usage grew from %1$@ to %2$@ in %3$@ minutes and is still rising.",
            bytes(evidence.baseline), bytes(evidence.current),
            String(format: "%.1f", evidence.end.timeIntervalSince(evidence.start) / 60))
    }
}
