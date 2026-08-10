import Foundation

/// Distils `/usr/bin/sample` output — a per-thread call-stack profile — into a
/// compact, plain-text digest the on-device model can reason over: which threads
/// were actually on-CPU and the hot call path they were running, versus threads
/// merely parked in a wait. Pure string parsing, so it lives in Core and is
/// unit-testable against captured `sample` output.
///
/// `sample` samples every thread at each interval regardless of whether it is
/// running, so a thread's raw sample count is NOT its CPU use — the signal is the
/// thread's dominant *leaf* frame: a wait syscall (mach_msg, kevent, …) means it
/// was parked; a real function means it was burning CPU there.
public enum SampleDigest {
    /// Leaf symbols that mean a thread was parked, not consuming CPU.
    static let waitSymbols: Set<String> = [
        "mach_msg_trap", "mach_msg2_trap", "mach_msg", "mach_msg_overwrite",
        "mach_msg2_internal", "semaphore_wait_trap", "semaphore_timedwait_trap",
        "__psynch_cvwait", "__psynch_mutexwait", "__psynch_rw_rdlock", "__psynch_rw_wrlock",
        "__semwait_signal", "__ulock_wait", "__ulock_wait2",
        "kevent", "kevent64", "kevent_id", "__select", "select", "poll", "__poll",
        "__workq_kernreturn", "read", "__read", "__read_nocancel",
        "recvfrom", "__recvfrom", "accept", "__accept", "recvmsg", "__recvmsg",
        "nanosleep", "__wait4", "thread_switch", "swtch_pri", "__sigwait", "sigsuspend",
    ]

    public struct ThreadSummary: Sendable, Equatable {
        public var name: String
        public var samples: Int
        public var isWaiting: Bool
        public var leafSymbol: String
        public var leafBinary: String
        /// Samples captured at the dominant leaf. `leafSamples / samples` is how
        /// concentrated the thread is on one spot: ≈1 means it sat in a single
        /// function/wait the whole time (a tight loop, or stuck), lower means varied.
        public var leafSamples: Int
        /// The dominant call path, root → leaf (symbols only).
        public var hotPath: [String]

        public var concentration: Double {
            samples > 0 ? Double(leafSamples) / Double(samples) : 0
        }
    }

    public struct Report: Sendable, Equatable {
        public var process: String
        public var footprint: String?
        public var threads: [ThreadSummary]
        public var onCPU: [ThreadSummary] { threads.filter { !$0.isWaiting } }
    }

    private struct Frame {
        let depth: Int
        let count: Int
        let symbol: String
        let binary: String
    }

