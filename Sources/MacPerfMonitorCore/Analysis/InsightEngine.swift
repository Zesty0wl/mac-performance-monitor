import Foundation

/// Synthesises the analysis engines' findings into a small, ranked list of
/// plain-language insights for the Insights tab: suspected leaks (the
/// `LeakDetector` via the leak board), pressure spikes and their likely trigger
/// (`PressureCorrelation`), sudden footprint jumps (`ChangeDetector`), a swap
/// trend, and the Rosetta translation cost. Pure and synchronous so it is
/// trivially testable; callers gather the inputs off the main thread.
public enum InsightEngine {

    /// One ranked, plain-language finding for the Insights tab.
    public struct Insight: Sendable, Identifiable, Equatable {
        /// Ordered by how urgently the finding deserves attention.
        public enum Severity: Int, Sendable, Comparable, CaseIterable {
            /// Positive reassurance shown only when nothing else was found.
            case allClear = 0
            /// Worth knowing, no action implied (e.g. a modest Rosetta cost).
            case info = 1
            /// Worth a look (e.g. a sudden jump that may be intentional).
            case advisory = 2
            /// Likely needs action (e.g. a suspected leak).
            case warning = 3
            /// Needs action now (e.g. pressure is critical right now).
            case critical = 4

            public static func < (lhs: Severity, rhs: Severity) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        /// What produced the insight, so the UI can pick an icon per source.
        public enum Kind: String, Sendable {
            case leak, pressure, attribution, stepChange, swap, rosetta, cpu, network
            case thermalDrift
            case allClear
        }

        /// Stable across reloads for the same underlying finding, so SwiftUI
        /// animates updates rather than rebuilding every card.
        public var id: String
        public var kind: Kind
        public var severity: Severity
        /// Short plain-language headline ("Slack looks like it's leaking").
        public var headline: String
        /// One or two sentences of supporting evidence.
        public var detail: String
        /// Big trailing figure for the card ("+1.2 GB", "82% peak").
        public var metricText: String?
        /// The process the insight is about, when there is one, so the card can
        /// offer the shared process actions and an app icon.
        public var identity: ProcessIdentity?
        public var processName: String?
        public var executablePath: String?

        public init(
            id: String,
            kind: Kind,
            severity: Severity,
            headline: String,
            detail: String,
            metricText: String? = nil,
            identity: ProcessIdentity? = nil,
            processName: String? = nil,
            executablePath: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.severity = severity
            self.headline = headline
            self.detail = detail
            self.metricText = metricText
            self.identity = identity
            self.processName = processName
            self.executablePath = executablePath
        }
    }

    /// Everything the engine reads. All series are oldest-first; `events` is
    /// newest-first, matching `SampleStore.pressureEvents`.
    public struct Inputs {
        public var now: Date
        public var totalRAM: UInt64
        public var currentPressure: PressureLevel
        /// Raw system history over the analysis window (about two hours).
        public var systemHistory: [SystemHistoryPoint]
        public var leaks: [LeakBoardEntry]
        public var events: [PressureEvent]
        /// Top consumers over the last hour, for naming and step detection.
        public var consumers: [ProcessConsumer]
        /// Raw footprint series for the top consumers (about 30 minutes), for
        /// step detection and pressure attribution.
        public var consumerSeries: [ProcessIdentity: [(Date, UInt64)]]
        public var rosetta: RosettaCost
        /// The latest live CPU sample, for the current total/cluster load.
        public var cpu: CPUSample?
        /// Top consumers ranked by mean CPU over the recent window, for the
        /// heavy/runaway CPU insight. Empty disables that insight.
        public var cpuConsumers: [ProcessConsumer]
        /// Top consumers ranked by mean network throughput over the recent
        /// window, for the heavy-network insight. Empty (the default, and the
        /// case when per-app network tracking is off) disables that part.
        public var networkConsumers: [ProcessConsumer]
        /// Fans-working-harder-at-the-same-temperature finding, computed from
        /// the hour tier by the caller (see `ThermalDrift`). Nil disables the
        /// dust insight.
        public var thermalDrift: ThermalDrift.Finding?

