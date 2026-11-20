// SPDX-License-Identifier: MIT
import AppKit
import MacPerfMonitorCore
import SwiftUI

/// What the Dock icon shows: the app's own icon, or a live trend of one metric.
enum DockTileMetric: String, CaseIterable, Identifiable {
    case appIcon
    case load
    case cpu
    case memory
    case gpu
    case energy
    case network
    case disk

    static let defaultsKey = "dockTileMetric"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appIcon: return t("Application Icon")
        case .load: return t("Load Average")
        case .cpu: return "CPU"
        case .memory: return t("Memory Pressure")
        case .gpu: return "GPU"
        case .energy: return t("Power Draw")
        case .network: return t("Network")
        case .disk: return t("Disk")
        }
    }

    var symbolName: String {
        switch self {
        case .appIcon: return "app"
        case .load: return "gauge.with.dots.needle.67percent"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "display"
        case .energy: return "bolt.fill"
        case .network: return "network"
        case .disk: return "internaldrive"
        }
    }

    var showsTrend: Bool { self != .appIcon }

    static func current(_ defaults: UserDefaults = .standard) -> DockTileMetric {
        defaults.string(forKey: defaultsKey).flatMap(DockTileMetric.init(rawValue:)) ?? .appIcon
    }
}

/// How much history the Dock trend spans.
enum DockTileRange: Int, CaseIterable, Identifiable {
    case two = 2
    case five = 5
    case ten = 10
    case fifteen = 15

    static let defaultsKey = "dockTileRangeMinutes"

    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    var title: String { t("%lld min", rawValue) }

    static func current(_ defaults: UserDefaults = .standard) -> DockTileRange {
        DockTileRange(rawValue: defaults.integer(forKey: defaultsKey)) ?? .five
    }
}

/// How big the Dock trend draws. Standard keeps the margin every app icon
/// has, so the tile sits in line with its neighbours; Large trades some of that
/// margin for a bigger plate and text that reads at a small Dock size.
enum DockTileSize: String, CaseIterable, Identifiable {
    case standard
    case large

    static let defaultsKey = "dockTileSize"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return t("Standard")
        case .large: return t("Large")
        }
    }

    /// The plate's frame on the 128 point canvas. Standard follows Apple's
    /// icon grid, an 824 unit body on a 1024 unit canvas.
    var plate: CGRect {
        switch self {
        case .standard: return CGRect(x: 12.5, y: 11.5, width: 103, height: 103)
        case .large: return CGRect(x: 6, y: 5, width: 116, height: 116)
        }
    }

    var cornerRadius: CGFloat { self == .standard ? 23 : 26 }
    /// Text size relative to Standard.
    var textScale: CGFloat { self == .standard ? 1 : 1.5 }
    /// Caption margin from the plate's sides.
    var inset: CGFloat { self == .standard ? 11 : 9 }

    /// Large reads better at the sizes the Dock usually draws, so it is the
    /// default.
    static func current(_ defaults: UserDefaults = .standard) -> DockTileSize {
        defaults.string(forKey: defaultsKey).flatMap(DockTileSize.init) ?? .large
    }
}

/// When the app keeps its Dock icon with no window open.
enum DockPresenceMode: String, CaseIterable, Identifiable {
    /// The icon comes and goes with the windows.
    case withWindows
    /// Always in the Dock while the app runs.
    case always
    /// In the Dock while it shows a metric trend, otherwise with the windows.
    case whileShowingTrend

