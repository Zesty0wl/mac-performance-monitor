import Foundation

/// What an interpreter is running, from its command line: `train.py` for
/// `python3 train.py`, `http.server` for `python -m http.server`, `tsc` for
/// `node node_modules/.bin/tsc`. Every Python, Node or Java process shows the
/// same kernel name, so this short label is what tells them apart in the
/// process list, the history and the agent views.
///
/// Only the label is kept, never the whole command line, because arguments
/// routinely carry tokens and passwords. Pure string rules, so the sampler can
/// call it once per process identity and tests can pin every case.
public enum CommandLabel {
    /// Longest label kept; anything longer is cut in the middle.
    static let maxLength = 60

    enum Interpreter: Equatable {
        case python, node, bun, deno, ruby, perl, php, java, shell, osascript, generic
        /// Launchers that start the real program as a child: the child gets
        /// its own label, and the launcher is named by what it was asked to run.
        case uv, uvx, pythonRunner, nodePackageManager(String), cargo, go
    }

    /// Whether a process is an interpreter worth reading the command line of.
    /// Checked before the (one-off) argument read, so other processes pay
    /// nothing.
    public static func isInterpreter(name: String, executablePath: String?) -> Bool {
        interpreter(name: name, executablePath: executablePath) != nil
    }

    static func interpreter(name: String, executablePath: String?) -> Interpreter? {
        let base = executablePath.map { ($0 as NSString).lastPathComponent } ?? ""
        for candidate in [base, name] where !candidate.isEmpty {
            if let found = interpreter(basename: candidate.lowercased()) { return found }
        }
        return nil
    }

