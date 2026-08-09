import Foundation

/// The on-demand, deep per-process memory inspection feature: a thin, secure
/// wrapper around Apple's own developer tools (`footprint`, `heap`, `leaks`)
/// plus parsers that turn their text output into structured values the UI can
/// render and diff.
///
/// Why shell out to the system tools instead of reading the data ourselves:
/// `heap`/`vmmap`/`leaks` carry the Apple-private `com.apple.system-task-ports`
/// entitlement, which lets them obtain the task port of processes a third-party
/// app cannot (anything without `get-task-allow`, i.e. almost every shipping
/// app, is otherwise protected by SIP even from root). By invoking the signed
/// tools we piggyback on their entitlement rather than calling `task_for_pid`
/// directly, so the inspector works where a direct read never could.
///
/// Everything here is pure value types and string parsing with no process
/// execution, so it is fully unit-testable against captured tool output. The
/// actual (privileged, security-sensitive) execution lives in `MemoryToolRunner`.
public enum MemoryInspection {}

// MARK: - Tools

extension MemoryInspection {
    /// The fixed set of Apple memory tools the inspector may run. The raw value
    /// is the stable wire code sent across XPC to the root helper, so the helper
    /// can map it back to an allow-listed absolute path without ever trusting a
    /// caller-supplied command string.
    public enum Tool: Int, CaseIterable, Sendable, Codable {
        case footprint = 0
        case heap = 1
        case leaks = 2
        /// CPU/activity profiler (`/usr/bin/sample`): samples the target's call
        /// stacks for a few seconds so we can see what it is actually doing. Not a
        /// memory tool, but it rides the same secure allow-list + runner, and like
        /// the others it carries the entitlement to inspect protected processes.
        case sample = 3

        /// The absolute, hard-coded path of the signed Apple binary. Never built
        /// from user input, so a compromised caller cannot redirect execution.
        public var executablePath: String {
            switch self {
            case .footprint: return "/usr/bin/footprint"
            case .heap: return "/usr/bin/heap"
            case .leaks: return "/usr/bin/leaks"
            case .sample: return "/usr/bin/sample"
            }
        }

        /// The argument vector for a target PID. The PID is the only variable and
        /// is passed as a separate argument (never interpolated into a shell
        /// string), so it cannot inject further arguments.
        public func arguments(pid: Int32) -> [String] {
            switch self {
            case .footprint: return [String(pid)]
            case .heap: return [String(pid)]
            case .leaks: return [String(pid)]
            // pid, 5s duration, 10ms interval, tolerate the target exiting mid-run.
            case .sample: return [String(pid), "5", "10", "-mayDie"]
            }
        }

        /// A human label for empty/error states.
        public var label: String {
            switch self {
            case .footprint: return "footprint"
            case .heap: return "heap"
            case .leaks: return "leaks"
            case .sample: return "sample"
            }
        }
    }
}

// MARK: - Shared failure detection

extension MemoryInspection {
    /// Whether a tool's combined stdout/stderr indicates the OS refused access
    /// (the target is owned by another user or is system/SIP-protected and the
    /// caller is not privileged). Used to turn a raw failure into actionable UI
    /// guidance ("enable Full Coverage") rather than a confusing empty result.
    public static func indicatesPrivilegeFailure(_ output: String) -> Bool {
        let markers = [
            "appropriate privileges",
            "cannot examine process",
            "try running with",
            "try as root",
            "mach port for process 0 not valid",
            "Unable to find pid",
        ]
        return markers.contains { output.localizedCaseInsensitiveContains($0) }
    }
}

// MARK: - Byte parsing

