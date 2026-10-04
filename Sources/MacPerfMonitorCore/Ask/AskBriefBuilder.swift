import Foundation

/// The latest live readings, filled by the app from the sampler. Every field
/// is optional: a reader that has not reported yet is unknown, not zero.
public struct AskLiveReading: Sendable, Equatable {
    public var date: Date
    public var cpuPercent: Double?
    public var pressurePercent: Double?
    public var gpuPercent: Double?
    public var aneMillisecondsPerSecond: Double?
    public var networkInBytesPerSec: Double?
    public var networkOutBytesPerSec: Double?
    public var diskBusyPercent: Double?
    public var bootFreeBytes: UInt64?
    public var bootTotalBytes: UInt64?
    public var batteryCharge: Double?
    public var batteryIsCharging: Bool?
    public var onExternalPower: Bool?
    public var thermal: ThermalPressureState?
    public var cpuDieC: Double?
    public var fanRPM: Double?

    public init(date: Date) { self.date = date }
}

/// An app's average use of one resource over the period.
public struct AskAppUsage: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var name: String
    public var average: Double
    public var kind: AskProcessKind
    public var owner: String?

    public init(
        identity: ProcessIdentity, name: String, average: Double, kind: AskProcessKind = .app,
        owner: String? = nil
    ) {
        self.identity = identity
        self.name = name
        self.average = average
        self.kind = kind
        self.owner = owner
    }
}

/// An app whose memory grew steadily, from the leak detector.
public struct AskGrowth: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var name: String
    public var growthBytes: UInt64
    public var durationSeconds: TimeInterval
    public var kind: AskProcessKind
    public var owner: String?

    public init(
        identity: ProcessIdentity, name: String, growthBytes: UInt64, durationSeconds: TimeInterval,
        kind: AskProcessKind = .app, owner: String? = nil
    ) {
        self.identity = identity
        self.name = name
        self.growthBytes = growthBytes
        self.durationSeconds = durationSeconds
        self.kind = kind
        self.owner = owner
    }
}

/// A program that has kept the processor busy for a long time, up to the end
/// of the period (see `SustainedCPU`).
public struct AskSustained: Sendable, Equatable {
    public var name: String
    public var identity: ProcessIdentity
    public var kind: AskProcessKind
    public var owner: String?
    public var since: Date
    public var end: Date
    /// Average over the spell, percent of one core.
    public var average: Double

    public init(
        name: String, identity: ProcessIdentity, kind: AskProcessKind, owner: String?, since: Date,
        end: Date, average: Double
    ) {
        self.name = name
        self.identity = identity
        self.kind = kind
        self.owner = owner
        self.since = since
        self.end = end
        self.average = average
    }

    public var duration: TimeInterval { end.timeIntervalSince(since) }
}

/// Everything one area's brief is built from. Plain values, so briefs can be
/// built and tested without a database or a running sampler.
public struct AskBriefInputs: Sendable {
    public var area: AskArea
    public var start: Date
    public var end: Date
    public var now: Date
    /// Recorded system history inside the period.
    public var points: [SystemHistoryPoint] = []
    /// Hourly history from the week before, for what is normal on this Mac.
    public var baseline: [SystemHistoryPoint] = []
    public var live: AskLiveReading?
    /// Apps ranked by the area's resource, highest first.
    public var apps: [AskAppUsage] = []
    public var growth: [AskGrowth] = []
    /// Programs busy for an hour or more at the end of the period.
    public var sustained: [AskSustained] = []
    /// The app a question named ("is Chrome slowing me down?"), when it matched
    /// recorded processes; `focusName` is what the question said.
    public var focus: [AskAppUsage] = []
    public var focusName: String?
    public var recording = true
    public var networkTracking = true
    public var coreCount = 8
    public var hasBattery = true

    public init(area: AskArea, start: Date, end: Date, now: Date) {
        self.area = area
        self.start = start
        self.end = end
        self.now = now
    }
}

public enum AskBriefBuilder {
    public static func brief(_ input: AskBriefInputs) -> AreaBrief {
        var brief: AreaBrief
        switch input.area {
        case .overall, .processor: brief = processor(input)
        case .memory: brief = memory(input)
        case .graphics: brief = graphics(input)
        case .neuralEngine: brief = neuralEngine(input)
        case .network: brief = network(input)
        case .storage: brief = storage(input)
        case .energy: brief = energy(input)
        case .heat: brief = heat(input)
        }
        if !input.recording, input.points.isEmpty {
            brief.gaps.append(t("History recording is off, so only the current reading is known."))
        }
        for app in input.focus.prefix(2) {
            brief.facts.append(
                usage(input.area, average: app.average, input: input).map {
                    t("\"%1$@\" used %2$@.", app.name, $0)
                } ?? t("\"%@\" used very little of it.", app.name))
            if var chart = brief.chart, !chart.processes.contains(app.identity) {
                chart.processes = Array(([app.identity] + chart.processes).prefix(4))
                brief.chart = chart
            }
        }
        brief.advice = advice(for: brief, growth: input.growth, sustained: input.sustained)
        if let name = input.focusName, input.focus.isEmpty, input.area != .overall {
            brief.gaps.append(t("No app called \"%@\" was recorded in this time.", name))
        }
        return brief
    }