        public init(
            now: Date = Date(),
            totalRAM: UInt64,
            currentPressure: PressureLevel,
            systemHistory: [SystemHistoryPoint],
            leaks: [LeakBoardEntry],
            events: [PressureEvent],
            consumers: [ProcessConsumer],
            consumerSeries: [ProcessIdentity: [(Date, UInt64)]],
            rosetta: RosettaCost,
            cpu: CPUSample? = nil,
            cpuConsumers: [ProcessConsumer] = [],
            networkConsumers: [ProcessConsumer] = [],
            thermalDrift: ThermalDrift.Finding? = nil
        ) {
            self.now = now
            self.totalRAM = totalRAM
            self.currentPressure = currentPressure
            self.systemHistory = systemHistory
            self.leaks = leaks
            self.events = events
            self.consumers = consumers
            self.consumerSeries = consumerSeries
            self.rosetta = rosetta
            self.cpu = cpu
            self.cpuConsumers = cpuConsumers
            self.networkConsumers = networkConsumers
            self.thermalDrift = thermalDrift
        }
    }

    /// How far before a pressure event `PressureCorrelation` looks for the
    /// process that grew the most.
    static let attributionWindow: TimeInterval = 15 * 60
    /// Growth below this is not pinned on a process as a spike's likely trigger.
    static let attributionFloor: Int64 = 256 * 1024 * 1024
    /// A step change at or above this is a warning rather than an advisory.
    static let largeStepBytes: Int64 = 1024 * 1024 * 1024
    /// Rosetta cost below max(this, 2% of RAM) is not worth a card.
    static let rosettaFloor: UInt64 = 512 * 1024 * 1024
    /// How far back the sustained-CPU check averages total CPU.
    static let cpuSustainedWindow: TimeInterval = 15 * 60
    /// Mean total CPU at/above this fraction over the window is worth a heads-up.
    static let cpuSustainedFloor = 0.75
    /// A process averaging at/above this percent of one core over the recent
    /// window is flagged as a heavy CPU user.
    static let cpuRunawayFloor = 80.0
    /// How far back the sustained-network check averages total throughput.
    static let networkSustainedWindow: TimeInterval = 10 * 60
    /// Mean total throughput (down+up, bytes/s) at/above this over the window is
    /// worth a heads-up — a sustained ~2 MB/s is a real, ongoing transfer.
    static let networkSustainedFloor = 2_000_000.0
    /// A single app averaging at/above this throughput (bytes/s) over the recent
    /// window is flagged as a heavy network user.
    static let networkAppFloor = 1_000_000.0