    static let defaultsKey = "dockPresenceMode"
    /// The switch older versions read: on exactly when the mode is `always`.
    static let legacyPinKey = "showDockIcon"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .withWindows: return t("While a window is open")
        case .always: return t("Always")
        case .whileShowingTrend: return t("While showing a trend")
        }
    }

    /// The saved mode. Before the mode existed there was one switch,
    /// `showDockIcon`, whose on state is `always`; with no mode saved yet,
    /// that switch decides.
    static func current(_ defaults: UserDefaults = .standard) -> DockPresenceMode {
        if let saved = defaults.string(forKey: defaultsKey).flatMap(DockPresenceMode.init) {
            return saved
        }
        return defaults.bool(forKey: legacyPinKey) ? .always : .withWindows
    }

    /// Bring the mode and the old switch into step at launch.
    ///
    /// The mode is the setting; `showDockIcon` is kept as its mirror (on for
    /// `always`), so an older version, which reads only the switch, still
    /// does the right thing. If the two disagree at launch, something other
    /// than this version changed the switch (an older version after a
    /// downgrade, an imported preferences file, `defaults write`), so the
    /// switch wins: on means `always`, and off ends `always` but leaves
    /// `whileShowingTrend` alone, since an older version has no trends.
    static func reconcile(_ defaults: UserDefaults = .standard) {
        var mode = current(defaults)
        if let pinned = defaults.object(forKey: legacyPinKey) as? Bool,
            pinned != (mode == .always)
        {
            mode = pinned ? .always : (mode == .always ? .withWindows : mode)
        }
        defaults.set(mode.rawValue, forKey: defaultsKey)
        mirror(defaults)
    }

    /// Keep `showDockIcon` matching the mode. Called whenever the mode may
    /// have changed; it writes only when the switch is out of step.
    static func mirror(_ defaults: UserDefaults = .standard) {
        let pinned = current(defaults) == .always
        if defaults.object(forKey: legacyPinKey) as? Bool != pinned {
            defaults.set(pinned, forKey: legacyPinKey)
        }
    }

    /// Whether the app stays in the Dock with no window open.
    func keepsIcon(showing metric: DockTileMetric) -> Bool {
        switch self {
        case .withWindows: return false
        case .always: return true
        case .whileShowingTrend: return metric.showsTrend
        }
    }
}

// MARK: - Buckets

/// Averages samples into fixed time slots for the Dock trend.
///
/// Slots are aligned to absolute time, not to the moment of drawing, so a
/// slot's average never changes once the slot has ended. The trend only shows
/// completed slots, which means it has to be redrawn only when a new slot
/// completes: about every second on a two-minute range and every few seconds on
/// fifteen minutes, rather than on every sample.
enum DockTileBuckets {
    /// The most points the trend draws. Roughly one per pixel column at the
    /// Dock's largest size, so a longer range does not cost more to draw.
    static let maximumCount = 256
    /// The sampler's heartbeat. Slots shorter than this would mostly be empty.
    static let sampleInterval: TimeInterval = 1
    /// Empty slots joined over rather than drawn as a gap. Sampler jitter can
    /// leave a one-second slot empty, and that is not a hole in the history.
    static let bridgedGap = 3

    static func count(for range: DockTileRange) -> Int {
        min(maximumCount, Int(range.seconds / sampleInterval))
    }

    static func width(for range: DockTileRange) -> TimeInterval {
        range.seconds / TimeInterval(count(for: range))
    }

    /// The slot `date` falls in.
    static func index(of date: Date, width: TimeInterval) -> Int {
        Int(floor(date.timeIntervalSince1970 / width))
    }

    /// When the slot holding `now` ends, which is when the trend next changes.
    static func nextBoundary(after now: Date, range: DockTileRange) -> Date {
        let width = width(for: range)
        return Date(
            timeIntervalSince1970: TimeInterval(index(of: now, width: width) + 1) * width)
    }

    /// The mean of each channel in each completed slot of `range` before the
    /// slot holding `now`, oldest first. A slot with no samples is nil, so a
    /// gap in the history draws as a gap. A non-finite value is left out of
    /// its channel's mean rather than counted as zero.
    static func average(
        _ samples: [(date: Date, values: [Double])], channels: Int, now: Date,
        range: DockTileRange
    ) -> [[Double?]] {
        let count = count(for: range)
        let width = width(for: range)
        let first = index(of: now, width: width) - count
        var sums = Array(repeating: Array(repeating: 0.0, count: count), count: channels)
        var counts = Array(repeating: Array(repeating: 0, count: count), count: channels)
        for sample in samples {
            let slot = index(of: sample.date, width: width) - first
            guard slot >= 0, slot < count else { continue }
            for channel in 0..<min(channels, sample.values.count) {
                let value = sample.values[channel]
                guard value.isFinite else { continue }
                sums[channel][slot] += value
                counts[channel][slot] += 1
            }
        }
        return (0..<channels).map { channel in
            (0..<count).map { slot in
                let samples = counts[channel][slot]
                return samples > 0 ? sums[channel][slot] / Double(samples) : nil
            }
        }
    }
}
