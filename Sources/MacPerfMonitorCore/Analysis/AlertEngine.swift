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
    /// Notify when GPU utilisation stays above `highGPUThresholdPercent` for a
    /// sustained period: an AI workload, a stuck render loop, or a game left
    /// running. Off by default like high CPU.
    public var highGPUEnabled: Bool
    public var highGPUThresholdPercent: Int
    /// Total-CPU threshold (percent of capacity, 0...100) for the high-CPU alert.
    public var highCPUThresholdPercent: Int
    /// Notify when macOS's thermal pressure stays at serious or critical (the
    /// throttling states) for a sustained period, naming the top CPU process.
    /// Off by default: fanless Macs throttle routinely under real work.
    public var thermalEnabled: Bool
    /// Notify when one program keeps the processor busy for an hour or more,
    /// such as a part of macOS stuck in a loop. On by default: unlike total
    /// CPU, this is rarely normal. See `SustainedCPU`.
    public var sustainedProcessCPUEnabled: Bool
    public var observeGrowthOnly: Bool
    public var accessoryBatteryEnabled: Bool
    public var accessoryBatteryThresholdPercent: Int

    /// Whether any sampler-driven alert is switched on. Accessory batteries
    /// use a separate minute-limited reader, not the system sampling tick.
    public var anyEnabled: Bool {
        criticalPressureEnabled || swapEnabled || processCeilingEnabled || leakEnabled
            || highCPUEnabled || highGPUEnabled || thermalEnabled || sustainedProcessCPUEnabled
    }

    public init(
        criticalPressureEnabled: Bool = true,
        swapEnabled: Bool = false,
        swapThresholdBytes: UInt64 = 3 * 1024 * 1024 * 1024,
        processCeilingEnabled: Bool = false,
        processCeilingBytes: UInt64 = 8 * 1024 * 1024 * 1024,
        leakEnabled: Bool = true,
        highCPUEnabled: Bool = false,
        highCPUThresholdPercent: Int = 85,
        highGPUEnabled: Bool = false,
        highGPUThresholdPercent: Int = 85,
        thermalEnabled: Bool = false,
        sustainedProcessCPUEnabled: Bool = true,
        observeGrowthOnly: Bool = false,
        accessoryBatteryEnabled: Bool = false,
        accessoryBatteryThresholdPercent: Int = 20
    ) {
        self.criticalPressureEnabled = criticalPressureEnabled
        self.swapEnabled = swapEnabled
        self.swapThresholdBytes = swapThresholdBytes
        self.processCeilingEnabled = processCeilingEnabled
        self.processCeilingBytes = processCeilingBytes
        self.leakEnabled = leakEnabled
        self.highCPUEnabled = highCPUEnabled
        self.highCPUThresholdPercent = highCPUThresholdPercent
        self.highGPUEnabled = highGPUEnabled
        self.highGPUThresholdPercent = highGPUThresholdPercent
        self.thermalEnabled = thermalEnabled
        self.sustainedProcessCPUEnabled = sustainedProcessCPUEnabled
        self.observeGrowthOnly = observeGrowthOnly
        self.accessoryBatteryEnabled = accessoryBatteryEnabled
        self.accessoryBatteryThresholdPercent = min(50, max(5, accessoryBatteryThresholdPercent))
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
        highGPUEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .highGPUEnabled) ?? d.highGPUEnabled
        highGPUThresholdPercent =
            try c.decodeIfPresent(Int.self, forKey: .highGPUThresholdPercent)
            ?? d.highGPUThresholdPercent
        thermalEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .thermalEnabled) ?? d.thermalEnabled
        // Settings saved before this rule existed: on, unless every
        // default-on alert was turned off, which says "no alerts".
        sustainedProcessCPUEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .sustainedProcessCPUEnabled)
            ?? (criticalPressureEnabled || leakEnabled)
        observeGrowthOnly = try c.decodeIfPresent(Bool.self, forKey: .observeGrowthOnly) ?? false
        accessoryBatteryEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .accessoryBatteryEnabled) ?? false
        accessoryBatteryThresholdPercent = min(
            50,
            max(5, try c.decodeIfPresent(Int.self, forKey: .accessoryBatteryThresholdPercent) ?? 20)
        )
    }

    public static let `default` = AlertConfig()
}

