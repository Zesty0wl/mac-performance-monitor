# Mac Performance Monitor 2.3.1

Build 280, 11 October 2026. For Apple silicon Macs running macOS 15 or later.
This update includes changes since 2.3.0, build 279.

[Download the signed installer](https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v2.3.1.280/MacPerformanceMonitor.pkg).
Existing installs can use **Check for Updates** through Sparkle. Homebrew uses
the same installer; its cask update may arrive after this release.

## Much Less Memory

Every time the menu bar dropdown opened and closed, the closed dropdown stayed
in memory, about 25 MB each time, and kept updating in the background. After a
few days of normal use the app could reach 600 MB or more and use more CPU than
it should. Closed dropdowns are now released: opening and closing the dropdown
48 times, which used to add over 1 GB, now leaves the app at about 64 MB once
it settles. The problem dates from 1.7.0.

Thanks to [Jonathan Lin](https://github.com/ernsheong) for reporting it in
[#145](https://github.com/Zesty0wl/mac-performance-monitor/issues/145).

See the [changelog](CHANGELOG.md) for the full list.
