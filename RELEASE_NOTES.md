# Mac Performance Monitor 2.4.0

Build 289, 17 October 2026. For Apple silicon Macs running macOS 15 or later.
This update includes changes since 2.3.1, build 280.

[Download the signed installer](https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v2.4.0.289/MacPerformanceMonitor.pkg).
Existing installs can use **Check for Updates** through Sparkle. Homebrew uses
the same installer; its cask update may arrive after this release.

## A Clearer GPU Tab

The GPU tab used to stack six full-width charts above the list of processes,
so you had to scroll to the bottom to see what was using the GPU. The list now
sits near the top, beside the category split and AI workloads, and in the
default window you can see it without scrolling.

The six charts now share one panel. Pick Utilization, Power, Bandwidth, Neural
Engine or Temperature, and the tab remembers your choice. The headline cards
fit on one row, and the longer explanations are behind info buttons. The page
is about half as tall as before.

## Even Less Memory

2.3.1 stopped closed menu bar dropdowns from piling up in memory. This release
goes further. Small charts draw into reusable images, caches have fixed
limits, history is read one row at a time, and the app frees unused charts,
icons and cached history when you close the last menu or window. In
menu-only tests, warm idle memory fell from 152-166 MiB to 68-76 MiB.
Recording, alerts and history are unchanged.

## Fixes

The Processes details panel no longer grows and shrinks when you select a
different process, and the table and details no longer overlap.

See the [changelog](CHANGELOG.md) for the full list.
