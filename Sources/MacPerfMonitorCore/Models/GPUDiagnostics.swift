import Foundation

/// The GPU's clock table: the frequency of each performance state, from the
/// power manager's `voltage-states9` property in the IORegistry (the same
/// table macmon and asitop read). Each entry is a little-endian pair of
/// UInt32 values, frequency in Hz then voltage in mV; the first entry is the
/// OFF state at 0 Hz. IOReport's `GPUPH` channel names the states OFF, P1,
/// P2, ..., and Pn is the table's nth non-zero entry: under full load an M3
/// Pro sat in P13, the table's 1,380 MHz entry and the chip's rated maximum.
public struct GPUFrequencyTable: Sendable, Equatable {
    /// Frequency per P-state in MHz, P1 first.
    public let megahertz: [Double]

    public init?(megahertz: [Double]) {
        guard megahertz.count >= 2, megahertz.count <= 64,
            megahertz.allSatisfy({ $0.isFinite && (50...10_000).contains($0) })
        else { return nil }
        self.megahertz = megahertz
    }

    /// Decode the raw `voltage-states9` bytes.
    public init?(voltageStates data: Data) {
        guard data.count >= 16, data.count % 8 == 0, data.count <= 8 * 65 else { return nil }
        let bytes = [UInt8](data)
        var values: [Double] = []
        for offset in stride(from: 0, to: bytes.count, by: 8) {
            let hertz =
                UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            // The leading 0 Hz entry is the OFF state, not a P-state.
            if hertz == 0 {
                guard values.isEmpty else { return nil }
                continue
            }
            values.append(Double(hertz) / 1_000_000)
        }
        self.init(megahertz: values)
    }

    public var maximumMHz: Double { megahertz.max() ?? 0 }

    /// The frequency of a state named "P<n>", or nil for OFF, unknown names
    /// and indexes past the table.
    public func frequency(ofState name: String) -> Double? {
        let upper = name.uppercased()
        guard upper.hasPrefix("P"), let index = Int(upper.dropFirst()), index >= 1,
            index <= megahertz.count
        else { return nil }
        return megahertz[index - 1]
    }

    /// The residency-weighted mean clock while the GPU was awake, the figure
    /// powermetrics reports as the GPU's active frequency. nil when the GPU
    /// was off for the whole interval or when more than 1% of the awake time
    /// sat in a state the table cannot name.
    public func effectiveMHz(states: [GPUPerformanceState]) -> Double? {
        var weighted = 0.0
        var mapped = 0.0
        var awake = 0.0
        for state in states where state.name.uppercased() != "OFF" {
            guard state.residency.isFinite, state.residency > 0 else { continue }
            awake += state.residency
            if let mhz = frequency(ofState: state.name) {
                weighted += mhz * state.residency
                mapped += state.residency
            }
        }
        guard awake > 0, mapped > 0, mapped >= awake * 0.99 else { return nil }
        return weighted / mapped
    }
}

/// The three kinds of work the GPU's firmware queues separately.
public enum GPUEngine: String, Sendable, Codable, CaseIterable {
    /// Compute dispatches (CDM): AI inference, MLX, PyTorch MPS, Core ML on
    /// the GPU, video filters.
    case compute
    /// Fragment shading (FRG): drawing pixels for the display, games and UI.
    case fragment
    /// Vertex work and tiling (GTP/TA): the geometry half of rendering.
    case geometry

    /// The prefix of the engine's `vChannel Usage` subgroup.
    var submissionPrefix: String {
        switch self {
        case .compute: return "CDM"
        case .fragment: return "FRG"
        case .geometry: return "GTP"
        }
    }

    /// The prefix of the engine's `Context Switch Latencies` channels.
    var contextSwitchPrefix: String {
        switch self {
        case .compute: return "CL"
        case .fragment: return "3D"
        case .geometry: return "TA"
        }
    }
}

