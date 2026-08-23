# Changelog

Notable changes to Mac Performance Monitor. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.4.0] - 2026-08-23

### Added

- **A GPU tab:** what the GPU is doing, at what clock and power, who is using
  it, and how much of that is AI work. Live utilization (device, renderer,
  tiler, active share) and power (GPU, Neural Engine, CPU) timelines with
  history, the chip's clock-state residency, thermal limit and power cap from
  IOReport, and a "who is using the GPU" table built from the AGX driver's
  per-context accounting, which needs no helper and no root: GPU share,
  milliseconds of GPU time per second, and last activity for every process
  holding a Metal context. Processes are classified into AI and ML, display
  and UI, media, and other; known runtimes (Ollama, llama.cpp, MLX, LM Studio,
  Core ML hosts, Apple Intelligence, the media analysis daemons) are named,
  and a bare Python or Node serving a model is recognised from its command
  line, with the model file where the arguments say. An AI workloads card
  shows those processes with their GPU share and whether the Neural Engine is
  busy. Research and data sources are in `docs/gpu-tab-design.md`.
- **GPU history (schema v13):** system samples record GPU utilization and GPU
  and Neural Engine power, process samples record GPU time and share, all with
  minute and hour rollups, so the GPU timelines have a past to show.
- **Sustained high GPU alert:** off by default, with a threshold in Settings,
  alongside the existing pressure, swap and per-process alerts.
- **Top GPU processes in the menu bar:** the GPU dropdown (and the GPU panel of
  the combined item) lists the processes drawing on the GPU with their share,
  naming the AI runtime where there is one. An empty list after a scan reads
  "Nothing is using the GPU" rather than "Sampling".
- **A Hardware tab:** this Mac's inventory as a searchable, browsable tree with
  a visual overview: a block diagram of the system on a chip (CPU clusters with
  one square per core, the GPU's cores, the Neural Engine, the unified memory
  they share, scaled to fit anything up to an Ultra), capacity bars for memory
  and volumes, the displays drawn to their aspect ratio, the battery's health
  ring, the radios and buses, and the running software. Nineteen sections
  cover everything `system_profiler` and the kernel report: Mac identity,
  processor (performance levels with their caches, every instruction-set
  feature the kernel publishes), Metal device limits, memory, displays,
  storage, power and battery (the raw gauge: cells, adapter, manufacture
  date), network, Wi-Fi via CoreWLAN, Bluetooth, USB, Thunderbolt and USB4,
  audio, cameras, PCI, peripherals, printers, security (secure boot, SIP,
  signed system volume, the Secure Element) and software. Search matches any
  title or property; every value copies with a click; any item or the whole
  inventory exports as text or JSON. The page reads once when opened and again
  only on Refresh (Command-R), never on the sampling tick.
- **250 ms and 500 ms refresh intervals:** the live charts, read-outs and the
  process rows on screen now move at the dial rate, including 4 Hz. The full
  per-process scan, the table order, rankings and alerts keep a 5 s floor.
- **A chart benchmark harness** (`--benchmark-charts`): measures the live
  pipeline per tick offscreen, renders any page to a PNG with `--snapshot`,
  and checks the Hardware page against an Ultra-sized chip.

### Changed

- **Every live chart is now a scrolling strip:** a fixed trailing window that
  moves right to left as samples arrive, drawn by AppKit layers that scroll
  by moving pixels rather than repainting. Completed columns are final (bucket
  extremes are anchored to absolute time), so a tick costs the same whether
  the window holds a minute or seven days of samples. With the window open on
  the Dashboard at 250 ms the app's CPU fell from about 53% to about 11%; the
  per-tick cost of the Dashboard page dropped from 45 ms to under 8 ms.
  Details and every measurement are in `docs/efficiency-analysis-2026-08-22.md`.
