// SPDX-License-Identifier: MIT
import AppKit
import MacPerfMonitorCore
import SwiftUI

/// Which text the Dock tile draws above its trend. Each part has its own
/// switch, so a tile can keep just the colored ↓ and ↑ arrows, just the
/// numbers, both, or neither (the trend then fills the tile).
struct DockTileText: Equatable {
    var label: Bool
    var value: Bool

    static let all = DockTileText(label: true, value: true)
    static let none = DockTileText(label: false, value: false)

    static let labelKey = "dockTileShowsLabel"
    static let valueKey = "dockTileShowsValue"

    /// Both parts are on unless turned off.
    static func current(_ defaults: UserDefaults = .standard) -> DockTileText {
        DockTileText(
            label: defaults.object(forKey: labelKey) as? Bool ?? true,
            value: defaults.object(forKey: valueKey) as? Bool ?? true)
    }
}

/// Everything the Dock tile draws, already resolved from the samples.
struct DockTileContent: Equatable {
    struct Line: Equatable {
        var values: [Double?]
        var color: NSColor
    }

    struct Caption: Equatable {
        var text: String
        var color: NSColor
        /// Point size on the 128 point canvas, before any shrinking to fit.
        var size: CGFloat = labelSize
    }

    static let labelSize: CGFloat = 14
    static let valueSize: CGFloat = 21
    static let rateSize: CGFloat = 16

    /// Top left and top right of the tile. With neither, the trend fills it.
    var leading: Caption?
    var trailing: Caption?
    var lines: [Line]
    /// The value at the top of the plot. The bottom is zero.
    var top: Double

    /// Labels on their own are centred in a shorter row, giving the trend
    /// more height; a value, alone or with its label, uses the full row.
    var centersCaptions = false

    var hasCaptions: Bool { leading != nil || trailing != nil }

    static let captionColor = NSColor.white.withAlphaComponent(0.72)
    static let valueColor = NSColor.white

    /// Smallest rate scale, so an idle link or disk does not fill the tile
    /// with noise.
    static let rateFloor: Double = 64 * 1024
    /// Smallest power scale, in watts, so an idle Mac's draw is not magnified.
    static let powerFloor: Double = 10

    /// The top of a rate scale (network, disk; power uses the same fit). It
    /// fits a smoothed copy of the lines, not their highest point, so one
    /// brief burst does not flatten everything else along the bottom. The
    /// drawn line is not smoothed, so a burst still shows: it runs flat along
    /// the top of the plot where it passes the scale. The percentage metrics
    /// keep their fixed 0 to 100 scale and never come through here.
    static func rateTop(_ channels: [[Double?]], range: DockTileRange) -> Double {
        let window = smoothingWindow(for: range)
        let peak = channels.map { smoothedPeak($0, window: window) }.max() ?? 0
        return max(LiveChartGeometry.binaryNiceCeiling(peak * 1.1), rateFloor)
    }

    /// Slots in the averaging window: at least five seconds, so a burst of a
    /// second or two never sets the scale, and a sixtieth of longer ranges.
    static func smoothingWindow(for range: DockTileRange) -> Int {
        let seconds = max(5, range.seconds / 60)
        return max(1, Int((seconds / DockTileBuckets.width(for: range)).rounded()))
    }

    /// The highest point of a trailing average over `window` slots. Empty
    /// slots are skipped, and a gap the renderer would draw restarts the
    /// average, so it never reaches across one.
    static func smoothedPeak(_ values: [Double?], window: Int) -> Double {
        var recent: [Double] = []
        var sum = 0.0
        var missing = 0
        var peak = 0.0
        for value in values {
            guard let value, value.isFinite else {
                missing += 1
                if missing > DockTileBuckets.bridgedGap {
                    recent.removeAll()
                    sum = 0
                }
                continue
            }
            missing = 0
            recent.append(value)
            sum += value
            if recent.count > window { sum -= recent.removeFirst() }
            peak = max(peak, sum / Double(recent.count))
        }
        return peak
    }

