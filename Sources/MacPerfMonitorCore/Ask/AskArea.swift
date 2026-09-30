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
        case .energy: return t("Battery")
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

    /// The question a tile tap asks, written out per area so each language
    /// can phrase it naturally.
    public var question: String {
        switch self {
        case .overall: return t("How is my Mac doing?")
        case .processor: return t("How is my processor doing?")
        case .memory: return t("How is my memory doing?")
        case .graphics: return t("How is my graphics chip doing?")
        case .neuralEngine: return t("How is my Neural Engine doing?")
        case .network: return t("How is my network doing?")
        case .storage: return t("How is my storage doing?")
        case .energy: return t("How is my battery doing?")
        case .heat: return t("How hot is my Mac running?")
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

    /// What the status means, for the model and for accessibility.
    public var meaning: String {
        switch self {
        case .unknown: return t("there are no readings to judge from")
        case .calm: return t("nothing here needs attention")
        case .busy: return t("working hard, but coping")
        case .unusual: return t("different from normal for this Mac, worth a look")
        case .attention: return t("likely to be causing problems")
        }
    }

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

/// What kind of thing a process is, so advice only ever tells someone to
/// quit something they can actually quit.
public enum AskProcessKind: String, Codable, Sendable, Hashable {
    /// An app, or a helper inside one (a browser's renderer).
    case app
    /// Part of macOS: WindowServer, contactsd, mds_stores.
    case system
    /// Anything else running in the background: a command-line tool, a daemon.
    case background

    /// Classifies by where the executable lives, and finds the app a helper
    /// belongs to ("Google Chrome" for its renderer).
    public static func classify(path: String?) -> (kind: AskProcessKind, app: String?) {
        // A run recorded mid-launch keeps the launcher's path; where it
        // really lives is unknown.
        guard let path, !path.isEmpty, path != SustainedCPU.launcherPath else {
            return (.background, nil)
        }
        let systemRoots = [
            "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/",
            "/Library/Apple/",
        ]
        if systemRoots.contains(where: { path.hasPrefix($0) }) { return (.system, nil) }
        if let range = path.range(of: ".app/") {
            let bundle = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
            return (.app, bundle.isEmpty ? nil : bundle)
        }
        return (.background, nil)
    }

    /// How the model is told what it is, after the name.
    var note: String? {
        switch self {
        case .app: return nil
        case .system: return t("part of macOS")
        case .background: return t("a background process")
        }
    }
}

/// An app that stood out in an area, with its use already put into words.
public struct AskApp: Codable, Sendable, Hashable {
    public var name: String
    public var identity: ProcessIdentity
    public var usage: String
    public var kind: AskProcessKind
    /// The app to quit for this process, when it is one or belongs to one.
    public var owner: String?
    /// Whether its share is big enough to be a cause. A process using 2% of a
    /// busy processor is listed for context, never blamed or quit.
    public var major: Bool

    public init(
        name: String, identity: ProcessIdentity, kind: AskProcessKind = .app, owner: String? = nil,
        major: Bool = true, usage: String
    ) {
        self.name = name
        self.identity = identity
        self.usage = usage
        self.kind = kind
        self.owner = owner
        self.major = major
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
    /// Safe, simple next steps that fit this area and status, so the model
    /// picks advice from a known list instead of inventing it.
    public var advice: [String] = []
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
        var lines = [
            "## \(area.title)", t("Status: %1$@ (%2$@)", status.title, status.meaning), headline,
        ]
        lines += facts.map { "- \($0)" }
        if let normal { lines.append("- " + t("Normal for this Mac: %@", normal)) }
        if !apps.isEmpty {
            lines.append(
                status <= .calm
                    ? t("Apps using the most (normal amounts, not a problem):")
                    : t("Apps using the most:"))
            lines += apps.map { app in
                let notes = [app.kind.note, app.major ? nil : t("a small share, not the cause")]
                    .compactMap { $0 }
                return "- \"\(app.name)\""
                    + (notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))")
                    + ": \(app.usage)"
            }
        }
        lines += notable.map { "- " + t("Worth noting: %@", $0) }
        lines += gaps.map { "- " + t("Not known: %@", $0) }
        if !advice.isEmpty {
            lines.append(t("Things that help:"))
            lines += advice.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}
