import Foundation

/// User-configurable alert thresholds and toggles (PRD section 8.7). Every alert
/// is individually switchable with quiet defaults: critical-pressure and leak
/// alerts are on, while the swap and per-process ceiling alerts stay off until
/// the user opts into a threshold they care about.
public struct AlertConfig: Sendable, Equatable, Codable {
    public var criticalPressureEnabled: Bool
    public var swapEnabled: Bool
    public var swapThresholdBytes: UInt64
    public var processCeilingEnabled: Bool
    public var processCeilingBytes: UInt64
    public var leakEnabled: Bool
    /// Notify when total CPU stays above `highCPUThresholdPercent` for a
    /// sustained period. Off by default — high CPU is normal during real work.
    public var highCPUEnabled: Bool
    /// Total-CPU threshold (percent of capacity, 0...100) for the high-CPU alert.
    public var highCPUThresholdPercent: Int

    public init(
        criticalPressureEnabled: Bool = true,
        swapEnabled: Bool = false,
        swapThresholdBytes: UInt64 = 3 * 1024 * 1024 * 1024,
        processCeilingEnabled: Bool = false,
        processCeilingBytes: UInt64 = 8 * 1024 * 1024 * 1024,
        leakEnabled: Bool = true,
        highCPUEnabled: Bool = false,
        highCPUThresholdPercent: Int = 85
    ) {
        self.criticalPressureEnabled = criticalPressureEnabled
        self.swapEnabled = swapEnabled
        self.swapThresholdBytes = swapThresholdBytes
        self.processCeilingEnabled = processCeilingEnabled
        self.processCeilingBytes = processCeilingBytes
        self.leakEnabled = leakEnabled
        self.highCPUEnabled = highCPUEnabled
        self.highCPUThresholdPercent = highCPUThresholdPercent
    }

    /// Decode every field with a default so a config saved by an older build
    /// (missing the newer keys) still loads with its existing choices intact,
    /// rather than being discarded and reset. Encoding stays synthesised.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertConfig.default
        criticalPressureEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .criticalPressureEnabled)
            ?? d.criticalPressureEnabled
        swapEnabled = try c.decodeIfPresent(Bool.self, forKey: .swapEnabled) ?? d.swapEnabled
        swapThresholdBytes =
            try c.decodeIfPresent(UInt64.self, forKey: .swapThresholdBytes) ?? d.swapThresholdBytes
        processCeilingEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .processCeilingEnabled)
            ?? d.processCeilingEnabled
        processCeilingBytes =
            try c.decodeIfPresent(UInt64.self, forKey: .processCeilingBytes)
            ?? d.processCeilingBytes
        leakEnabled = try c.decodeIfPresent(Bool.self, forKey: .leakEnabled) ?? d.leakEnabled
        highCPUEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .highCPUEnabled) ?? d.highCPUEnabled
        highCPUThresholdPercent =
            try c.decodeIfPresent(Int.self, forKey: .highCPUThresholdPercent)
            ?? d.highCPUThresholdPercent
    }

    public static let `default` = AlertConfig()
}

/// One alert the engine decided to raise this tick. The app turns these into
/// user notifications; `id` is stable per logical alert so repeated deliveries
/// of the same condition replace rather than stack.
public struct Alert: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case criticalPressure
        case swap
        case processCeiling
        case leak
        case highCPU
    }

    public var kind: Kind
    public var title: String
    public var body: String
    public var identity: ProcessIdentity?
    public var date: Date

    public init(
        kind: Kind, title: String, body: String, identity: ProcessIdentity? = nil, date: Date
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.identity = identity
        self.date = date
    }

    public var id: String {
        switch kind {
        case .criticalPressure: return "pressure.critical"
        case .swap: return "swap.threshold"
        case .processCeiling: return "ceiling.\(identityKey)"
        case .leak: return "leak.\(identityKey)"
        case .highCPU: return "cpu.high"
        }
    }

    private var identityKey: String {
        guard let identity else { return "unknown" }
        return "\(identity.pid).\(Int(identity.startTime.timeIntervalSince1970))"
    }
}

