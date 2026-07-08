# Changelog

Notable changes to Mac Performance Monitor. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/Zesty0wl/mac-performance-monitor/compare/v1.2.0.127...HEAD
[1.2.0]: https://github.com/Zesty0wl/mac-performance-monitor/compare/v1.1.5.118...v1.2.0.127
[1.1.5]: https://github.com/Zesty0wl/mac-performance-monitor/releases/tag/v1.1.5.118
