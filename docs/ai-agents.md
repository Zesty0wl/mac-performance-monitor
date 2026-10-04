# Using AI agents with Mac Performance Monitor

Mac Performance Monitor keeps a detailed history of how your Mac has been
doing. AI agents such as Claude Code and Codex can read that history to answer
questions the app's own views don't, like "what was slowing my Mac down at
10am?" or "which app's memory has been growing all week?", and then explain
what they found in plain English, with the numbers behind it.

There are three ways in:

- **The MCP server** (recommended). Your agent connects to the app's bundled
  `mpm` tool and gets five read-only tools: a guide to the data, SQL queries,
  the app's own judged summaries, a process finder, and links that open the
  matching charts in the app.
- **The hand-off prompt.** Ask About This Mac copies a ready-made prompt that
  teaches any agent how the history is stored, and can carry over the
  question you just asked and the facts behind its answer.
- **The `mpm` command line.** The same read-only access from Terminal, for
  scripts or for agents without MCP.

Everything is read-only. Nothing an agent does through these routes can change
the app's history or settings. See [Privacy and safety](#privacy-and-safety)
for what does leave your Mac.

## Before you start

- **Mac Performance Monitor 2.3 or later, in `/Applications`.** `mpm` ships
  inside the app at:

  ```
  /Applications/Mac Performance Monitor.app/Contents/MacOS/mpm
  ```

  If you installed the app somewhere else, use that path in the commands below.

- **History recording turned on**, in Settings > Record history (on by
  default). The agent reads what the app has recorded, so the longer the app
  has run, the more there is to work with. `mpm coverage` shows how far back
  the history goes.

- **Open the app once after updating** so it can prepare the views agents
  read.

- **macOS 15 or later.** The MCP server and `mpm` work on every macOS version
  the app supports. The Ask window, and its hand-off buttons, need macOS 27.

## Set up Claude Code

Run this once in Terminal:

```sh
claude mcp add --scope user mac-performance-monitor -- "/Applications/Mac Performance Monitor.app/Contents/MacOS/mpm" mcp
```

`--scope user` makes the server available in every folder you start Claude
Code in. Without it, Claude Code adds the server only for the current folder.

Check it worked with `claude mcp list` (it should show
`mac-performance-monitor` as connected), or type `/mcp` inside Claude Code.
Then just ask:

> Why was my Mac slow this morning?

Claude Code calls `describe_data` first to learn the data, then the other
tools as it needs them.

## Set up Codex

```sh
codex mcp add mac-performance-monitor -- "/Applications/Mac Performance Monitor.app/Contents/MacOS/mpm" mcp
```

Codex stores this in `~/.codex/config.toml`, so it applies everywhere. Check it
with `codex mcp list`, or `/mcp` inside Codex. If you prefer to edit the file
yourself, the entry is:

```toml
[mcp_servers.mac-performance-monitor]
command = "/Applications/Mac Performance Monitor.app/Contents/MacOS/mpm"
args = ["mcp"]
```

## Set up other MCP clients

`mpm mcp` is a standard MCP server that talks over stdin and stdout, so any
client that can launch a local (stdio) server can use it. The command is the
`mpm` path and the only argument is `mcp`.

**Claude Desktop:** Settings > Developer > Edit Config opens
`~/Library/Application Support/Claude/claude_desktop_config.json`. Add the
server and restart Claude Desktop:

```json
{
  "mcpServers": {
    "mac-performance-monitor": {
      "command": "/Applications/Mac Performance Monitor.app/Contents/MacOS/mpm",
      "args": ["mcp"]
    }
  }
}
```

**Cursor** reads the same `mcpServers` shape from `~/.cursor/mcp.json` (all
projects) or `.cursor/mcp.json` in a project.

**VS Code** (agent mode) reads `.vscode/mcp.json` in a workspace, or the user
`mcp.json` from the command palette's "MCP: Open User Configuration":

```json
{
  "servers": {
    "mac-performance-monitor": {
      "type": "stdio",
      "command": "/Applications/Mac Performance Monitor.app/Contents/MacOS/mpm",
      "args": ["mcp"]
    }
  }
}
```

