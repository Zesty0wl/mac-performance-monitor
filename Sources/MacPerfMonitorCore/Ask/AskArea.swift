import Foundation

/// A part of the Mac that Ask can look at and explain. Each has a friendly
/// name for people new to Macs, not the technical one the main window uses.
public enum AskArea: String, CaseIterable, Codable, Sendable, Identifiable {
    case overall, processor, memory, graphics, neuralEngine, network, storage, energy, heat

    public var id: String { rawValue }

    /// The areas shown as tiles and offered to the planner. `overall` is the
    /// summary of these, not a tile of its own.
    public static let parts: [AskArea] = [
        .processor, .memory, .graphics, .neuralEngine, .network, .storage, .energy, .heat,
    ]

    public var title: String {
        switch self {
        case .overall: return t("Your Mac overall")
        case .processor: return t("Processor")
        case .memory: return t("Memory")
        case .graphics: return t("Graphics")
        case .neuralEngine: return t("Neural Engine")
        case .network: return t("Network")
        case .storage: return t("Storage")
        case .energy: return t("Battery and energy")
        case .heat: return t("Heat")
        }
    }

    /// One line on what the part does, for someone who has never heard of it.
    public var explanation: String {
        switch self {
        case .overall: return t("How every part of your Mac is doing.")
        case .processor:
            return t("The chip that runs your apps. When it is busy, things slow down.")
        case .memory:
            return t(
                "Where open apps keep their work. When it runs short, the Mac uses the disk instead, which is slower."
            )
        case .graphics: return t("Draws everything on screen, and runs games, video and some AI.")
        case .neuralEngine:
            return t("A part of the chip built for AI features like dictation and photo search.")
        case .network: return t("What your Mac sends and receives over Wi-Fi or a cable.")
        case .storage: return t("Your disk: how much space is left, and how hard it is working.")
        case .energy: return t("How much power your Mac uses, and which apps use the most.")
        case .heat:
            return t(
                "How warm the chip is running, and whether macOS is slowing it down to cool it.")
        }
    }

    public var symbol: String {
        switch self {
        case .overall: return "gauge.with.dots.needle.50percent"
        case .processor: return "cpu"
        case .memory: return "memorychip"
        case .graphics: return "display"
        case .neuralEngine: return "brain"
        case .network: return "network"
        case .storage: return "internaldrive"
        case .energy: return "bolt.fill"
        case .heat: return "thermometer.medium"
        }
    }
}

/// How an area is doing, in words a newcomer can act on. Ordered from least to
/// most concerning, so the overall status is the highest of the parts.
public enum AskStatus: Int, Codable, Sendable, Comparable {
    case unknown, calm, busy, unusual, attention

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .unknown: return t("Not enough data")
        case .calm: return t("Calm")
        case .busy: return t("Busy")
        case .unusual: return t("Worth a look")
        case .attention: return t("Needs attention")
        }
    }
}

/// Where a chart link lands: the Explorer charts to show, the time to show
/// them for, and the apps to select. Built by Swift from what it checked, so a
/// link is always there and always matches the answer's facts.
public struct AskChartLink: Codable, Sendable, Hashable {
    public var title: String
    public var laneIDs: [String]
    public var start: Date
    public var end: Date
    public var processes: [ProcessIdentity]

    public init(
        title: String, laneIDs: [String], start: Date, end: Date,
        processes: [ProcessIdentity] = []
    ) {
        self.title = title
        self.laneIDs = laneIDs
        self.start = start
        self.end = end
        self.processes = Array(processes.prefix(4))
    }
}

/// An app that stood out in an area, with its use already put into words.
public struct AskApp: Codable, Sendable, Hashable {
    public var name: String
    public var identity: ProcessIdentity
    public var usage: String

    public init(name: String, identity: ProcessIdentity, usage: String) {
        self.name = name
        self.identity = identity
        self.usage = usage
    }
}

/// Everything Ask knows about one area over one stretch of time, already
/// judged and phrased. The model reads `promptText`; the window shows the same
/// facts under "What I looked at".
public struct AreaBrief: Codable, Sendable, Hashable {
    public var area: AskArea
    public var start: Date
    public var end: Date
    public var status: AskStatus
    /// A short line for the area's tile: "About a quarter busy, as usual."
    public var headline: String
    /// Ready-to-read facts about the period.
    public var facts: [String]
    /// What is normal for this Mac, when there is enough history to say.
    public var normal: String?
    public var apps: [AskApp]
    /// Things worth pointing out: spikes, steady growth, alerts.
    public var notable: [String]
    /// What Ask could not see, so it does not guess.
    public var gaps: [String]
    public var chart: AskChartLink?

    public init(
        area: AskArea, start: Date, end: Date, status: AskStatus, headline: String,
        facts: [String] = [], normal: String? = nil, apps: [AskApp] = [],
        notable: [String] = [], gaps: [String] = [], chart: AskChartLink? = nil
    ) {
        self.area = area
        self.start = start
        self.end = end
        self.status = status
        self.headline = headline
        self.facts = facts
        self.normal = normal
        self.apps = apps
        self.notable = notable
        self.gaps = gaps
        self.chart = chart
    }

    /// The facts as the model sees them. Plain lines, no identifiers, so the
    /// model has nothing to do but explain. Process names are data, never
    /// instructions, and are quoted.
    public var promptText: String {
        var lines = ["## \(area.title): \(status.title)", headline]
        lines += facts.map { "- \($0)" }
        if let normal { lines.append("- " + t("Normal for this Mac: %@", normal)) }
        if !apps.isEmpty {
            lines.append(t("Apps using the most:"))
            lines += apps.map { "- \"\($0.name)\": \($0.usage)" }
        }
        lines += notable.map { "- " + t("Worth noting: %@", $0) }
        lines += gaps.map { "- " + t("Not known: %@", $0) }
        return lines.joined(separator: "\n")
    }
}
