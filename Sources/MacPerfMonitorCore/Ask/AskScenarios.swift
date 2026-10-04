import Foundation

/// Made-up but realistic situations, built through the real brief builder, for
/// judging the model's answers by eye (`--ask-eval`) without touching anyone's
/// recorded history.
public enum AskScenario: String, CaseIterable, Sendable {
    case idle, busyBuild, memoryGrowth, fullDisk, batteryDrain, hotAndLoud

    public var summary: String {
        switch self {
        case .idle: return "A quiet Mac with nothing unusual."
        case .busyBuild: return "Xcode compiling for an hour: processor near full, fans up."
        case .memoryGrowth: return "Task Manager's memory growing steadily; pressure still low."
        case .fullDisk: return "Startup disk nearly full."
        case .batteryDrain:
            return "On battery, draining about 20% an hour, Chrome the biggest user."
        case .hotAndLoud: return "A game keeping graphics and processor busy; macOS managing heat."
        }
    }

    /// Every part's brief for the last hour, plus the overall one.
    public func briefs(now: Date = Date()) -> [AskArea: AreaBrief] {
        let start = now.addingTimeInterval(-3600)
        var parts: [AskArea: AreaBrief] = [:]
        for area in AskArea.parts {
            var input = AskBriefInputs(area: area, start: start, end: now, now: now)
            input.coreCount = 11
            input.points = points(end: now) { configure(&$0, $1) }
            input.baseline = points(end: start, minutes: 7 * 24 * 60, every: 3600) { point, _ in
                point.cpuLoad = 0.18
                point.pressurePercent = 14
                point.gpuUtilization = 6
                point.diskUtilizationPercent = 4
                point.cpuDieC = 48
            }
            var live = AskLiveReading(date: now)
            if let last = input.points.last {
                live.cpuPercent = last.cpuLoad * 100
                live.pressurePercent = last.pressurePercent
                live.gpuPercent = last.gpuUtilization
                live.thermal = last.thermalPressure
                live.fanRPM = last.fanRPM
                live.batteryCharge = last.batteryCharge
                live.onExternalPower = self != .batteryDrain
            }
            live.bootTotalBytes = 494_000_000_000
            live.bootFreeBytes = self == .fullDisk ? 6_200_000_000 : 182_000_000_000
            input.live = live
            input.apps = apps(for: area)
            if area == .memory, self == .memoryGrowth {
                input.growth = [
                    AskGrowth(
                        identity: identity(3), name: "Task Manager", growthBytes: 466_000_000,
                        durationSeconds: 44 * 60)
                ]
            }
            parts[area] = AskBriefBuilder.brief(input)
        }
        parts[.overall] = AskBriefBuilder.overall(
            AskArea.parts.compactMap { parts[$0] }, start: start, end: now)
        return parts
    }

    private func configure(_ point: inout SystemHistoryPoint, _ index: Int) {
        point.cpuLoad = 0.12
        point.pressurePercent = 12
        point.gpuUtilization = 4
        point.aneTimeMillisecondsPerSecond = 5
        point.diskUtilizationPercent = 3
        point.networkInBytesPerSec = 40_000
        point.networkOutBytesPerSec = 8_000
        point.thermalPressure = .nominal
        point.cpuDieC = 46
        point.fanRPM = 0
        point.batteryCharge = 92
        switch self {
        case .idle, .fullDisk: break
        case .busyBuild:
            point.cpuLoad = index % 7 == 0 ? 0.62 : 0.93
            point.cpuDieC = 94
            point.fanRPM = 4200
            point.thermalPressure = index > 40 ? .fair : .nominal
        case .memoryGrowth:
            point.pressurePercent = 16 + Double(index) / 10
        case .batteryDrain:
            point.cpuLoad = 0.35
            point.batteryCharge = 82 - Double(index) / 3
        case .hotAndLoud:
            point.cpuLoad = 0.58
            point.gpuUtilization = 88
            point.cpuDieC = 97
            point.fanRPM = 5600
            point.thermalPressure = index > 20 ? .fair : .nominal
        }
    }

    private func apps(for area: AskArea) -> [AskAppUsage] {
        switch (self, area) {
        case (.busyBuild, .processor):
            return [
                AskAppUsage(identity: identity(1), name: "swift-frontend", average: 620),
                AskAppUsage(identity: identity(2), name: "Xcode", average: 140),
            ]
        case (.batteryDrain, .processor), (.batteryDrain, .energy):
            return [
                AskAppUsage(
                    identity: identity(4), name: "Google Chrome",
                    average: area == .energy ? 48 : 190),
                AskAppUsage(
                    identity: identity(5), name: "Slack", average: area == .energy ? 12 : 30),
            ]
        case (.hotAndLoud, .graphics):
            return [AskAppUsage(identity: identity(6), name: "Baldur's Gate 3", average: 81)]
        case (.hotAndLoud, .processor):
            return [AskAppUsage(identity: identity(6), name: "Baldur's Gate 3", average: 410)]
        case (_, .memory):
            return [
                AskAppUsage(identity: identity(4), name: "Google Chrome", average: 3_100_000_000),
                AskAppUsage(identity: identity(3), name: "Task Manager", average: 620_000_000),
            ]
        default: return []
        }
    }

    private func identity(_ pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func points(
        end: Date, minutes: Int = 60, every seconds: Double = 60,
        _ configure: (inout SystemHistoryPoint, Int) -> Void
    ) -> [SystemHistoryPoint] {
        let count = Int(Double(minutes) * 60 / seconds)
        return (0..<count).map { index in
            var point = SystemHistoryPoint(
                sample: SystemSample(
                    timestamp: end.addingTimeInterval(-Double(count - index) * seconds),
                    totalRAM: 18_000_000_000, free: 1_000_000_000, active: 6_000_000_000,
                    inactive: 5_000_000_000, wired: 3_000_000_000, speculative: 0,
                    compressed: 2_000_000_000, appMemory: 6_000_000_000, cachedFiles: 4_000_000_000,
                    swapTotal: 4_000_000_000, swapUsed: 1_000_000_000, pressureLevel: .normal,
                    pressurePercent: 12, pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0
                ))
            point.bucketDuration = seconds
            configure(&point, index)
            return point
        }
    }
}