/// One alert the engine decided to raise this tick. The app turns these into
/// user notifications; `id` is stable per logical alert so repeated deliveries
/// of the same condition replace rather than stack.
public struct Alert: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case criticalPressure
        case swap
        case processCeiling
        case leak
        case highCPU
        case highGPU
        case thermalThrottle
        case sustainedProcessCPU
    }

    public var kind: Kind
    public var title: String
    public var body: String
    public var identity: ProcessIdentity?
    public var processName: String?
    public var executablePath: String?
    public var date: Date
    public var severity: AlertSeverity
    public var evidence: AlertEvidence?
    public var snoozedUntil: Date? = nil
    public var previousNotification: AlertEvidence? = nil

    public init(
        kind: Kind, title: String, body: String, identity: ProcessIdentity? = nil,
        processName: String? = nil, executablePath: String? = nil, date: Date,
        severity: AlertSeverity = .warning, evidence: AlertEvidence? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.identity = identity
        self.processName = processName
        self.executablePath = executablePath
        self.date = date
        self.severity = severity
        self.evidence = evidence
    }

    public var id: String {
        switch kind {
        case .criticalPressure: return "pressure.critical"
        case .swap: return "swap.threshold"
        case .processCeiling: return "ceiling.\(identityKey)"
        case .leak: return "leak.\(identityKey)"
        case .highCPU: return "cpu.high"
        case .highGPU: return "gpu.high"
        case .thermalThrottle: return "thermal.throttle"
        // By program, not run: a stuck daemon restarts under new pids.
        case .sustainedProcessCPU:
            return "cpu.process.\(executablePath ?? processName ?? "unknown")"
        }
    }

    private var identityKey: String {
        guard let identity else { return "unknown" }
        return
            "\(identity.pid).\(String(identity.startTime.timeIntervalSinceReferenceDate.bitPattern, radix: 16))"
    }
}

/// Builds current risk evidence and reconciles incident state on a serial queue.
/// Notification baselines, pending cooldowns, and recovery are independent of
/// the latest reading. See docs/adaptive-alerts.md for the policy.
public final class AlertEngine {
    private struct TimedState {
        var since: Date?
        var last: Date?
        var samples = 0
        var active = false
    }

    private let refireCooldown: TimeInterval
    private let notificationSpacing: TimeInterval
    private var tracker: AlertIncidentTracker
    private var swap = SwapGrowthDetector()
    private var growth = ProcessGrowthMonitor()
    private var sustained = SustainedCPUMonitor()
    private var timers: [Alert.Kind: TimedState] = [:]
    private var pressureLatched = false
    private var lastEvaluation: Date?

    public var activeKinds: Set<Alert.Kind> { Set(activeAlerts.map(\.kind)) }
    public var activeAlerts: [Alert] { tracker.active }
    public var observations: [AlertIncident] { tracker.observations }
    public var incidentSnapshot: AlertIncidentTracker.Snapshot { tracker.snapshot }
    public var incidentRevision: UInt64 { tracker.revision }

    public init(
        refireCooldown: TimeInterval = 300, notificationSpacing: TimeInterval = 60,
        snapshot: AlertIncidentTracker.Snapshot? = nil
    ) {
        self.refireCooldown = refireCooldown
        self.notificationSpacing = notificationSpacing
        tracker = AlertIncidentTracker(
            cooldown: refireCooldown, notificationSpacing: notificationSpacing, snapshot: snapshot)
        pressureLatched = tracker.active.contains { $0.kind == .criticalPressure }
    }

