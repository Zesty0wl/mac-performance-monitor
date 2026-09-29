import Foundation

public enum AlertSeverity: Int, Codable, Sendable, Comparable {
    case watching, warning, critical

    public static func < (first: Self, second: Self) -> Bool { first.rawValue < second.rawValue }
}

public struct AlertEvidence: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var baseline: Double
    public var current: Double
    public var rate: Double?
    public var unit: String
    public var signal: String?

    public init(
        start: Date, end: Date, baseline: Double, current: Double, rate: Double? = nil,
        unit: String = "bytes", signal: String? = nil
    ) {
        self.start = start
        self.end = end
        self.baseline = baseline
        self.current = current
        self.rate = rate
        self.unit = unit
        self.signal = signal
    }
}

public struct AlertCondition: Codable, Sendable, Equatable {
    public var alert: Alert
    public var recoveryDelay: TimeInterval
    public var escalationDelta: Double

    public init(_ alert: Alert, recoveryDelay: TimeInterval = 120, escalationDelta: Double = 0) {
        self.alert = alert
        self.recoveryDelay = recoveryDelay
        self.escalationDelta = escalationDelta
    }
}

public struct AlertIncident: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case watching, active, recovering, resolved, unknown
    }
    public var id: String { condition.alert.id }
    public var condition: AlertCondition
    public var phase: Phase
    public var episodeID = UUID()
    public var startedAt: Date
    public var observedAt: Date
    public var quietSince: Date?
    public var notifiedEpisode: UUID?
    public var notifiedAt: Date?
    public var notifiedSeverity: AlertSeverity?
    public var notifiedValue: Double?
    public var notifiedRate: Double?
    public var notifiedSignal: String?
    public var snoozedUntil: Date?
}

public struct AlertDecision: Codable, Sendable, Equatable {
    public var ruleVersion: Int? = 2
    public var date: Date
    public var id: String
    public var reason: String
    public var evidence: AlertEvidence?
}

public final class AlertIncidentTracker {
    public struct Snapshot: Codable, Sendable {
        public var version = 1
        public var incidents: [String: AlertIncident] = [:]
        public var decisions: [AlertDecision] = []
        public var lastNotification: Date?
    }

    public private(set) var snapshot: Snapshot
    public private(set) var revision: UInt64 = 0
    private let cooldown: TimeInterval
    private let notificationSpacing: TimeInterval

    public init(
        cooldown: TimeInterval = 300, notificationSpacing: TimeInterval = 60,
        snapshot: Snapshot? = nil
    ) {
        self.cooldown = max(0, cooldown)
        self.notificationSpacing = max(0, notificationSpacing)
        self.snapshot = snapshot?.version == 1 ? snapshot! : Snapshot()
    }

    public var active: [Alert] {
        ordered.filter { $0.phase == .active }.map { incident in
            var alert = incident.condition.alert
            alert.date = incident.startedAt
            alert.snoozedUntil = incident.snoozedUntil
            return alert
        }
    }

    public var observations: [AlertIncident] {
        ordered.filter { $0.phase != .resolved && $0.phase != .active }
    }

    private var ordered: [AlertIncident] {
        snapshot.incidents.values.sorted { first, second in
            if first.condition.alert.severity != second.condition.alert.severity {
                return first.condition.alert.severity > second.condition.alert.severity
            }
            return first.id < second.id
        }
    }

