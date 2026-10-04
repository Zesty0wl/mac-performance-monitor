import Foundation
import MacPerfMonitorCore

// mpm: read-only access to Mac Performance Monitor's recorded history, for
// people and AI agents. It never writes to the database; see AgentStore.

let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

struct Options {
    var command: String?
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    init(_ arguments: [String]) {
        var index = 0
        let valued: Set<String> = [
            "--db", "--format", "--limit", "--last", "--at", "--from", "--to", "--app",
        ]
        while index < arguments.count {
            let argument = arguments[index]
            if valued.contains(argument), index + 1 < arguments.count {
                flags[argument] = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--") {
                switches.insert(argument)
            } else if command == nil {
                command = argument
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mpm: \(message)\n".utf8))
    exit(1)
}

func usage() -> String {
    """
    mpm \(version): read this Mac's performance history, recorded by Mac Performance Monitor.
    Read-only: it never changes the database.

    Usage:
      mpm schema                         Views, columns, units and rules (Markdown)
      mpm coverage                       What history exists
      mpm sql "SELECT ..."               Run one read-only query
            [--format table|csv|json] [--limit N]
      mpm brief PART [time] [--app NAME] [--json]
                                         The app's judged summary of one part
      mpm find NAME                      Recorded runs of an app or process
      mpm link PART [time] [--open]      A link that opens the matching charts
      mpm prompt                         A prompt to paste into an AI agent
      mpm mcp                            Run as an MCP server (stdin/stdout)

    PART: \(AskArea.agentNames.joined(separator: ", "))
    time: --last MINUTES (default 60) | --at HH:MM | --from TIME [--to TIME]
          TIME is HH:MM, "YYYY-MM-DD HH:MM", ISO 8601 or Unix seconds.
    --db PATH uses another copy of the database.

    Add to Claude Code:  claude mcp add --scope user mac-performance-monitor -- "\(AgentGuide.mpmPath)" mcp
    Add to Codex:        codex mcp add mac-performance-monitor -- "\(AgentGuide.mpmPath)" mcp
    """
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
let databaseURL =
    options.flags["--db"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? MacPerfMonitorDatabase.defaultURL()

func openStore() -> AgentStore {
    do { return try AgentStore(url: databaseURL) } catch { fail(error.localizedDescription) }
}

func window(_ store: AgentStore) -> DateInterval {
    do {
        return try AgentWindow.resolve(
            minutesBack: options.flags["--last"].flatMap(Int.init), from: options.flags["--from"],
            to: options.flags["--to"], at: options.flags["--at"],
            earliest: try store.earliestRecord())
    } catch { fail(error.localizedDescription) }
}

func area() -> AskArea {
    guard let name = options.positional.first, let area = AskArea(agentName: name) else {
        fail("name a part: \(AskArea.agentNames.joined(separator: ", "))")
    }
    return area
}

switch options.command {
case nil, "help", "-h", "--help":
    print(usage())

case "version", "--version":
    print(version)

case "schema":
    print(AgentMCPServer.describe(openStore()))

case "coverage":
    do { print(try openStore().coverage().render(as: options.flags["--format"] ?? "table")) } catch
    {
        fail(error.localizedDescription)
    }

case "sql":
    guard let sql = options.positional.first else { fail("give a query: mpm sql \"SELECT ...\"") }
    do {
        let table = try openStore().query(
            sql, limit: options.flags["--limit"].flatMap(Int.init) ?? 500)
        print(table.render(as: options.flags["--format"] ?? "table"))
    } catch { fail(error.localizedDescription) }

case "brief":
    let store = openStore()
    let part = area()
    do {
        let briefs = try store.briefs(
            areas: [part], interval: window(store), appName: options.flags["--app"])
        if options.switches.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(briefs), as: UTF8.self))
        } else {
            print(AgentMCPServer.render(briefs))
        }
    } catch { fail(error.localizedDescription) }

case "find":
    guard let name = options.positional.first else { fail("give a name: mpm find Chrome") }
    do {
        print(try openStore().findProcesses(name).render(as: options.flags["--format"] ?? "table"))
    } catch {
        fail(error.localizedDescription)
    }

case "link":
    let store = openStore()
    let part = area()
    do {
        let briefs = try store.briefs(areas: [part], interval: window(store))
        guard let link = briefs.first?.chart, let url = AgentChartURL.url(for: link) else {
            fail("no chart for \(part)")
        }
        print(url.absoluteString)
        if options.switches.contains("--open") {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [url.absoluteString]
            try open.run()
        }
    } catch { fail(error.localizedDescription) }

case "prompt":
    let store = openStore()
    print(
        AgentGuide.prompt(
            databasePath: databaseURL.path, coverage: try? store.coverage().render(as: "table"),
            context: nil))

case "mcp":
    let server = AgentMCPServer(version: version) { try AgentStore(url: databaseURL) }
    setvbuf(stdout, nil, _IOLBF, 0)
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        if let reply = server.handle(line) {
            print(reply)
            fflush(stdout)
        }
    }

default:
    fail("unknown command \"\(options.command ?? "")\". Run mpm help.")
}
