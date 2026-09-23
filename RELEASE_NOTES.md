# Mac Performance Monitor 2.2.1

Build 261, 23 September 2026. For Apple silicon Macs running macOS 15 or later.
This update includes changes since 2.2.0, build 260.

[Download the signed installer](https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v2.2.1.261/MacPerformanceMonitor.pkg).
Existing installs can use **Check for Updates** through Sparkle. Homebrew uses
the same installer; its cask update may arrive after this release.

## Liquid Glass Is Back

On macOS 26 and 27, version 2.2.0 showed the older, pre-Liquid Glass look.
Thanks to [Frank Yang](https://github.com/FrankYang0610) for reporting it in
[#117](https://github.com/Zesty0wl/mac-performance-monitor/issues/117).

The cause was a bug in our build script, not in the app itself. 2.2.0 was our
first release built with Xcode 27. Its default Swift build engine recorded the
macOS 15 deployment target as the SDK the app was built with. macOS uses that
value to decide whether an app gets the current design, so it gave 2.2.0 the
compatibility appearance.

The build now records the real SDK, and packaging refuses any app binary that
reports an SDK older than 26. Mac Performance Monitor still supports macOS 15.

## Startup

**Start minimised** is a new setting in Settings > General > Startup, on by
default. With the menu bar on, the app starts without opening its main window,
including at login. Turn it off to show the window at startup. The window always
opens at startup if the menu bar is off, and first-run setup still appears.

The main window no longer restores itself at startup from macOS launch data;
the saved startup setting decides. A pinned Dock icon no longer takes focus
when no window is open.

## GitHub Star Request

After at least seven days, and once you have used both a menu bar panel and the
main window, the app asks once whether you would like to star it on GitHub. It
waits until the main window is in front with no other prompt showing. Either
answer stops future requests. The usage flags it checks stay on your Mac.

## Further Reading

- [Full changelog](https://github.com/Zesty0wl/mac-performance-monitor/blob/v2.2.1.261/CHANGELOG.md).

- [2.2.0 release notes](https://github.com/Zesty0wl/mac-performance-monitor/releases/tag/v2.2.0.260),
  including the Ask preview, GPU bandwidth history, and known limits.

- [Security policy](https://github.com/Zesty0wl/mac-performance-monitor/blob/v2.2.1.261/SECURITY.md).