extension MemoryInspection {
    /// Parse a tool-formatted size such as `"90 MB"`, `"0 B"`, `"6592 KB"`, or
    /// `"121.1M"` into bytes. Accepts both the spaced form `footprint` prints and
    /// the compact form `vmmap`/`heap` headers print. Returns nil if it cannot
    /// be parsed.
    public static func parseBytes(_ raw: String) -> UInt64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Split a trailing unit (with or without a space) from the number.
        var numberPart = trimmed
        var unit = "B"
        if let spaceIndex = trimmed.lastIndex(of: " ") {
            numberPart = String(trimmed[..<spaceIndex])
            unit = String(trimmed[trimmed.index(after: spaceIndex)...])
        } else if let firstUnitChar = trimmed.firstIndex(where: { "KMGTB".contains($0) }) {
            numberPart = String(trimmed[..<firstUnitChar])
            unit = String(trimmed[firstUnitChar...])
        }

        guard let value = Double(numberPart.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        let multiplier: Double
        switch unit.uppercased().first {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1  // "B" or bare number
        }
        // The value comes straight from a parsed tool token, so it can be
        // negative (a stray "-" token), infinite, NaN, or simply larger than
        // UInt64 can hold. `UInt64(_:)` traps on any of those, taking down the
        // inspector; `UInt64(exactly:)` returns nil instead, which is what this
        // function's "returns nil if it cannot be parsed" contract promises.
        return UInt64(exactly: (value * multiplier).rounded())
    }
}

// MARK: - footprint

extension MemoryInspection {
    /// One memory region category from `footprint`, e.g. MALLOC_SMALL or
    /// IOSurface, with its dirty/clean/reclaimable bytes and region count.
    public struct FootprintRegion: Sendable, Equatable, Identifiable {
        public var category: String
        public var dirtyBytes: UInt64
        public var cleanBytes: UInt64
        public var reclaimableBytes: UInt64
        public var regionCount: Int

        public var id: String { category }

        public init(
            category: String, dirtyBytes: UInt64, cleanBytes: UInt64,
            reclaimableBytes: UInt64, regionCount: Int
        ) {
            self.category = category
            self.dirtyBytes = dirtyBytes
            self.cleanBytes = cleanBytes
            self.reclaimableBytes = reclaimableBytes
            self.regionCount = regionCount
        }
    }

    /// A parsed `footprint` report: the headline total plus the per-category
    /// region breakdown, sorted largest dirty first.
    public struct FootprintSnapshot: Sendable, Equatable {
        public var totalBytes: UInt64
        public var regions: [FootprintRegion]

        public init(totalBytes: UInt64, regions: [FootprintRegion]) {
            self.totalBytes = totalBytes
            self.regions = regions
        }
    }