- **Everything that moves is an AppKit surface:** sparklines, metric cards,
  timelines, the core grid, the taxonomy bar and the header read-outs repaint
  their own layers from feeds; SwiftUI builds the static chrome once. The
  process table is an AppKit outline view whose rows on screen are re-read at
  the dial rate (task info, rusage and GPU time for just those pids, about a
  millisecond for thirty rows) and patched in place; re-sorting happens on
  the 5 s calc.
- **Menu bar items follow the dial** and skip unchanged renders, so the
  status item figures move with the charts instead of lagging them.
- **The per-process scan runs on its own queue:** the system tick publishes at
  once and never waits behind a scan; scans never pile up, and a forced scan
  (a pressure event) is remembered rather than dropped.
- **Cheaper Network and Disk pages at fast dials:** SystemConfiguration,
  CoreWLAN and host-name lookups are cached between polls, and the block
  storage enumeration is reused across reads.
- **Process detail and system header** re-render only when the model
  publishes; their live parts ride the feeds.

### Fixed

- **The GPU tab and GPU dropdown updated once a second regardless of the
  dial:** the device read (IORegistry, IOReport, SMC) was decimated to 1 Hz.
  It now runs every tick while a GPU surface is open (the driver's utilization
  figure does change between sub-second reads) and once a second when only
  the menu bar icon or history logging wants it.
- **A reopened popover could offer kill or inspect on stale rows:** a top
  process list older than the dial interval is cleared when its popover
  opens, until the immediate scan lands.


## [1.3.8] - 2026-08-14

### Added

- **A dedicated Disk tab:** every disk fact the system exposes, on one page.
  Live read/write throughput and IOPS with history, per-operation service
  latency and a busy-time utilization figure derived from the driver's
  counters, a card per physical device with its full hardware identity (model,
  vendor, firmware, serial, interconnect, NAND status, NVMe revision, block
  size), per-volume capacity bars grouped by APFS container with purgeable
  space and role badges, SMART health for the internal SSD (temperature, life
  used, spare, power-on hours, unsafe shutdowns, lifetime reads and writes),
  a boot-volume free-space trend with a low-space rule, and the top processes
  by attributed disk I/O over the selected range. The menu bar disk panel's
  Open button now lands on the new tab.
- **Disk detail history (schema v12):** system samples now record read/write
  service latency, disk utilization, and boot volume free space (sampled once
  a minute), with minute and hour rollups. The new columns are nullable on
  purpose: an interval with no IO charts as a gap, never as a fake 0 ms, and
  free space keeps its low water mark through every aggregation tier.

### Fixed

- **Hot battery temperatures are no longer misread as sub-zero:** the
  AppleSmartBattery `Temperature` key is centi-degrees, and most controllers
  report centi-Celsius while a few report centi-Kelvin. The decoder told the
  two apart with a greater-than-100 threshold, but 100 degrees is plausible
  for an actively failing cell, so a genuine (if extreme) Celsius reading
  above that was treated as Kelvin and converted to a value below absolute
  zero. The detector now uses a 200 threshold: no real Celsius reading
  reaches it (thermal runaway destroys the cell first), and no real Kelvin
  reading falls below it (that would be a battery colder than minus 73
  degrees), so the two units separate cleanly. The decode is also extracted
  into a pure helper so it is unit-tested alongside the other battery
  decoders.
- **The network scanner recognises the whole IPv6 link-local range:** the NDP
  table parser and the per-interface address collector matched only an `fe80`
  prefix, but RFC 4291 defines link-local unicast as `fe80::/10`, which spans
  `fe80::` through `febf::`. Addresses in `fe90::` to `febf::` were sorted into
  the global bucket of the NDP view and, on the Network page, were kept in the
  global IPv6 list instead of being filtered out as link-local noise. A shared
  `isIPv6LinkLocal` predicate now matches the full `fe80::/10` range, so every
  link-local address lands in the right place.

