# Security Policy

Mac Performance Monitor reads process, memory, and device data. It keeps that
history and alert evidence on your Mac. It sends no usage telemetry, but it
does use the network. For example, it checks for updates and runs network tests.

## Reporting a vulnerability

Report security issues in private, not in a public issue.

- Use GitHub's private vulnerability reporting (the "Report a vulnerability"
  button under the repository's **Security** tab), or
- contact the maintainers at the address listed on the repository profile.

Tell us what went wrong, which version or commit you used, and how to repeat it.
We will confirm receipt, look into the issue, and keep you informed about a fix.
Please allow time for that work before making the report public.

## Supported versions

Fixes target the latest release and current development branches. Include the
version and build number when reporting an issue, plus the commit for a source
build. Older releases may not receive the same fixes.

## Privacy posture

- No usage telemetry or analytics. With recording on, the app stores full
  performance history in a local SQLite database.

- **Usage Timeline** can read Apple's local activity history. Each window starts
  with this off, even if the app already has Full Disk Access. Turning it on
  reads only app-usage and media intervals for the selected app bundle in the
  current user's account. These rows do not verify the source device or process.
  The read does not change Apple's database. The app keeps the rows in that
  window's memory and clears them when switched off or closed. It does not add
  them to saved performance history, trace exports, or network requests.

- Alert state uses separate local files. They can hold process names, paths,
  IDs, and evidence even with full history off. See
  [Adaptive alerts](docs/adaptive-alerts.md#local-evidence) for the limits.

- **Ask About This Mac** (macOS 27) uses only Apple's on-device model through
  Foundation Models. It never uses Private Cloud Compute or any other cloud
  service. The app reads its own history and current readings, then gives the
  model short, ready-made summaries: levels, what is normal for this Mac, the
  busiest apps by name, and notable events. It excludes full paths, command
  arguments, file names and raw history. The model has no tools: it cannot run
  queries, commands, or change anything. Questions and answers stay in memory
  and are cleared when Ask closes; nothing is logged or saved. Settings has a
  switch to turn Ask off. Earlier versions offered downloadable Qwen and
  DeepAnalyze models; this version deletes any that were downloaded.

- **AI agents** (Claude Code, Codex and others) can read the history through
  `mpm`, a command-line tool and MCP server inside the app bundle. It opens the
  database read-only, runs only single read-only SQL statements that SQLite
  confirms cannot write, caps rows and stops long queries. `mpm` itself makes
  no network requests, but an agent sends what it reads, including app names,
  paths and usage, to its own AI provider under that provider's terms. Nothing
  is shared until you set up an agent or paste the prompt Ask copies; Ask
  explains this before the first copy. `macperfmonitor://` links only open
  Explorer on a checked set of charts, times and processes.

- Siri and Shortcuts can open Ask. They receive no readings, reports or
  answers from the app.

- CSV, traces, hardware reports, and screenshots can contain private details.
  Check them before sharing. Exports keep the original names and paths; they
  do not hide who or what the data describes.

- Sparkle checks for and downloads updates. The app also downloads signed
  checks and glossary content. Network tools contact the hosts or networks you
  choose. These features do not upload your recorded performance history.

- The app is not sandboxed. You can enable a privileged helper to read more
  processes. The app and helper check each other's code signatures.
  Full Disk Access lets disk scans and other tools read more files.

- **ANE power** uses that approved helper to run Apple's powermetrics as root.
  The executable, arguments, one-second interval, and 60-sample child lifetime
  are fixed. Clients cannot supply commands or paths. One shared sampler uses
  short client leases; it stops when demand ends or a client disconnects.
  Output frames and replies have size limits, and stale replies are discarded.
  The helper returns only ANE watts, a timestamp, and the sample interval. It
  saves no raw tool output and makes no network requests. ANE Time does not
  need root. See [ANE power](docs/gpu-tab-design.md#ane-power-18-september-2026).

- Actions you choose can make changes. These include force-quitting a process,
  installing the helper, or applying an update. Routine monitoring is separate
  from those actions. Read prompts and check permissions before proceeding.

## Release Integrity

Published apps and packages use Developer ID signing and Apple notarization.
Sparkle also checks the update's EdDSA signature. A local or ad-hoc build does
not provide the same checks as a published package.

Keep signing keys, certificates, private settings, databases, and alert logs
out of git and security reports. Send only what we need to repeat the issue.
Remove unrelated paths and account details first.