    /// Safe next steps for a newcomer, only when the area needs them. Nothing
    /// here deletes files, changes settings, or needs Terminal.
    static func advice(
        for brief: AreaBrief, growth: [AskGrowth] = [], sustained: [AskSustained] = []
    ) -> [String] {
        var steps: [String] = []
        switch brief.area {
        case .overall, .neuralEngine:
            break
        case .processor where !sustained.isEmpty:
            steps += sustainedAdvice(sustained[0])
        case .processor where brief.status >= .busy:
            steps += quitAdvice(
                brief.apps,
                fallback: t(
                    "It usually passes on its own. If the Mac stays this busy for hours, restarting it helps."
                ))
        case .memory:
            if let grower = growth.first(where: { $0.growthBytes >= 256 * 1_048_576 }) {
                switch grower.kind {
                case .app:
                    steps.append(
                        t(
                            "Quitting and reopening \"%@\" usually gives its memory back.",
                            grower.owner ?? grower.name))
                case .system:
                    steps.append(
                        t(
                            "\"%@\" is part of macOS, so don't try to quit it. Its memory usually settles; if it keeps growing for hours, restarting the Mac gives it back.",
                            grower.name))
                case .background:
                    steps.append(
                        t(
                            "\"%@\" is a background process. If it keeps growing, quitting the app or tool that started it, or restarting the Mac, gives its memory back.",
                            grower.name))
                }
            }
            if brief.status >= .unusual {
                steps.append(
                    t("Quit apps you are not using, and close browser tabs you do not need."))
            }
        case .graphics where brief.status >= .busy:
            steps.append(
                t(
                    "Close games or video apps you are not using, or lower a game's graphics settings."
                ))
        case .network where brief.status >= .busy:
            steps.append(
                t("If the internet feels slow, pause large downloads, uploads or backups."))
        case .storage where brief.status >= .unusual:
            steps.append(t("Empty the Trash, and delete or move large files you no longer need."))
            steps.append(t("The Disk Map shows which folders take the most space."))
        case .energy where brief.status >= .busy:
            steps.append(t("Plug in to charge, and lower the screen brightness."))
            steps += quitAdvice(brief.apps, fallback: nil)
        case .heat where brief.status >= .busy:
            steps.append(t("Keep the vents clear and use the Mac on a hard, flat surface."))
        default:
            break
        }
        if steps.isEmpty, brief.status <= .calm {
            steps.append(t("Nothing is needed: this part of the Mac is fine."))
        }
        return steps
    }

    /// "Quit X" only for something that can be quit: an app, or the app a
    /// helper belongs to. A busy part of macOS gets patience instead.
    /// For a program busy for hours "it usually settles" is wrong: it has not.
    static func sustainedAdvice(_ spell: AskSustained) -> [String] {
        let known = KnownBackgroundWork.info(for: spell.name)
        var steps: [String] = []
        switch spell.kind {
        case .app:
            steps.append(
                t(
                    "If you are not using \"%@\", quit it: an app that stays this busy for hours in the background is often stuck.",
                    spell.owner ?? spell.name))
        case .system, .background:
            if known?.job == true {
                steps.append(
                    t(
                        "\"%@\" is doing a job for macOS. Let it finish; if it is still this busy tomorrow, restart the Mac.",
                        spell.name))
            } else if known?.neverQuit == true {
                steps.append(
                    t(
                        "\"%@\" is part of macOS and should not stay this busy. Don't quit it; restarting the Mac resets it.",
                        spell.name))
            } else {
                steps.append(
                    t(
                        "\"%@\" should not stay this busy for hours. Quitting it in Activity Monitor is safe: macOS starts it again. If it gets busy again, restart the Mac.",
                        spell.name))
            }
        }
        if let explanation = known?.explanation { steps.append(explanation) }
        return steps
    }

    static func quitAdvice(_ apps: [AskApp], fallback: String?) -> [String] {
        guard let top = apps.first(where: \.major) else { return fallback.map { [$0] } ?? [] }
        switch top.kind {
        case .app:
            return [
                t(
                    "Quit \"%@\" if you are not using it, or let it finish if it is doing a job such as a backup, an update or a build.",
                    top.owner ?? top.name)
            ]
        case .system:
            return [
                t(
                    "\"%@\" is part of macOS. It usually settles down on its own; if it stays busy for hours, restarting the Mac helps.",
                    top.name)
            ]
        case .background:
            return [
                t(
                    "\"%@\" is a background process, often started by an app or a tool you installed. It usually finishes on its own.",
                    top.name)
            ]
        }
    }

