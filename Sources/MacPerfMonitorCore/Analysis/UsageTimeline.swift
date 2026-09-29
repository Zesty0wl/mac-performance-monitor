import Foundation

public enum UsageTimeline {
    public enum Kind: String, CaseIterable, Sendable {
        case observedRunning
        case appUsage
        case mediaUsage
    }

    public struct Interval: Identifiable, Hashable, Sendable {
        public var kind: Kind
        public var start: Date
        public var end: Date

        public var id: Self { self }
        public var duration: TimeInterval { end.timeIntervalSince(start) }

        public init(kind: Kind, start: Date, end: Date) {
            self.kind = kind
            self.start = start
            self.end = end
        }
    }

    public struct ObservedHistory: Sendable {
        public var intervals: [Interval]
        public var bucketSeconds: TimeInterval

        public init(intervals: [Interval], bucketSeconds: TimeInterval) {
            self.intervals = intervals
            self.bucketSeconds = bucketSeconds
        }
    }

    public static func normalized(
        _ intervals: [Interval], within range: ClosedRange<Date>
    ) -> [Interval] {
        var result: [Interval] = []
        for kind in Kind.allCases {
            let ordered = intervals.compactMap { interval -> Interval? in
                guard interval.kind == kind,
                    interval.start.timeIntervalSince1970.isFinite,
                    interval.end.timeIntervalSince1970.isFinite
                else { return nil }
                let start = max(interval.start, range.lowerBound)
                let end = min(interval.end, range.upperBound)
                guard start < end else { return nil }
                return Interval(kind: kind, start: start, end: end)
            }.sorted {
                $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
            }
            for interval in ordered {
                if let previous = result.last,
                    previous.kind == kind, interval.start <= previous.end
                {
                    result[result.count - 1].end = max(previous.end, interval.end)
                } else {
                    result.append(interval)
                }
            }
        }
        return result
    }
}