/// Context switches on one engine over an interval and how long they took,
/// from the driver's latency histogram (buckets of `< 100 us`, `< 200 us`,
/// and so on up to `>= 40000 us`).
public struct GPUContextSwitches: Sendable, Equatable, Codable {
    public struct Bucket: Sendable, Equatable, Codable {
        /// Exclusive upper bound in microseconds; nil for the open top bucket.
        public let upperBoundMicroseconds: Double?
        public let count: Int64

        public init(upperBoundMicroseconds: Double?, count: Int64) {
            self.upperBoundMicroseconds = upperBoundMicroseconds
            self.count = count
        }
    }

    public let buckets: [Bucket]

    public init?(buckets: [Bucket]) {
        guard !buckets.isEmpty, buckets.allSatisfy({ $0.count >= 0 }) else { return nil }
        self.buckets = buckets.sorted {
            ($0.upperBoundMicroseconds ?? .infinity) < ($1.upperBoundMicroseconds ?? .infinity)
        }
    }

    public var total: Int64 { buckets.reduce(0) { $0 + $1.count } }

    /// The bound 95% of switches finished within: the upper edge of the
    /// bucket where the running total reaches 95%. nil when there were no
    /// switches; `.infinity` when that bucket is the open top one.
    public var percentile95Microseconds: Double? {
        let total = total
        guard total > 0 else { return nil }
        let target = Double(total) * 0.95
        var running: Int64 = 0
        for bucket in buckets {
            running += bucket.count
            if Double(running) >= target { return bucket.upperBoundMicroseconds ?? .infinity }
        }
        return .infinity
    }

    /// Parse a channel name such as
    /// `3D CtxSwitch Latency Histogram Bucket 4 (<500us)` into the engine
    /// prefix and the bucket's bound. Returns nil for anything else.
    static func parse(channel name: String) -> (prefix: String, upperBound: Double?)? {
        guard let marker = name.range(of: " CtxSwitch Latency Histogram Bucket ") else {
            return nil
        }
        let prefix = String(name[..<marker.lowerBound])
        guard let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"),
            open < close
        else { return nil }
        let bound = name[name.index(after: open)..<close]
        if bound.hasPrefix(">=") { return (prefix, nil) }
        guard bound.hasPrefix("<"), bound.hasSuffix("us"),
            let value = Double(bound.dropFirst().dropLast(2)), value > 0
        else { return nil }
        return (prefix, value)
    }
}

/// Per-engine activity over the latest interval.
public struct GPUEngineActivity: Sendable, Equatable, Codable {
    /// Work items the firmware queued on this engine, per second.
    public var submissionsPerSecond: Double?
    public var contextSwitches: GPUContextSwitches?
    public var contextSwitchesPerSecond: Double?

    public init(
        submissionsPerSecond: Double? = nil, contextSwitches: GPUContextSwitches? = nil,
        contextSwitchesPerSecond: Double? = nil
    ) {
        self.submissionsPerSecond = submissionsPerSecond
        self.contextSwitches = contextSwitches
        self.contextSwitchesPerSecond = contextSwitchesPerSecond
    }
}

/// What the GPU's power controller was doing and what work it ran, over the
/// latest IOReport interval. Everything here is read without root.
public struct GPUDiagnostics: Sendable, Equatable, Codable {
    /// Residency of the power controller's states (`PWRCTRL`): why the GPU
    /// is clocked the way it is. Non-zero states only, largest first.
    public var controllerStates: [GPUPerformanceState] = []
    /// Residency of the firmware's "lost performance" reason codes
    /// (`PMU_RC`), the NONE state excluded: time a thermal or electrical
    /// limit on a GPU cluster or the fabric held performance back. Empty
    /// means nothing was lost.
    public var lostPerformance: [GPUPerformanceState] = []
    /// True when the lost-performance channel was read at all, so an empty
    /// list means "none" rather than "unknown".
    public var lostPerformanceKnown = false
    public var engines: [GPUEngine: GPUEngineActivity] = [:]
    /// Times per second the GPU woke from idle to run work.
    public var wakeupsPerSecond: Double?
    /// Mean length of a busy period and of an idle gap, in milliseconds.
    public var meanBusyMilliseconds: Double?
    public var meanIdleMilliseconds: Double?