    /// Parse `/usr/bin/footprint <pid>` output. Returns nil if no recognisable
    /// region rows were found (e.g. the tool printed only a privilege error).
    public static func parseFootprint(_ output: String) -> FootprintSnapshot? {
        var total: UInt64 = 0
        if let totalRange = output.range(
            of: #"Footprint:\s+([\d.]+\s*[KMGT]?B)"#, options: .regularExpression)
        {
            let slice = String(output[totalRange])
            if let sizeRange = slice.range(
                of: #"[\d.]+\s*[KMGT]?B"#, options: .regularExpression)
            {
                total = parseBytes(String(slice[sizeRange])) ?? 0
            }
        }

        // Each region row is: <dirty> <clean> <reclaimable> <regions> <category>,
        // where the three sizes are "<num> <unit>" and the category is free text
        // (may contain spaces and parentheses).
        let rowPattern =
            #"^\s*([\d.]+\s+[KMGT]?B)\s+([\d.]+\s+[KMGT]?B)\s+([\d.]+\s+[KMGT]?B)\s+(\d+)\s+(.+?)\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: rowPattern, options: [.anchorsMatchLines])
        else { return nil }

        var regions: [FootprintRegion] = []
        let ns = output as NSString
        let matches = regex.matches(
            in: output, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let dirty = parseBytes(ns.substring(with: match.range(at: 1))) ?? 0
            let clean = parseBytes(ns.substring(with: match.range(at: 2))) ?? 0
            let reclaimable = parseBytes(ns.substring(with: match.range(at: 3))) ?? 0
            let count = Int(ns.substring(with: match.range(at: 4))) ?? 0
            let category = ns.substring(with: match.range(at: 5))
                .trimmingCharacters(in: .whitespaces)
            guard !category.isEmpty else { continue }
            regions.append(
                FootprintRegion(
                    category: category, dirtyBytes: dirty, cleanBytes: clean,
                    reclaimableBytes: reclaimable, regionCount: count))
        }

        guard !regions.isEmpty else { return nil }
        regions.sort { $0.dirtyBytes > $1.dirtyBytes }
        return FootprintSnapshot(totalBytes: total, regions: regions)
    }
}

// MARK: - heap

extension MemoryInspection {
    /// One class/type row from a `heap` census: how many live instances of a
    /// class exist and how many bytes they occupy.
    public struct HeapClassCensus: Sendable, Equatable, Identifiable {
        public var className: String
        public var instanceCount: Int
        public var totalBytes: UInt64
        /// The allocator/language bucket the tool assigns: ObjC, Swift, C, C++,
        /// CFType, or empty for the catch-all `non-object` row.
        public var type: String
        /// The owning binary/framework, or empty/`<unknown>` when the tool can't
        /// attribute it.
        public var binary: String

        public var id: String { className + "\u{1}" + binary }

        public init(
            className: String, instanceCount: Int, totalBytes: UInt64,
            type: String, binary: String
        ) {
            self.className = className
            self.instanceCount = instanceCount
            self.totalBytes = totalBytes
            self.type = type
            self.binary = binary
        }
    }

    /// A parsed `heap` report: overall node totals plus the per-class census,
    /// sorted by byte size descending.
    public struct HeapSnapshot: Sendable, Equatable {
        public var totalNodes: Int
        public var totalBytes: UInt64
        public var classes: [HeapClassCensus]

        public init(totalNodes: Int, totalBytes: UInt64, classes: [HeapClassCensus]) {
            self.totalNodes = totalNodes
            self.totalBytes = totalBytes
            self.classes = classes
        }
    }

    /// Parse `/usr/bin/heap <pid>` output. Returns nil if no census rows were
    /// found (e.g. the tool printed only a privilege error).
    public static func parseHeap(_ output: String) -> HeapSnapshot? {
        var totalNodes = 0
        var totalBytes: UInt64 = 0
        // "All zones: 202503 nodes (47995927 bytes)"
        if let range = output.range(
            of: #"All zones:\s+(\d+)\s+nodes\s+\((\d+)\s+bytes\)"#,
            options: .regularExpression)
        {
            let slice = String(output[range])
            let numbers = slice.matches(of: #/(\d+)/#).map { String($0.output.1) }
            if numbers.count >= 2 {
                totalNodes = Int(numbers[0]) ?? 0
                totalBytes = UInt64(numbers[1]) ?? 0
            }
        }

        // Census rows: COUNT BYTES AVG CLASS_NAME [TYPE BINARY]. CLASS_NAME may
        // contain single spaces; the optional TYPE/BINARY follow a 2+ space gap.
        // Order the type alternation so "C++" is tried before "C".
        let rowPattern =
            #"^\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(.+?)(?:\s{2,}(ObjC|Swift|C\+\+|C|CFType)\s+(.+?))?\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: rowPattern, options: [.anchorsMatchLines])
        else { return nil }

        var classes: [HeapClassCensus] = []
        let ns = output as NSString
        let matches = regex.matches(
            in: output, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard let count = Int(ns.substring(with: match.range(at: 1))),
                let bytes = UInt64(ns.substring(with: match.range(at: 2)))
            else { continue }
            let className = ns.substring(with: match.range(at: 4))
                .trimmingCharacters(in: .whitespaces)
            guard !className.isEmpty else { continue }
            var type = ""
            if match.range(at: 5).location != NSNotFound {
                type = ns.substring(with: match.range(at: 5))
            }
            var binary = ""
            if match.range(at: 6).location != NSNotFound {
                binary = ns.substring(with: match.range(at: 6))
                    .trimmingCharacters(in: .whitespaces)
            }
            classes.append(
                HeapClassCensus(
                    className: className, instanceCount: count, totalBytes: bytes,
                    type: type, binary: binary))
        }

        guard !classes.isEmpty else { return nil }
        classes.sort { $0.totalBytes > $1.totalBytes }
        return HeapSnapshot(totalNodes: totalNodes, totalBytes: totalBytes, classes: classes)
    }
}

// MARK: - leaks

extension MemoryInspection {
    /// A parsed `leaks` summary: how many nodes are allocated, how many are
    /// genuinely leaked (unreachable), and whether the tool had full debug access
    /// (needed to show leak backtraces; absent for hardened release builds).
    public struct LeaksSummary: Sendable, Equatable {
        public var totalNodes: Int
        public var totalBytes: UInt64
        public var leakCount: Int
        public var leakedBytes: UInt64
        /// False when `leaks` reported the target "is not debuggable" — it can
        /// still count leaks but cannot show their contents or backtraces.
        public var isDebuggable: Bool

        public init(
            totalNodes: Int, totalBytes: UInt64, leakCount: Int,
            leakedBytes: UInt64, isDebuggable: Bool
        ) {
            self.totalNodes = totalNodes
            self.totalBytes = totalBytes
            self.leakCount = leakCount
            self.leakedBytes = leakedBytes
            self.isDebuggable = isDebuggable
        }

        /// How much weight a leaks result deserves in the UI.
        ///
        /// `/usr/bin/leaks` finds leaks with a *conservative* scan: it walks every
        /// malloc block and flags any it cannot find a pointer to. On a process
        /// without `get-task-allow` — which is every shipping app, including
        /// Apple's own (Music, Safari, …) and hardened third-party builds — it can
        /// only partially read the target's memory, so it cannot see many of the
        /// references that exist and routinely flags blocks that are NOT real
        /// leaks. A non-zero count on such a process is therefore expected noise,
        /// not evidence of a bug. The trustworthy signal for a genuine leak is
        /// sustained *growth* across snapshots (the Leak Hunt), so a single-sample
        /// count is only ever raised to a warning for a fully debuggable build
        /// (a debug build with get-task-allow) where the scan can be trusted.
        /// This keeps the inspector from crying wolf on essentially every process.
        public enum Significance: Sendable, Equatable {
            /// No unreachable allocations at all.
            case none
            /// Background noise: a few small leaks, or any count on a process we
            /// can't fully inspect (a conservative-scan estimate). Not actionable.
            case minor
            /// A large, trustworthy leaked volume on a debuggable build — worth
            /// investigating.
            case notable
        }

        /// Leaked bytes at or above which a result is `.notable` (1 MiB).
        public static let notableLeakedBytes: UInt64 = 1 << 20
        /// Block count at or above which a result is `.notable`, regardless of size.
        public static let notableLeakCount = 100

        /// A coarse significance rating used to decide whether to highlight.
        public var significance: Significance {
            if leakCount == 0 { return .none }
            // A one-shot conservative scan over a process we can't fully inspect
            // (no get-task-allow — every shipping app, Apple's included) is
            // unreliable and over-reports, so never escalate it to a warning.
            guard isDebuggable else { return .minor }
            if leakedBytes >= Self.notableLeakedBytes || leakCount >= Self.notableLeakCount {
                return .notable
            }
            return .minor
        }
    }

    /// Parse `/usr/bin/leaks <pid>` output. Returns nil if neither a node total
    /// nor a leak summary line was found (e.g. only a privilege error).
    public static func parseLeaks(_ output: String) -> LeaksSummary? {
        let isDebuggable = !output.localizedCaseInsensitiveContains("is not debuggable")

        var totalNodes = 0
        var totalBytes: UInt64 = 0
        var foundNodes = false
        // "Process 14047: 201626 nodes malloced for 46857 KB"
        if let m = output.firstMatch(of: #/(\d+)\s+nodes\s+malloced\s+for\s+(\d+)\s+KB/#) {
            totalNodes = Int(m.output.1) ?? 0
            totalBytes = (UInt64(m.output.2) ?? 0) * 1024
            foundNodes = true
        }

        var leakCount = 0
        var leakedBytes: UInt64 = 0
        var foundLeaks = false
        // "Process 14047: 0 leaks for 0 total leaked bytes."
        if let m = output.firstMatch(of: #/(\d+)\s+leaks?\s+for\s+(\d+)\s+total\s+leaked\s+bytes/#)
        {
            leakCount = Int(m.output.1) ?? 0
            leakedBytes = UInt64(m.output.2) ?? 0
            foundLeaks = true
        }

        guard foundNodes || foundLeaks else { return nil }
        return LeaksSummary(
            totalNodes: totalNodes, totalBytes: totalBytes, leakCount: leakCount,
            leakedBytes: leakedBytes, isDebuggable: isDebuggable)
    }
}

// MARK: - Heap diff (leak-suspect ranking)

extension MemoryInspection {
    /// The change in one class between two `heap` snapshots: the heart of the
    /// leak hunt. A class whose instance count climbs steadily between samples
    /// (while the workload is steady) is the signature of a leak.
    public struct HeapClassDelta: Sendable, Equatable, Identifiable {
        public var className: String
        public var type: String
        public var binary: String
        public var baselineCount: Int
        public var currentCount: Int
        public var baselineBytes: UInt64
        public var currentBytes: UInt64

        public var id: String { className + "\u{1}" + binary }

        /// Net change in live instances (may be negative).
        public var countDelta: Int { currentCount - baselineCount }
        /// Net change in bytes (may be negative).
        public var bytesDelta: Int64 { Int64(currentBytes) - Int64(baselineBytes) }

        public init(
            className: String, type: String, binary: String,
            baselineCount: Int, currentCount: Int,
            baselineBytes: UInt64, currentBytes: UInt64
        ) {
            self.className = className
            self.type = type
            self.binary = binary
            self.baselineCount = baselineCount
            self.currentCount = currentCount
            self.baselineBytes = baselineBytes
            self.currentBytes = currentBytes
        }
    }

    /// Diff two heap snapshots and rank classes by growth. Returns every class
    /// that grew in instance count (the leak suspects), largest count increase
    /// first; classes that shrank or were unchanged are omitted, since the hunt
    /// is for unbounded growth. A class present only in `current` counts its full
    /// size as growth; one present only in `baseline` is treated as removed.
    public static func diffHeap(
        baseline: HeapSnapshot, current: HeapSnapshot
    ) -> [HeapClassDelta] {
        func key(_ c: HeapClassCensus) -> String { c.className + "\u{1}" + c.binary }
        let baseByKey = Dictionary(baseline.classes.map { (key($0), $0) }) { a, _ in a }
        let currByKey = Dictionary(current.classes.map { (key($0), $0) }) { a, _ in a }

        var deltas: [HeapClassDelta] = []
        for (k, cur) in currByKey {
            let base = baseByKey[k]
            let delta = HeapClassDelta(
                className: cur.className, type: cur.type, binary: cur.binary,
                baselineCount: base?.instanceCount ?? 0, currentCount: cur.instanceCount,
                baselineBytes: base?.totalBytes ?? 0, currentBytes: cur.totalBytes)
            if delta.countDelta > 0 { deltas.append(delta) }
        }
        deltas.sort {
            $0.countDelta != $1.countDelta
                ? $0.countDelta > $1.countDelta
                : $0.bytesDelta > $1.bytesDelta
        }
        return deltas
    }
}