- **The deep memory inspector no longer traps on a malformed size token:**
  `MemoryInspection.parseBytes` built its result with `UInt64((value *
  multiplier).rounded())`, and `value` is parsed straight from a `footprint` /
  `heap` / `vmmap` token. Any non-representable result (a negative number, an
  `inf` / `NaN` token, or a value past `UInt64.max`) made that initializer trap
  with a fatal error, aborting the inspector mid-parse even though the function
  advertises "returns nil if it cannot be parsed". The conversion now uses
  `UInt64(exactly:)`, which returns nil for those inputs, so a stray token is
  treated as unparseable instead of crashing the report.

## [1.3.7] - 2026-08-09

### Fixed

- **A timed-out memory inspection no longer masquerades as success:** the deep
  memory inspector shells out to Apple's tools (`footprint`, `heap`, `leaks`,
  `sample`) under a hard timeout, and a wedged target that printed a few lines
  before hanging was killed on time, but its partial text was then returned as a
  complete `.success` instead of `.failure(.timedOut)`. The decision checked the
  captured text before the timeout flag, so any output at all, however truncated,
  hid that the run had been cut short. The timeout now wins regardless of output:
  a run killed for exceeding the limit reports `.timedOut` even when it managed
  to write partial stdout first, so an incomplete report is shown as a failure
  rather than presented as the tool's full answer.
- **Quiet the notification spam during a sustained memory crisis:** real memory
  pressure can bounce between critical and normal while the kernel compresses,
  swaps, and throttles, and every bounce re-armed the alert so the next critical
  tick fired a fresh notification. The engine now delivers at most one
  notification for each alert during a cooldown window (five minutes by default),
  so a condition that keeps flapping notifies once instead of re-firing on every
  flap. The condition is still tracked and shown as active until it genuinely
  recovers; only the repeat notifications are held back.
- **Vendor grouping works for processes whose team id resolves late:** the
  recording cache short-circuited the per-process upsert on (name, path,
  bundle id) without checking the team id, so a process first seen with
  team_id nil (the common case, since codesign lookups are expensive and the
  sampler resolves a team id for only ~30 of ~800 processes per tick) and
  later resolved to a real team id never had that id written, leaving the row
  NULL forever. Grouping by vendor, which keys on team_id, therefore broke
  for the bulk of processes after every app launch. The cache now carries the
  team id and compares it, so a late-resolved id defeats the short-circuit and
  the row's existing COALESCE upsert heals it in place.
- **Disk tab trend no longer flattens to zero on long ranges:** the Disk tab's
  read/write trend lines collapsed to a flat zero on any dashboard range whose
  point count exceeded the chart cap (the six-hour, day, and longer windows),
  even though the underlying raw and minute-tier rows carried the values. The
  chart downsampler builds one averaged point per time bucket, and it carried
  the pressure, memory, CPU, battery, and network scalars through but omitted
  the four disk-throughput fields, so they defaulted to 0. The four disk
  scalars (read and write bytes per second, and read and write operations per
  second) are now averaged per bucket like the network scalars, the same fix
  the battery and network fields already got. The downsampler also moved from
  the app target into `MacPerfMonitorCore/Persistence` (alongside the history
  type it operates on), bringing this chart-path function under the headless
  test suite for the first time.

## [1.3.6] - 2026-08-04

### Fixed

- **Exited processes keep their real name:** an app could be recorded in the
  history under the name "xpcproxy" instead of its own, so killing (say)
  Microsoft Word left the Analytics picker offering an "xpcproxy" entry with
  Word's data. macOS launches apps through an xpcproxy trampoline that becomes
  the app in place, and a sample straddling that moment captured the trampoline's
  name with the app's path; the recording cache then froze that first glimpse for
  the whole session. The store now refreshes a process's recorded name, path, and
  bundle when they change, and rows already recorded with the trampoline's name
  resolve their display name from the executable path, so existing history heals
  without a migration.
