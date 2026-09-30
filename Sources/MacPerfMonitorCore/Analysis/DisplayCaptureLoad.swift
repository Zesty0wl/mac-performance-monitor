// SPDX-License-Identifier: MIT
import Foundation

/// A conservative correlation, not a measurement of input latency or proof of
/// an abandoned capture stream. Uses existing process readings only.
public enum DisplayCaptureLoad {
    public static let sustainedWindow: TimeInterval = 120
    public static let maximumGap: TimeInterval = 90
    public static let historyWindow = sustainedWindow + maximumGap

    private static let displayFloor = 70.0
    private static let helperFloor = 5.0
    private static let replayFloor = 1.0

    public struct Finding: Sendable, Equatable {
        public var helper: ProcessSample
        public var windowServerCPU: Double
        public var helperCPU: Double
        public var replayCPU: Double
    }

    /// Bounds the history read to the display service, replayd, and at most
    /// three known capture helpers. An idle helper alone asks for no history.
    public static func candidates(from processes: [ProcessSample], now: Date) -> [ProcessSample] {
        let fresh = processes.filter {
            let age = now.timeIntervalSince($0.timestamp)
            return age.isFinite && age >= 0 && age <= maximumGap
                && $0.cpuPercent.isFinite && $0.cpuPercent >= 0
        }
        guard
            let display = fresh.first(where: {
                $0.displayName == "WindowServer" && $0.cpuPercent >= displayFloor
            }),
            let replay = fresh.first(where: {
                $0.displayName == "replayd" && $0.cpuPercent >= replayFloor
            })
        else { return [] }
        let helpers = fresh.filter {
            isCaptureHelper($0) && $0.cpuPercent >= helperFloor
        }.sorted {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return $0.pid < $1.pid
        }.prefix(3)
        guard !helpers.isEmpty else { return [] }
        return [display, replay] + Array(helpers)
    }

    public static func analyze(
        processes: [ProcessSample], histories: [ProcessIdentity: [ProcessHistoryPoint]], now: Date
    ) -> Finding? {
        let selected = candidates(from: processes, now: now)
        guard selected.count >= 3 else { return nil }
        let display = selected[0]
        let replay = selected[1]
        for helper in selected.dropFirst(2) {
            let pair = [display, replay, helper]
            let trails = pair.compactMap {
                trail(for: $0, history: histories[$0.id] ?? [], now: now)
            }
            guard trails.count == pair.count else { continue }
            if let averages = simultaneousLoad(trails, now: now) {
                return Finding(
                    helper: helper, windowServerCPU: averages[0], helperCPU: averages[2],
                    replayCPU: averages[1])
            }
        }
        return nil
    }

    private static func isCaptureHelper(_ process: ProcessSample) -> Bool {
        // This service is shared by Computer Use, Computer History, and app
        // context. Its presence does not tell us which feature owns the stream.
        process.displayName == "SkyComputerUseService"
            || process.bundleID?.lowercased() == "com.openai.sky.cuaservice"
    }

    private struct Point {
        var date: Date
        var cpu: Double
    }

    private static func trail(
        for process: ProcessSample, history: [ProcessHistoryPoint], now: Date
    ) -> [Point]? {
        let cutoff = now.addingTimeInterval(-sustainedWindow)
        let earliest = cutoff.addingTimeInterval(-maximumGap)
        var byDate: [Date: Double] = [:]
        for point in history where point.date >= earliest && point.date <= process.timestamp {
            guard point.date.timeIntervalSince1970.isFinite,
                point.cpuPercent.isFinite && point.cpuPercent >= 0,
                !point.startsNewRun
            else { return nil }
            byDate[point.date] = point.cpuPercent
        }
        // The live row may not have reached the store yet. Do not count a
        // duplicate timestamp as fresh evidence or merge another PID lifetime.
        byDate[process.timestamp] = process.cpuPercent
        let points = byDate.map { Point(date: $0.key, cpu: $0.value) }.sorted { $0.date < $1.date }
        guard points.count >= 3,
            let first = points.lastIndex(where: { $0.date <= cutoff }),
            cutoff.timeIntervalSince(points[first].date) <= maximumGap
        else { return nil }
        return Array(points[first...])
    }

    /// Weight the intersection of the three timelines, rather than comparing
    /// independent averages that might describe different parts of the window.
    private static func simultaneousLoad(_ trails: [[Point]], now: Date) -> [Double]? {
        let cutoff = now.addingTimeInterval(-sustainedWindow)
        var boundaries: Set<Date> = [cutoff, now]
        for trail in trails {
            boundaries.formUnion(trail.map(\.date).filter { $0 > cutoff && $0 < now })
        }
        let edges = boundaries.sorted()
        let floors = [displayFloor, replayFloor, helperFloor]
        var indices = [0, 0, 0]
        var totals = [0.0, 0.0, 0.0]
        var busySeconds = 0.0
        for (start, end) in zip(edges, edges.dropFirst()) {
            let seconds = end.timeIntervalSince(start)
            var allBusy = true
            for index in trails.indices {
                let trail = trails[index]
                while indices[index] + 1 < trail.count && trail[indices[index] + 1].date <= start {
                    indices[index] += 1
                }
                let point = trail[indices[index]]
                guard point.date <= start, end.timeIntervalSince(point.date) <= maximumGap else {
                    return nil
                }
                totals[index] += point.cpu * seconds
                if point.cpu < floors[index] { allBusy = false }
            }
            if allBusy { busySeconds += seconds }
        }
        let averages = totals.map { $0 / sustainedWindow }
        guard busySeconds >= sustainedWindow * 0.8,
            zip(averages, floors).allSatisfy({ $0.0 >= $0.1 })
        else { return nil }
        return averages
    }
}
