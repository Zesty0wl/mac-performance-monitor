import Foundation

/// A plain-language "what is this process?" glossary. Like the check catalog, it is
/// data — a signed JSON file downloaded from the server and matched LOCALLY, so the
/// set of explanations grows without an app release and no process name ever leaves
/// the Mac. Pure + Codable, so it lives in Core and is unit-tested.
public struct ProcessGlossary: Codable, Sendable, Equatable {
    public var version: Int
    public var entries: [Entry]

    public init(version: Int, entries: [Entry]) {
        self.version = version
        self.entries = entries
    }

    /// How an entry is matched to a running process. Fields are tried most-specific
    /// first (see `lookup`); generic catch-alls use prefix or pattern fields.
    public struct Match: Codable, Sendable, Equatable {
        public var name: String?  // exact executable name, e.g. "mDNSResponder"
        public var bundleID: String?  // exact bundle id
        public var bundleIDPrefix: String?  // e.g. "com.google.Chrome.helper", "com.apple."
        public var path: String?  // exact executable path, e.g. "/usr/bin/log"
        public var pathPrefix: String?  // e.g. "/System/Library/"
        public var pathSuffix: String?  // stable tail below a versioned or UUID directory
        public var pathPattern: String?  // case-sensitive substring of the executable path
        public var namePattern: String?  // case-insensitive substring of the name

        public init(
            name: String? = nil, bundleID: String? = nil, bundleIDPrefix: String? = nil,
            path: String? = nil, pathPrefix: String? = nil, pathSuffix: String? = nil,
            pathPattern: String? = nil, namePattern: String? = nil
        ) {
            self.name = name
            self.bundleID = bundleID
            self.bundleIDPrefix = bundleIDPrefix
            self.path = path
            self.pathPrefix = pathPrefix
            self.pathSuffix = pathSuffix
            self.pathPattern = pathPattern
            self.namePattern = namePattern
        }
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var match: Match
        public var title: String
        public var description: String
        /// system | app | helper | background | developer | security (free-form; the
        /// UI maps known values to an icon/tint and tolerates unknowns).
        public var category: String
        public var vendor: String?
        public var url: String?
        /// True when high CPU/RAM is normal for this process (e.g. WindowServer), so
        /// the UI — and later the diagnostics — can soften alarms.
        public var expectedHigh: Bool?

        public var id: String {
            match.bundleID ?? match.path ?? match.name ?? match.bundleIDPrefix ?? match.pathPrefix
                ?? match.pathSuffix ?? match.pathPattern ?? match.namePattern ?? title
        }

        public init(
            match: Match, title: String, description: String, category: String,
            vendor: String? = nil, url: String? = nil, expectedHigh: Bool? = nil
        ) {
            self.match = match
            self.title = title
            self.description = description
            self.category = category
            self.vendor = vendor
            self.url = url
            self.expectedHigh = expectedHigh
        }
    }

    /// The best entry for a process, most-specific first:
    /// exact bundle id → exact path → longest path suffix/substring → exact name →
    /// longest bundle-id prefix → longest path prefix → name substring. Path-aware
    /// rules keep generic executable names such as `log` or `tracer` from labeling
    /// unrelated software. Returns nil when nothing matches.
    public func lookup(name: String, bundleID: String?, path: String?) -> Entry? {
        // The kernel name (p_comm) is truncated to ~15 chars, so entries key on the
        // FULL name recovered from the executable's filename. Match that (and the raw
        // truncated name as a fallback).
        let resolved = ProcessSample.resolvedDisplayName(name: name, executablePath: path)
        if let bundleID, let e = entries.first(where: { $0.match.bundleID == bundleID }) {
            return e
        }
        if let path, let e = entries.first(where: { $0.match.path == path }) { return e }
        if let path, let e = longestSuffixMatch(path, keyPath: \.match.pathSuffix) { return e }
        if let path, let e = longestContainsMatch(path, keyPath: \.match.pathPattern) { return e }
        if let e = entries.first(where: { $0.match.name == resolved || $0.match.name == name }) {
            return e
        }
        if let bundleID, let e = longestPrefixMatch(bundleID, keyPath: \.match.bundleIDPrefix) {
            return e
        }
        if let path, let e = longestPrefixMatch(path, keyPath: \.match.pathPrefix) { return e }
        if let e = entries.first(where: {
            $0.match.namePattern.map {
                resolved.localizedCaseInsensitiveContains($0)
                    || name.localizedCaseInsensitiveContains($0)
            } ?? false
        }) {
            return e
        }
        return nil
    }

    private func longestPrefixMatch(_ value: String, keyPath: KeyPath<Entry, String?>) -> Entry? {
        entries
            .filter { ($0[keyPath: keyPath]).map(value.hasPrefix) ?? false }
            .max { ($0[keyPath: keyPath]?.count ?? 0) < ($1[keyPath: keyPath]?.count ?? 0) }
    }

    private func longestSuffixMatch(_ value: String, keyPath: KeyPath<Entry, String?>) -> Entry? {
        entries
            .filter { ($0[keyPath: keyPath]).map(value.hasSuffix) ?? false }
            .max { ($0[keyPath: keyPath]?.count ?? 0) < ($1[keyPath: keyPath]?.count ?? 0) }
    }

    private func longestContainsMatch(
        _ value: String, keyPath: KeyPath<Entry, String?>
    ) -> Entry? {
        entries
            .filter { ($0[keyPath: keyPath]).map(value.contains) ?? false }
            .max { ($0[keyPath: keyPath]?.count ?? 0) < ($1[keyPath: keyPath]?.count ?? 0) }
    }

    /// A best-effort line when nothing in the glossary matches, derived from the
    /// path/bundle id — so the UI always shows *something* and the user can tell at a
    /// glance roughly what kind of process it is.
    public static func generic(
        name: String, bundleID: String?, path: String?
    )
        -> (title: String, detail: String, category: String)
    {
        if let path, let appName = appName(fromPath: path) {
            return ("Part of \(appName)", "A process belonging to the app “\(appName)”.", "app")
        }
        if let bundleID, bundleID.hasPrefix("com.apple.") {
            return ("Apple system process", "A built-in macOS component.", "system")
        }
        if let path, path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") {
            return ("System process", "A low-level macOS background process.", "system")
        }
        return (
            "No description yet", "We don't have an explanation for this process yet.", "background"
        )
    }

    /// Extract "Foo" from "/Applications/Foo.app/Contents/MacOS/…".
    private static func appName(fromPath path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? path.range(of: ".app") else { return nil }
        let upto = String(path[path.startIndex..<range.lowerBound])
        guard let slash = upto.lastIndex(of: "/") else { return nil }
        let name = String(upto[upto.index(after: slash)...])
        return name.isEmpty ? nil : name
    }
}
