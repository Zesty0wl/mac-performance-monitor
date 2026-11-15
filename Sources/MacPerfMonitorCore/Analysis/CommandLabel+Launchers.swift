import Foundation

/// Launchers: tools that start the real program as a child (`uv run`,
/// `npm run`, `cargo run`). The child is labelled by its own command line;
/// these name the launcher by what it was asked to run, so a row of `uv` or
/// `npm` processes can be told apart too.
extension CommandLabel {
    /// Operands of a command line, with flags (and the values of `valued`
    /// flags) removed, stopping at `--`.
    static func operands(_ args: [String], valued: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { break }
            if arg.hasPrefix("-") || arg.hasPrefix("+") {
                index += valued.contains(arg) ? 2 : 1
                continue
            }
            result.append(arg)
            index += 1
        }
        return result
    }

    /// `pkg@1.2.3` and `@scope/pkg@latest` without the version.
    static func withoutVersion(_ spec: String) -> String {
        guard let at = spec.lastIndex(of: "@"), at != spec.startIndex else { return spec }
        return String(spec[..<at])
    }

    private static func isPython(_ word: String) -> Bool {
        let base = (word as NSString).lastPathComponent.lowercased()
        return base.range(of: #"^python[0-9.]*$"#, options: .regularExpression) != nil
    }

    /// What a `run` subcommand runs: a Python invocation is named as Python
    /// would be, anything else as a script or tool. Falls back to "python"
    /// for inline code, so the launcher still says what it started.
    private static func runTarget(_ args: [String], valued: Set<String>) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                index += 1
                break
            }
            if arg == "-m" || arg == "--module" {
                return args.indices.contains(index + 1) ? args[index + 1] : nil
            }
            guard arg.hasPrefix("-") else { break }
            index += valued.contains(arg) ? 2 : 1
        }
        guard args.indices.contains(index) else { return nil }
        let target = args[index]
        if isPython(target) {
            return python(Array(args[(index + 1)...])) ?? (target as NSString).lastPathComponent
        }
        return script(target)
    }

    // MARK: Python

    private static let uvGlobalValued: Set<String> = [
        "--directory", "--project", "--cache-dir", "--config-file", "--color", "--python", "-p",
        "--allow-insecure-host", "--index", "--default-index", "--index-url", "--extra-index-url",
    ]

    /// `uv run [flags] script.py`, `uv run -m module`, `uv tool run tool`,
    /// or the subcommand (`sync`, `pip`, `lock`).
    static func uv(_ args: [String]) -> String? {
        let words = operands(args, valued: uvGlobalValued)
        guard let sub = words.first, let at = args.firstIndex(of: sub) else { return nil }
        let rest = Array(args[(at + 1)...])
        switch sub {
        case "run":
            let valued = uvGlobalValued.union([
                "--with", "--with-editable", "--with-requirements", "--package", "--extra",
                "--group", "--only-group", "--no-group", "--env-file", "--isolated-env",
            ])
            return runTarget(rest, valued: valued) ?? sub
        case "tool":
            // `uvx pkg` runs as `uv tool uvx pkg` (seen live).
            guard rest.first == "run" || rest.first == "uvx" else { return sub }
            return uvToolRun(Array(rest.dropFirst())) ?? sub
        default:
            return sub
        }
    }

    /// `uvx tool@version args`, `uv tool run --from pkg tool`.
    static func uvToolRun(_ args: [String]) -> String? {
        let valued = uvGlobalValued.union(["--from", "--with", "--with-requirements"])
        return operands(args, valued: valued).first.map(withoutVersion)
    }

    /// `poetry run`, `pipenv run`, `pdm run`, `hatch run`, `rye run`.
    static func pythonRunner(_ args: [String]) -> String? {
        let valued: Set<String> = ["-C", "--directory", "--project", "-e", "--env", "-p"]
        guard let sub = operands(args, valued: valued).first, let at = args.firstIndex(of: sub)
        else { return nil }
        guard sub == "run" else { return sub }
        return runTarget(Array(args[(at + 1)...]), valued: valued) ?? sub
    }

    // MARK: Node

    /// The package manager a Node script path is, if any:
    /// `…/bin/npm`, `…/npm/bin/npm-cli.js`, `…/pnpm/bin/pnpm.cjs`.
    static func packageManager(scriptPath: String) -> String? {
        let base = (scriptPath as NSString).lastPathComponent.lowercased()
        let stem = base.split(separator: ".").first.map(String.init) ?? base
        switch stem {
        case "npm", "npm-cli": return "npm"
        case "npx", "npx-cli": return "npx"
        case "pnpm", "pnpx", "yarn": return stem
        default: return nil
        }
    }

    /// `npm run dev` is `dev`; `npm exec tool`, `npx tool@latest` and
    /// `pnpm dlx tool` are the tool; `npm test` is `test`.
    static func nodePackageManager(_ tool: String, _ args: [String]) -> String? {
        let valued: Set<String> = [
            "--prefix", "-w", "--workspace", "-C", "--dir", "--filter", "-F", "--cwd", "-p",
            "--package", "--call", "-c",
        ]
        let words = operands(args, valued: valued)
        guard let first = words.first else { return nil }
        if ["npx", "pnpx", "bunx"].contains(tool) { return withoutVersion(first) }
        switch first {
        case "run", "run-script", "rum", "urn", "exec", "x", "dlx":
            return words.count > 1 ? withoutVersion(words[1]) : first
        default:
            return first
        }
    }

    // MARK: Compiled languages

    /// `cargo run --bin server` is `server`; `cargo build` is `build`.
    static func cargo(_ args: [String]) -> String? {
        let valued: Set<String> = [
            "--bin", "-p", "--package", "--example", "--manifest-path", "--target", "--features",
            "-F", "-j", "--jobs", "--profile", "--target-dir", "--config", "-Z", "--color",
        ]
        guard let sub = operands(args, valued: valued).first else { return nil }
        guard sub == "run" else { return sub }
        for flag in ["--bin", "--example", "-p", "--package"] {
            if let at = args.firstIndex(of: flag), args.indices.contains(at + 1) {
                return args[at + 1]
            }
            if let joined = args.first(where: { $0.hasPrefix(flag + "=") }) {
                return String(joined.dropFirst(flag.count + 1))
            }
        }
        return sub
    }

    /// `go run ./cmd/server` is `server`; `go run main.go` is its folder;
    /// `go test` is `test`.
    static func go(_ args: [String]) -> String? {
        let valued: Set<String> = ["-C", "-o", "-p", "-tags", "-ldflags", "-gcflags", "-mod"]
        let words = operands(args, valued: valued)
        guard let sub = words.first else { return nil }
        guard sub == "run" else { return sub }
        guard words.count > 1 else { return sub }
        let target = withoutVersion(words[1])
        if target.hasSuffix(".go") { return script(target) ?? sub }
        let last = target.split(separator: "/").last.map(String.init) ?? target
        return [".", "..", "..."].contains(last) ? sub : last
    }
}