    /// How much of an area's resource one app used, in the area's own words,
    /// or nil when it is too small to mention.
    static func usage(_ area: AskArea, average: Double, input: AskBriefInputs) -> String? {
        switch area {
        case .overall, .processor:
            let share = average / Double(max(1, input.coreCount))
            guard share >= 0.5 else { return nil }
            return t("about %@ of the processor on average", AskWords.percent(share))
        case .memory:
            guard average >= 1_048_576 else { return nil }
            return t("about %@ on average", ByteFormat.string(UInt64(average)))
        case .graphics:
            guard average >= 1 else { return nil }
            return t("about %@ of the graphics chip on average", AskWords.percent(average))
        case .network:
            guard average >= 1_000 else { return nil }
            return t("about %@ on average", ByteFormat.rate(average))
        case .storage:
            guard average >= 10_000 else { return nil }
            return t("about %@ of reading and writing on average", ByteFormat.rate(average))
        case .energy:
            guard average > 0 else { return nil }
            return t("an energy impact of about %@", String(Int64(average.rounded())))
        case .neuralEngine, .heat:
            return nil
        }
    }

    /// The whole Mac, from the briefs of its parts: the worst status wins and
    /// the parts that caused it are named.
    public static func overall(_ parts: [AreaBrief], start: Date, end: Date) -> AreaBrief {
        let known = parts.filter { $0.status != .unknown }
        let worst = known.map(\.status).max() ?? .unknown
        let flagged = known.filter { $0.status >= .unusual }.sorted { $0.status > $1.status }
        let busy = known.filter { $0.status == .busy }
        let headline: String
        if worst == .unknown {
            headline = t("There are not enough readings yet to say how your Mac is doing.")
        } else if flagged.isEmpty && busy.isEmpty {
            headline = t("Your Mac is running smoothly.")
        } else if flagged.isEmpty {
            headline = t("Your Mac is busy but coping: %@.", list(busy.map(\.area.title)))
        } else {
            // Each part under its own status's words, the more serious first.
            let attention = flagged.filter { $0.status == .attention }.map(\.area.title)
            let unusual = flagged.filter { $0.status == .unusual }.map(\.area.title)
            headline = [
                attention.isEmpty ? nil : t("Needs attention: %@.", list(attention)),
                unusual.isEmpty ? nil : t("Worth a look: %@.", list(unusual)),
            ].compactMap { $0 }.joined(separator: " ")
        }
        var apps: [AskApp] = []
        for part in (flagged + busy) {
            for app in part.apps where !apps.contains(where: { $0.identity == app.identity }) {
                apps.append(app)
            }
        }
        return AreaBrief(
            area: .overall, start: start, end: end, status: worst, headline: headline,
            facts: known.map { "\($0.area.title): \($0.status.title). \($0.headline)" },
            apps: Array(apps.prefix(3)),
            notable: flagged.flatMap(\.notable).prefix(3).map { $0 },
            gaps: parts.filter { $0.status == .unknown }.map {
                t("%@: no readings.", $0.area.title)
            },
            chart: (flagged.first ?? busy.first)?.chart)
    }

    // MARK: Processor

