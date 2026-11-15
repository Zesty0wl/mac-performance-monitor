import Foundation

/// Labels that depend on more than the command line's words: processes that
/// renamed themselves, and workers named after the interpreter that started
/// them.
extension CommandLabel {
    // MARK: Titles

    /// Whether argv is a title the process set for itself rather than its real
    /// command line. Node's `process.title`, Python's `setproctitle` and
    /// `$0 =` in Ruby and Perl overwrite argv in place: the title, then empty
    /// strings where the other arguments were. A Node title may also be one
    /// string with spaces ("npm exec @scope/tool"). argv[0] that is the
    /// interpreter itself (`node`, `/usr/bin/python3`) is never a title, so a
    /// bare REPL stays unlabelled.
    static func isTitle(_ arguments: [String], kind: Interpreter) -> Bool {
        guard let first = arguments.first, !first.isEmpty, kind != .shell else { return false }
        let base = (first as NSString).lastPathComponent.lowercased()
        guard interpreter(basename: base) == nil else { return false }
        if kind == .node, first.contains(" ") { return true }
        let rest = arguments.dropFirst()
        return !rest.isEmpty && rest.allSatisfy(\.isEmpty)
    }

    /// The label for a title: "npm exec @scope/tool" and "npm run dev" are
    /// named as npm would be; any other title ("pi", "gunicorn: worker [app]")
    /// is the name the program chose for itself.
    static func title(_ title: String) -> String? {
        let words = title.split(separator: " ").map(String.init)
        guard let tool = words.first.flatMap(packageManager(scriptPath:)) else { return title }
        return nodePackageManager(tool, Array(words.dropFirst()))
    }

    // MARK: Workers

    /// Interpreters whose unlabelled children of the same family are workers
    /// (a `multiprocessing` pool, an execnet or `node -e` helper). Shells and
    /// launchers are left out: a bare shell under a script is not its worker.
    static func family(_ kind: Interpreter) -> String? {
        switch kind {
        case .python: return "python"
        case .node, .nodePackageManager: return "node"
        case .bun: return "bun"
        case .deno: return "deno"
        case .ruby: return "ruby"
        case .perl: return "perl"
        case .php: return "php"
        case .java: return "java"
        case .generic: return "generic"
        case .shell, .osascript, .uv, .uvx, .pythonRunner, .cargo, .go: return nil
        }
    }

    static let workerSuffix = " (worker)"

    /// A worker's label from its parent's: "train.py (worker)". A worker's
    /// own workers keep the one suffix, and the parent's part is cut to fit.
    static func workerLabel(parent: String) -> String {
        if parent.hasSuffix(workerSuffix) { return parent }
        let room = maxLength - workerSuffix.count
        guard parent.count > room else { return parent + workerSuffix }
        let head = (room - 1) / 2
        return String(parent.prefix(head)) + "…" + String(parent.suffix(room - 1 - head))
            + workerSuffix
    }

    // MARK: Per-process state

    /// What the sampler keeps per process: the label, the kernel name it was
    /// read under (an exec keeps pid and start time, so a new name means a
    /// fresh read), and whether an unlabelled interpreter is still waiting to
    /// find its parent.
    public struct State: Sendable, Equatable {
        public private(set) var label: String?
        var readUnder: String?
        var family: String?
        /// Ticks left to find the parent. A parent and its worker first seen
        /// in the same scan may be visited in either order, and a parent that
        /// has exited is never found, so the search is retried a few times
        /// and then dropped.
        var parentTries = 0

        public init() {}

        /// Bring the label up to date. The command line is read only when the
        /// process is new (or exec'd under a new name) and is an interpreter
        /// or launcher this user owns; everything else is skipped before any
        /// read, since its command line is either not worth reading or not
        /// readable without privilege. `parent` is asked only while an
        /// unlabelled interpreter is looking for its parent's label.
        public mutating func update(
            name: String, executablePath: String?, uid: uid_t,
            arguments: () -> [String]?, parent: () -> State?
        ) {
            if readUnder != name {
                self = State()
                readUnder = name
                guard uid == getuid(),
                    let kind = CommandLabel.interpreter(name: name, executablePath: executablePath)
                else { return }
                family = CommandLabel.family(kind)
                label = CommandLabel.derive(
                    name: name, executablePath: executablePath, arguments: arguments())
                if label == nil, family != nil { parentTries = 3 }
            }
            guard label == nil, parentTries > 0 else { return }
            parentTries -= 1
            guard let parent = parent() else { return }
            // A parent still looking for its own parent may yet be labelled.
            if parent.label == nil, parent.parentTries > 0 { return }
            parentTries = 0
            if parent.family == family, let parentLabel = parent.label {
                label = CommandLabel.workerLabel(parent: parentLabel)
            }
        }
    }
}