/// Decides which alerts to raise from each tick (PRD sections 8.6–8.7). The
/// engine is edge-triggered with hysteresis so a sustained condition fires once,
/// not every two seconds: each alert re-arms only after the condition clearly
/// clears. State is held across calls, so one engine instance must be driven by
/// a single serial context (the sampler queue).
public final class AlertEngine {
    /// Fraction of a threshold a value must fall back below before its alert
    /// re-arms, damping oscillation around the threshold.
    private let rearmFraction = 0.8

    private var pressureArmed = true
    private var swapArmed = true
    private var ceilingFired: Set<ProcessIdentity> = []
    private var leakFired: Set<ProcessIdentity> = []
    private var cpuArmed = true
    /// When total CPU first crossed the threshold in the current high spell, so a
    /// brief spike does not alert — only one sustained past `sustainedCPUDuration`
    /// does. Nil while CPU is below the threshold. Time-based rather than a tick
    /// count, so it is unaffected by the sampling cadence.
    private var highCPUSince: Date?
    /// Conditions that are active after the most recent evaluation. Unlike the
    /// returned alerts, this remains populated until each condition recovers.
    public private(set) var activeKinds: Set<Alert.Kind> = []
    /// How long total CPU must stay at/above the threshold before alerting.
    private let sustainedCPUDuration: TimeInterval = 8

    public init() {}

    /// Evaluate one tick. `leakingProcesses` is supplied by the caller from the
    /// leak board (leak detection needs a series, not a single sample). Returns
    /// only the alerts that newly fired this tick.
    public func evaluate(
        system: SystemSample,
        processes: [ProcessSample],
        leakingProcesses: Set<ProcessIdentity> = [],
        config: AlertConfig = .default,
        cpu: CPUSample? = nil,
        now: Date = Date()
    ) -> [Alert] {
        var alerts: [Alert] = []
        evaluatePressure(system, config: config, now: now, into: &alerts)
        evaluateSwap(system, config: config, now: now, into: &alerts)
        evaluateCeiling(processes, config: config, now: now, into: &alerts)
        evaluateLeaks(
            processes, leakingProcesses: leakingProcesses, config: config, now: now, into: &alerts)
        evaluateCPU(cpu, config: config, now: now, into: &alerts)
        refreshActiveKinds()
        return alerts
    }

    /// Forget all edge state, so the next evaluation treats every condition as
    /// new. Used when alerting is reconfigured or sampling restarts.
    public func reset() {
        pressureArmed = true
        swapArmed = true
        ceilingFired.removeAll()
        leakFired.removeAll()
        cpuArmed = true
        highCPUSince = nil
        activeKinds.removeAll()
    }

    private func refreshActiveKinds() {
        var kinds: Set<Alert.Kind> = []
        if !pressureArmed { kinds.insert(.criticalPressure) }
        if !swapArmed { kinds.insert(.swap) }
        if !ceilingFired.isEmpty { kinds.insert(.processCeiling) }
        if !leakFired.isEmpty { kinds.insert(.leak) }
        if !cpuArmed { kinds.insert(.highCPU) }
        activeKinds = kinds
    }

    // MARK: - Critical pressure

    private func evaluatePressure(
        _ system: SystemSample, config: AlertConfig, now: Date, into alerts: inout [Alert]
    ) {
        guard config.criticalPressureEnabled else {
            pressureArmed = true
            return
        }
        switch system.pressureLevel {
        case .critical:
            if pressureArmed {
                pressureArmed = false
                alerts.append(
                    Alert(
                        kind: .criticalPressure,
                        title: "Memory pressure is critical",
                        body:
                            "Your Mac is under heavy memory pressure and is compressing and swapping to cope. Closing a few large apps will give it room.",
                        date: now))
            }
        case .normal:
            // Re-arm only once pressure has fully recovered, so it will not
            // re-fire while flapping between warning and critical.
            pressureArmed = true
        case .warning:
            break
        }
    }

    // MARK: - Swap threshold

