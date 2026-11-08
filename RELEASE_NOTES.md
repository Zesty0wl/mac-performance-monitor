# Mac Performance Monitor 2.7.0

Build 312, 8 November 2026. For Apple silicon Macs running macOS 15 or later.
This update includes changes since 2.6.0, build 306.

[Download the signed installer](https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v2.7.0.312/MacPerformanceMonitor.pkg).
Existing installs can use **Check for Updates** through Sparkle. Homebrew uses
the same installer; its cask update may arrive after this release.

## Inside the GPU

The GPU tab's Device panel now has five pages, all read without administrator
rights:

- **Clock:** the average clock while the GPU is awake against its top clock,
  and time spent at each clock state.
- **Limits:** what held the clock back, for how long, and the performance lost.
- **Work:** compute, fragment and geometry submissions, wake-ups and context
  switch latency.
- **Memory:** the GPU's wired-memory limit and how much headroom is left.
- **Health:** recoveries, firmware restarts, killed work, under-voltage
  warnings and thermal activations.

**Over time** gains a **Clock** chart, kept in history like the other GPU
readings.

## Quieter Updates

Scheduled update checks no longer open a window or take focus. When an update
is ready, an **Update** button appears in the main window and an "Update to"
item in the menu bar menus. Settings > General has "Check for updates
automatically" and "Install updates automatically", and both now work: with
automatic install on, updates install while the app is in the background.

This is the last update that 2.6.0 will announce with the old prompt.

## Fixes

- Windows no longer open behind other apps when reopened just after closing.
- Everyone on a shared Mac can run the app at the same time, each in their own
  account.

See the [changelog](CHANGELOG.md) for the full list.
