import Foundation

/// A declarative diagnostic check: a condition over a named probe (from the fixed
/// `DiagnosticProbes` allow-list), a severity, and message templates. Codable, so a
/// signed manifest downloaded from the server can add or tune checks WITHOUT an app
/// update — it references probe names, never commands.
public struct CheckCondition: Codable, Sendable, Equatable {
    public var probe: String
    public var op: String  // ">=", "<=", ">", "<", "==", "!="
    public var value: Double

    public init(probe: String, op: String, value: Double) {
        self.probe = probe
        self.op = op
        self.value = value
    }
}

public struct CheckRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Optional gate: if present and false, the rule is skipped entirely.
    public var appliesWhen: CheckCondition?
    /// The trigger — when this holds, the check fails at `severity` with `failText`.
    public var when: CheckCondition
    public var severity: String  // "info" | "warning" | "critical"
    public var failText: String
    public var passText: String
    /// A list-probe name whose contents become the check's supporting evidence.
    public var detailsProbe: String?

    public init(
        id: String, title: String, appliesWhen: CheckCondition? = nil, when: CheckCondition,
        severity: String, failText: String, passText: String, detailsProbe: String? = nil
    ) {
        self.id = id
        self.title = title
        self.appliesWhen = appliesWhen
        self.when = when
        self.severity = severity
        self.failText = failText
        self.passText = passText
        self.detailsProbe = detailsProbe
    }
}

public struct CheckManifest: Codable, Sendable, Equatable {
    public var version: Int
    public var checks: [CheckRule]

    public init(version: Int, checks: [CheckRule]) {
        self.version = version
        self.checks = checks
    }
}

public enum CheckCatalog {
    /// Evaluate a manifest against gathered probe values into findings. A rule whose
    /// gate fails, or whose trigger probe is unavailable on this build, is skipped —
    /// so a manifest can carry checks for probes a given build doesn't have yet.
    public static func evaluate(_ manifest: CheckManifest, probes: ProbeValues) -> [DiagnosticCheck]
    {
        manifest.checks.compactMap { evaluate($0, probes) }
    }

    static func evaluate(_ rule: CheckRule, _ p: ProbeValues) -> DiagnosticCheck? {
        if let gate = rule.appliesWhen, !holds(gate, p) { return nil }
        guard p.numbers[rule.when.probe] != nil else { return nil }
        let failed = holds(rule.when, p)
        let status: DiagnosticCheck.Status =
            failed ? (DiagnosticCheck.Status(rawValue: rule.severity) ?? .warning) : .ok
        // Translate before substituting: the {probe} tokens are identical in
        // every language, so a translation carries them through unchanged.
        let summary = template(t(failed ? rule.failText : rule.passText), p)
        let details = rule.detailsProbe.flatMap { p.lists[$0] } ?? []
        return DiagnosticCheck(
            id: rule.id, title: rule.title, status: status, summary: summary, details: details)
    }

    private static func holds(_ c: CheckCondition, _ p: ProbeValues) -> Bool {
        guard let v = p.numbers[c.probe] else { return false }
        switch c.op {
        case ">=": return v >= c.value
        case "<=": return v <= c.value
        case ">": return v > c.value
        case "<": return v < c.value
        case "==": return v == c.value
        case "!=": return v != c.value
        default: return false
        }
    }

    /// Fill `{probe}`, `{probe|pct}`, `{probe|bytes}`, `{probe|rate}` tokens from the
    /// probe values. Replacements never contain `{`, so the scan terminates.
    static func template(_ text: String, _ p: ProbeValues) -> String {
        var out = text
        while let open = out.firstIndex(of: "{"), let close = out[open...].firstIndex(of: "}") {
            let token = String(out[out.index(after: open)..<close])
            out.replaceSubrange(open...close, with: render(token, p))
        }
        return out
    }

    private static func render(_ token: String, _ p: ProbeValues) -> String {
        let parts = token.split(separator: "|", maxSplits: 1)
        let name = String(parts.first ?? "")
        let fmt = parts.count == 2 ? String(parts[1]) : ""
        if let s = p.strings[name] { return s }
        guard let v = p.numbers[name] else { return "?" }
        switch fmt {
        case "pct": return "\(Int((v * 100).rounded()))%"
        case "bytes": return ByteFormat.string(UInt64(max(0, v)))
        case "rate": return ByteFormat.rate(v)
        default: return String(Int(v.rounded()))
        }
    }

    // MARK: - Built-in pack

