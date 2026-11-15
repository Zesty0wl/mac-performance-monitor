import Foundation

/// A user-defined set of processes whose combined resource footprint is tracked
/// together. Membership is a boolean predicate tree (`GroupRule`) over each
/// process's own attributes, so it survives PID churn and applies retroactively
/// to history. Pure + Codable so it lives in Core, is unit-tested, and is
/// persisted as JSON by the app.
public struct ProcessGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Root of the membership predicate tree. A process belongs to the group when
    /// this evaluates true; an empty tree matches nothing.
    public var rule: GroupRule

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        rule: GroupRule = .any([])
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.rule = rule
    }

    /// OR a node into the group's root — the "Add to group" action. If the root is
    /// already an `any` (OR) it is appended; otherwise the existing root and the
    /// new node are wrapped in a fresh `any`.
    public mutating func add(_ node: GroupRule) {
        switch rule {
        case .any(var children):
            guard !children.contains(node) else { return }
            children.append(node)
            rule = .any(children)
        default:
            rule = .any([rule, node])
        }
    }
}

/// A boolean predicate tree defining group membership. Leaf `condition`s are
/// combined by `all` (AND) / `any` (OR), and any node can be negated with `not`,
/// nested arbitrarily. Auto-`Codable`/`Hashable` (Swift synthesizes both for
/// enums with associated values), so it persists as JSON and can key a cache.
public indirect enum GroupRule: Codable, Sendable, Equatable, Hashable {
    case condition(GroupCondition)
    /// AND — true only when it has children and every child is true.
    case all([GroupRule])
    /// OR — true when any child is true (false when empty).
    case any([GroupRule])
    /// Negation.
    case not(GroupRule)

    /// Whether the tree contains at least one condition. A node built only from
    /// empty collections matches nothing — this guards against a group that would
    /// otherwise silently capture every process (e.g. an empty `all`, which is
    /// vacuously true).
    public var hasCondition: Bool {
        switch self {
        case .condition: return true
        case .all(let children), .any(let children): return children.contains { $0.hasCondition }
        case .not(let child): return child.hasCondition
        }
    }
}

/// One leaf predicate: a `field` of the process compared to `value` by `op`.
/// Value-typed equality (by field/op/value) so structurally-identical conditions
/// compare equal — used for dedup and as part of the report cache key.
public struct GroupCondition: Codable, Sendable, Equatable, Hashable {
    /// Which attribute of the process to test. `classification` and `vendor` are
    /// resolved through the glossary; the rest are read from the process directly.
    public enum Field: String, Codable, Sendable, CaseIterable {
        case bundleID
        case name
        case path
        case teamID
        case classification  // glossary category, e.g. "security"
        case vendor  // glossary vendor, e.g. "Microsoft"
        case commandLabel  // what an interpreter runs (`CommandLabel`), e.g. "train.py"
    }

    /// How `value` is compared to the field. All comparisons are case-insensitive.
    public enum Op: String, Codable, Sendable, CaseIterable {
        case equals  // "is"
        case contains
        case startsWith
    }

    public var field: Field
    public var op: Op
    public var value: String

    public init(field: Field, op: Op = .equals, value: String = "") {
        self.field = field
        self.op = op
        self.value = value
    }

    /// Every field supports every operator. Keeps the editor flexible (e.g.
    /// "Team ID contains", "Vendor starts with") and means the operator picker is
    /// never disabled — `equals` is just the sensible default.
    public static func operators(for field: Field) -> [Op] {
        [.equals, .contains, .startsWith]
    }