    static func processor(_ input: AskBriefInputs) -> AreaBrief {
        let period = AskWords.period(input.start, input.end, now: input.now)
        let series = AskSeries(
            input.points, busyThreshold: 70, value: { $0.cpuLoad * 100 }, peak: { $0.cpuLoad * 100 }
        )
        let normal = AskSeries.median(input.baseline) { $0.cpuLoad * 100 }
        var facts: [String] = []
        if let now = input.live?.cpuPercent {
            facts.append(t("Right now the processor is %@ busy.", AskWords.percent(now)))
        }
        var status = AskStatus.unknown
        var headline = t("No recent processor readings yet.")
        if let series {
            facts.append(
                t("Over %1$@ it averaged %2$@ busy.", period, AskWords.percent(series.mean)))
            facts.append(t("It was over 70%% busy %@.", AskWords.share(series.busyShare)))
            facts.append(
                t(
                    "The busiest moment reached %1$@ at %2$@.", AskWords.percent(series.peak),
                    AskWords.time(series.peakDate)))
            let compared = normal.flatMap {
                AskWords.comparedWithNormal(series.mean, normal: $0, floor: 10)
            }
            let ratio = normal.map { series.mean / max($0, 10) } ?? 1
            status = grade(
                mean: series.mean, busy: 40, unusual: 70, attention: 85,
                sustained: series.busyShare, ratio: ratio)
            headline =
                t("About %@ busy", AskWords.percent(series.mean))
                + (compared.map { ", " + $0 } ?? "") + "."
        } else if let now = input.live?.cpuPercent {
            status = now >= 85 ? .busy : .calm
            headline = t("%@ busy right now.", AskWords.percent(now))
        }
        let cores = Double(max(1, input.coreCount))
        let busyForHours = input.sustained.prefix(2).map { spell in
            AskApp(
                name: spell.name, identity: spell.identity, kind: spell.kind, owner: spell.owner,
                major: true,
                usage: t(
                    "about %@ of the processor, for hours",
                    AskWords.percent(spell.average / cores)))
        }
        let ranked = input.apps.compactMap { app -> AskApp? in
            let share = app.average / cores
            guard share >= 0.5 else { return nil }
            return AskApp(
                name: app.name, identity: app.identity, kind: app.kind, owner: app.owner,
                major: share >= 5,
                usage: share < 1
                    ? t("under 1%% of the processor on average")
                    : t("about %@ of the processor on average", AskWords.percent(share)))
        }
        let apps =
            (busyForHours + ranked.filter { app in !busyForHours.contains { $0.name == app.name } })
            .prefix(3)
        var notable: [String] = []
        // A program busy for hours matters however calm the Mac looks: after
        // a few days of it, it is part of this Mac's "normal".
        for spell in input.sustained.prefix(2) {
            let cores = String(format: "%.1f", spell.average / 100)
            let longest = spell.duration >= 86400 - 180
            notable.append(
                longest
                    ? t(
                        "\"%1$@\" has kept about %2$@ cores busy for more than a day.", spell.name,
                        cores)
                    : t(
                        "\"%1$@\" has kept about %2$@ cores busy for %3$@ without a break.",
                        spell.name,
                        cores, AskWords.minutes(spell.duration)))
            let known = KnownBackgroundWork.info(for: spell.name)
            let raised: AskStatus
            switch spell.kind {
            case .app: raised = spell.duration >= SustainedCPU.appWarningSpell ? .unusual : .busy
            case .system, .background:
                raised =
                    known?.job == true
                    ? .busy : spell.duration >= SustainedCPU.appWarningSpell ? .attention : .unusual
            }
            if raised > status || status == .unknown {
                status = max(status, raised)
                headline = t("\"%@\" has been busy for hours.", spell.name)
            }
        }
        let flagged = Set(input.sustained.map(\.identity))
        if status >= .busy, !apps.contains(where: \.major), flagged.isEmpty {
            notable.append(
                t(
                    "No single app stands out: lots of smaller tasks are adding up, as happens during updates, indexing or builds."
                ))
        }
        return AreaBrief(
            area: .processor, start: input.start, end: input.end, status: status,
            headline: headline,
            facts: facts,
            normal: normal.map { t("about %@ busy on average", AskWords.percent($0)) },
            apps: Array(apps), notable: notable,
            chart: AskChartLink(
                title: AskArea.processor.title, laneIDs: ["cpu", "process.cpu"], start: input.start,
                end: input.end, processes: apps.map(\.identity)))
    }

    // MARK: Memory

    static func pressureWords(_ value: Double) -> String {
        switch value {
        case ..<34: return t("low, with plenty of room")
        case ..<67: return t("moderate: macOS is squeezing memory to make room")
        default: return t("high: macOS is using the disk as extra memory, which slows things down")
        }
    }

    static func memory(_ input: AskBriefInputs) -> AreaBrief {
        let period = AskWords.period(input.start, input.end, now: input.now)
        let series = AskSeries(
            input.points, busyThreshold: 67, value: { $0.pressurePercent },
            peak: { $0.pressurePercent })
        let normal = AskSeries.median(input.baseline) { $0.pressurePercent }
        var facts: [String] = []
        var notable: [String] = []
        if let now = input.live?.pressurePercent {
            facts.append(t("Memory pressure right now is %@.", pressureWords(now)))
        }
        var status = AskStatus.unknown
        var headline = t("No recent memory readings yet.")
        var swapGrowth: Double = 0
        if let series {
            facts.append(
                t(
                    "Over %1$@ pressure averaged %2$@ out of 100 and peaked at %3$@ at %4$@.",
                    period,
                    String(Int64(series.mean.rounded())), String(Int64(series.peak.rounded())),
                    AskWords.time(series.peakDate)))
            let swaps = input.points.map(\.swapUsed)
            if let first = swaps.first, let last = swaps.last {
                swapGrowth = Double(last) - Double(first)
                if last > 0 {
                    facts.append(
                        t(
                            "The Mac is using %@ of disk as extra memory (swap).",
                            ByteFormat.string(last)))
                }
                if swapGrowth >= 512 * 1_048_576 {
                    notable.append(
                        t(
                            "Swap grew by %@ during this time, a sign memory ran short.",
                            ByteFormat.string(UInt64(swapGrowth))))
                }
            }
            // The middle band is routine on many Macs: macOS squeezing memory
            // is coping, not failing. Worth a look needs the upper half of it,
            // swap growing, or pressure well above this Mac's normal.
            let aboveNormal = normal.map { series.mean >= max($0 * 1.8, 34) } ?? false
            status =
                series.mean >= 67 || series.busyShare >= 0.25
                ? .attention
                : series.mean >= 50 || swapGrowth >= 1_073_741_824 || aboveNormal
                    ? .unusual
                    : series.mean >= 34 || series.peak >= 50 ? .busy : .calm
            headline = t("Pressure %@.", pressureWords(series.mean))
            // Swap growing is the reason to look when pressure itself reads
            // low, so say so rather than a calm line under a Worth a look.
            if status == .unusual, series.mean < 34, swapGrowth >= 1_073_741_824 {
                headline = t(
                    "Swap grew by %@, though pressure is low.",
                    ByteFormat.string(UInt64(swapGrowth)))
            }
        } else if let now = input.live?.pressurePercent {
            status = now >= 67 ? .attention : now >= 34 ? .unusual : .calm
            headline = t("Pressure %@.", pressureWords(now))
        }
        for growth in input.growth.prefix(2) where growth.growthBytes >= 256 * 1_048_576 {
            notable.append(
                t(
                    "\"%1$@\" kept using more memory: it grew steadily by %2$@ over %3$@.",
                    growth.name,
                    ByteFormat.string(growth.growthBytes), AskWords.minutes(growth.durationSeconds))
            )
            if status < .unusual, growth.growthBytes >= 512 * 1_048_576 {
                status = .unusual
                headline = t("\"%@\" keeps using more memory.", growth.name)
            }
        }
        let apps = input.apps.prefix(3).map {
            AskApp(
                name: $0.name, identity: $0.identity, kind: $0.kind, owner: $0.owner,
                usage: t("about %@ on average", ByteFormat.string(UInt64(max(0, $0.average)))))
        }
        var chartProcesses = apps.map(\.identity)
        for growth in input.growth.prefix(2) where !chartProcesses.contains(growth.identity) {
            chartProcesses.insert(growth.identity, at: 0)
        }
        return AreaBrief(
            area: .memory, start: input.start, end: input.end, status: status, headline: headline,
            facts: facts,
            normal: normal.map {
                t(
                    "pressure around %1$@ out of 100 (%2$@)", String(Int64($0.rounded())),
                    pressureWords($0))
            },
            apps: apps, notable: notable,
            chart: AskChartLink(
                title: AskArea.memory.title, laneIDs: ["pressure", "memory", "process.footprint"],
                start: input.start, end: input.end, processes: chartProcesses))
    }

