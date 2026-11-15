# Mac Performance Monitor 2.8.1

Build 316, 15 November 2026. For Apple silicon Macs running macOS 15 or later.
This update includes changes since 2.8.0, build 315.

[Download the signed installer](https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v2.8.1.316/MacPerformanceMonitor.pkg).
Existing installs can use **Check for Updates** through Sparkle. Homebrew uses
the same installer; its cask update may arrive after this release.

## Recent History Is Kept at the Size Limit

Once the history database reached its size limit (1 GB unless you changed it
in Settings > Storage), the 5 minute, 30 minute and 1 hour ranges lost their
history every minute and only ever showed the last minute or so, while 6 hours
and longer looked complete. The limit deleted the most detailed samples first,
including the most recent ones.

It now drops the oldest data first: detailed samples older than an hour, then
minute averages older than a day, then hourly ones older than a week. Only if
that is not enough does it cut into recent history, and the newest detail is
the last to go. After updating, the short ranges fill back up within the hour.

## Also

- A process started without arguments, such as the XPC services macOS starts
  for Metal, now shows "No arguments" in its Command line row instead of
  repeating its path.

For everything new in 2.8, including interpreter labels, process controls and
the low disk space alert, see the
[2.8.0 notes](https://github.com/Zesty0wl/mac-performance-monitor/blob/v2.8.0.315/RELEASE_NOTES.md)
and the [changelog](CHANGELOG.md).