    public func evaluate(
        system: SystemSample,
        processes: [ProcessSample],
        leakingProcesses _: Set<ProcessIdentity> = [],
        config: AlertConfig = .default,
        cpu: CPUSample? = nil,
        gpu: GPUSample? = nil,
        now: Date? = nil,
        expectedInterval: TimeInterval = 2,
        processSnapshotAvailable: Bool = true
    ) -> [Alert] {
        let now = now ?? system.timestamp
        guard now.timeIntervalSince1970.isFinite, lastEvaluation.map({ now >= $0 }) ?? true else {
            return []
        }
        lastEvaluation = now
        let maximumGap = max(30, min(120, expectedInterval * 3))
        var conditions: [AlertCondition] = []
        var unknown: Set<String> = []
        let systemFresh = Self.fresh(system.timestamp, at: now, maximumGap: maximumGap)
        if config.criticalPressureEnabled {
            if !systemFresh || system.pressureSampleValid == false {
                unknown.insert("pressure.critical")
            } else {
                if system.pressureLevel == .critical { pressureLatched = true }
                if system.pressureLevel == .normal { pressureLatched = false }
                if pressureLatched {
                    let critical = system.pressureLevel == .critical
                    conditions.append(
                        AlertCondition(
                            Alert(
                                kind: .criticalPressure,
                                title: critical
                                    ? t("Memory pressure is critical")
                                    : t("Memory pressure remains elevated"),
                                body: critical
                                    ? t(
                                        "Your Mac is under heavy memory pressure. Review the largest memory consumers."
                                    )
                                    : t(
                                        "Memory pressure has improved but has not yet returned to normal."
                                    ), date: system.timestamp,
                                severity: critical ? .critical : .warning,
                                evidence: AlertEvidence(
                                    start: system.timestamp, end: system.timestamp,
                                    baseline: 67, current: system.pressurePercent, unit: "index")),
                            recoveryDelay: 0))
                }
            }
        } else {
            pressureLatched = false
        }
        if config.swapEnabled {
            if !systemFresh || system.swapSampleValid == false {
                swap.reset()
                unknown.insert("swap.threshold")
            } else {
                if let condition = swap.evaluate(system, maximumGap: maximumGap) {
                    conditions.append(condition)
                }
                if !swap.isReady { unknown.insert("swap.threshold") }
                if tracker.snapshot.incidents["swap.threshold"]?.condition.alert.evidence?.signal
                    == "swapActivity",
                    system.swapInBytesPerSecond == nil || system.swapOutBytesPerSecond == nil
                {
                    unknown.insert("swap.threshold")
                }
            }
        } else {
            swap.reset()
        }
        if config.processCeilingEnabled, processSnapshotAvailable {
            for process in processes {
                let id = Alert(
                    kind: .processCeiling, title: "", body: "", identity: process.id, date: now
                ).id
                guard process.footprintReadable,
                    Self.fresh(
                        process.timestamp, at: now, maximumGap: max(120, maximumGap),
                        lead: Self.processLead)
                else {
                    unknown.insert(id)
                    continue
                }
                let previous = tracker.snapshot.incidents[id]
                let latched =
                    previous.map { $0.phase != .resolved && $0.phase != .watching } ?? false
                let limit = Double(config.processCeilingBytes) * (latched ? 0.8 : 1)
                guard Double(process.physFootprint) > limit else { continue }
                conditions.append(
                    AlertCondition(
                        Alert(
                            kind: .processCeiling,
                            title: t("Process memory budget exceeded"),
                            body: t(
                                "%1$@ is using %2$@. Your memory budget is %3$@.",
                                process.displayName,
                                ByteFormat.string(process.physFootprint),
                                ByteFormat.string(config.processCeilingBytes)),
                            identity: process.id, processName: process.displayName,
                            executablePath: process.executablePath, date: process.timestamp,
                            evidence: AlertEvidence(
                                start: previous?.startedAt ?? process.timestamp,
                                end: process.timestamp,
                                baseline: Double(config.processCeilingBytes),
                                current: Double(process.physFootprint))),
                        recoveryDelay: 0,
                        escalationDelta: max(
                            Double(config.processCeilingBytes) * 0.5, 1_073_741_824)))
            }
        }
        if config.leakEnabled, processSnapshotAvailable {
            let result = growth.evaluate(
                processes, totalRAM: system.totalRAM, now: now, maximumGap: max(120, maximumGap))
            conditions += result.conditions
            for identity in result.unknown {
                unknown.insert(
                    Alert(kind: .leak, title: "", body: "", identity: identity, date: now).id)
            }
            for identity in result.warmingLong {
                let id = Alert(kind: .leak, title: "", body: "", identity: identity, date: now).id
                if tracker.snapshot.incidents[id]?.condition.alert.evidence?.signal
                    != "fastProcessGrowth"
                {
                    unknown.insert(id)
                }
            }
        } else if !config.leakEnabled {
            growth.reset()
        }
        if !processSnapshotAvailable {
            for incident in tracker.snapshot.incidents.values {
                if (incident.condition.alert.kind == .leak && config.leakEnabled)
                    || (incident.condition.alert.kind == .processCeiling
                        && config.processCeilingEnabled)
                {
                    unknown.insert(incident.id)
                }
            }
        }
        if config.sustainedProcessCPUEnabled {
            let result = processSnapshotAvailable ? sustained.evaluate(processes, now: now) : nil
            conditions += result?.conditions ?? []
            // After launch, or without a process scan, an open incident can be
            // neither confirmed nor cleared until a full spell has been watched.
            if result?.warming ?? true {
                let raised = Set(conditions.map(\.alert.id))
                for incident in tracker.snapshot.incidents.values
                where incident.condition.alert.kind == .sustainedProcessCPU
                    && !raised.contains(incident.id)
                {
                    unknown.insert(incident.id)
                }
            }
        } else {
            sustained.reset()
        }
        if config.highCPUEnabled {
            appendTimed(
                kind: .highCPU, value: cpu.map { $0.totalUsage * 100 }, timestamp: cpu?.timestamp,
                threshold: Double(config.highCPUThresholdPercent), duration: 8,
                title: t("CPU has been busy"),
                unit: "percent", now: now, maximumGap: maximumGap, conditions: &conditions,
                unknown: &unknown)
        } else {
            timers.removeValue(forKey: .highCPU)
        }
        if config.highGPUEnabled {
            appendTimed(
                kind: .highGPU, value: gpu?.utilization,
                timestamp: gpu?.sampledAt ?? system.timestamp,
                threshold: Double(config.highGPUThresholdPercent), duration: 8,
                title: t("GPU has been busy"),
                unit: "percent", now: now, maximumGap: maximumGap, conditions: &conditions,
                unknown: &unknown)
        } else {
            timers.removeValue(forKey: .highGPU)
        }
        if config.thermalEnabled {
            appendTimed(
                kind: .thermalThrottle, value: system.thermalPressure.map { Double($0.rawValue) },
                timestamp: system.timestamp,
                threshold: 2, duration: 30, title: t("Thermal throttling"), unit: "state", now: now,
                maximumGap: maximumGap, conditions: &conditions, unknown: &unknown)
        } else {
            timers.removeValue(forKey: .thermalThrottle)
        }
        if config.observeGrowthOnly {
            for index in conditions.indices
            where conditions[index].alert.kind == .swap || conditions[index].alert.kind == .leak {
                conditions[index].alert.severity = .watching
            }
        }
        return tracker.reconcile(conditions, unknownIDs: unknown, now: now)
    }