    /// The mark and color of each line of a two-line metric, in the order
    /// download then upload, or read then write.
    @MainActor
    static func pairStyle(
        _ metric: DockTileMetric
    ) -> (
        first: (mark: String, color: NSColor), second: (mark: String, color: NSColor)
    ) {
        if metric == .disk {
            return (("R", NSColor(DiskStyle.read)), ("W", NSColor(DiskStyle.write)))
        }
        return (("↓", NSColor(NetworkStyle.download)), ("↑", NSColor(NetworkStyle.upload)))
    }

    /// The caption row for `metric`. `latest` is the newest value of each line:
    /// one for CPU and memory, download then upload for the network.
    @MainActor
    static func captions(
        metric: DockTileMetric, latest: [Double?], text: DockTileText
    ) -> (leading: Caption?, trailing: Caption?) {
        switch metric {
        case .appIcon:
            return (nil, nil)
        case .load, .cpu, .memory, .gpu, .energy:
            let value = latest.first ?? nil
            return (
                text.label ? Caption(text: label(metric), color: captionColor) : nil,
                text.value
                    ? value.map {
                        Caption(text: format($0, for: metric), color: valueColor, size: valueSize)
                    } : nil
            )
        case .network, .disk:
            // The direction marks are the label: ↓ and ↑ for the network, R and
            // W for the disk, so the two read apart without a name. With the
            // label off the numbers keep their colors to say which is which.
            func caption(_ mark: String, _ value: Double?, _ color: NSColor) -> Caption? {
                // A thin space keeps a letter mark off its number ("R 12M");
                // an arrow reads fine touching it.
                let spaced = mark.first?.isLetter == true && text.value ? mark + "\u{2009}" : mark
                let parts =
                    (text.label ? spaced : "")
                    + (text.value ? (value.map(ByteFormat.rateCompact) ?? "--") : "")
                return parts.isEmpty ? nil : Caption(text: parts, color: color, size: rateSize)
            }
            let style = pairStyle(metric)
            return (
                caption(style.first.mark, latest.first ?? nil, style.first.color),
                caption(style.second.mark, latest.count > 1 ? latest[1] : nil, style.second.color)
            )
        }
    }

    /// The samples a trend over `range` can use, oldest first: walked back
    /// from the newest so a short range does not copy the whole history.
    static func recent<History: BidirectionalCollection>(
        _ history: History, now: Date, range: DockTileRange,
        date: (History.Element) -> Date
    ) -> [History.Element] {
        let start = now.addingTimeInterval(-range.seconds - DockTileBuckets.width(for: range))
        var samples: [History.Element] = []
        for sample in history.reversed() {
            if date(sample) < start { break }
            samples.append(sample)
        }
        return samples.reversed()
    }

    static func recent<History: BidirectionalCollection>(
        _ history: History, now: Date, range: DockTileRange
    ) -> [SystemSample] where History.Element == SystemSample {
        recent(history, now: now, range: range, date: \.timestamp)
    }

    @MainActor
    static func make(
        metric: DockTileMetric, samples: [SystemSample], now: Date, range: DockTileRange,
        text: DockTileText = .all
    ) -> DockTileContent? {
        guard let trend = trend(metric: metric, samples: samples, now: now, range: range)
        else { return nil }
        // Newest value of each line, in the order `captions` expects.
        let ordered = trend.lines.count > 1 ? trend.lines.reversed() : trend.lines
        let latest = ordered.map { line in line.values.last { $0 != nil } ?? nil }
        let captions = captions(metric: metric, latest: latest, text: text)
        return DockTileContent(
            leading: captions.leading, trailing: captions.trailing, lines: trend.lines,
            top: trend.top, centersCaptions: text.label && !text.value)
    }