    private static func interpreter(basename: String) -> Interpreter? {
        if basename.range(of: #"^python[0-9.]*w?$"#, options: .regularExpression) != nil {
            return .python
        }
        if basename.range(of: #"^perl[0-9.]*$"#, options: .regularExpression) != nil {
            return .perl
        }
        if basename.range(of: #"^(ruby|php|lua|luajit|tclsh)[0-9.]*$"#, options: .regularExpression)
            != nil
        {
            return basename.hasPrefix("ruby") ? .ruby : basename.hasPrefix("php") ? .php : .generic
        }
        switch basename {
        case "node", "nodejs": return .node
        case "bun": return .bun
        case "deno": return .deno
        case "java": return .java
        case "bash", "zsh", "sh", "dash", "ksh", "fish", "tcsh", "csh": return .shell
        case "osascript": return .osascript
        case "rscript": return .generic
        case "uv": return .uv
        case "uvx": return .uvx
        case "poetry", "pipenv", "pdm", "hatch", "rye": return .pythonRunner
        case "npm", "npx", "pnpm", "pnpx", "yarn", "bunx": return .nodePackageManager(basename)
        case "cargo": return .cargo
        case "go": return .go
        default: return nil
        }
    }

    /// The label for a live process: its command line is read only when it
    /// is an interpreter or launcher this user owns. Everything else is
    /// skipped before any read, since its command line is either not worth
    /// reading or (another user's) not readable without privilege.
    public static func read(
        pid: pid_t, name: String, executablePath: String?, uid: uid_t
    )
        -> String?
    {
        guard uid == getuid(), isInterpreter(name: name, executablePath: executablePath)
        else { return nil }
        return derive(
            name: name, executablePath: executablePath,
            arguments: ProcessArguments.read(pid: pid))
    }

    /// The label for a process's command line, or nil when there is nothing
    /// to add (not an interpreter, an interactive shell, inline `-c` code).
    public static func derive(
        name: String, executablePath: String?, arguments: [String]?
    )
        -> String?
    {
        guard let arguments, let first = arguments.first,
            let kind = interpreter(name: name, executablePath: executablePath)
        else { return nil }
        // Node tools that set `process.title` overwrite argv with it: one string
        // ("npm exec @scope/tool", "pi") followed by empty arguments.
        if kind == .node, isNodeTitle(arguments) { return nodeTitle(first).flatMap(clean) }
        guard arguments.count > 1 else { return nil }
        let rest = Array(arguments.dropFirst())
        let label: String?
        switch kind {
        case .python: label = python(rest)
        case .node: label = node(rest)
        case .bun: label = bun(rest)
        case .deno: label = deno(rest)
        case .ruby:
            label = firstOperand(rest, valued: ["-I", "-r", "-C", "-E", "-x"], inline: ["-e"])
        case .perl:
            label = firstOperand(rest, valued: ["-I", "-M", "-m", "-x"], inline: ["-e", "-E"])
        case .php:
            label = firstOperand(
                rest, valued: ["-c", "-d", "-z", "-t"], inline: ["-r"], file: "-f")
        case .java: label = java(rest)
        case .shell: label = shell(rest)
        case .osascript: label = firstOperand(rest, valued: ["-l", "-s"], inline: ["-e"])
        case .generic: label = firstOperand(rest, valued: [], inline: ["-e"])
        case .uv: label = uv(rest)
        case .uvx: label = uvToolRun(rest)
        case .pythonRunner: label = pythonRunner(rest)
        case .nodePackageManager(let tool): label = nodePackageManager(tool, rest)
        case .cargo: label = cargo(rest)
        case .go: label = go(rest)
        }
        return label.flatMap(clean)
    }

    // MARK: Scanning a command line

    /// What a flag means to the rule scanning past it.
    enum FlagOutcome {
        /// An ordinary flag: step over it (and its value, when it takes one).
        case skip
        /// The flag settles the label (`-m module`, `-c code`).
        case result(String?)
    }

    /// Walk `args` the way most interpreters parse them: flags first (with
    /// the values of `valued` flags), then the first operand, which names
    /// the program. `--` ends the flags. `onFlag` sees each flag with the
    /// argument after it; `onOperand` gets the index of the first operand.
    static func scan(
        _ args: [String], valued: Set<String>, flagPrefixes: [String] = ["-"],
        onFlag: (_ flag: String, _ next: String?) -> FlagOutcome = { _, _ in .skip },
        onOperand: (_ index: Int) -> String?
    ) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { return args.indices.contains(index + 1) ? onOperand(index + 1) : nil }
            guard flagPrefixes.contains(where: { arg.hasPrefix($0) }) else {
                return onOperand(index)
            }
            let next = args.indices.contains(index + 1) ? args[index + 1] : nil
            if case .result(let label) = onFlag(arg, next) { return label }
            index += valued.contains(arg) ? 2 : 1
        }
        return nil
    }

    /// The first operand after the interpreter's flags, for the interpreters
    /// that share the usual `tool [flags] script` shape. `inline` flags run
    /// code given on the command line, so there is no script to name; the
    /// `file` flag (`php -f`) takes the script as its value.
    static func firstOperand(
        _ args: [String], valued: Set<String>, inline: Set<String>, file: String? = nil
    ) -> String? {
        scan(
            args, valued: valued,
            onFlag: { flag, next in
                if inline.contains(flag) { return .result(nil) }
                if let file, flag == file { return .result(next.flatMap(script)) }
                return .skip
            },
            onOperand: { script(args[$0]) })
    }

    // MARK: Per-interpreter rules

    /// `python [flags] script.py ...`, `python -m module ...`.
    static func python(_ args: [String]) -> String? {
        scan(
            args, valued: ["-X", "-W", "-Q", "--check-hash-based-pycs"],
            onFlag: { flag, next in
                if flag == "-" { return .result(nil) }  // the script is on stdin
                guard !flag.hasPrefix("--") else { return .skip }
                // A cluster such as `-u`, `-OO` or `-Bm module`; `-c` and `-m`
                // end it, and what follows is code or a module name.
                let letters = flag.dropFirst()
                guard let position = letters.firstIndex(where: { $0 == "c" || $0 == "m" })
                else { return .skip }
                if letters[position] == "c" { return .result(nil) }
                let attached = String(letters[letters.index(after: position)...])
                return .result(attached.isEmpty ? next : attached)
            },
            onOperand: { script(args[$0]) })
    }

    /// `node [flags] script.js ...`. `-e` and `-p` run inline code.
    static func node(_ args: [String]) -> String? {
        let valued: Set<String> = [
            "-r", "--require", "--import", "--loader", "--experimental-loader", "--env-file",
            "-C", "--conditions", "--input-type", "--watch-path", "--title",
            "--redirect-warnings", "--icu-data-dir", "--openssl-config", "--cpu-prof-dir",
            "--heap-prof-dir", "--diagnostic-dir", "--report-dir", "--inspect-port",
        ]
        let inline: Set<String> = ["-e", "--eval", "-p", "--print"]
        return scan(
            args, valued: valued,
            onFlag: { flag, _ in inline.contains(flag) ? .result(nil) : .skip },
            onOperand: { index in
                // `node …/bin/npm run dev`: name it as npm itself would be.
                if let tool = packageManager(scriptPath: args[index]) {
                    return nodePackageManager(tool, Array(args[(index + 1)...])) ?? tool
                }
                return script(args[index])
            })
    }

    /// `bun run script`, `bun script.ts`, `bun test`, `bun x tool`.
    static func bun(_ args: [String]) -> String? {
        let operands = args.filter { !$0.hasPrefix("-") }
        guard let first = operands.first else { return nil }
        switch first {
        case "run", "x", "exec":
            return operands.count > 1 ? script(operands[1]) : nil
        case "test", "install", "add", "build", "dev", "upgrade", "repl", "init", "create", "pm":
            return first
        default:
            return script(first)
        }
    }

    /// `deno run [flags] script.ts`, `deno task name`, `deno test`.
    static func deno(_ args: [String]) -> String? {
        let operands = args.filter { !$0.hasPrefix("-") }
        guard let first = operands.first else { return nil }
        switch first {
        case "run", "serve", "task", "compile", "bench", "test":
            if operands.count > 1 { return script(operands[1]) }
            return first
        default:
            return first
        }
    }

    /// `java [options] -jar app.jar`, `java -m module/Class`, or a main class.
    static func java(_ args: [String]) -> String? {
        let valued: Set<String> = [
            "-cp", "-classpath", "--class-path", "-p", "--module-path", "--upgrade-module-path",
            "--add-modules", "--add-opens", "--add-exports", "--add-reads", "--patch-module",
            "--limit-modules", "--enable-native-access",
        ]
        return scan(
            args, valued: valued,
            onFlag: { flag, next in
                if flag == "-jar" { return .result(next.flatMap(script)) }
                if flag == "-m" || flag == "--module" { return .result(next.flatMap(mainClass)) }
                if flag.hasPrefix("--module=") {
                    return .result(mainClass(String(flag.dropFirst("--module=".count))))
                }
                return .skip
            },
            onOperand: { mainClass(args[$0]) })
    }

    /// `bash script.sh`, or the command `sh -c "exec tool --flag"` runs.
    /// An interactive shell (`-zsh`, `zsh -l`) gets no label.
    static func shell(_ args: [String]) -> String? {
        scan(
            args, valued: ["-o", "+o", "-O", "+O", "--rcfile", "--init-file"],
            flagPrefixes: ["-", "+"],
            onFlag: { flag, next in
                guard !flag.hasPrefix("--"), flag.dropFirst().contains("c") else { return .skip }
                return .result(next.flatMap(commandWord))
            },
            onOperand: { script(args[$0]) })
    }

    // MARK: Naming a script

    /// Entry files whose name says nothing (`index.js`, `__main__.py`), so the
    /// folder they sit in names the program instead.
    private static let genericStems: Set<String> = [
        "index", "main", "cli", "__main__", "app", "run", "start", "entry", "bin",
    ]
    /// Folders that hold an entry file without naming the program.
    private static let genericFolders: Set<String> = [
        "bin", "dist", "build", "lib", "src", "out", "cjs", "esm", "scripts", "", ".",
    ]

    /// The readable name of a script path.
    static func script(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(
            String.init)
        guard let base = components.last else { return nil }
        // node_modules/.bin/tsc is the tool's own name.
        if components.count >= 2, components[components.count - 2] == ".bin" { return base }
        if let package = nodePackage(components) {
            // A package's bin script (typescript/bin/tsc) names the tool;
            // anything else in the package is best named by the package.
            let stem = stem(of: base)
            if components.count >= 2, components[components.count - 2] == "bin",
                !genericStems.contains(stem.lowercased())
            {
                return stem
            }
            return package
        }
        guard genericStems.contains(stem(of: base).lowercased()) else { return base }
        for folder in components.dropLast().reversed()
        where !genericFolders.contains(folder.lowercased()) {
            return folder
        }
        return base
    }

    /// The package a path inside `node_modules` belongs to, scope included.
    private static func nodePackage(_ components: [String]) -> String? {
        guard let marker = components.lastIndex(of: "node_modules"),
            components.indices.contains(marker + 1)
        else { return nil }
        let first = components[marker + 1]
        if first.hasPrefix("@"), components.indices.contains(marker + 2) {
            return "\(first)/\(components[marker + 2])"
        }
        return first
    }

    private static func stem(of base: String) -> String {
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return base }
        return String(base[..<dot])
    }

    /// `com.example.app.Main` is `Main`; `module/com.example.Main` likewise.
    private static func mainClass(_ value: String) -> String? {
        let last = value.split(separator: "/").last.map(String.init) ?? value
        return last.split(separator: ".").last.map(String.init) ?? last
    }

    /// Shell words that start a command without naming a program: keywords
    /// (`if`, `then`), builtins (`cd`, `export`), and the prefixes (`exec`,
    /// `env`, `command`) that hand off to the program that follows.
    private static let shellWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
        "esac", "in", "select", "function", "time", "!", "{", "}", "[[", "]]", "[", "]",
        "exec", "env", "command", "builtin", "nohup", "nice", "sudo", "cd", "pushd", "popd",
        "export", "unset", "set", "shopt", "source", ".", "eval", "trap", "local", "declare",
        "typeset", "readonly", "read", "test", "true", "false", ":", "echo", "printf", "exit",
        "return", "wait", "umask", "ulimit", "shift", "alias", "hash", "type",
    ]

    /// The program a `-c` command string runs. The string is split into
    /// commands at `;`, `&&`, `||`, `|` and newlines; in each, keywords,
    /// builtins, `NAME=value` assignments and flags are passed over, so
    /// `cd /app && exec node server.js` names `node`, not `cd`.
    private static func commandWord(_ command: String) -> String? {
        let separators = CharacterSet(charactersIn: ";&|\n")
        for segment in command.components(separatedBy: separators) {
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" })
            for word in words {
                let text = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()"))
                if text.isEmpty || text.contains("=") || text.hasPrefix("-")
                    || (text.hasPrefix("$") && !text.contains("/"))
                {
                    continue
                }
                if shellWords.contains(text) {
                    // A builtin's own arguments (`cd /app`) are not programs.
                    if !Self.prefixWords.contains(text) { break }
                    continue
                }
                return (text as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// Shell words that run the next word as the program (`exec node`), as
    /// opposed to builtins whose arguments are data (`cd /app`). Keywords
    /// such as `if` and `then` also precede a command.
    private static let prefixWords: Set<String> = [
        "if", "then", "else", "elif", "while", "until", "do", "time", "!", "{", "exec", "env",
        "command", "builtin", "nohup", "nice", "sudo",
    ]

    /// Trim, drop control characters, and cut an overlong label in the middle.
    private static func clean(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count > maxLength else { return text }
        let head = (maxLength - 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(maxLength - 1 - head))
    }
}
