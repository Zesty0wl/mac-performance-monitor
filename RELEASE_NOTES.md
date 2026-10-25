# Mac Performance Monitor 2.5.0

Build 297, 25 October 2026. For Apple silicon Macs running macOS 15 or later.
This update includes changes since 2.4.0, build 289.

[Download the signed installer](https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v2.5.0.297/MacPerformanceMonitor.pkg).
Existing installs can use **Check for Updates** through Sparkle. Homebrew uses
the same installer; its cask update may arrive after this release.

## USB-C Port Diagnostics

The Hardware tab has a new **Ports** section listing every USB-C, MagSafe,
HDMI and SD port. For each one it shows what is plugged in and the link it
negotiated, the charger's power options and what the Mac is drawing, the
cable's rating from its e-marker chip, and the USB devices behind it, nested
by hub.

Plain-language findings flag problems such as an overcurrent event, liquid in
the port, a USB 2-only cable on a fast port, a 3 A cable capping charging at
60 W, a slow charger, or a USB 3 device running at USB 2 speed. The page
updates about a second after something is plugged in or removed, and needs no
administrator rights.

## The Disk Page Leads With Your Drives

A new Drives panel puts a card for each internal and external drive at the
top, with its free space, capacity bar, connection, SMART status and live
reads and writes. USB drives show the USB version and speed they connected at
and the port they are plugged into; click the port to jump to Hardware > Ports.
System containers and disk images are folded away so they no longer bury the
volumes you use.

## Where Your Power Comes From

On a laptop, the energy menu now shows a stacked chart of power from the
adapter, power from the battery, and power going into the battery while it
charges. The header says what the battery is doing: time left, time to full or
to its charge limit, **Charging on hold** with the reason, or **Not charging**.

## Bigger Explorer Charts

Explorer charts now share the window instead of sitting at a fixed height, so
three or four charts fill the view. The chart layout button is a menu: keep
**Fit to window**, or pick 1, 2, 4, 6 or 9 charts per screen.

See the [changelog](CHANGELOG.md) for the full list.