- **Real icons for exited processes:** the Analytics legend and picker showed
  this app's own icon for any process that was no longer running. The executable
  path is now captured when a process is added to the chart, so an exited process
  keeps its actual app icon. Processes with no usable path, or whose binary has
  since been deleted, show the system's generic executable icon rather than
  masquerading as this app.

## [1.3.5] - 2026-08-02

### Added

- **Hide Notch:** a toggle in the menu bar panel's overflow menu switches the
  built-in display to its notch-free mode, so the menu bar drops below the camera
  housing and runs edge to edge. On a 14-inch that returns 185pt the notch was
  taking, which is what makes room for status items on a crowded bar. The choice
  is remembered and re-applied at launch and whenever the display configuration
  changes, so a reboot does not undo it; changing scaled size in System Settings
  keeps the notch hidden at the size you picked. Only appears on Macs with a notch.
- **Chart processes that have exited:** the Analytics picker now lists processes
  the history recorded but that are no longer running, alongside the running ones,
  with the time each was last seen. Their data was always in the database and the
  charts always drew them; only the live-process list stood in the way. Searching
  runs against the whole window rather than the visible page, so a process that
  exited hours ago is still reachable.

### Changed

- **Group members are merged per program:** a process that was quit and relaunched,
  and an app's many identical helper instances, now share one row instead of
  appearing once per PID. A row shows what its instances weighed together while
  running, carries an instance count, and notes how much of the window the program
  was actually up for. Group cards count programs and name the biggest contributors.

### Fixed

- **Group totals no longer inflated by exited members:** on the raw tier a member's
  last footprint was carried forward for the rest of the window, so every instance
  that had died kept contributing to the group's timeline. Members are now dropped
  one heartbeat after their last sample, which is what tells a live process from a
  dead one. Groups whose members restart often read far heavier than they were.

## [1.3.4] - 2026-08-01

### Changed

- **New app icon:** the Dock, Finder, and Launchpad icon is now a blue activity
  chart with an alert marker, replacing the previous line-and-nodes mark. It reads
  more clearly at small sizes and matches the app's charting and alerting focus.

## [1.3.3] - 2026-07-29

### Fixed

- **Combined menu bar dual-rate layout:** Disk and Network Focus/Strip readouts no
  longer overlap their down/up figures. Stacked rates use matched compact fonts and
  a shared half-height layout, and sit on the same 22pt band as other strip cells.
- **Strip caption cells:** RAM, CPU, and GPU titles sit higher with larger medium-weight
  values, so the strip stays even without the over-bold look that clashed with
  Disk/Network rates.

### Changed

- **Sampling hot path:** `RingBuffer.elements()` returns a chronological collection
  view instead of copying a full array each read. Bundle IDs are cached by `.app`
  path so helpers sharing one bundle do not each re-read `Info.plist` on first sight.

## [1.3.2] - 2026-07-10

### Added

- **Network Scan:** discover devices on a selected local interface and IPv4 subnet
  in a sortable, horizontally scrollable table. Results include reachability,
  MAC address, host and service names, vendor, SMB identity, optional IPv6
  columns, editable device labels and comments, plus on-demand TCP port scans.
  Vendor cells show queued and lookup states before reporting a result, and
  resolved or unknown MAC prefixes are cached for faster repeat scans. Private
  or randomized MAC addresses are identified separately because they contain no
  IEEE vendor ID, rather than being reported as vendor not found.

## [1.3.1] - 2026-07-10

### Added

- **Physical disk activity:** optional Disk readout in the combined menu bar,
  with read and write throughput, IOPS, device identity, service time, errors,
  retries, and a live process-attributed leaderboard.
- **Disk history:** physical read and write trends on Dashboard, range-aware top
  disk processes, Disk ranking in Insights, and separate read and write charts
  in each process detail.

### Changed

- **Clear directional readouts:** Network and Disk use distinct system icons with
  fixed-width download/upload or read/write rows, so changing values do not move
  their arrows.

### Fixed

