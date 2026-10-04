# Mac Performance Monitor 2.3.0

Build 279, 4 October 2026. For Apple silicon Macs running macOS 15 or later.
This update includes changes since 2.2.1, build 261.

[Download the signed installer](https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v2.3.0.279/MacPerformanceMonitor.pkg).
Existing installs can use **Check for Updates** through Sparkle. Homebrew uses
the same installer; its cask update may arrive after this release.

## Ask About This Mac, Rebuilt

On macOS 27, Ask opens with a one-line verdict and a tile for each part of the
Mac: Processor, Memory, Graphics, Neural Engine, Network, Storage, Battery and
Heat, each with a plain status such as Calm, Busy or Worth a look. Tap a tile or
a starter question, or type your own. The app reads its own history, compares
it with what is normal for your Mac and works out which apps are responsible;
Apple's on-device model then explains it in everyday words and suggests one
safe next step. Each answer links to the matching charts in Explorer and shows
the facts behind it. Nothing leaves your Mac, and the conversation is cleared
when Ask closes.

## Hand Off To An AI Agent

For deeper digging, Ask can copy a ready-made prompt for Claude Code, Codex or
another agent, carrying your question and the facts behind its answer, or the
one-line command that connects one. The app now ships `mpm`, a read-only
command-line tool and MCP server, inside the app:

```sh
claude mcp add --scope user mac-performance-monitor -- "/Applications/Mac Performance Monitor.app/Contents/MacOS/mpm" mcp
```

Agents get documented views of your history, the same judged summaries Ask
uses, and links that open the matching charts. The
[AI agents guide](docs/ai-agents.md) covers Claude Code, Codex, Claude Desktop,
Cursor and VS Code, what to ask, and what leaves your Mac: an agent sends what
it reads to its own provider, so Ask explains that before the first copy.

## Temperatures In Your Unit

Every temperature in the app now shows in the unit your Mac is set to in
System Settings > General > Language & Region > Temperature, so Macs set to
Fahrenheit see °F. Settings > General > Temperature can override it. History
is still recorded in Celsius, so switching is instant and loses nothing.
Thanks to [McTTRS](https://github.com/McTTRS) for asking in
[#134](https://github.com/Zesty0wl/mac-performance-monitor/issues/134).

## New Alerts And Insights

- **A program busy for hours is now flagged.** A part of macOS stuck in a loop,
  such as contactsd syncing Contacts all night, used to go unnoticed. Alerts now
  watch each program across its restarts and warn when one keeps about a core
  busy for an hour. It has its own switch in Settings > Alerts.
- **Screen capture slowing the desktop.** Insights flags WindowServer busy with
  most of a core while macOS's screen capture service is busy too, from screen
  sharing, recording or an AI agent watching the screen. Thanks to
  [Giorgio Zamparelli](https://github.com/giorgio-zamparelli) for
  [#131](https://github.com/Zesty0wl/mac-performance-monitor/pull/131).

## Lighter And Faster

- Tabs you have left stop working in the background. On macOS 26 and later,
  every tab visited since the window opened kept updating while hidden, so a
  long session grew slower and used more memory with each tab opened.
- The app launches about a second faster, and the Processes, Hardware and
  Explorer tabs open more quickly.
- The history database is flushed once a minute instead of every 15 seconds,
  writing about a tenth less to disk, and the leak scan takes half the time and
  memory.

## Also Changed

- The Dashboard's right-hand rail shows CPU usage history under the live CPU
  cores grid.
- With one or two charts showing, the Explorer stacks them full width, and a
  lone spike no longer sets a chart's whole axis.
- Ask names the app behind its busiest processes, and the Ask preview's optional
  model downloads and local AI worker are gone; models downloaded by earlier
  versions are deleted to free the space.

## Fixes

- The menu bar item keeps its place after an update
  ([#120](https://github.com/Zesty0wl/mac-performance-monitor/issues/120)). The
  first launch of this version still uses the default spot.
- The menu bar item appears again on macOS 27 when a specific language is
  chosen ([#124](https://github.com/Zesty0wl/mac-performance-monitor/issues/124)).
- The main window can be dragged again on macOS 26 and 27, and can enter full
  screen when it opens while the app runs without a Dock icon.
- Turning Hide Notch off outside the menu now brings the notch back.
- Leak and memory budget alerts no longer flicker in the menu bar.
- The app no longer crashes when a process inspector's Disk I/O charts show a
  process that has just restarted.

See the [changelog](CHANGELOG.md) for the full list.