    public init() {}

    /// The power controller's share of time limiting the GPU rather than
    /// following demand: the thermal, power, current and performance-limit
    /// states. 0...100, nil when the channel was not read.
    public var limitedResidency: Double? {
        guard !controllerStates.isEmpty else { return nil }
        return controllerStates.filter { GPUControllerState($0.name).isLimit }
            .reduce(0) { $0 + $1.residency }
    }

    /// Total lost-performance residency, 0...100.
    public var lostResidency: Double? {
        guard lostPerformanceKnown else { return nil }
        return min(100, lostPerformance.reduce(0) { $0 + $1.residency })
    }
}

/// A `PWRCTRL` state with a reader-facing meaning. The driver's names are
/// abbreviations; only the ones whose meaning is clear get a description,
/// the rest are shown under their own name.
public struct GPUControllerState: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case idle, demand, deadline, boost, thermal, power, performanceLimit, other
    }

    public let name: String
    public let kind: Kind

    public init(_ name: String) {
        self.name = name
        switch name.uppercased() {
        // Only names whose meaning is plain from the driver's own wording
        // (and, for PERF and IDLE_OFF, from watching them track load) are
        // classified. FAST_DIE, SE, CORE_EFF, TURB0, AVMR, PMULOOP and UT
        // stay `.other` and are shown under their own names.
        case "IDLE_OFF", "STANDBY": kind = .idle
        case "PERF", "AVGPERF": kind = .demand
        case "DEADLINE", "DEADAWAR": kind = .deadline
        case "PRFBOOST": kind = .boost
        case "CLTMLIMI": kind = .thermal
        case "POWER", "PWR_ZONE", "PPMLIMIT", "PPMTARGE": kind = .power
        case "PRFLIMIT": kind = .performanceLimit
        default: kind = .other
        }
    }

    /// True for the states where a limit, not demand, set the clock.
    public var isLimit: Bool {
        switch kind {
        case .thermal, .power, .performanceLimit: return true
        default: return false
        }
    }
}

/// A `PMU_RC` reason code (`GPU3_TH`, `AFR0_EMT`, `FAB0_TH`) split into the
/// block it applies to and the kind of limit.
public struct GPULostPerformanceReason: Sendable, Equatable {
    public enum Limit: Sendable, Equatable { case thermal, electrical, other }

    public let block: String
    public let limit: Limit

    public init(_ name: String) {
        let parts = name.uppercased().split(separator: "_", maxSplits: 1).map(String.init)
        block = parts.first ?? name
        switch parts.count > 1 ? parts[1] : "" {
        case "TH": limit = .thermal
        case "EMT": limit = .electrical
        default: limit = .other
        }
    }
}

/// GPU fault and limit counters since boot, from IOReport's `Issue Counts`,
/// `UV Warn State` and `THM Counters` subgroups. Zero is the healthy value.
public struct GPUHealthCounters: Sendable, Equatable, Codable {
    /// GPU firmware restarts.
    public var restarts: Int64?
    /// Work the driver killed, usually after a timeout or a fault, by engine.
    public var killedWork: [GPUEngine: Int64] = [:]
    /// Render passes that failed for lack of memory.
    public var memorylessRenderFailures: Int64?
    /// Under-voltage warnings.
    public var undervoltageWarnings: Int64?
    /// Thermal management activations.
    public var thermalActivations: Int64?

    public init() {}

    public var killedTotal: Int64? {
        killedWork.isEmpty ? nil : killedWork.values.reduce(0, +)
    }

