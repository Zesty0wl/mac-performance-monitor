import XCTest

@testable import MacPerfMonitorCore

/// Every python3 and node looks the same by name; these pin the label that
/// tells them apart, so a rule change that renames a familiar process is
/// caught here rather than noticed in the process list.
final class CommandLabelTests: XCTestCase {
    private func label(_ argv: [String], name: String? = nil, path: String? = nil) -> String? {
        let first = argv.first ?? ""
        return CommandLabel.derive(
            name: name ?? (first as NSString).lastPathComponent,
            executablePath: path ?? first, arguments: argv)
    }

    func testPythonScriptsAndModules() {
        XCTAssertEqual(label(["python3", "train.py", "--epochs", "3"]), "train.py")
        XCTAssertEqual(
            label(["/usr/bin/python3", "-u", "-X", "dev", "/srv/job/run_job.py"]), "run_job.py")
        XCTAssertEqual(label(["python3", "-m", "http.server", "8000"]), "http.server")
        XCTAssertEqual(label(["python3", "-Bm", "pytest"]), "pytest")
        XCTAssertEqual(label(["python3", "-mvenv"]), "venv")
        XCTAssertEqual(
            label(["python3", "-m", "ipykernel_launcher", "-f", "/tmp/kernel-1.json"]),
            "ipykernel_launcher")
        XCTAssertEqual(label(["python3", "/Users/me/tool/__main__.py"]), "tool")
        XCTAssertEqual(label(["python3", "/proj/.venv/bin/jupyter-lab"]), "jupyter-lab")
        XCTAssertEqual(
            label(
                [
                    "/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
                    "manage.py", "runserver",
                ]),
            "manage.py")
        XCTAssertNil(label(["python3", "-c", "print(1)"]))
        XCTAssertNil(label(["python3"]))
        XCTAssertNil(label(["python3", "-"]))
    }

