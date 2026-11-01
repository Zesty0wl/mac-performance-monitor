# Mac Performance Monitor 2.6.0

Build 305, 1 November 2026. For Apple silicon Macs running macOS 15 or later.
This update includes changes since 2.5.0, build 297.

[Download the signed installer](https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v2.6.0.305/MacPerformanceMonitor.pkg).
Existing installs can use **Check for Updates** through Sparkle. Homebrew uses
the same installer; its cask update may arrive after this release.

## Memory Per App

The Processes tab has a new **Apps** layout: one row per app, with its memory,
CPU, threads and open files added up across every process working for it, and
those processes listed beneath. That includes the helpers macOS starts on an
app's behalf, such as Safari's and Mail's web content processes, which the
Hierarchy view could not connect to their app. Select an app to see its totals
and its processes, largest first.

Right-click an app row to quit it, reveal it in Finder, or add its processes to
the Explorer. Switch between Processes, Apps and Hierarchy with the new layout
picker; your choice is remembered.

## Security Hardening

An October security review led to these changes. None was known to be
exploited.

- The privileged helper now checks who is asking. On a shared Mac, a standard
  user can force quit or inspect only their own processes; administrators can
  still act on any process.
- Force quit checks the process's start time, so it cannot stop a different
  process that reused the same ID.
- macOS only starts the helper if it carries our signature.
- Process names and paths are always shown as plain text, odd app bundles can
  no longer stall the window, and the uninstaller only runs a copy signed by us.

## Steadier Disk Page

The drive cards on the Disk page no longer jump as readings change, and two
drives in a wide window each take half of the Drives panel.

See the [changelog](CHANGELOG.md) for the full list.