    public func reconcile(
        _ conditions: [AlertCondition], unknownIDs: Set<String> = [], now: Date
    ) -> [Alert] {
        prune(now: now)
        let incoming = Dictionary(
            conditions.map { ($0.alert.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for (id, condition) in incoming {
            var incident =
                snapshot.incidents[id]
                ?? AlertIncident(
                    condition: condition,
                    phase: .watching, startedAt: now, observedAt: now)
            let previous = incident.phase
            if previous == .resolved
                || (previous == .watching && condition.alert.severity > .watching
                    && incident.quietSince.map {
                        now.timeIntervalSince($0) >= condition.recoveryDelay
                    } == true)
            {
                incident.startedAt = now
                incident.episodeID = UUID()
            }
            incident.condition = condition
            incident.observedAt = now
            if condition.alert.severity == .watching {
                incident.phase =
                    previous == .active || previous == .recovering ? .recovering : .watching
                if incident.phase == .recovering {
                    incident.quietSince = incident.quietSince ?? now
                    if now.timeIntervalSince(incident.quietSince!) >= condition.recoveryDelay {
                        incident.phase = .watching
                    }
                }
            } else {
                incident.phase = .active
                incident.quietSince = nil
            }
            snapshot.incidents[id] = incident
            if incident.phase != previous { record(id, reason: incident.phase.rawValue, now: now) }
        }
        for id in Array(snapshot.incidents.keys) where incoming[id] == nil {
            guard var incident = snapshot.incidents[id], incident.phase != .resolved else {
                continue
            }
            let previous = incident.phase
            if unknownIDs.contains(id) {
                incident.phase = .unknown
                incident.quietSince = nil
            } else {
                incident.quietSince = incident.quietSince ?? now
                incident.phase =
                    now.timeIntervalSince(incident.quietSince!) >= incident.condition.recoveryDelay
                    ? .resolved : .recovering
            }
            snapshot.incidents[id] = incident
            if incident.phase != previous { record(id, reason: incident.phase.rawValue, now: now) }
        }

        var ready: [AlertIncident] = []
        for incident in ordered where incident.phase == .active && incoming[incident.id] != nil {
            let alert = incident.condition.alert
            let freshEpisode = incident.notifiedEpisode != incident.episodeID
            let upgraded = alert.severity > (incident.notifiedSeverity ?? .watching)
            let step = incident.condition.escalationDelta
            let increase =
                (alert.evidence?.current ?? 0)
                - (incident.notifiedValue ?? alert.evidence?.current ?? 0)
            let accelerated = (alert.evidence?.rate ?? 0) > max((incident.notifiedRate ?? 0) * 2, 0)
            let worsened = step > 0 && (increase >= step || (increase >= step / 2 && accelerated))
            let changedRisk = alert.evidence?.signal != incident.notifiedSignal
            guard freshEpisode || upgraded || worsened || changedRisk else { continue }
            let urgent = alert.severity == .critical && upgraded
            if alert.severity != .critical, let until = incident.snoozedUntil, until > now {
                record(incident.id, reason: "snoozed", now: now)
                continue
            }
            if !urgent, let last = incident.notifiedAt, now.timeIntervalSince(last) < cooldown {
                record(incident.id, reason: "cooldown", now: now)
                continue
            }
            if !urgent, let last = snapshot.lastNotification,
                now.timeIntervalSince(last) < notificationSpacing
            {
                record(incident.id, reason: "notificationBudget", now: now)
                continue
            }
            ready.append(incident)
        }
        guard let first = ready.first else {
            prune(now: now)
            return []
        }
        let family = Self.family(first.condition.alert.kind)
        let selected = ready.filter { Self.family($0.condition.alert.kind) == family }
        var notifications: [Alert] = []
        for var incident in selected {
            let repeated = incident.notifiedEpisode == incident.episodeID
            var alert = incident.condition.alert
            if repeated, let at = incident.notifiedAt, let value = incident.notifiedValue {
                alert.previousNotification = AlertEvidence(
                    start: at, end: at, baseline: value,
                    current: value, rate: incident.notifiedRate,
                    unit: alert.evidence?.unit ?? "bytes",
                    signal: incident.notifiedSignal)
            }
            notifications.append(alert)
            incident.notifiedEpisode = incident.episodeID
            incident.notifiedAt = now
            incident.notifiedSeverity = incident.condition.alert.severity
            incident.notifiedValue = incident.condition.alert.evidence?.current
            incident.notifiedRate = incident.condition.alert.evidence?.rate
            incident.notifiedSignal = incident.condition.alert.evidence?.signal
            snapshot.incidents[incident.id] = incident
            record(incident.id, reason: repeated ? "escalated" : "notification", now: now)
        }
        snapshot.lastNotification = now
        prune(now: now)
        return notifications
    }

    public static func family(_ kind: Alert.Kind) -> String {
        switch kind {
        case .criticalPressure, .swap, .processCeiling, .leak: return "memory"
        case .highCPU: return "cpu"
        case .highGPU: return "gpu"
        case .thermalThrottle: return "thermal"
        }
    }

    public func snooze(_ id: String, until: Date, now: Date) {
        guard var incident = snapshot.incidents[id], incident.condition.alert.severity != .critical
        else { return }
        incident.snoozedUntil = min(max(now, until), now.addingTimeInterval(86400))
        snapshot.incidents[id] = incident
        record(id, reason: "snoozed", now: now)
    }

    public func deliveryFailed(_ ids: [String], attemptedAt: Date, now: Date) {
        for id in ids {
            guard var incident = snapshot.incidents[id], let notified = incident.notifiedAt,
                notified <= attemptedAt
            else { continue }
            incident.notifiedEpisode = nil
            incident.notifiedAt = now
            snapshot.incidents[id] = incident
            record(id, reason: "deliveryFailed", now: now)
        }
    }

    private func record(_ id: String, reason: String, now: Date) {
        if let last = snapshot.decisions.last(where: { $0.id == id }), last.reason == reason {
            return
        }
        snapshot.decisions.append(
            AlertDecision(
                date: now, id: id, reason: reason,
                evidence: snapshot.incidents[id]?.condition.alert.evidence))
        if snapshot.decisions.count > 256 {
            snapshot.decisions.removeFirst(snapshot.decisions.count - 256)
        }
        revision &+= 1
    }

    private func prune(now: Date) {
        snapshot.incidents = snapshot.incidents.filter {
            now.timeIntervalSince($0.value.observedAt) < 7 * 86400
        }
        if snapshot.incidents.count > 512 {
            let keep = snapshot.incidents.values.sorted { $0.observedAt > $1.observedAt }.prefix(
                512)
            snapshot.incidents = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
    }
}
