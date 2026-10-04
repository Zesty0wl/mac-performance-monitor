// SPDX-License-Identifier: MIT
import Foundation

/// A conservative correlation, not a measurement of input latency or proof of
/// an abandoned capture stream. Uses existing process readings only.
///
/// The signal is WindowServer and replayd staying busy together: replayd is
/// the service behind ScreenCaptureKit, which nearly every current capture
/// tool uses (screen sharing in Teams and Zoom, OBS, Loom, QuickTime
/// recording, AI agents that watch the screen), so the two together mean
/// something is capturing the screen and it is costing the display service,
/// whoever owns the stream. A recognised capture helper that is busy over the
/// same window is named as the likely owner, but is never required.
public enum DisplayCaptureLoad {
    public static let sustainedWindow: TimeInterval = 120
    public static let maximumGap: TimeInterval = 90
    public static let historyWindow = sustainedWindow + maximumGap

    private static let displayFloor = 70.0
    private static let replayFloor = 1.0
    private static let helperFloor = 5.0

    public struct Finding: Sendable, Equatable {
        public var windowServer: ProcessSample
        public var replayd: ProcessSample
        public var windowServerCPU: Double
        public var replayCPU: Double
        /// A recognised capture helper that was busy over the same window,
        /// named as the likely owner of the stream. Nil when none was.
        public var helper: ProcessSample?
        public var helperCPU: Double?
    }

    /// Bounds the history read to the display service, replayd, and at most
    /// three busy known capture helpers. Nothing is read unless WindowServer
    /// and replayd are both busy in the live scan.
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
        return [display, replay] + Array(helpers)
    }

    public static func analyze(
        processes: [ProcessSample], histories: [ProcessIdentity: [ProcessHistoryPoint]], now: Date
    ) -> Finding? {
        let selected = candidates(from: processes, now: now)
        guard selected.count >= 2 else { return nil }
        let display = selected[0]
        let replay = selected[1]
        guard
            let displayTrail = trail(for: display, history: histories[display.id] ?? [], now: now),
            let replayTrail = trail(for: replay, history: histories[replay.id] ?? [], now: now),
            let averages = simultaneousLoad(
                [displayTrail, replayTrail], floors: [displayFloor, replayFloor], now: now)
        else { return nil }
        var finding = Finding(
            windowServer: display, replayd: replay, windowServerCPU: averages[0],
            replayCPU: averages[1], helper: nil, helperCPU: nil)
        // Attribution only: the first recognised helper whose load overlaps
        // the same window by the same rules. Its absence changes the wording,
        // not whether the card shows.
        for helper in selected.dropFirst(2) {
            guard
                let helperTrail = trail(
                    for: helper, history: histories[helper.id] ?? [], now: now),
                let withHelper = simultaneousLoad(
                    [displayTrail, replayTrail, helperTrail],
                    floors: [displayFloor, replayFloor, helperFloor], now: now)
            else { continue }
            finding.helper = helper
            finding.helperCPU = withHelper[2]
            break
        }
        return finding
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

    /// Weight the intersection of the timelines, rather than comparing
    /// independent averages that might describe different parts of the window.
    private static func simultaneousLoad(
        _ trails: [[Point]], floors: [Double], now: Date
    ) -> [Double]? {
        let cutoff = now.addingTimeInterval(-sustainedWindow)
        var boundaries: Set<Date> = [cutoff, now]
        for trail in trails {
            boundaries.formUnion(trail.map(\.date).filter { $0 > cutoff && $0 < now })
        }
        let edges = boundaries.sorted()
        var indices = Array(repeating: 0, count: trails.count)
        var totals = Array(repeating: 0.0, count: trails.count)
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
