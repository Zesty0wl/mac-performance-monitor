import Foundation

/// Pure cadence calculations for the live sampler and its gated UI work.
public enum LiveRefreshCadence {
    public static let fastestInterval: TimeInterval = 0.25
    public static let normalBaseInterval: TimeInterval = 1
    public static let minimumProcessInterval: TimeInterval = 1
    /// The full per-process calculation (the scan, the re-sort, the table and
    /// alert publish) runs no more often than this while a window shows
    /// processes; the rows on screen are re-read at the dial rate in between.
    /// History logging keeps its own cadence.
    public static let fullProcessInterval: TimeInterval = 5

    /// The sampler runs faster than 1 Hz only when the selected UI refresh needs
    /// it. Slower selections keep the established 1 Hz system heartbeat.
    public static func baseInterval(for refreshInterval: TimeInterval) -> TimeInterval {
        min(normalBaseInterval, max(fastestInterval, refreshInterval))
    }

    /// Process enumeration and broad UI publication never run above 1 Hz. The
    /// selected subsecond interval remains available to lightweight system charts.
    public static func processInterval(for refreshInterval: TimeInterval) -> TimeInterval {
        max(fullProcessInterval, refreshInterval)
    }

    /// Number of base ticks needed to reach a gated cadence.
    public static func tickCount(
        for cadence: TimeInterval, baseInterval: TimeInterval
    ) -> Int {
        guard cadence > 0, baseInterval > 0 else { return 1 }
        return max(1, Int((cadence / baseInterval).rounded()))
    }
}