    /// Parse a `sample` report. Returns nil if no call graph was found (e.g. the
    /// tool printed only a privilege error).
    public static func parse(_ output: String) -> Report? {
        let lines = output.components(separatedBy: "\n")

        var process = ""
        if let p = firstCapture(lines, prefix: "Process:") { process = p }
        let footprint = firstCapture(lines, prefix: "Physical footprint:")

        guard let graphStart = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }) else {
            return nil
        }

        var threads: [ThreadSummary] = []
        var currentName: String?
        var currentSamples = 0
        var frames: [Frame] = []

        func flush() {
            guard let name = currentName else { return }
            if let summary = summarize(name: name, samples: currentSamples, frames: frames) {
                threads.append(summary)
            }
            frames = []
        }

        for line in lines[(graphStart + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            // A thread header has a leading count then "Thread_", and no "+".
            if let header = parseThreadHeader(line) {
                flush()
                currentName = header.name
                currentSamples = header.samples
            } else if let frame = parseFrame(line) {
                frames.append(frame)
            } else if currentName != nil, !line.hasPrefix(" ") {
                // A non-indented, non-frame line (e.g. "Total number in stack…")
                // ends the call graph.
                break
            }
        }
        flush()

        guard !threads.isEmpty else { return nil }
        return Report(
            process: process.isEmpty ? "unknown" : process, footprint: footprint, threads: threads)
    }

    /// Build the digest string fed to the model.
    public static func make(from output: String, fallbackName: String, pid: Int32) -> String? {
        guard let report = parse(output) else { return nil }
        var lines: [String] = []
        let name = report.process.isEmpty ? fallbackName : report.process
        var head = "Process: \(name) [pid \(pid)]"
        if let fp = report.footprint { head += ", memory footprint \(fp)" }
        lines.append(head + ".")
        lines += activityLines(report)
        return lines.joined(separator: "\n")
    }

    /// The thread-activity lines (on-CPU work + idle threads) without the process
    /// header, so a richer profile can fold them in alongside other signals.
    public static func activityLines(_ report: Report) -> [String] {
        var lines: [String] = []
        let onCPU = report.onCPU.sorted { $0.samples > $1.samples }
        let waiting = report.threads.filter { $0.isWaiting }
        lines.append(
            "Sampled ~5s. \(report.threads.count) threads total; "
                + "\(onCPU.count) on-CPU (doing work), \(waiting.count) idle/waiting.")

        if onCPU.isEmpty {
            lines.append(
                "No thread was on-CPU during the sample — every thread was parked in a "
                    + "wait, so the process was not burning CPU at this moment.")
        } else {
            lines.append("On-CPU threads (where the CPU time is going):")
            for t in onCPU.prefix(4) {
                lines.append("- \(t.name): running in \(t.leafSymbol) (\(t.leafBinary)).")
                let path = condensePath(t.hotPath)
                if !path.isEmpty { lines.append("    call path: \(path.joined(separator: " → "))") }
            }
        }

        if !waiting.isEmpty {
            let names = waiting.prefix(6).map { "\($0.name) (in \($0.leafSymbol))" }
            lines.append("Idle/waiting threads: \(names.joined(separator: ", ")).")
        }
        return lines
    }

    // MARK: - Parsing helpers

    private static func firstCapture(_ lines: [String], prefix: String) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// "    1719 Thread_3723338   DispatchQueue_1: com.apple.main-thread  (serial)"
    private static func parseThreadHeader(_ line: String) -> (samples: Int, name: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("+") else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let samples = Int(parts[0]), parts[1].hasPrefix("Thread") else {
            return nil
        }
        // Drop the "Thread_<id>" token, keep the descriptive remainder.
        var rest = String(parts[1])
        if let idEnd = rest.firstIndex(where: { $0 == " " || $0 == ":" }) {
            rest = String(rest[rest.index(after: idEnd)...])
        } else {
            rest = ""
        }
        var nm = rest.trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        if nm.localizedCaseInsensitiveContains("main-thread") { nm = "main thread" }
        return (samples, nm.isEmpty ? "thread" : nm)
    }

    /// One call-graph frame. `/usr/bin/sample` prints these as an indented
    /// "<count> <symbol> (in <binary>) + <offset> [addr]" line; some report
    /// variants prefix the count with a "+" marker, which is tolerated. The "+"
    /// inside the address offset is NOT a marker, so the count is found from the
    /// leading indentation, never by scanning for the first "+". Depth is the
    /// column of the count digit, so deeper frames compare greater.
    private static func parseFrame(_ line: String) -> Frame? {
        var rest = line[...]
        while rest.first == " " { rest = rest.dropFirst() }
        // Tolerate a leading "+" marker (and the spaces after it) before the count.
        if rest.first == "+" {
            rest = rest.dropFirst()
            while rest.first == " " { rest = rest.dropFirst() }
        }
        let depth = line.distance(from: line.startIndex, to: rest.startIndex)
        let tokens = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard tokens.count >= 1, Int(tokens[0]) != nil else { return nil }
        let count = Int(tokens[0]) ?? 0
        let remainder = tokens.count == 2 ? String(tokens[1]) : ""
        let symbol = symbolName(remainder)
        let binary = binaryName(remainder)
        guard !symbol.isEmpty else { return nil }
        return Frame(depth: depth, count: count, symbol: symbol, binary: binary)
    }

    /// The function name is everything before "  (in " (or before " + offset").
    private static func symbolName(_ remainder: String) -> String {
        var s = remainder
        if let r = s.range(of: "  (in ") { s = String(s[..<r.lowerBound]) }
        // Strip a trailing " + <offset>" if there was no "(in …)" segment.
        if let r = s.range(of: " + ", options: .backwards) {
            let tail = s[r.upperBound...]
            if tail.first?.isNumber == true { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func binaryName(_ remainder: String) -> String {
        guard let r = remainder.range(of: "(in ") else { return "" }
        let afterIn = remainder[r.upperBound...]
        // The binary name itself may contain parens (e.g. "… Helper (Renderer)"),
        // and the trailing "[0x…]" address has none, so the closing paren of
        // "(in …)" is the LAST ")" on the line.
        guard let close = afterIn.lastIndex(of: ")") else { return "" }
        return String(afterIn[..<close]).trimmingCharacters(in: .whitespaces)
    }

    /// Reduce a thread's frames to its dominant leaf and the path to it. `sample`
    /// prints children heaviest-first and depth-first, so the first branch is the
    /// dominant one and its leaf is the frame just before the depth decreases.
    private static func summarize(name: String, samples: Int, frames: [Frame]) -> ThreadSummary? {
        guard !frames.isEmpty else { return nil }
        var leafIndex = frames.count - 1
        for i in 0..<(frames.count - 1) where frames[i + 1].depth <= frames[i].depth {
            leafIndex = i
            break
        }
        let leaf = frames[leafIndex]
        let path = frames[0...leafIndex].map(\.symbol)
        return ThreadSummary(
            name: name, samples: samples,
            isWaiting: waitSymbols.contains(leaf.symbol),
            leafSymbol: leaf.symbol, leafBinary: leaf.binary.isEmpty ? "unknown" : leaf.binary,
            leafSamples: leaf.count, hotPath: path)
    }

    /// Keep the most specific (deepest) frames, dropping the generic launch
    /// preamble (start → main → …), and collapse immediate repeats.
    private static func condensePath(_ path: [String]) -> [String] {
        var deduped: [String] = []
        for s in path where deduped.last != s { deduped.append(s) }
        return Array(deduped.suffix(7))
    }
}
