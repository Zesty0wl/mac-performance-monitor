import Foundation

final class ProcessGrowthMonitor {
    struct Result {
        var conditions: [AlertCondition] = []
        var unknown: Set<ProcessIdentity> = []
        var warmingLong: Set<ProcessIdentity> = []
    }

    private var windows: [ProcessIdentity: AlertGrowthWindow] = [:]
    private var evaluatedAt: [ProcessIdentity: Date] = [:]
    private var cached: [ProcessIdentity: AlertCondition] = [:]
    private var candidateSince: [ProcessIdentity: Date] = [:]
    var trackedProcessCount: Int { windows.count }

    func reset() {
        windows.removeAll()
        evaluatedAt.removeAll()
        cached.removeAll()
        candidateSince.removeAll()
    }

    func evaluate(
        _ processes: [ProcessSample], totalRAM: UInt64, now: Date, maximumGap: TimeInterval
    ) -> Result {
        let selected = processes.prefix(4096)
        let present = Set(selected.map(\.id))
        for identity in windows.keys.filter({ !present.contains($0) }) {
            windows.removeValue(forKey: identity)
            evaluatedAt.removeValue(forKey: identity)
            cached.removeValue(forKey: identity)
            candidateSince.removeValue(forKey: identity)
        }
        var result = Result()
        result.unknown = Set(processes.dropFirst(4096).map(\.id))
        for process in selected {
            let identity = process.id
            let age = now.timeIntervalSince(process.timestamp)
            guard process.footprintReadable, age >= -AlertEngine.processLead, age <= maximumGap
            else {
                result.unknown.insert(identity)
                continue
            }
            if let last = windows[identity]?.points.last,
                process.timestamp.timeIntervalSince(last.date) > maximumGap
            {
                cached.removeValue(forKey: identity)
                candidateSince.removeValue(forKey: identity)
                evaluatedAt.removeValue(forKey: identity)
            }
            windows[identity, default: AlertGrowthWindow(retention: 3600, bucket: 30)]
                .append(
                    Double(process.physFootprint), at: process.timestamp, maximumGap: maximumGap)
            guard let window = windows[identity] else { continue }
            if let first = window.points.first,
                process.timestamp.timeIntervalSince(first.date) < 1200
            {
                result.warmingLong.insert(identity)
                if process.timestamp.timeIntervalSince(first.date) < 120 {
                    result.unknown.insert(identity)
                }
            }
            if process.timestamp.timeIntervalSince(evaluatedAt[identity] ?? .distantPast) >= 30 {
                evaluatedAt[identity] = process.timestamp
                cached.removeValue(forKey: identity)
                let fast = window.trend(seconds: 120)
                let fastFloor = max(1_073_741_824, Double(totalRAM) * 0.08)
                let fastRisk =
                    fast.map { $0.growth >= fastFloor && $0.slope >= fastFloor / 150 } ?? false
                let finding = LeakDetector.analyze(
                    series: window.points.map {
                        ($0.date, UInt64(min($0.value, Double(UInt64.max).nextDown)))
                    }, config: .init(maximumGap: maximumGap))
                let material =
                    finding.map {
                        Double($0.totalGrowth) >= max(512 * 1024 * 1024, Double(totalRAM) * 0.03)
                    } ?? false
                if fastRisk || finding != nil {
                    let trend = fastRisk ? fast : window.trend(seconds: 3600, coverage: 1.0 / 3)
                    if let trend {
                        if fastRisk || material {
                            candidateSince[identity] = candidateSince[identity] ?? process.timestamp
                        } else {
                            candidateSince.removeValue(forKey: identity)
                        }
                        let confirmed =
                            candidateSince[identity].map {
                                process.timestamp.timeIntervalSince($0) >= (fastRisk ? 30 : 60)
                            } ?? false
                        let severity: AlertSeverity = confirmed ? .warning : .watching
                        let title =
                            fastRisk
                            ? t("Rapid process memory growth") : t("Sustained memory growth")
                        var evidence = trend.evidence
                        evidence.signal = fastRisk ? "fastProcessGrowth" : "processGrowth"
                        cached[identity] = AlertCondition(
                            Alert(
                                kind: .leak, title: title,
                                body: t(
                                    "%1$@: %2$@", process.displayName,
                                    AlertText.growth(trend.evidence)),
                                identity: identity, processName: process.displayName,
                                executablePath: process.executablePath,
                                date: process.timestamp, severity: severity, evidence: evidence),
                            recoveryDelay: 180,
                            escalationDelta: max(512 * 1024 * 1024, Double(totalRAM) * 0.05))
                    }
                } else {
                    candidateSince.removeValue(forKey: identity)
                }
            }
            if let condition = cached[identity] {
                result.conditions.append(condition)
                result.unknown.remove(identity)
                result.warmingLong.remove(identity)
            }
        }
        return result
    }
}