    private func evaluateSwap(
        _ system: SystemSample, config: AlertConfig, now: Date, into alerts: inout [Alert]
    ) {
        guard config.swapEnabled else {
            swapArmed = true
            return
        }
        if system.swapUsed > config.swapThresholdBytes {
            if swapArmed {
                swapArmed = false
                alerts.append(
                    Alert(
                        kind: .swap,
                        title: "Swap is growing",
                        body:
                            "Swap has passed \(ByteFormat.string(config.swapThresholdBytes)). Sustained swapping under pressure can slow things down — consider freeing some memory.",
                        date: now))
            }
        } else if Double(system.swapUsed) < Double(config.swapThresholdBytes) * rearmFraction {
            swapArmed = true
        }
    }

    // MARK: - Per-process ceiling

    private func evaluateCeiling(
        _ processes: [ProcessSample], config: AlertConfig, now: Date, into alerts: inout [Alert]
    ) {
        guard config.processCeilingEnabled else {
            ceilingFired.removeAll()
            return
        }
        let ceiling = config.processCeilingBytes
        let rearmBelow = UInt64(Double(ceiling) * rearmFraction)

        // Keep a process "fired" only while it remains near the ceiling; drop it
        // once it falls back below the re-arm level or exits, so a later climb
        // alerts again.
        let stillElevated = Set(processes.filter { $0.physFootprint >= rearmBelow }.map(\.id))
        ceilingFired.formIntersection(stillElevated)

        for process in processes where process.footprintReadable && process.physFootprint > ceiling
        {
            guard !ceilingFired.contains(process.id) else { continue }
            ceilingFired.insert(process.id)
            alerts.append(
                Alert(
                    kind: .processCeiling,
                    title: "\(process.displayName) is using a lot of memory",
                    body:
                        "\(process.displayName) has passed \(ByteFormat.string(ceiling)) (now \(ByteFormat.string(process.physFootprint))).",
                    identity: process.id,
                    date: now))
        }
    }

    // MARK: - Leaks

    private func evaluateLeaks(
        _ processes: [ProcessSample], leakingProcesses: Set<ProcessIdentity>, config: AlertConfig,
        now: Date, into alerts: inout [Alert]
    ) {
        guard config.leakEnabled else {
            leakFired.removeAll()
            return
        }
        // Drop processes that have stopped leaking so a recurrence alerts again.
        leakFired.formIntersection(leakingProcesses)

        var names: [ProcessIdentity: String] = [:]
        for process in processes { names[process.id] = process.displayName }

        for identity in leakingProcesses where !leakFired.contains(identity) {
            leakFired.insert(identity)
            let name = names[identity] ?? "A process"
            alerts.append(
                Alert(
                    kind: .leak,
                    title: "Possible memory leak",
                    body:
                        "\(name) has been growing steadily and may be leaking memory. If it keeps climbing, restarting it will reclaim the memory.",
                    identity: identity,
                    date: now))
        }
    }

    // MARK: - Sustained high CPU

    /// Fire once when total CPU has stayed at/above the threshold for several
    /// consecutive ticks, so a brief spike is ignored and only a sustained climb
    /// alerts. Re-arms after CPU falls back below the re-arm fraction.
    private func evaluateCPU(
        _ cpu: CPUSample?, config: AlertConfig, now: Date, into alerts: inout [Alert]
    ) {
        guard config.highCPUEnabled, let cpu else {
            cpuArmed = true
            highCPUSince = nil
            return
        }
        let percent = cpu.totalUsage * 100
        let threshold = Double(config.highCPUThresholdPercent)
        if percent >= threshold {
            let since = highCPUSince ?? now
            highCPUSince = since
            if cpuArmed && now.timeIntervalSince(since) >= sustainedCPUDuration {
                cpuArmed = false
                alerts.append(
                    Alert(
                        kind: .highCPU,
                        title: "CPU has been busy",
                        body:
                            "Total CPU has stayed above \(config.highCPUThresholdPercent)% for a sustained period. If this is unexpected, the top CPU process is the place to look.",
                        date: now))
            }
        } else {
            highCPUSince = nil
            if percent < threshold * rearmFraction { cpuArmed = true }
        }
    }
}