    // MARK: Graphics

    static func graphics(_ input: AskBriefInputs) -> AreaBrief {
        let period = AskWords.period(input.start, input.end, now: input.now)
        let series = AskSeries(
            input.points, busyThreshold: 70, value: { $0.gpuUtilization },
            peak: { $0.gpuUtilization })
        let normal = AskSeries.median(input.baseline) { $0.gpuUtilization }
        var facts: [String] = []
        var gaps: [String] = []
        if let now = input.live?.gpuPercent {
            facts.append(t("Right now the graphics chip is %@ busy.", AskWords.percent(now)))
        }
        var status = AskStatus.unknown
        var headline = t("No recent graphics readings yet.")
        if let series {
            facts.append(
                t("Over %1$@ it averaged %2$@ busy.", period, AskWords.percent(series.mean)))
            facts.append(
                t(
                    "The busiest moment reached %1$@ at %2$@.", AskWords.percent(series.peak),
                    AskWords.time(series.peakDate)))
            let ratio = normal.map { series.mean / max($0, 10) } ?? 1
            status = grade(
                mean: series.mean, busy: 40, unusual: 75, attention: 101,
                sustained: series.busyShare,
                ratio: ratio)
            headline =
                t("About %@ busy", AskWords.percent(series.mean))
                + (normal.flatMap {
                    AskWords.comparedWithNormal(series.mean, normal: $0, floor: 10)
                }
                .map { ", " + $0 } ?? "") + "."
        } else if input.live?.gpuPercent == nil {
            gaps.append(
                t("Graphics use is only measured while its charts are open or history is recorded.")
            )
        }
        let apps = input.apps.filter { $0.average >= 1 }.prefix(3).map {
            AskApp(
                name: $0.name, identity: $0.identity, kind: $0.kind, owner: $0.owner,
                major: $0.average >= 20,
                usage: t("about %@ of the graphics chip on average", AskWords.percent($0.average)))
        }
        return AreaBrief(
            area: .graphics, start: input.start, end: input.end, status: status, headline: headline,
            facts: facts,
            normal: normal.map { t("about %@ busy on average", AskWords.percent($0)) },
            apps: apps, gaps: gaps,
            chart: AskChartLink(
                title: AskArea.graphics.title, laneIDs: ["gpu", "process.gpu"], start: input.start,
                end: input.end, processes: apps.map(\.identity)))
    }

    // MARK: Neural Engine