- **Stable Disk panel:** the process leaderboard always reserves eight ranked
  rows, so scans can reorder activity without moving the Open and Settings
  controls.
- **Correct multi-display contrast:** each copy of the combined status item now
  follows its own display's menu bar appearance. Light and dark menu bars remain
  legible at the same time instead of both following whichever display was active.

## [1.3.0] - 2026-07-10

### Added

- **One combined menu bar item:** memory pressure, CPU, GPU, energy, and network
  now share one compact status item instead of occupying five separate spaces.
- **Configurable readouts:** choose any combination of metrics, put them in the
  order you prefer, and switch between Focus mode for one value and Strip mode
  for every selected value. At least one readout always remains available.
- **Context-aware panels:** clicking a metric in the status strip opens its panel.
  Clicking another metric while the panel is open switches the content in place.
- **Persistent alarm state:** active alert conditions stay visible until they
  recover using the same hysteresis as notifications.

### Changed

- **Clearer compact typography:** short RAM, CPU, GPU, and BAT labels identify the
  percentage readouts. Network shows fixed-width download and upload rates, with
  stable trailing arrows that do not move as the values change length.
- **Calmer status colors:** normal readouts follow the menu bar's light or dark
  appearance. Active alarms add a red warning marker while values remain in the
  highest-contrast system color.
- **Unified panel navigation:** the combined panel uses text labels for each metric,
  shows both network directions, and provides full-cell click targets.
- **Relevant Open actions:** RAM and GPU open Dashboard, CPU opens Processes,
  energy opens Energy, and network opens Network. The action label names its
  destination.

### Fixed

- **Reliable menu bar targeting:** changing digit counts no longer shifts the
  network arrows, and clicking a different metric no longer closes the open panel.
- **Accessible alarm presentation:** alarm state no longer turns whole readouts red,
  which was difficult to read against some menu bar backgrounds.

## [1.2.1] - 2026-07-10

### Added

- **Share process data (Analytics):** export recorded process history to a
  compressed `.mpmtrace` file. Choose the current view or the last 1, 6, or 24
  hours or 7 days, at full, standard, or coarse resolution. Open a trace from
  Analytics or double-click it in Finder. Imported traces remain interactive even
  when their processes are not running on your Mac.
- **Broader process descriptions:** glossary version 4 adds 137 descriptions,
  including 72 Microsoft entries and 22 for Office. It covers Word, Excel,
  PowerPoint, Outlook, OneNote, Teams, OneDrive, Edge, Defender, Intune, Company
  Portal, Entra sign-in, AutoUpdate, Global Secure Access, Microsoft 365 Copilot,
  Scout, and their helpers.

### Changed

- **Faster Analytics interaction:** trace import, export, chart preparation,
  projection, and statistics now run away from the main thread. The app limits zoom
  and pan updates to the display rate and uses binary search for visible ranges.
  Imported traces retain every process and plot up to eight selected overlays.
- **More efficient history access:** multi-process history loads now use bounded,
  batched SQL reads. New covering indexes speed up network leaderboards and process
  pruning on large databases.
- **Bounded maintenance work:** retention now deletes data in short transactions.
  Sample writes stay responsive after large policy changes. Disabling logging also
  releases history caches and stale analysis data.
- **Lower sampling overhead:** one interface-list pass now collects system network
  counters and addresses. The app also caches the fixed page-size and physical-memory
  values.
- **Safer glossary matching:** signed glossary updates can match exact executable
  paths, stable suffixes, and path patterns. This avoids false labels for generic
  names such as `log`, `node`, `profiles`, and `tracer`.

### Fixed

- **Bounded trace files:** imports and exports now share size, process, and point
  limits. Streaming decompression and validation reject damaged, unsupported, or
  inconsistent traces before they exhaust memory or create invalid charts.
- **Reliable trace export:** users can cancel database reads and output preparation.
  File writes use a temporary file and an atomic final commit. The app cannot create
  a trace that its own reader refuses to open.