    public var isEmpty: Bool { value.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Pure membership evaluation, shared by the live UI and the history queries.
/// Classification/vendor predicates are resolved through the glossary; the rest
/// are direct string checks against the process's own attributes.
public enum GroupMatcher {
    /// The process attributes needed to test membership. Built from a live
    /// `ProcessSample` or a stored `processes` row.
    public struct Candidate {
        public var name: String
        public var bundleID: String?
        public var executablePath: String?
        public var teamID: String?
        /// What an interpreter is running (`CommandLabel`), so a rule can pick
        /// out one python3 by its script. Nil for everything else.
        public var commandLabel: String?

        public init(
            name: String, bundleID: String?, executablePath: String?, teamID: String?,
            commandLabel: String? = nil
        ) {
            self.name = name
            self.bundleID = bundleID
            self.executablePath = executablePath
            self.teamID = teamID
            self.commandLabel = commandLabel
        }

        public init(sample: ProcessSample) {
            self.init(
                name: sample.name, bundleID: sample.bundleID,
                executablePath: sample.executablePath, teamID: sample.teamID,
                commandLabel: sample.commandLabel)
        }
    }

    /// Whether `candidate` belongs to a group with this `rule`. `glossary` is only
    /// consulted for classification/vendor predicates, and resolved at most once.
    public static func matches(
        _ candidate: Candidate, rule: GroupRule, glossary: ProcessGlossary?
    ) -> Bool {
        guard rule.hasCondition else { return false }
        var resolved: ProcessGlossary.Entry??
        func entry() -> ProcessGlossary.Entry? {
            if let cached = resolved { return cached }
            let e = glossary?.lookup(
                name: candidate.name, bundleID: candidate.bundleID,
                path: candidate.executablePath)
            resolved = .some(e)
            return e
        }
        return evaluate(rule, candidate, entry)
    }

    static func evaluate(
        _ rule: GroupRule, _ c: Candidate, _ entry: () -> ProcessGlossary.Entry?
    ) -> Bool {
        switch rule {
        case .condition(let cond): return matches(c, cond, entry)
        case .all(let children):
            return !children.isEmpty && children.allSatisfy { evaluate($0, c, entry) }
        case .any(let children): return children.contains { evaluate($0, c, entry) }
        case .not(let child): return !evaluate(child, c, entry)
        }
    }

    static func matches(
        _ c: Candidate, _ cond: GroupCondition, _ entry: () -> ProcessGlossary.Entry?
    ) -> Bool {
        let value = cond.value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return false }
        // `name` is matched against both the kernel name and the de-truncated
        // display name, since p_comm is capped at ~15 characters.
        let targets: [String]
        switch cond.field {
        case .bundleID: targets = [c.bundleID].compactMap { $0 }
        case .name:
            let resolved = ProcessSample.resolvedDisplayName(
                name: c.name, executablePath: c.executablePath)
            targets = Array(Set([c.name, resolved]))
        case .path: targets = [c.executablePath].compactMap { $0 }
        case .teamID: targets = [c.teamID].compactMap { $0 }
        case .classification: targets = [entry()?.category].compactMap { $0 }
        case .vendor: targets = [entry()?.vendor].compactMap { $0 }
        case .commandLabel: targets = [c.commandLabel].compactMap { $0 }
        }
        guard !targets.isEmpty else { return false }
        return targets.contains { satisfies($0, cond.op, value) }
    }

    private static func satisfies(
        _ target: String, _ op: GroupCondition.Op, _ value: String
    ) -> Bool {
        switch op {
        case .equals: return target.caseInsensitiveCompare(value) == .orderedSame
        case .contains: return target.localizedCaseInsensitiveContains(value)
        case .startsWith: return target.lowercased().hasPrefix(value.lowercased())
        }
    }

    /// The most durable single-condition rule for a concrete process — the
    /// "Add to group" default: prefer Team ID, then bundle id, then executable
    /// path (as a prefix), falling back to the name.
    public static func condition(for c: Candidate) -> GroupRule {
        if let t = c.teamID, !t.isEmpty {
            return .condition(GroupCondition(field: .teamID, op: .equals, value: t))
        }
        if let b = c.bundleID, !b.isEmpty {
            return .condition(GroupCondition(field: .bundleID, op: .equals, value: b))
        }
        if let p = c.executablePath, !p.isEmpty {
            return .condition(GroupCondition(field: .path, op: .startsWith, value: p))
        }
        return .condition(GroupCondition(field: .name, op: .equals, value: c.name))
    }
}
