# Mac Performance Monitor 2.8.0

Build 315, 15 November 2026. For Apple silicon Macs running macOS 15 or later.
This update includes changes since 2.7.0, build 312.

[Download the signed installer](https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v2.8.0.315/MacPerformanceMonitor.pkg).
Existing installs can use **Check for Updates** through Sparkle. Homebrew uses
the same installer; its cask update may arrive after this release.

## Tell One Python From Another

Interpreters now show what they are running next to their name:
`python3 · train.py`, `python3 · http.server`, `node · tsc`. Launchers are
named by what they were asked to run (`uv · train.py`, `npm · dev`,
`cargo · server`), pool workers by the script that started them
(`Python · train.py (worker)`), and gunicorn or celery by the title they chose.
The label appears wherever a process is named and is kept in history. Groups
can match it with a new **Script or tool** rule, and the process details have a
**Command line** row with a Copy button. Only the short label is stored, never
the full command line. Contributed by @georgeharker.

## Control and Inspect Processes

Right-click a process for:

- **Quit**, **Suspend** and **Resume**, five **Priority** levels, and **Force
  Quit Process Tree**, which stops a process and everything it started.
- **Threads:** every thread with its CPU now, total CPU time, state and
  priority, refreshed every two seconds.

The Processes tab can also:

- **Find Open File or Port** (Shift-Command-F): which process holds a file,
  a disk you cannot eject, or port 8080. It can include loaded libraries.
- **Click a window to find its process:** the target button beside the filter
  selects whichever process owns the window you click.
- Show what **started** a process (a launchd job, an app's XPC service, or its
  parent), its working directory, TCP connection states, entitlements and
  SHA-256.
- Tint new processes green and keep exited ones, labelled **Exited**, for a
  few seconds. Type the first letters of a name to jump to it.

## Low Disk Space

A new **Low disk space** alert tells you when the startup disk has less than
10% left, and again below 5%. It counts the space macOS can free on its own,
as Finder does. It is on by default; choose 5% to 25% in Settings > Alerts.
Add **Free Space** to the menu bar to keep an eye on what is left, on the
startup disk and any other drives you connect.

## Fixes

- The Disk page's Throughput chart fits its axis to the average line, so a
  steady copy is no longer squashed by a brief burst, and its steps are round
  numbers. The IOPS card's peak is no longer shown as a percentage.
- The main window fits smaller screens in every language
  ([#188](https://github.com/Zesty0wl/mac-performance-monitor/issues/188)).
- The main window keeps the tab you chose after switching Spaces or minimizing
  it ([#189](https://github.com/Zesty0wl/mac-performance-monitor/issues/189)).

See the [changelog](CHANGELOG.md) for the full list.