- **Database write recovery:** a failed transaction no longer leaves stale process
  IDs or change-gating state in memory. Retrying the same write now succeeds.
- **Memory-inspection cleanup:** capped tool output now stops and drains the child
  promptly. Launch failures no longer retain pipe descriptors or blocked readers.
- **Extreme counter handling:** disk throughput differences no longer overflow when
  read and write counters approach their integer limits.

## [1.2.0] - 2026-07-07

### Added

- **Analytics timeline:** a draggable timeline under the charts. In the multi-chart
  grid, panning, zooming, or scrolling the timeline moves every chart together. Drag
  the bar to pan, drag its edges to zoom, or scroll and pinch to zoom about the
  pointer.
- **Chart zoom on the charts:** scroll-wheel and pinch now zoom the analytics charts
  directly, in both the grid and the focused single-chart view.
- **Statistics overlay:** in single-chart mode, an optional panel showing each
  process's average, peak, current value, and trend across the visible window.

## [1.1.5] - 2026-07-05

The first public, open-source (MIT) release.

Mac Performance Monitor is a macOS performance analyzer and logger that lives in
your menu bar. It records CPU, memory pressure, GPU, network, battery, and
per-process usage to a local database, then helps you find trends, leaks, and the
processes behind them.

### Features

- **Dashboard:** memory pressure as a 0 to 100 index, a processor timeline, CPU
  cores, a memory composition breakdown, swap, and live network throughput, with a
  plain-language verdict.
- **Process explorer:** a live, sortable, filterable table of every process, plus a
  detail inspector charting memory footprint, CPU, file descriptors, and disk I/O
  over time, with Rosetta status and code-signing details.
- **Energy:** battery health and wear, an energy-flow view of what is drawing power,
  charge history, and the top energy users.
- **Network:** download and upload throughput, per-adapter detail, and connection
  configuration, with optional per-app tracking.
- **Analytics:** build your own per-process charts (memory, CPU, network, file
  descriptors, disk I/O) over any window, from a configurable-resolution local log.
- **Insights:** plain-language callouts for what changed, a pressure-event history,
  and the heaviest consumers by memory, CPU, energy, or network.
- **Process groups:** group related apps and helpers into a stack and see its
  blended footprint as a share of the device.
- **Leak detection:** flags processes whose footprint climbs steadily.
- **Deep-dive diagnostics:** explains what a process is and whether its behavior is
  normal, using signed, updatable check packs and a process glossary.
- **Menu bar:** pressure, CPU, GPU, network, and battery readouts, each with a quick
  popover.
- **Alerts:** quiet-by-default notifications for critical pressure, sustained swap,
  per-process ceilings, and suspected leaks, with hysteresis so they do not spam.

### Under the hood

- Apple silicon only. Distributed as a Developer ID signed, notarized, stapled
  installer (`.pkg`), with in-app auto-updates via Sparkle from GitHub Releases.
- No telemetry. Every sample is stored locally in SQLite (via GRDB) and never
  leaves your Mac.
- A clean split between a headless, unit-tested data layer and the SwiftUI app. CI
  builds, tests, and lints on every push and pull request.

[Unreleased]: https://github.com/Zesty0wl/mac-performance-monitor/compare/v1.3.1.158...HEAD
[1.3.1]: https://github.com/Zesty0wl/mac-performance-monitor/compare/v1.3.0.148...v1.3.1.158
[1.3.0]: https://github.com/Zesty0wl/mac-performance-monitor/compare/v1.2.1.131...v1.3.0.148
[1.2.1]: https://github.com/Zesty0wl/mac-performance-monitor/compare/v1.2.0.127...v1.2.1.131
[1.2.0]: https://github.com/Zesty0wl/mac-performance-monitor/compare/v1.1.5.118...v1.2.0.127
[1.1.5]: https://github.com/Zesty0wl/mac-performance-monitor/releases/tag/v1.1.5.118