The path contains spaces. In JSON and TOML it is a single quoted string, as
above; in a shell command, keep it in quotes.

## Hand off from Ask About This Mac

On macOS 27, Ask About This Mac answers everyday questions itself. Open it from
the menu bar item or the sparkles button in the main window's toolbar. When you
want to dig further, use the **Dig deeper with an AI agent** card, or the
**Hand off to an AI agent** menu in Ask's toolbar:

- **Copy prompt** (in the toolbar, **Copy prompt with this conversation** once
  you have asked something): a prompt that explains this Mac, the history
  available, how to read it with `mpm`, the rules for reading it correctly, and
  example queries. After a question, it also carries your question, the facts
  Ask found and its answer, and asks the agent to check them and go further.
  Paste it into Claude Code, Codex, or any agent that can run commands on your
  Mac.
- **Set up once > Claude Code** or **Codex** (in the toolbar, **Copy Claude
  Code setup** and **Copy Codex setup**): the one-line setup command above,
  ready to paste into Terminal.

The first time you copy, Ask explains that the agent sends what it reads to its
own provider and asks you to confirm.

You can also get the same prompt from Terminal with `mpm prompt`.

## Things to ask

Agents do best with a concrete question and a time:

- "Why did my Mac feel slow around 10:00 today?"
- "Which apps used the most energy yesterday afternoon?"
- "Has any app's memory been growing steadily this week?"
- "Is anything keeping a core busy for hours at a time?"
- "Compare today's memory pressure with the same time last Tuesday."
- "When was my disk busiest in the last 24 hours, and what was writing?"
- "Did the fans or temperatures change after I installed the update on Friday?"

Ask for a chart link when you want to see the evidence: the agent returns a
`macperfmonitor://` link that opens the app's Explorer on the right charts and
time, with the busiest apps selected.

## MCP tools

| Tool | What it returns | Arguments |
| --- | --- | --- |
| `describe_data` | This Mac (chip, cores, memory, macOS), what history exists, the rules for reading it, every view and column with units, and example queries. Agents should call it first. | none |
| `query` | The result of one read-only SQL statement against the `agent_*` views. | `sql` (required), `limit` (default 200, at most 2,000), `format` (`table`, `csv` or `json`) |
| `summarize` | The app's own judged summary of one part of the Mac: a status (calm, busy, worth a look, needs attention), what is normal for this Mac, the apps responsible, notable events, what isn't known, safe next steps, and a chart link. The same facts Ask uses. | `part` (required), `app`, and a time |
| `find_process` | Recorded runs of an app or process, matched by name, app, bundle ID or path, with the `process_key` used in `agent_process_usage`. | `name` (required) |
| `chart_link` | A `macperfmonitor://` link that opens Explorer on the charts for one part of the Mac over a period. | `part` (required), and a time |

**Parts:** `overall`, `processor`, `memory`, `graphics`, `neural-engine`,
`network`, `storage`, `battery`, `heat`. Common aliases such as `cpu`, `ram`,
`gpu`, `ane`, `disk` and `thermal` also work.

**Time** (for `summarize` and `chart_link`): `minutes_back` (default 60), or
`at` (half an hour either side, for example `10:00`), or `from` and `to`. Times
can be `HH:MM` (today, local time), `YYYY-MM-DD HH:MM`, ISO 8601, or Unix
seconds.

## The `mpm` command line

```sh
MPM="/Applications/Mac Performance Monitor.app/Contents/MacOS/mpm"

"$MPM" coverage                        # how far back the history goes
"$MPM" brief overall --last 60         # the app's judged summary of the last hour
"$MPM" brief processor --at 10:00      # around 10:00 today
"$MPM" brief memory --from "2026-10-03 09:00" --to "2026-10-03 12:00"
"$MPM" brief battery --last 120 --app Safari   # include one app's use
"$MPM" find Chrome                     # recorded runs of an app
"$MPM" link processor --last 60 --open # open the matching charts in the app
"$MPM" schema                          # every view and column, with units
"$MPM" sql "SELECT time_local, ROUND(cpu_percent) AS cpu FROM agent_system_by_minute WHERE ts >= strftime('%s','now') - 3600"
"$MPM" prompt                          # the hand-off prompt
"$MPM" help                            # everything else
```

