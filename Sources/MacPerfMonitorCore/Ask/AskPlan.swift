import Foundation

/// When a question is about. The model picks one of these shapes from the
/// question; Swift turns it into exact dates, so "around 10am" always means the
/// same thing and never lands in the future.
public enum AskTimeSpec: Codable, Sendable, Equatable {
    /// The last few minutes up to now: "right now", "in the last hour".
    case recent(minutes: Int)
    /// Half an hour either side of a clock time: "at 10am", "around 3pm yesterday".
    case around(hour: Int, minute: Int, daysAgo: Int)
    /// A whole day, or today so far: "today", "yesterday".
    case day(daysAgo: Int)

    public static let `default` = AskTimeSpec.recent(minutes: 60)

    /// The exact interval, never in the future, at least five minutes long, and
    /// clipped to when recording began so a brief does not report hours of
    /// "missing" data from before the app existed.
    public func interval(
        now: Date, calendar: Calendar = .current, earliest: Date? = nil
    )
        -> DateInterval
    {
        var start: Date
        var end: Date
        switch self {
        case .recent(let minutes):
            let clamped = min(max(minutes, 5), 7 * 24 * 60)
            end = now
            start = now.addingTimeInterval(-Double(clamped) * 60)
        case .around(let hour, let minute, let daysAgo):
            let day = calendar.date(byAdding: .day, value: -max(0, daysAgo), to: now) ?? now
            var anchor =
                calendar.date(
                    bySettingHour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59),
                    second: 0,
                    of: day) ?? now
            // "At 3pm" asked at 10am means yesterday's 3pm, not a time to come.
            if anchor > now, daysAgo == 0 {
                anchor = calendar.date(byAdding: .day, value: -1, to: anchor) ?? anchor
            }
            start = anchor.addingTimeInterval(-30 * 60)
            end = min(now, anchor.addingTimeInterval(30 * 60))
        case .day(let daysAgo):
            let day = calendar.date(byAdding: .day, value: -max(0, daysAgo), to: now) ?? now
            start = calendar.startOfDay(for: day)
            end = min(now, calendar.date(byAdding: .day, value: 1, to: start) ?? now)
        }
        if let earliest, earliest > start, earliest < end.addingTimeInterval(-5 * 60) {
            start = earliest
        }
        if end.timeIntervalSince(start) < 5 * 60 { start = end.addingTimeInterval(-5 * 60) }
        return DateInterval(start: start, end: end)
    }
}

/// What a question is about, after Swift has checked the model's choices.
public struct AskPlan: Codable, Sendable, Equatable {
    public var areas: [AskArea]
    public var time: AskTimeSpec
    public var appName: String?

    public init(areas: [AskArea], time: AskTimeSpec = .default, appName: String? = nil) {
        self.areas = areas
        self.time = time
        self.appName = appName
    }

    /// Up to three distinct parts. A question the planner could not place gets
    /// the overall check, which looks at every part and names the worst.
    public func resolved() -> AskPlan {
        var seen = Set<AskArea>()
        var parts = areas.filter { $0 != .overall && seen.insert($0).inserted }
        if parts.isEmpty { parts = [.overall] }
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AskPlan(
            areas: Array(parts.prefix(3)), time: time,
            appName: (name?.isEmpty ?? true) ? nil : String(name!.prefix(60)))
    }
}
