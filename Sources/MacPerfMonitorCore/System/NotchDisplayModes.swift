import Foundation

/// One display mode, reduced to what pairing a notched mode with its notch-free
/// twin needs. Mirrors the fields of `CGDisplayMode` so the pairing rule below can
/// be exercised without a display attached.
public struct DisplayModeDescriptor: Sendable, Hashable {
    /// Logical size in points, what the menu bar and windows are laid out in.
    public var width: Int
    public var height: Int
    /// Backing size in pixels. Distinguishes a HiDPI mode from a same-named
    /// low-resolution one, which the pairing must never mix.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double

    public init(
        width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double
    ) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }
}

/// Pairing a notched Mac's display modes with their notch-free twins.
///
/// A notched Mac publishes every scaled size twice: once using the whole panel,
/// where the menu bar straddles the camera housing (1512x982 on a 14-inch), and
/// once excluding the band the housing sits in (1512x945). Selecting the twin is
/// all the "hide the notch" utilities do. The menu bar drops below the housing and
/// runs edge to edge, so the display reads as though the top bezel were simply
/// thicker: it costs the height of the band and gives back its width, which on a
/// 14-inch is 185pt of menu bar that status items could not use before.
///
/// Both modes are ordinary public ones, so `CGDisplaySetDisplayMode` is the whole
/// mechanism. No private API and no entitlement is involved.
///
/// Twins share a logical width, a pixel width and a refresh rate, and differ only
/// in height by that band. Pairing on those facts rather than looking for a 16:10
/// aspect ratio is deliberate: the ratios are not exact at every scaled size
/// (1147x716 comes out at 1.602), and a hard-coded panel geometry would not
/// survive the next model.
public enum NotchDisplayModes {
    /// How short the notch-free twin may be relative to its notched partner. The
    /// camera band is about 3.8% of the panel on current models (945/982 = 0.962).
    /// The window is wide enough to absorb rounding across the scaled sizes and
    /// narrow enough that two unrelated modes which happen to share a width (an
    /// external panel offering both 1920x1080 and 1920x1200) can never pair.
    static let twinHeightRatio: ClosedRange<Double> = 0.93...0.99

    /// Modes that could be `current`'s notch twin: the same mode in every respect
    /// except the height of the camera band.
    private static func twins(
        of current: DisplayModeDescriptor, in modes: [DisplayModeDescriptor]
    ) -> (shorter: [DisplayModeDescriptor], taller: [DisplayModeDescriptor]) {
        var shorter: [DisplayModeDescriptor] = []
        var taller: [DisplayModeDescriptor] = []
        for mode in modes
        where mode.width == current.width
            && mode.pixelWidth == current.pixelWidth
            && abs(mode.refreshRate - current.refreshRate) < 0.5
        {
            if mode.height < current.height,
                ratioInBand(short: mode.height, tall: current.height)
            {
                shorter.append(mode)
            } else if mode.height > current.height,
                ratioInBand(short: current.height, tall: mode.height)
            {
                taller.append(mode)
            }
        }
        return (shorter, taller)
    }

    private static func ratioInBand(short: Int, tall: Int) -> Bool {
        guard tall > 0 else { return false }
        return twinHeightRatio.contains(Double(short) / Double(tall))
    }

    /// The mode that hides the notch: the same scaled size with the camera band
    /// excluded. Nil when `current` already excludes it, or when the display has
    /// no notch at all.
    ///
    /// Where several candidates qualify, the tallest wins, so the switch gives up
    /// as little height as the panel allows.
    public static func notchFreeTwin(
        of current: DisplayModeDescriptor, in modes: [DisplayModeDescriptor]
    ) -> DisplayModeDescriptor? {
        twins(of: current, in: modes).shorter.max { $0.height < $1.height }
    }

    /// The mode that brings the notch back: the same scaled size using the whole
    /// panel. The counterpart of `notchFreeTwin`, so the shortest candidate wins.
    public static func notchedTwin(
        of current: DisplayModeDescriptor, in modes: [DisplayModeDescriptor]
    ) -> DisplayModeDescriptor? {
        twins(of: current, in: modes).taller.min { $0.height < $1.height }
    }

    /// Whether `current` is the notch-free half of a pair, i.e. the menu bar is
    /// already sitting below the camera housing.
    public static func isNotchHidden(
        current: DisplayModeDescriptor, in modes: [DisplayModeDescriptor]
    ) -> Bool {
        let pair = twins(of: current, in: modes)
        return pair.shorter.isEmpty && !pair.taller.isEmpty
    }

    /// Whether this display publishes notch pairs at all, which is what makes it a
    /// notched Mac. Checked against the whole mode list rather than the current
    /// mode, so the answer holds while the notch is hidden as well as while it is
    /// showing.
    public static func hasNotchPair(in modes: [DisplayModeDescriptor]) -> Bool {
        modes.contains { notchFreeTwin(of: $0, in: modes) != nil }
    }
}