    static func neuralEngine(_ input: AskBriefInputs) -> AreaBrief {
        let period = AskWords.period(input.start, input.end, now: input.now)
        // Activity is milliseconds busy per second; a tenth of it is a percent.
        let series = AskSeries(
            input.points, busyThreshold: 50,
            value: { $0.aneTimeMillisecondsPerSecond.map { $0 / 10 } },
            peak: { $0.aneTimeMillisecondsPerSecond.map { $0 / 10 } })
        let normal = AskSeries.median(input.baseline) {
            $0.aneTimeMillisecondsPerSecond.map { $0 / 10 }
        }
        var facts: [String] = []
        var gaps = [t("macOS does not say which app is using the Neural Engine.")]
        var status = AskStatus.unknown
        var headline = t("No Neural Engine readings yet.")
        if let now = input.live?.aneMillisecondsPerSecond {
            facts.append(t("Right now it is active %@ of the time.", AskWords.percent(now / 10)))
        }
        if let series {
            facts.append(
                t(
                    "Over %1$@ it was active %2$@ of the time on average, at most %3$@.", period,
                    AskWords.percent(series.mean), AskWords.percent(series.peak)))
            let power = AskSeries(input.points, value: { $0.anePowerWatts })
            if let power, power.mean >= 0.05 {
                facts.append(t("It used about %@ W of power.", String(format: "%.1f", power.mean)))
            }
            let ratio = normal.map { series.mean / max($0, 5) } ?? 1
            status = grade(
                mean: series.mean, busy: 25, unusual: 60, attention: 101,
                sustained: series.busyShare,
                ratio: ratio)
            headline =
                series.mean < 2
                ? t("Mostly idle.")
                : t("Active about %@ of the time.", AskWords.percent(series.mean))
            if input.points.contains(where: { $0.aneSampleIsPartial == true }) {
                gaps.append(t("Some readings only covered part of the time."))
            }
        } else {
            gaps.append(t("Neural Engine activity was not recorded for this time."))
        }
        return AreaBrief(
            area: .neuralEngine, start: input.start, end: input.end, status: status,
            headline: headline,
            facts: facts,
            normal: normal.map { t("active about %@ of the time", AskWords.percent($0)) },
            gaps: gaps,
            chart: AskChartLink(
                title: AskArea.neuralEngine.title, laneIDs: ["aneTime", "power"],
                start: input.start,
                end: input.end))
    }

    // MARK: Network

    static func network(_ input: AskBriefInputs) -> AreaBrief {
        let period = AskWords.period(input.start, input.end, now: input.now)
        let down = AskSeries(
            input.points, value: { $0.networkInBytesPerSec }, peak: { $0.networkInBytesPerSec })
        let up = AskSeries(
            input.points, value: { $0.networkOutBytesPerSec }, peak: { $0.networkOutBytesPerSec })
        let normal = AskSeries.median(input.baseline) {
            $0.networkInBytesPerSec + $0.networkOutBytesPerSec
        }
        var facts: [String] = []
        var gaps: [String] = []
        if let live = input.live, let inRate = live.networkInBytesPerSec,
            let outRate = live.networkOutBytesPerSec
        {
            facts.append(
                t(
                    "Right now: %1$@ down and %2$@ up.", ByteFormat.rate(inRate),
                    ByteFormat.rate(outRate)))
        }
        var status = AskStatus.unknown
        var headline = t("No recent network readings yet.")
        if let down, let up {
            let seconds = max(1, input.end.timeIntervalSince(input.start))
            facts.append(
                t(
                    "Over %1$@ it downloaded about %2$@ and uploaded about %3$@.", period,
                    ByteFormat.string(UInt64(down.mean * seconds)),
                    ByteFormat.string(UInt64(up.mean * seconds))))
            facts.append(
                t(
                    "The fastest download was %1$@ at %2$@.", ByteFormat.rate(down.peak),
                    AskWords.time(down.peakDate)))
            let total = down.mean + up.mean
            let ratio = normal.map { total / max($0, 50_000) } ?? 1
            // Several times this Mac's quiet normal is still small in absolute
            // terms on most connections; only a real volume is worth a look.
            status =
                ratio >= 3 && total >= 5_000_000 ? .unusual : total >= 1_000_000 ? .busy : .calm
            headline =
                total < 20_000
                ? t("Quiet.")
                : t(
                    "About %1$@ down and %2$@ up on average.", ByteFormat.rate(down.mean),
                    ByteFormat.rate(up.mean))
            if up.mean >= 1_000_000, up.mean > down.mean {
                facts.append(t("It sent more than it received, for example an upload or a backup."))
            }
        }
        var apps: [AskApp] = []
        if input.networkTracking {
            apps = input.apps.filter { $0.average >= 10_000 }.prefix(3).map {
                AskApp(
                    name: $0.name, identity: $0.identity, kind: $0.kind, owner: $0.owner,
                    usage: t("about %@ on average", ByteFormat.rate($0.average)))
            }
        } else {
            gaps.append(
                t(
                    "Per-app network use is turned off in Settings, so the apps using it are not known."
                ))
        }
        return AreaBrief(
            area: .network, start: input.start, end: input.end, status: status, headline: headline,
            facts: facts, normal: normal.map { t("about %@ in total", ByteFormat.rate($0)) },
            apps: apps,
            gaps: gaps,
            chart: AskChartLink(
                title: AskArea.network.title, laneIDs: ["network", "process.network"],
                start: input.start,
                end: input.end, processes: apps.map(\.identity)))
    }