`sql` takes `--format table|csv|json` and `--limit N` (default 500).
`brief` takes `--json`. Every command takes `--db PATH` to read a copy of the
database instead of the live one.

## The data agents read

Agents query a set of views that stitch the app's history together and use
plain units (percent, MB, GB, KB/s, degrees Celsius, local times):

| View | What it holds |
| --- | --- |
| `agent_system` | The whole Mac over time: CPU, memory pressure, swap, network, disk, GPU, Neural Engine, temperatures, fans, battery. The finest detail available for each period. |
| `agent_system_by_minute` | The same at no finer than one minute, for anything longer than a couple of hours. |
| `agent_processes` | Every recorded process: name, app, kind (`app`, `macos` or `background`), when it ran. |
| `agent_process_usage` | Each process's CPU, memory, GPU, network, energy and disk use per minute (per hour further back). |
| `agent_coverage` | How far back each tier of history goes. |
| `agent_mac` | This Mac's core counts and memory. |
| `agent_battery_daily` | Battery health and cycle count by day. |

`describe_data` (or `mpm schema`) lists every column with its units. How far
back detail goes depends on Settings: by default, the last 2 hours are kept in
full detail, a week at one-minute resolution, and 90 days at one-hour
resolution.

The app also gives agents rules for reading the data honestly, for example:
NULL means "not measured", never zero; an app using a small share of the Mac
isn't the cause of a slowdown however high it ranks; macOS's own processes
shouldn't be quit; and conclusions should show their numbers and say when the
data can't answer the question.

## Privacy and safety

**Read-only, by design.** `mpm` opens the database read-only, with SQLite's
`query_only` mode on, accepts a single `SELECT`, `WITH` or `EXPLAIN` statement
at a time, refuses statements such as `ATTACH`, `PRAGMA` and `VACUUM`, stops any
query after 20 seconds, and caps the rows it returns. Chart links are only
returned for you to click; `mpm` never opens anything itself unless you pass
`--open`.

**What leaves your Mac.** The app itself sends nothing. But an AI agent sends
whatever it reads to its own provider (Anthropic, OpenAI or whoever runs the
model) to work on your question. That can include app and process names,
executable paths and timings, as well as performance figures. Use a local model
if that matters to you, and check your provider's data policy.

**Keep agents out of the app's files.** The rules tell agents never to write
to, move or delete anything in
`~/Library/Application Support/MacPerformanceMonitor/`. If your agent can run
arbitrary shell commands, it is still worth keeping an eye on what it does
there.

## Troubleshooting

**`claude mcp list` or `codex mcp list` shows the server failing to connect.**
Run the command by hand:

```sh
"/Applications/Mac Performance Monitor.app/Contents/MacOS/mpm" coverage
```

If that prints a table, the server is fine; check the path in your client's
config, including the quotes. If it reports that the app isn't installed there,
use the path where it is.

**"no such table: agent_system" or similar.** The views are created when the
app opens its history. Open Mac Performance Monitor once (after an update too),
and make sure Settings > Record history is on.

**The agent says there's no data for a time.** Check `mpm coverage`: the
history only reaches back as far as the app has been recording, and detail
thins out with age (see [The data agents read](#the-data-agents-read)).

**The server works in one folder but not another (Claude Code).** It was added
without `--scope user`. Remove it with
`claude mcp remove mac-performance-monitor` and add it again with the scope.

**The agent's times look an hour out.** The `*_local` columns use your Mac's
current time zone; `ts` is Unix seconds (UTC). Ask the agent to work in local
time and use `time_local`.

**Chart links don't open.** They need Mac Performance Monitor installed; the
link opens it on the Explorer tab. If nothing happens, open the app first and
click the link again.