    /// All current insights, most urgent first. Empty inputs produce a single
    /// "all clear" card so the page is never blank reassurance-free.
    public static func insights(_ inputs: Inputs) -> [Insight] {
        var found: [Insight] = []
        found += leakInsights(inputs)
        found += pressureInsights(inputs)
        found += attributionInsights(inputs)
        found += stepChangeInsights(inputs)
        found += swapInsights(inputs)
        found += rosettaInsights(inputs)
        found += cpuInsights(inputs)
        found += networkInsights(inputs)
        found += thermalDriftInsights(inputs)

        guard !found.isEmpty else {
            return [
                Insight(
                    id: "all-clear",
                    kind: .allClear,
                    severity: .allClear,
                    headline: t("Nothing needs your attention"),
                    detail: t(
                        "No suspected leaks, pressure spikes, or sudden memory jumps in the last 2 hours. Memory is healthy."
                    )
                )
            ]
        }
        // Severity first; ties keep generation order (leaks ahead of pressure,
        // pressure ahead of step changes, and so on).
        return found.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.severity != rhs.element.severity {
                    return lhs.element.severity > rhs.element.severity
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Sources

    /// The dust signal: fans measurably faster at the same die temperature
    /// than weeks ago. Advisory, one card, hardware-care rather than software.
    private static func thermalDriftInsights(_ inputs: Inputs) -> [Insight] {
        guard let finding = inputs.thermalDrift else { return [] }
        let percent = Int((finding.increaseFraction * 100).rounded())
        return [
            Insight(
                id: "thermal-drift",
                kind: .thermalDrift,
                severity: .advisory,
                headline: t("Fans are working harder than they used to"),
                detail: t(
                    "At the same die temperature, the fans now run about %1$@%% faster than %2$@ weeks ago. Dust buildup in the vents is the usual cause; cleaning them usually brings speeds back down.",
                    String(percent), String(finding.baselineWeeksAgo)),
                metricText: "+\(percent)%"
            )
        ]
    }

    private static func leakInsights(_ inputs: Inputs) -> [Insight] {
        inputs.leaks.prefix(3).map { entry in
            let finding = entry.finding
            let minutes = Int((finding.durationSeconds / 60).rounded())
            let rate = ByteFormat.string(UInt64(max(finding.slopeBytesPerSecond, 0)))
            let critical =
                finding.confidence >= 0.85 && finding.totalGrowth >= 512 * 1024 * 1024
            return Insight(
                id: "leak-\(entry.identity.pid)-\(entry.identity.startTime.timeIntervalSince1970)",
                kind: .leak,
                severity: critical ? .critical : .warning,
                headline: t("%@ looks like it's leaking", entry.displayName),
                detail: t(
                    "Grew %1$@ over %2$@ min at a steady ~%3$@/s, with no sign of levelling off.",
                    ByteFormat.string(finding.totalGrowth), String(minutes), rate),
                metricText: "+\(ByteFormat.string(finding.totalGrowth))",
                identity: entry.identity,
                processName: entry.displayName,
                executablePath: entry.executablePath
            )
        }
    }

    private static func pressureInsights(_ inputs: Inputs) -> [Insight] {
        guard let latest = inputs.events.first else { return [] }

        let severity: Insight.Severity
        switch inputs.currentPressure {
        case .critical: severity = .critical
        case .warning: severity = .warning
        case .normal: severity = .advisory  // it happened, but it has passed
        }

        let headline =
            inputs.events.count == 1
            ? t("Memory pressure rose to %@", latest.level.label.lowercased())
            : t("%@ memory-pressure spikes in 2 hours", String(inputs.events.count))

        var sentences = [
            t("Most recent at %@.", Self.time(latest.date))
        ]
        if let name = latest.dominantName {
            sentences.append(
                t(
                    "%1$@ was the largest process at %2$@.", name,
                    ByteFormat.string(latest.dominantFootprint))
            )
        }
        sentences.append(
            inputs.currentPressure == .normal
                ? t("Pressure is back to normal now.")
                : t("Pressure is still %@.", inputs.currentPressure.label.lowercased())
        )

        let peak = inputs.systemHistory.map(\.pressurePercent).max()
        return [
            Insight(
                id: "pressure-\(latest.date.timeIntervalSince1970)",
                kind: .pressure,
                severity: severity,
                headline: headline,
                detail: sentences.joined(separator: " "),
                metricText: peak.map { "\(Int($0.rounded()))% peak" },
                identity: latest.dominantIdentity,
                processName: latest.dominantName
            )
        ]
    }

    /// Pin the most recent spike on the process that grew the most just before
    /// it, when the loaded series cover that window and the growth is material.
    /// A process already flagged as a leak is skipped — its own card names it.
    private static func attributionInsights(_ inputs: Inputs) -> [Insight] {
        guard let event = inputs.events.first else { return [] }
        let window = event.date.addingTimeInterval(-attributionWindow)...event.date
        let growers = PressureCorrelation.topGrowers(
            series: inputs.consumerSeries, window: window, limit: 1)
        guard let top = growers.first, top.growthBytes >= attributionFloor else { return [] }
        guard !inputs.leaks.contains(where: { $0.identity == top.identity }) else { return [] }
        guard let consumer = inputs.consumers.first(where: { $0.identity == top.identity })
        else { return [] }

        let grown = ByteFormat.string(UInt64(top.growthBytes))
        return [
            Insight(
                id: "attribution-\(top.identity.pid)-\(event.date.timeIntervalSince1970)",
                kind: .attribution,
                severity: .warning,
                headline: t("%@ likely triggered the spike", consumer.displayName),
                detail: t(
                    "It grew %1$@ in the %2$@ minutes before pressure rose at %3$@.",
                    grown, String(Int(attributionWindow / 60)), Self.time(event.date)),
                metricText: "+\(grown)",
                identity: top.identity,
                processName: consumer.displayName,
                executablePath: consumer.executablePath
            )
        ]
    }

    /// Sudden one-off jumps among the top consumers. Processes already on the
    /// leak board are skipped: a step is the *opposite* evidence to a leak, and
    /// one card per process is enough.
    private static func stepChangeInsights(_ inputs: Inputs) -> [Insight] {
        let leaking = Set(inputs.leaks.map(\.identity))
        let steps: [(ProcessConsumer, ChangeDetector.StepChange)] = inputs.consumers.compactMap {
            consumer in
            guard !leaking.contains(consumer.identity),
                let series = inputs.consumerSeries[consumer.identity],
                let step = ChangeDetector.analyze(series: series),
                step.deltaBytes > 0
            else { return nil }
            return (consumer, step)
        }
        return
            steps
            .sorted { $0.1.deltaBytes > $1.1.deltaBytes }
            .prefix(2)
            .map { consumer, step in
                let delta = ByteFormat.string(UInt64(step.deltaBytes))
                return Insight(
                    id:
                        "step-\(consumer.identity.pid)-\(step.at.timeIntervalSince1970)",
                    kind: .stepChange,
                    severity: step.deltaBytes >= largeStepBytes ? .warning : .advisory,
                    headline: t("%@ jumped %@ suddenly", consumer.displayName, delta),
                    detail: t(
                        "Footprint stepped from %1$@ to %2$@ at %3$@. A sharp one-off step usually means a heavy document or operation, not a leak.",
                        ByteFormat.string(step.beforeMean), ByteFormat.string(step.afterMean), Self.time(step.at)),
                    metricText: "+\(delta)",
                    identity: consumer.identity,
                    processName: consumer.displayName,
                    executablePath: consumer.executablePath
                )
            }
    }

    /// Sustained swap growth across the window: macOS paying for oversubscribed
    /// RAM with disk. Static swap is expected and stays off this page.
    private static func swapInsights(_ inputs: Inputs) -> [Insight] {
        guard inputs.totalRAM > 0,
            let first = inputs.systemHistory.first,
            let last = inputs.systemHistory.last,
            last.swapUsed > first.swapUsed
        else { return [] }
        let growth = last.swapUsed - first.swapUsed
        guard growth >= inputs.totalRAM / 20 else { return [] }  // ≥ 5% of RAM

        let minutes = Int((last.date.timeIntervalSince(first.date) / 60).rounded())
        return [
            Insight(
                id: "swap",
                kind: .swap,
                severity: inputs.currentPressure >= .warning ? .warning : .advisory,
                headline: t("Swap is climbing"),
                detail: t(
                    "Swap grew %1$@ over the last %2$@ min, from %3$@ to %4$@. A sustained climb means memory is oversubscribed.",
                    ByteFormat.string(growth), String(minutes), ByteFormat.string(first.swapUsed), ByteFormat.string(last.swapUsed)),
                metricText: "+\(ByteFormat.string(growth))"
            )
        ]
    }

    private static func rosettaInsights(_ inputs: Inputs) -> [Insight] {
        let cost = inputs.rosetta
        let floor = max(rosettaFloor, inputs.totalRAM / 50)  // 2% of RAM
        guard cost.processCount > 0, cost.totalFootprint >= floor else { return [] }
        let heavy = inputs.totalRAM > 0 && cost.totalFootprint >= inputs.totalRAM / 20
        return [
            Insight(
                id: "rosetta",
                kind: .rosetta,
                severity: heavy ? .advisory : .info,
                headline: t("Intel apps are using %@", ByteFormat.string(cost.totalFootprint)),
                // Two whole sentences rather than one template with the verb
                // spliced in as an argument. English grammar fragments (" is" /
                // "es are") cannot survive translation: substituted into the
                // Chinese template they surfaced verbatim in the middle of the
                // sentence. Anything that inflects has to live inside the key.
                detail: cost.processCount == 1
                    ? t(
                        "One process is running translated under Rosetta. Apple-silicon-native versions typically need less memory and CPU."
                    )
                    : t(
                        "%@ processes are running translated under Rosetta. Apple-silicon-native versions typically need less memory and CPU.",
                        String(cost.processCount)),
                metricText: ByteFormat.string(cost.totalFootprint)
            )
        ]
    }

    /// CPU findings: a sustained-system-CPU heads-up and a single heavy CPU
    /// process. Both lean informational — sustained CPU is normal during real
    /// work — so they sit below the memory findings unless clearly excessive.
    private static func cpuInsights(_ inputs: Inputs) -> [Insight] {
        var found: [Insight] = []

        // Sustained total CPU across the recent window.
        let cutoff = inputs.now.addingTimeInterval(-cpuSustainedWindow)
        let recent = inputs.systemHistory.filter { $0.date >= cutoff }.map(\.cpuLoad)
        if recent.count >= 5 {
            let average = recent.reduce(0, +) / Double(recent.count)
            if average >= cpuSustainedFloor {
                let minutes = Int((cpuSustainedWindow / 60).rounded())
                let percent = Int((average * 100).rounded())
                found.append(
                    Insight(
                        id: "cpu-sustained",
                        kind: .cpu,
                        severity: average >= 0.9 ? .warning : .advisory,
                        headline: t("Your Mac has been working hard"),
                        detail: t(
                            "Total CPU has averaged %1$@%% over the last %2$@ min. Sustained high CPU is normal during real work, but it warms the machine and drains battery — the top CPU process is the place to look.",
                            String(percent), String(minutes)),
                        metricText: "\(percent)% avg"))
            }
        }

        // A single heavy CPU process over the recent window.
        if let top = inputs.cpuConsumers.first, top.averageCPU >= cpuRunawayFloor {
            let percent = Int(top.averageCPU.rounded())
            found.append(
                Insight(
                    id:
                        "cpu-heavy-\(top.identity.pid)-\(top.identity.startTime.timeIntervalSince1970)",
                    kind: .cpu,
                    severity: top.averageCPU >= 300 ? .warning : .advisory,
                    headline: t("%@ is using a lot of CPU", top.displayName),
                    detail: t(
                        top.averageCPU >= 100
                            ? "It has averaged %1$@%% of one core recently — more than a full core. If it is not doing work you expect, restarting it usually settles it."
                            : "It has averaged %@%% of one core recently. If it is not doing work you expect, restarting it usually settles it.",
                        String(percent)),
                    metricText: "\(percent)%",
                    identity: top.identity,
                    processName: top.displayName,
                    executablePath: top.executablePath))
        }
        return found
    }

    /// Network findings: a sustained-throughput heads-up and a single heavy
    /// network app. Both are informational — sustained transfers are normal — so
    /// they sit below the memory and CPU findings. The per-app card appears only
    /// when per-app network tracking is on (its `networkConsumers` are non-empty).
    private static func networkInsights(_ inputs: Inputs) -> [Insight] {
        var found: [Insight] = []

        // Sustained total throughput across the recent window.
        let cutoff = inputs.now.addingTimeInterval(-networkSustainedWindow)
        let recent = inputs.systemHistory.filter { $0.date >= cutoff }
        if recent.count >= 5 {
            let totals = recent.map { $0.networkInBytesPerSec + $0.networkOutBytesPerSec }
            let average = totals.reduce(0, +) / Double(totals.count)
            if average >= networkSustainedFloor {
                let minutes = Int((networkSustainedWindow / 60).rounded())
                let peak = totals.max() ?? average
                found.append(
                    Insight(
                        id: "network-sustained",
                        kind: .network,
                        severity: .info,
                        headline: t("Steady network activity"),
                        detail: t(
                            "Your Mac has moved an average of %1$@ over the last %2$@ min, peaking at %3$@. That usually means an ongoing download, upload, sync, or backup.",
                            ByteFormat.rate(average), String(minutes), ByteFormat.rate(peak)),
                        metricText: ByteFormat.rate(average)))
            }
        }

        // A single heavy network app over the recent window (per-app only).
        if let top = inputs.networkConsumers.first, top.averageNetwork >= networkAppFloor {
            found.append(
                Insight(
                    id:
                        "network-heavy-\(top.identity.pid)-\(top.identity.startTime.timeIntervalSince1970)",
                    kind: .network,
                    severity: .info,
                    headline: t("%@ is using the network heavily", top.displayName),
                    detail: t(
                        "It has averaged %@ of network traffic recently. If that is not work you expect, it is worth a look.",
                        ByteFormat.rate(top.averageNetwork)),
                    metricText: ByteFormat.rate(top.averageNetwork),
                    identity: top.identity,
                    processName: top.displayName,
                    executablePath: top.executablePath))
        }
        return found
    }

    // MARK: - Formatting

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