    // MARK: Storage

    static func storage(_ input: AskBriefInputs) -> AreaBrief {
        let period = AskWords.period(input.start, input.end, now: input.now)
        let busy = AskSeries(input.points, busyThreshold: 60, value: { $0.diskUtilizationPercent })
        let normal = AskSeries.median(input.baseline) { $0.diskUtilizationPercent }
        var facts: [String] = []
        var notable: [String] = []
        var space = AskStatus.unknown
        var spaceHeadline: String?
        let free = input.live?.bootFreeBytes ?? input.points.last?.bootFreeBytes
        let total = input.live?.bootTotalBytes ?? input.points.last?.bootTotalBytes
        if let free, let total, total > 0 {
            let fraction = Double(free) / Double(total)
            facts.append(
                t(
                    "%1$@ free of %2$@ on the startup disk (%3$@).", ByteFormat.string(free),
                    ByteFormat.string(total), AskWords.percent(fraction * 100)))
            space =
                fraction < 0.05 || free < 10_000_000_000
                ? .attention : fraction < 0.1 || free < 20_000_000_000 ? .unusual : .calm
            spaceHeadline =
                space == .calm
                ? t("%@ free.", ByteFormat.string(free))
                : t(
                    "Only %@ free. The Mac slows down when its disk is nearly full.",
                    ByteFormat.string(free))
            if let earlier = (input.baseline.first ?? input.points.first)?.bootFreeBytes,
                earlier > free, earlier - free >= 5_000_000_000
            {
                notable.append(
                    t("Free space has dropped by %@ recently.", ByteFormat.string(earlier - free)))
            }
        }
        var activity = AskStatus.unknown
        if let busy {
            let read = AskSeries(input.points, value: { $0.diskReadBytesPerSec })?.mean ?? 0
            let write = AskSeries(input.points, value: { $0.diskWriteBytesPerSec })?.mean ?? 0
            facts.append(
                t(
                    "Over %1$@ the disk was busy %2$@ of the time, reading %3$@ and writing %4$@ on average.",
                    period,
                    AskWords.percent(busy.mean), ByteFormat.rate(read), ByteFormat.rate(write)))
            activity = busy.mean >= 60 ? .unusual : busy.mean >= 30 ? .busy : .calm
        }
        let status = max(space, activity)
        let headline: String
        if let spaceHeadline, space >= activity {
            headline = spaceHeadline
        } else if activity >= .busy {
            headline = t("The disk has been working hard.")
        } else {
            headline = spaceHeadline ?? t("No recent disk readings yet.")
        }
        let apps = input.apps.filter { $0.average >= 100_000 }.prefix(3).map {
            AskApp(
                name: $0.name, identity: $0.identity, kind: $0.kind, owner: $0.owner,
                usage: t("about %@ of reading and writing on average", ByteFormat.rate($0.average)))
        }
        return AreaBrief(
            area: .storage, start: input.start, end: input.end, status: status, headline: headline,
            facts: facts,
            normal: normal.map { t("disk busy about %@ of the time", AskWords.percent($0)) },
            apps: apps, notable: notable,
            chart: AskChartLink(
                title: AskArea.storage.title,
                laneIDs: ["capacity", "disk", "diskBusy", "process.diskWrite"],
                start: input.start, end: input.end, processes: apps.map(\.identity)))
    }

    // MARK: Battery and energy

    static func energy(_ input: AskBriefInputs) -> AreaBrief {
        var facts: [String] = []
        var gaps: [String] = []
        var status = AskStatus.calm
        var headline = t("No battery on this Mac.")
        let total = input.apps.prefix(10).reduce(0) { $0 + max(0, $1.average) }
        let apps = input.apps.prefix(3).compactMap { app -> AskApp? in
            guard total > 0, app.average > 0 else { return nil }
            return AskApp(
                name: app.name, identity: app.identity, kind: app.kind, owner: app.owner,
                major: app.average / total >= 0.25,
                usage: t(
                    "about %@ of the energy used by apps",
                    AskWords.percent(app.average / total * 100)))
        }
        if input.hasBattery {
            let charges = input.points.map(\.batteryCharge).filter { $0 > 0 }
            if let now = input.live?.batteryCharge ?? charges.last {
                facts.append(t("The battery is at %@.", AskWords.percent(now)))
                headline = t("Battery at %@.", AskWords.percent(now))
                if input.live?.batteryIsCharging == true {
                    facts.append(t("It is charging."))
                } else if input.live?.onExternalPower == true {
                    facts.append(t("It is plugged in."))
                }
            } else {
                status = .unknown
                headline = t("No battery readings yet.")
            }
            if let first = charges.first, let last = charges.last,
                let firstDate = input.points.first(where: { $0.batteryCharge > 0 })?.date,
                let lastDate = input.points.last(where: { $0.batteryCharge > 0 })?.date,
                lastDate.timeIntervalSince(firstDate) >= 900, first > last
            {
                let hours = lastDate.timeIntervalSince(firstDate) / 3600
                let perHour = (first - last) / hours
                facts.append(
                    t(
                        "It went from %1$@ to %2$@, about %3$@ an hour.", AskWords.percent(first),
                        AskWords.percent(last), AskWords.percent(perHour)))
                if perHour >= 20 {
                    status = .unusual
                    headline = t("Draining fast: about %@ an hour.", AskWords.percent(perHour))
                } else if perHour >= 10 {
                    status = .busy
                }
                if last > 0, input.live?.batteryIsCharging != true, perHour > 0 {
                    facts.append(
                        t(
                            "At that rate it would last about %@ more.",
                            AskWords.minutes(last / perHour * 3600)))
                }
            }
            if let now = input.live?.batteryCharge, now < 10, input.live?.onExternalPower != true {
                status = .attention
                headline = t("Battery low: %@. Plug in soon.", AskWords.percent(now))
            }
        } else {
            gaps.append(
                t("This Mac has no battery, so only which apps use the most energy is shown."))
        }
        if apps.isEmpty { gaps.append(t("No app energy use was recorded for this time.")) }
        return AreaBrief(
            area: .energy, start: input.start, end: input.end, status: status, headline: headline,
            facts: facts, apps: apps, gaps: gaps,
            chart: AskChartLink(
                title: AskArea.energy.title,
                laneIDs: input.hasBattery
                    ? ["charge", "batteryPower", "process.energyImpact"] : ["process.energyImpact"],
                start: input.start, end: input.end, processes: apps.map(\.identity)))
    }