    /// One averaged line of `value`. A sample where `value` is nil (a tick
    /// that did not read the GPU, a missed power read) is left out rather
    /// than counted as zero.
    private static func series(
        _ samples: [SystemSample], now: Date, range: DockTileRange,
        _ value: (SystemSample) -> Double?
    ) -> [Double?] {
        DockTileBuckets.average(
            samples.compactMap { sample in value(sample).map { (sample.timestamp, [$0]) } },
            channels: 1, now: now, range: range)[0]
    }

    /// A one-line trend colored by the level its newest value reaches, as a
    /// fraction of `top`.
    private static func levelLine(_ values: [Double?], top: Double) -> [Line] {
        let latest = values.last { $0 != nil } ?? nil
        return [Line(values: values, color: NSColor(CPULevel(fraction: (latest ?? 0) / top).color))]
    }

    @MainActor
    private static func trend(
        metric: DockTileMetric, samples: [SystemSample], now: Date, range: DockTileRange
    ) -> (lines: [Line], top: Double)? {
        switch metric {
        case .appIcon:
            return nil
        case .cpu:
            return (
                levelLine(series(samples, now: now, range: range) { $0.cpuLoad * 100 }, top: 100),
                100
            )
        case .memory:
            let values = series(samples, now: now, range: range) { $0.pressurePercent }
            // The level of the newest sample the line shows, not of one in the
            // slot still filling.
            let width = DockTileBuckets.width(for: range)
            let current = DockTileBuckets.index(of: now, width: width)
            let level =
                samples.last { DockTileBuckets.index(of: $0.timestamp, width: width) < current }?
                .pressureLevel ?? .normal
            return ([Line(values: values, color: NSColor(level.color))], 100)
        case .load:
            // Scaled against the core count: the top of the tile is every core
            // busy, so the height means the same thing on every Mac.
            let top = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
            return (
                levelLine(series(samples, now: now, range: range) { $0.loadAverage1 }, top: top),
                top
            )
        case .gpu:
            return (
                levelLine(series(samples, now: now, range: range) { $0.gpuUtilization }, top: 100),
                100
            )
        case .energy:
            // Whole-machine draw, on laptops and desktops alike. A zero is a
            // missed read, not a Mac drawing nothing.
            let values = series(samples, now: now, range: range) {
                $0.batterySystemPowerWatts > 0 ? $0.batterySystemPowerWatts : nil
            }
            let peak = smoothedPeak(values, window: smoothingWindow(for: range))
            let top = max(LiveChartGeometry.niceCeiling(peak * 1.1), powerFloor)
            return ([Line(values: values, color: NSColor(BatteryStyle.consumer))], top)
        case .network, .disk:
            let channels = DockTileBuckets.average(
                samples.map {
                    metric == .network
                        ? ($0.timestamp, [$0.networkInBytesPerSec, $0.networkOutBytesPerSec])
                        : ($0.timestamp, [$0.diskReadBytesPerSec, $0.diskWriteBytesPerSec])
                }, channels: 2, now: now, range: range)
            let style = pairStyle(metric)
            // The second line first, so the first (download, read) draws on top.
            let lines = [
                Line(values: channels[1], color: style.second.color),
                Line(values: channels[0], color: style.first.color),
            ]
            return (lines, rateTop(channels, range: range))
        }
    }

    /// The short name a one-line metric shows top left. These are drawn into
    /// the icon as abbreviations, like the menu bar's read-out captions
    /// (`MenuBarMetric.shortTitle`), and are not translated.
    static func label(_ metric: DockTileMetric) -> String {
        switch metric {
        case .load: return "LOAD"
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .gpu: return "GPU"
        case .energy: return "PWR"
        case .appIcon, .network, .disk: return ""
        }
    }

    /// The current value as the caption shows it.
    static func format(_ value: Double, for metric: DockTileMetric) -> String {
        switch metric {
        case .load: return String(format: "%.1f", locale: .current, value)
        case .energy: return "\(Int(value.rounded()))W"
        default: return "\(Int(value.rounded()))%"
        }
    }
}