    public func reset() {
        tracker = AlertIncidentTracker(
            cooldown: refireCooldown, notificationSpacing: notificationSpacing)
        swap.reset()
        growth.reset()
        sustained.reset()
        timers.removeAll()
        pressureLatched = false
        lastEvaluation = nil
    }

    public func restore(_ snapshot: AlertIncidentTracker.Snapshot) {
        reset()
        tracker = AlertIncidentTracker(
            cooldown: refireCooldown, notificationSpacing: notificationSpacing, snapshot: snapshot)
        pressureLatched = tracker.active.contains { $0.kind == .criticalPressure }
    }

    public func snooze(_ id: String, until: Date, now: Date = Date()) {
        tracker.snooze(id, until: until, now: now)
    }

    public func recordDeliveryFailure(_ ids: [String], attemptedAt: Date, now: Date = Date()) {
        tracker.deliveryFailed(ids, attemptedAt: attemptedAt, now: now)
    }

    /// How far a process sample may be stamped after the evaluation's `now`.
    /// The scan runs after the system tick it is evaluated with and stamps its
    /// samples when it reads them, so fresh evidence is routinely a few
    /// milliseconds "in the future"; treating that as unknown made every
    /// per-process incident flicker to unknown once per scan.
    static let processLead: TimeInterval = 5

    private static func fresh(
        _ timestamp: Date, at now: Date, maximumGap: TimeInterval, lead: TimeInterval = 0
    ) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age.isFinite && age >= -lead && age <= maximumGap
    }

    private func appendTimed(
        kind: Alert.Kind, value: Double?, timestamp: Date?, threshold: Double,
        duration: TimeInterval, title: String, unit: String, now: Date, maximumGap: TimeInterval,
        conditions: inout [AlertCondition], unknown: inout Set<String>
    ) {
        let id = Alert(kind: kind, title: "", body: "", date: now).id
        guard let value, value.isFinite, let timestamp,
            Self.fresh(timestamp, at: now, maximumGap: maximumGap)
        else {
            timers.removeValue(forKey: kind)
            unknown.insert(id)
            return
        }
        var state = timers[kind] ?? TimedState()
        if let last = state.last, timestamp.timeIntervalSince(last) > maximumGap || timestamp < last
        {
            state = TimedState()
        }
        if timestamp != state.last {
            state.last = timestamp
            if value >= threshold {
                state.since = state.since ?? timestamp
                state.samples += 1
                if timestamp.timeIntervalSince(state.since!) >= duration && state.samples >= 3 {
                    state.active = true
                }
            } else {
                state.since = nil
                state.samples = 0
                if value < threshold * 0.8 { state.active = false }
            }
        }
        timers[kind] = state
        guard state.active else {
            if value >= threshold { unknown.insert(id) }
            return
        }
        let body =
            kind == .thermalThrottle
            ? t("macOS has reported sustained thermal throttling. This can reduce performance.")
            : t(
                "Usage is %@%% and has remained elevated across fresh readings.",
                String(format: "%.0f", value))
        conditions.append(
            AlertCondition(
                Alert(
                    kind: kind, title: title, body: body, date: timestamp,
                    severity: kind == .thermalThrottle && value >= 3 ? .critical : .warning,
                    evidence: AlertEvidence(
                        start: state.since ?? timestamp, end: timestamp,
                        baseline: threshold, current: value, unit: unit)), recoveryDelay: 0))
    }
}