    // MARK: Heat

    static func thermalWords(_ state: ThermalPressureState) -> String {
        switch state {
        case .nominal: return t("normal")
        case .fair: return t("warm, and macOS is starting to manage it")
        case .serious: return t("hot, and macOS is slowing the chip down to cool it")
        case .critical: return t("very hot, and macOS is slowing the chip down hard")
        }
    }

    static func heat(_ input: AskBriefInputs) -> AreaBrief {
        let period = AskWords.period(input.start, input.end, now: input.now)
        var facts: [String] = []
        var gaps: [String] = []
        var status = AskStatus.unknown
        var headline = t("No recent heat readings yet.")
        let states = input.points.compactMap(\.thermalPressure)
        let worst = (states + [input.live?.thermal].compactMap { $0 }).max()
        if let now = input.live?.thermal {
            facts.append(t("Right now the heat level is %@.", thermalWords(now)))
        }
        if let worst {
            if let recorded = states.max(), recorded > .nominal {
                let hot = Double(states.filter { $0 >= .fair }.count) / Double(max(1, states.count))
                facts.append(
                    t(
                        "Over %1$@ it reached %2$@, %3$@.", period, thermalWords(recorded),
                        AskWords.share(hot)))
            }
            status = worst >= .serious ? .attention : worst == .fair ? .busy : .calm
            headline = t("Heat level %@.", thermalWords(worst))
        }
        if let die = AskSeries(input.points, value: { $0.cpuDieC }, peak: { $0.cpuDieC }) {
            facts.append(
                t(
                    "The chip averaged %1$@ and reached %2$@ at %3$@.",
                    TemperatureFormat.string(die.mean), TemperatureFormat.string(die.peak),
                    AskWords.time(die.peakDate)))
            if status == .unknown {
                status = .calm
                headline = t("Running at a normal temperature.")
            }
        }
        if let fan = AskSeries(input.points, value: { $0.fanRPM }, peak: { _ in nil }) {
            facts.append(
                fan.peak < 100
                    ? t("The fans stayed off or nearly off.")
                    : t(
                        "The fans averaged %1$@ rpm and reached %2$@ rpm.",
                        String(Int64(fan.mean.rounded())),
                        String(Int64(fan.peak.rounded()))))
        } else if input.live?.fanRPM == nil {
            gaps.append(t("This Mac does not report a fan speed. Some Macs have no fan."))
        }
        let normal = AskSeries.median(input.baseline) { $0.cpuDieC }
        return AreaBrief(
            area: .heat, start: input.start, end: input.end, status: status, headline: headline,
            facts: facts, normal: normal.map { t("chip around %@", TemperatureFormat.string($0)) },
            gaps: gaps,
            chart: AskChartLink(
                title: AskArea.heat.title, laneIDs: ["thermalState", "die", "fans"],
                start: input.start,
                end: input.end))
    }

    // MARK: Helpers

    /// Grades a busy-type resource: absolute levels first, then how it compares
    /// with this Mac's normal, so a Mac that is always busy is not always
    /// "worth a look".
    static func grade(
        mean: Double, busy: Double, unusual: Double, attention: Double, sustained: Double,
        ratio: Double
    ) -> AskStatus {
        if mean >= attention && sustained >= 0.6 { return .attention }
        if mean >= unusual || (ratio >= 1.8 && mean >= busy * 0.8) { return .unusual }
        if mean >= busy { return .busy }
        return .calm
    }

    static func list(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names)
    }
}