    func testNodeScriptsAndPackages() {
        XCTAssertEqual(label(["node", "server.js"]), "server.js")
        XCTAssertEqual(
            label(["node", "--inspect", "-r", "ts-node/register", "app/worker.ts"]), "worker.ts")
        XCTAssertEqual(label(["node", "/app/my-server/index.js"]), "my-server")
        XCTAssertEqual(label(["node", "/app/my-server/dist/main.js"]), "my-server")
        XCTAssertEqual(label(["node", "/x/node_modules/.bin/tsc", "-w"]), "tsc")
        XCTAssertEqual(label(["node", "/x/node_modules/typescript/bin/tsc"]), "tsc")
        XCTAssertEqual(
            label(["node", "/x/node_modules/next/dist/server/lib/start-server.js"]), "next")
        XCTAssertEqual(
            label(["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]),
            "@anthropic-ai/claude-code")
        XCTAssertNil(label(["node", "-e", "console.log(1)"]))
        XCTAssertNil(label(["node"]))
    }

    func testOtherInterpreters() {
        XCTAssertEqual(label(["bun", "run", "dev.ts"]), "dev.ts")
        XCTAssertEqual(label(["bun", "test"]), "test")
        XCTAssertEqual(label(["deno", "run", "--allow-net", "serve.ts"]), "serve.ts")
        XCTAssertEqual(label(["ruby", "bin/rails", "server"]), "rails")
        XCTAssertEqual(label(["perl", "-w", "report.pl"]), "report.pl")
        XCTAssertEqual(label(["java", "-Xmx2g", "-jar", "/opt/app/service.jar"]), "service.jar")
        XCTAssertEqual(
            label([
                "java", "-cp", "/x/lib.jar", "org.gradle.launcher.daemon.bootstrap.GradleDaemon",
                "8.5",
            ]),
            "GradleDaemon")
        XCTAssertEqual(label(["/bin/bash", "./deploy.sh", "prod"]), "deploy.sh")
        XCTAssertEqual(
            label(["/bin/sh", "-c", "FOO=1 exec /usr/local/bin/worker --once"]), "worker")
        XCTAssertNil(label(["-zsh"], name: "zsh", path: "/bin/zsh"))
        XCTAssertNil(label(["zsh", "-l"]))
        XCTAssertEqual(label(["osascript", "/Users/me/notify.scpt"]), "notify.scpt")
    }

    func testShellCommandsSkipKeywordsAndBuiltins() {
        XCTAssertEqual(label(["/bin/sh", "-c", "cd /app && exec node server.js"]), "node")
        // A real watchdog seen on this Mac: keywords, builtins, then the program.
        XCTAssertEqual(
            label([
                "/bin/sh", "-c",
                "if IFS= command read -r line; then\n  exit 0\nfi\nexec /bin/kill \"$2\" \"$1\"",
                "watchdog", "3206", "-TERM",
            ]),
            "kill")
        XCTAssertEqual(
            label(["/bin/sh", "-c", "export A=1; $HOME/bin/sync-tool --once"]), "sync-tool")
        XCTAssertNil(label(["/bin/sh", "-c", "cd /tmp; exit 0"]))
    }

    func testShellCommandsSeeThroughBackslashedBuiltinsAndZshSetup() {
        // `\builtin` and `\command` skip aliases; the backslash is not a name.
        XCTAssertEqual(label(["/bin/zsh", "-c", "\\command node server.js"]), "node")
        XCTAssertEqual(label(["/bin/zsh", "-c", "\\builtin exec python3 job.py"]), "python3")
        // A wrapper that only sets the shell up and evals a string names nothing,
        // rather than "\builtin", "setopt" or "pwd".
        XCTAssertNil(
            label([
                "/bin/zsh", "-c",
                "source /Users/me/.cache/snapshot-zsh.sh 2>/dev/null || true && "
                    + "\\builtin setopt NO_EXTENDED_GLOB 2>/dev/null || true && "
                    + "\\builtin unsetopt AUTO_CD && eval 'ls -la' < /dev/null && pwd -P",
            ]))
        XCTAssertEqual(
            label(["/bin/zsh", "-c", "emulate -L zsh; noglob nocorrect rsync -a src/ dst/"]),
            "rsync")
    }

    func testPythonLaunchers() {
        XCTAssertEqual(label(["uv", "run", "train.py"]), "train.py")
        XCTAssertEqual(label(["uv", "run", "--with", "rich", "-m", "http.server"]), "http.server")
        XCTAssertEqual(label(["uv", "run", "--no-project", "python", "serve.py"]), "serve.py")
        XCTAssertEqual(
            label(["uv", "run", "--no-project", "python", "-c", "import time"]), "python")
        XCTAssertEqual(label(["uv", "run", "pytest", "-x"]), "pytest")
        XCTAssertEqual(label(["uv", "--directory", "/proj", "sync"]), "sync")
        XCTAssertEqual(label(["uv", "tool", "run", "ruff", "check"]), "ruff")
        XCTAssertEqual(label(["uvx", "mcp-server-fetch@0.6.2"]), "mcp-server-fetch")
        XCTAssertEqual(
            label([
                "/Users/me/.local/bin/uv", "tool", "uvx", "jupyter-mcp-server@latest", "--port",
                "4040",
            ]),
            "jupyter-mcp-server")
        XCTAssertEqual(label(["poetry", "run", "python", "manage.py", "runserver"]), "manage.py")
        XCTAssertEqual(label(["pipenv", "run", "celery", "-A", "app", "worker"]), "celery")
        XCTAssertEqual(label(["poetry", "install"]), "install")
    }

    func testNodePackageManagers() {
        // npm sets process.title, leaving one string in argv (seen live).
        XCTAssertEqual(
            label(
                ["npm exec @doist/todoist-ai", "", "", ""], name: "npm exec @doist/",
                path: "/Users/me/.nvm/versions/node/v25.2.1/bin/node"),
            "@doist/todoist-ai")
        XCTAssertEqual(
            label(["npm run dev"], name: "npm run dev", path: "/opt/homebrew/bin/node"), "dev")
        XCTAssertEqual(
            label([
                "node", "/opt/homebrew/bin/npm", "exec", "@automattic/mcp-wordpress-remote@latest",
            ]),
            "@automattic/mcp-wordpress-remote")
        XCTAssertEqual(
            label(["node", "/x/lib/node_modules/npm/bin/npm-cli.js", "run", "build"]), "build")
        XCTAssertEqual(
            label(["node", "/x/bin/npx", "-y", "@scope/tool@1.2.0", "--flag"]), "@scope/tool")
        XCTAssertEqual(
            label(["node", "/x/.npm/_npx/d036eb05/node_modules/.bin/mcp-wordpress-remote"]),
            "mcp-wordpress-remote")
        XCTAssertEqual(label(["pnpm", "--filter", "web", "dev"]), "dev")
        XCTAssertEqual(label(["pnpm", "dlx", "create-vite@latest"]), "create-vite")
        XCTAssertEqual(label(["yarn", "test"]), "test")
        // Any other title is the name the program chose (an agent harness, seen live).
        XCTAssertEqual(
            label(["pi", "", "", "", "", ""], name: "node", path: "/opt/homebrew/bin/node"), "pi")
        XCTAssertEqual(
            label(["my server"], name: "my server", path: "/opt/homebrew/bin/node"), "my server")
        // A bare node with no title is the REPL: nothing to add.
        XCTAssertNil(label(["node"]))
        XCTAssertNil(label(["/opt/homebrew/bin/node", ""]))
    }

    func testCompiledLanguageLaunchers() {
        XCTAssertEqual(
            label(["cargo", "run", "--release", "--bin", "server", "--", "-v"]), "server")
        XCTAssertEqual(label(["cargo", "run", "-p", "worker"]), "worker")
        XCTAssertEqual(label(["cargo", "+nightly", "run"]), "run")
        XCTAssertEqual(label(["cargo", "build", "--release"]), "build")
        XCTAssertEqual(label(["go", "run", "./cmd/api"]), "api")
        XCTAssertEqual(label(["go", "run", "/src/tool/main.go"]), "tool")
        XCTAssertEqual(label(["go", "run", "."]), "run")
        XCTAssertEqual(label(["go", "run", "golang.org/x/tools/cmd/stringer@latest"]), "stringer")
        XCTAssertEqual(label(["go", "test", "./..."]), "test")
    }

    func testSelfChosenTitlesForEveryInterpreter() {
        // Python's setproctitle (gunicorn, celery), Ruby and Perl's `$0 =`:
        // the title, then empty strings where the other arguments were.
        XCTAssertEqual(
            label(
                ["gunicorn: worker [app]", "", "", ""], name: "Python",
                path: "/opt/homebrew/bin/python3"),
            "gunicorn: worker [app]")
        XCTAssertEqual(
            label(["celery", "", ""], name: "python3", path: "/usr/bin/python3"), "celery")
        XCTAssertEqual(
            label(
                ["puma: cluster worker 0: 4242 [blog]", "", ""], name: "ruby",
                path: "/usr/bin/ruby"),
            "puma: cluster worker 0: 4242 [blog]")
        XCTAssertEqual(
            label(["my-daemon", ""], name: "perl", path: "/usr/bin/perl"), "my-daemon")
        // Real command lines are not titles, even when argv[0] has a space.
        XCTAssertEqual(
            label(
                ["/Applications/My App.app/Contents/MacOS/python3", "serve.py"],
                name: "python3", path: "/Applications/My App.app/Contents/MacOS/python3"),
            "serve.py")
        XCTAssertNil(label(["/usr/bin/python3", ""], name: "python3", path: "/usr/bin/python3"))
        XCTAssertNil(label(["-zsh", ""], name: "zsh", path: "/bin/zsh"), "shells never retitle")
    }

    func testOnlyInterpretersAreLabelled() {
        XCTAssertFalse(
            CommandLabel.isInterpreter(
                name: "Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"))
        XCTAssertNil(label(["/usr/bin/make", "all"]))
        XCTAssertTrue(CommandLabel.isInterpreter(name: "python3.12", executablePath: nil))
        // A fork caught before exec still has the shell's path; the name decides.
        XCTAssertTrue(CommandLabel.isInterpreter(name: "node", executablePath: "/bin/zsh"))
    }

    func testOverlongLabelsAreCutInTheMiddle() {
        let long =
            String(repeating: "a", count: 50) + "_" + String(repeating: "b", count: 50) + ".py"
        let result = label(["python3", long])
        XCTAssertEqual(result?.count, CommandLabel.maxLength)
        XCTAssertTrue(result?.contains("…") == true)
        XCTAssertTrue(result?.hasSuffix(".py") == true)
    }

    func testLabeledNameJoinsTheTwo() {
        XCTAssertEqual(
            ProcessSample.labeledName("python3", commandLabel: "train.py"), "python3 · train.py")
        XCTAssertEqual(ProcessSample.labeledName("python3", commandLabel: nil), "python3")
    }
}
