# Changelog

Notable changes to Mac Performance Monitor. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
