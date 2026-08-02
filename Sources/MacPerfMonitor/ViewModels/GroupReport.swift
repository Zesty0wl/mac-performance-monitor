import Foundation
import MacPerfMonitorCore

/// Everything the Groups tab needs to render one group over a window: its
/// blended footprint score (% of device capacity), the per-member contributions
/// that sum to it, the combined timeline, and the energy aside. Built off the
/// main thread by `SamplerModel.loadGroupReport`.
struct GroupReport: Sendable {
    var device: GroupFootprint.Device
    var decomposition: GroupFootprint.Decomposition<String>
    /// The group's members, one row per program: a process that was quit and
    /// relaunched, and an app's many identical helper instances, are merged into
    /// a single member rather than listed once per PID. See `GroupMemberProgram`.
    var members: [GroupMemberProgram]
    var series: [GroupHistoryPoint]
    /// Summed windowed energy impact across members (reported beside the score,
    /// never folded into it).
    var totalEnergy: Double

    init(
        device: GroupFootprint.Device,
        decomposition: GroupFootprint.Decomposition<String> = .init(
            groupScore: 0, contributions: []),
        members: [GroupMemberProgram] = [],
        series: [GroupHistoryPoint] = [],
        totalEnergy: Double = 0
    ) {
        self.device = device
        self.decomposition = decomposition
        self.members = members
        self.series = series
        self.totalEnergy = totalEnergy
    }

    /// The honest group memory over the window: the time-average of the
    /// **concurrent** member footprint (the per-tick / per-bucket summed
    /// `series`), not the sum of each member's own average. A process that
    /// stopped and restarted several times in the window was resident only once
    /// at a time; summing per-member averages would multiply that single
    /// residency. Averaging the concurrent series counts only what was actually
    /// co-resident, so a long window does not double-count restarted processes.
    var averageFootprint: UInt64 {
        guard !series.isEmpty else { return 0 }
        let total = series.reduce(0.0) { $0 + Double($1.footprint) }
        return UInt64((total / Double(series.count)).rounded())
    }

    /// The honest group CPU over the window: the time-average of the concurrent
    /// member CPU (percent of one core; can exceed 100). Same anti-double-count
    /// reasoning as `averageFootprint`.
    var averageCPUPercent: Double {
        guard !series.isEmpty else { return 0 }
        return series.reduce(0.0) { $0 + $1.cpuPercent } / Double(series.count)
    }

    /// The headline blended footprint, 0…100 (% of this device's capacity),
    /// derived from the concurrent `series` so a process that restarted within
    /// the window is never counted more than once. Because the score is linear
    /// in CPU and memory, this equals the mean of `scorePoints()`, so the
    /// headline agrees with the score chart.
    var score: Double {
        GroupFootprint.score(
            cpuPercent: averageCPUPercent, physFootprint: averageFootprint, device: device)
    }

    /// The group's peak memory over the window: the highest combined member
    /// footprint reached at any single tick/bucket. Taken from the concurrent
    /// series (not a sum of per-member peaks), so members that peaked at
    /// different times are not added together.
    var peakFootprint: UInt64 {
        series.map(\.footprintPeak).max() ?? 0
    }

    /// The group's peak CPU over the window (percent of one core; can exceed
    /// 100): the highest combined member CPU reached at any single tick/bucket.
    var peakCPUPercent: Double {
        series.map(\.cpuPeakPercent).max() ?? 0
    }

    /// The peak blended footprint, 0…100 (% of device capacity), from the peak
    /// CPU and memory. An upper bound: the two peaks may fall at different
    /// moments, so this is the worst-case blend rather than one instant.
    var peakScore: Double {
        GroupFootprint.score(
            cpuPercent: peakCPUPercent, physFootprint: peakFootprint, device: device)
    }

    var memberCount: Int { members.count }
    var isEmpty: Bool { members.isEmpty }

    /// The per-bucket group score across the window, for the trend chart and the
    /// card sparkline. Uses the same linear blend as the headline. Pass
    /// `peak: true` for the per-bucket peak blend instead of the mean.
    func scorePoints(
        peak: Bool = false, weights: GroupFootprint.Weights = .default
    )
        -> [(date: Date, value: Double)]
    {
        series.map {
            (
                date: $0.date,
                value: GroupFootprint.score(
                    cpuPercent: peak ? $0.cpuPeakPercent : $0.cpuPercent,
                    physFootprint: peak ? $0.footprintPeak : $0.footprint,
                    device: device, weights: weights)
            )
        }
    }

    /// The contribution for a member program, if present.
    func contribution(for key: String) -> GroupFootprint.Contribution<String>? {
        decomposition.contributions.first { $0.id == key }
    }

    /// The heaviest contributing members, in the order the contribution bars show
    /// them. Backs the card subtitle, so a card names the programs that actually
    /// dominate the group rather than whichever happened to sort first.
    func topMembers(_ count: Int) -> [GroupMemberProgram] {
        let byKey = Dictionary(members.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return decomposition.contributions.prefix(count).compactMap { byKey[$0.id] }
    }
}