    /// True when every counter that was read is zero.
    public var isClean: Bool {
        let values =
            [restarts, memorylessRenderFailures, undervoltageWarnings, thermalActivations]
            .compactMap { $0 } + Array(killedWork.values)
        return !values.isEmpty && values.allSatisfy { $0 == 0 }
    }
}

/// How much unified memory the GPU may wire, the ceiling that decides how
/// large a model a Metal runtime can load.
public struct GPUMemoryLimit: Sendable, Equatable, Codable {
    public let bytes: UInt64
    /// True when `iogpu.wired_limit_mb` overrides macOS's default.
    public let isCustom: Bool

    public init(bytes: UInt64, isCustom: Bool) {
        self.bytes = bytes
        self.isCustom = isCustom
    }

    /// The effective limit: the `iogpu.wired_limit_mb` override when it is
    /// set, otherwise Metal's recommended working set. nil when neither is
    /// known or the values are implausible.
    public static func resolve(
        wiredLimitMB: Int?, recommendedBytes: UInt64?, physicalMemory: UInt64
    )
        -> GPUMemoryLimit?
    {
        if let wiredLimitMB, wiredLimitMB > 0 {
            let bytes = UInt64(wiredLimitMB) * 1_048_576
            guard physicalMemory == 0 || bytes <= physicalMemory else { return nil }
            return GPUMemoryLimit(bytes: bytes, isCustom: true)
        }
        guard let recommendedBytes, recommendedBytes > 0,
            physicalMemory == 0 || recommendedBytes <= physicalMemory
        else { return nil }
        return GPUMemoryLimit(bytes: recommendedBytes, isCustom: false)
    }
}

extension GPUSample {
    /// Label the clock states with their MHz and set the mean clock.
    ///
    /// The IORegistry frequency table is the source whenever the chip
    /// publishes one: it was verified against the chip's rated top clock under
    /// load, and it names every state on every tick, so the bars and the clock
    /// never depend on which states a frame happened to use. The helper's
    /// powermetrics reading is only a fallback for chips without a table: its
    /// per-state list labels the states when it covers every state that has
    /// time, and its active frequency is the clock when the list cannot be
    /// used. (Preferring the helper while a table existed made the clock
    /// vanish and the bar count change on ticks where the helper's list did
    /// not match, seen on build 307.)
    public mutating func resolveClock(
        table: GPUFrequencyTable?, helper: ANEPowerReading?, now: Date = Date()
    ) {
        let fresh = helper.flatMap { $0.isFresh(at: now) ? $0 : nil }
        var labels = table
        var fromHelper = false
        if labels == nil, let list = fresh?.gpuStateFrequenciesMHz,
            let helperTable = GPUFrequencyTable(megahertz: list),
            (performanceStates ?? []).allSatisfy({
                $0.residency <= 0 || helperTable.frequency(ofState: $0.name) != nil
            })
        {
            labels = helperTable
            fromHelper = true
        }
        if let labels, let states = performanceStates {
            // States past the end of the table (P14 and P15 on an M3 Pro's
            // 13-entry table) are dropped while empty; one with residency
            // stays, under its own name, so no time goes missing.
            performanceStates = states.compactMap {
                var state = $0
                state.frequencyMHz = labels.frequency(ofState: $0.name)
                return state.frequencyMHz == nil && state.residency <= 0 ? nil : state
            }
        }
        maximumClockMHz = labels?.maximumMHz
        if let labels, let states = performanceStates,
            let effective = labels.effectiveMHz(states: states)
        {
            clockMHz = effective
            clockSource = fromHelper ? .powermetrics : .frequencyTable
        } else if labels == nil, let frequency = fresh?.gpuFrequencyMHz,
            (activeResidency ?? 100) > 0
        {
            clockMHz = frequency
            clockSource = .powermetrics
        } else {
            clockMHz = nil
            clockSource = nil
        }
    }
}