    /// The default catalog shipped in the app — also the floor a server manifest
    /// extends. Bump this whenever the built-in pack changes, so clients prefer it
    /// over an older cached/server copy until a newer manifest is published.
    public static let builtIn = CheckManifest(
        version: 3,
        checks: [
            CheckRule(
                id: "cpu-loop", title: "Stuck in a loop",
                appliesWhen: CheckCondition(probe: "cpu.percent", op: ">=", value: 50),
                when: CheckCondition(probe: "sample.hotConcentration", op: ">=", value: 0.6),
                severity: "critical",
                failText:
                    "Using {cpu.percent}% CPU with {sample.hotConcentration|pct} of it in "
                    + "{sample.hotFunction} ({sample.hotBinary}) — a tight loop or heavy computation.",
                passText: "CPU work is spread out — not stuck in a loop.",
                detailsProbe: "sample.callPath"),
            CheckRule(
                id: "cpu-high", title: "High CPU",
                when: CheckCondition(probe: "cpu.percent", op: ">=", value: 85),
                severity: "warning",
                failText: "Using {cpu.percent}% CPU.",
                passText: "CPU is normal ({cpu.percent}%)."),
            CheckRule(
                id: "cpu-sustained", title: "Sustained high CPU",
                when: CheckCondition(probe: "cpu.sustainedPercent", op: ">=", value: 40),
                severity: "warning",
                failText:
                    "Averaging ~{cpu.sustainedPercent}% CPU over the last hour — holding this much "
                    + "CPU for so long usually means a stuck task, a busy loop, or runaway "
                    + "background work, even though it stays below the instantaneous-spike level.",
                passText: "No sustained high CPU over the recent window."),
            CheckRule(
                id: "not-responding", title: "Not responding",
                when: CheckCondition(probe: "sample.mainBlocked", op: ">=", value: 1),
                severity: "critical",
                failText:
                    "The main thread is blocked in {sample.mainFunction}, not its run loop — the "
                    + "app is frozen.",
                passText: "The main thread is servicing its run loop — responsive."),
            CheckRule(
                id: "memory-high", title: "High memory",
                when: CheckCondition(probe: "memory.pctOfRAM", op: ">=", value: 25),
                severity: "warning",
                failText: "Using {memory.bytes|bytes} ({memory.pctOfRAM}% of system RAM).",
                passText: "Memory use is {memory.bytes|bytes} ({memory.pctOfRAM}% of RAM)."),
            CheckRule(
                id: "memory-leak", title: "Possible memory leak",
                // A leak is a CONSISTENT upward trend (regression R² gate via
                // memory.leakConfidence), judged only once the process has been up a
                // while (≥15 min) so warm-up isn't mistaken for a leak. A noisy
                // sawtooth (e.g. a browser helper) does NOT qualify.
                appliesWhen: CheckCondition(probe: "process.uptimeMinutes", op: ">=", value: 15),
                when: CheckCondition(probe: "memory.leakConfidence", op: ">=", value: 0.5),
                severity: "warning",
                failText:
                    "Memory is climbing steadily (~{memory.leakSlopePerMin|bytes}/min, "
                    + "{memory.leakConfidence|pct} confident over {process.uptime}) — a consistent "
                    + "upward trend, the signature of a leak.",
                passText: "No consistent upward memory trend — no sign of a leak."),
            CheckRule(
                id: "memory-warmup", title: "Memory still warming up",
                // A young process with a consistent rise — likely normal start-up.
                appliesWhen: CheckCondition(probe: "process.uptimeMinutes", op: "<", value: 15),
                when: CheckCondition(probe: "memory.leakConfidence", op: ">=", value: 0.5),
                severity: "info",
                failText:
                    "Memory is rising, but the process has only been running {process.uptime} — "
                    + "likely normal start-up growth; re-check once it has been up a while.",
                passText: "Memory is stable."),
            CheckRule(
                id: "disk-read", title: "High disk reads",
                when: CheckCondition(probe: "disk.readRate", op: ">=", value: 20_971_520),
                severity: "warning",
                failText: "Reading {disk.readRate|rate} from disk — heavy read activity.",
                passText: "Disk reads are normal."),
            CheckRule(
                id: "disk-write", title: "High disk writes",
                when: CheckCondition(probe: "disk.writeRate", op: ">=", value: 20_971_520),
                severity: "warning",
                failText: "Writing {disk.writeRate|rate} to disk — heavy write activity.",
                passText: "Disk writes are normal."),
            CheckRule(
                id: "fd-leak", title: "Possible descriptor leak",
                when: CheckCondition(probe: "fd.growthPct", op: ">", value: 50),
                severity: "warning",
                failText:
                    "Open file descriptors are climbing ({fd.count} now) — they may be leaking "
                    + "(opened but not closed).",
                passText: "File-descriptor count is stable ({fd.count})."),
            CheckRule(
                id: "fd-many", title: "Open files",
                when: CheckCondition(probe: "fd.count", op: ">=", value: 1000),
                severity: "warning",
                failText: "Holding {fd.count} file descriptors — unusually high.",
                passText: "{fd.count} open file descriptors.",
                detailsProbe: "files.dataFiles"),
            CheckRule(
                id: "network", title: "Network connections",
                when: CheckCondition(probe: "socket.count", op: ">=", value: 100),
                severity: "warning",
                failText: "{socket.count} open connections — unusually many (a leak or storm).",
                passText: "{socket.count} active connection(s) — endpoints below.",
                detailsProbe: "network.endpoints"),
            CheckRule(
                id: "threads", title: "Threads",
                when: CheckCondition(probe: "thread.count", op: ">=", value: 200),
                severity: "warning",
                failText: "{thread.count} threads — very high (possible thread explosion).",
                passText: "{thread.count} threads."),
        ])
}
