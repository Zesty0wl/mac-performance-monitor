import Foundation

/// The blended "footprint score" for a process group: a single 0…100 figure
/// expressing the group's combined CPU + memory cost as a percentage of the
/// device's capacity, decomposable to each member's exact contribution.
///
/// The blend is **linear** in both CPU and memory, so it is additive: scoring a
/// group's summed CPU/footprint equals summing the per-member scores. That is
/// what lets "Security & MDM = 9% of this device" break down exactly into
/// "CrowdStrike 48%, Jamf 31%, …". Energy is deliberately not part of the blend;
/// it is reported alongside. Pure + unit-tested.
public enum GroupFootprint {
    /// Relative weighting of CPU vs. memory in the blend. Defaults to an even
    /// split; kept in one place so it can be tuned (or surfaced in Settings)
    /// later without touching call sites.
    public struct Weights: Sendable, Equatable {
        public var cpu: Double
        public var memory: Double

        public init(cpu: Double, memory: Double) {
            self.cpu = cpu
            self.memory = memory
        }

        public static let `default` = Weights(cpu: 0.5, memory: 0.5)
    }

    /// The device's capacity constants. Read live from `CPUTopology.current`
    /// and `SystemSample.totalRAM`; constant per machine.
    public struct Device: Sendable, Equatable {
        public var cores: Int
        public var totalRAM: UInt64

        public init(cores: Int, totalRAM: UInt64) {
            self.cores = cores
            self.totalRAM = totalRAM
        }
    }

    /// The blended footprint figure (0…100, share of device capacity) for one
    /// process — or for a group, when passed the members' summed CPU/footprint.
    ///
    /// - Parameters:
    ///   - cpuPercent: CPU as a percentage of one core (Activity-Monitor style;
    ///     can exceed 100 for multi-threaded work or a summed group).
    ///   - physFootprint: physical memory footprint in bytes.
    public static func score(
        cpuPercent: Double,
        physFootprint: UInt64,
        device: Device,
        weights: Weights = .default
    ) -> Double {
        guard device.cores > 0, device.totalRAM > 0 else { return 0 }
        let cpuShare = cpuPercent / 100 / Double(device.cores)
        let memShare = Double(physFootprint) / Double(device.totalRAM)
        return (weights.cpu * cpuShare + weights.memory * memShare) * 100
    }

    /// One member's slice of a group's blended footprint.
    public struct Contribution<ID: Hashable & Sendable>: Sendable, Equatable {
        public var id: ID
        /// This member's own footprint figure (0…100).
        public var score: Double
        /// `score / groupScore`, 0…1 (0 when the group score is 0).
        public var share: Double

        public init(id: ID, score: Double, share: Double) {
            self.id = id
            self.score = score
            self.share = share
        }
    }

    /// A group's blended score plus its members' contributions, descending.
    public struct Decomposition<ID: Hashable & Sendable>: Sendable, Equatable {
        public var groupScore: Double
        public var contributions: [Contribution<ID>]

        public init(groupScore: Double, contributions: [Contribution<ID>]) {
            self.groupScore = groupScore
            self.contributions = contributions
        }
    }

    /// Decompose a group into per-member contributions. `groupScore` is the sum
    /// of the member scores (which, by linearity, equals scoring the summed
    /// CPU/footprint), and each `share` is exact — the contributions' shares sum
    /// to 1 (modulo floating point) whenever the group score is non-zero.
    public static func decompose<ID>(
        members: [(id: ID, cpuPercent: Double, physFootprint: UInt64)],
        device: Device,
        weights: Weights = .default
    ) -> Decomposition<ID> {
        let scored = members.map {
            (
                id: $0.id,
                score: score(
                    cpuPercent: $0.cpuPercent, physFootprint: $0.physFootprint,
                    device: device, weights: weights)
            )
        }
        let total = scored.reduce(0.0) { $0 + $1.score }
        let contributions =
            scored
            .map {
                Contribution(id: $0.id, score: $0.score, share: total > 0 ? $0.score / total : 0)
            }
            .sorted { $0.score > $1.score }
        return Decomposition(groupScore: total, contributions: contributions)
    }

    /// Decompose a group from its members' windowed aggregates, using each
    /// member's average CPU and average footprint. Convenience over the generic
    /// `decompose`, returning contributions keyed by process identity.
    public static func decompose(
        consumers: [ProcessConsumer],
        device: Device,
        weights: Weights = .default
    ) -> Decomposition<ProcessIdentity> {
        decompose(
            members: consumers.map {
                (id: $0.identity, cpuPercent: $0.averageCPU, physFootprint: $0.averageFootprint)
            },
            device: device, weights: weights)
    }

    /// Decompose a group whose members have been merged one row per program
    /// (restarts and concurrent instances of the same executable folded together;
    /// see `GroupMemberProgram`), returning contributions keyed by merge key.
    public static func decompose(
        programs: [GroupMemberProgram],
        device: Device,
        weights: Weights = .default
    ) -> Decomposition<String> {
        decompose(
            members: programs.map {
                (id: $0.key, cpuPercent: $0.averageCPU, physFootprint: $0.averageFootprint)
            },
            device: device, weights: weights)
    }
}
