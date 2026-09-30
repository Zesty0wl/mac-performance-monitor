import Foundation

/// Follows busy programs across process scans and raises a condition for any
/// whose spell is sustained (see `SustainedCPU`). Only busy programs are held,
/// so the state stays small however many processes run.
final class SustainedCPUMonitor {
    struct Result {
        var conditions: [AlertCondition] = []
        /// Incidents that cannot be judged yet: the monitor has not watched
        /// long enough since launch to confirm or clear them.
        var warming = false
    }

    private struct Followed {
        var spell: SustainedSpell
        var name: String
        var path: String?
        var identity: ProcessIdentity
    }

    private static let limit = 256
    private var followed: [String: Followed] = [:]
    private var lastScan: Date?
    private var startedAt: Date?

    func reset() {
        followed.removeAll()
        lastScan = nil
        startedAt = nil
    }

    func evaluate(_ processes: [ProcessSample], now: Date) -> Result {
        if startedAt == nil { startedAt = now }
        // The engine runs every tick, but processes are rescanned less often;
        // integrate each scan once, at the time it was taken.
        guard let scan = processes.map(\.timestamp).max(), lastScan.map({ scan > $0 }) ?? true
        else { return result(now: now) }
        lastScan = scan

        var totals: [String: (cpu: Double, top: ProcessSample)] = [:]
        for process in processes where !SustainedCPU.exempt.contains(process.name) {
            let key = SustainedCPU.key(name: process.name, executablePath: process.executablePath)
            let cpu = process.cpuPercent.isFinite ? max(0, process.cpuPercent) : 0
            if let existing = totals[key] {
                totals[key] = (
                    existing.cpu + cpu, cpu > existing.top.cpuPercent ? process : existing.top
                )
            } else {
                totals[key] = (cpu, process)
            }
        }
        for key in Array(followed.keys) {
            let cpu = totals[key]?.cpu ?? 0
            guard var entry = followed[key], entry.spell.add(cpu: cpu, at: scan) else {
                followed.removeValue(forKey: key)
                continue
            }
            if let top = totals[key]?.top, cpu >= SustainedCPU.busyPercent {
                entry.identity = top.id
                entry.name = top.displayName
            }
            followed[key] = entry
        }
        for (key, total) in totals where followed[key] == nil && followed.count < Self.limit {
            if let spell = SustainedSpell(cpu: total.cpu, at: scan) {
                // The key already ignores a launcher path; the alert's id
                // and classification must too.
                let path = total.top.executablePath.flatMap {
                    $0 == SustainedCPU.launcherPath ? nil : $0
                }
                followed[key] = Followed(
                    spell: spell, name: total.top.displayName, path: path,
                    identity: total.top.id)
            }
        }
        return result(now: now)
    }

    private func result(now: Date) -> Result {
        var result = Result()
        result.warming =
            startedAt.map { now.timeIntervalSince($0) < SustainedCPU.minimumSpell } ?? true
        for entry in followed.values where entry.spell.isSustained {
            result.conditions.append(Self.condition(entry))
        }
        return result
    }

    private static func condition(_ entry: Followed) -> AlertCondition {
        let spell = entry.spell
        let kind = AskProcessKind.classify(path: entry.path)
        let known = KnownBackgroundWork.info(for: entry.name)
        let severity: AlertSeverity
        let advice: String
        switch kind.kind {
        case .app:
            severity = spell.duration >= SustainedCPU.appWarningSpell ? .warning : .watching
            advice = t("Quit it if you are not using it.")
        case .system, .background:
            severity = known?.job == true ? .watching : .warning
            advice =
                known?.explanation
                ?? (known?.neverQuit == true
                    ? t("Restarting the Mac resets it.")
                    : t("Quitting it in Activity Monitor is safe: macOS starts it again."))
        }
        let cores = String(format: "%.1f", spell.average / 100)
        return AlertCondition(
            Alert(
                kind: .sustainedProcessCPU,
                title: t("%@ has been busy for a long time", entry.name),
                body: t(
                    "It has kept about %1$@ cores busy for %2$@.", cores,
                    AskWords.minutes(spell.duration)) + " " + advice,
                identity: entry.identity, processName: entry.name, executablePath: entry.path,
                date: spell.last, severity: severity,
                evidence: AlertEvidence(
                    start: spell.since, end: spell.last, baseline: SustainedCPU.flagPercent,
                    current: spell.average, unit: "percent", signal: "sustainedProcessCPU")),
            recoveryDelay: 300, escalationDelta: 100)
    }
}
