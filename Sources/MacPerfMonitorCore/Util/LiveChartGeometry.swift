import Foundation

/// Pure geometry shared by live chart renderers.
public enum LiveChartGeometry {
    /// A fixed-width trailing window ending at the newest recorded sample.
    public static func trailingDomain(
        latest: Date?, span: TimeInterval
    ) -> ClosedRange<Date>? {
        guard let latest, span > 0 else { return nil }
        return latest.addingTimeInterval(-span)...latest
    }

    /// Horizontal position of a timestamp in a fixed time domain. Values outside
    /// 0...1 are preserved so renderers can clip lines cleanly at plot edges.
    public static func normalizedX(
        _ date: Date, in domain: ClosedRange<Date>
    ) -> Double {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return 0 }
        return date.timeIntervalSince(domain.lowerBound) / span
    }

    /// Vertical position in a fixed value domain, clamped to the plot. Keeping
    /// the domain unchanged means a new extreme cannot move existing values.
    public static func normalizedY(
        _ value: Double, in domain: ClosedRange<Double>
    ) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0.5 }
        return min(1, max(0, (value - domain.lowerBound) / span))
    }

    /// The smallest "nice" value at or above `value`: 1, 1.2, 1.5, 2, 2.5, 3,
    /// 4, 5, 6, 8 or 10 times a power of ten. An auto-scaled axis that snaps its
    /// top to this ladder moves only when the data crosses a rung, so its
    /// gridlines and labels hold still between ticks instead of being re-laid
    /// out for every new peak, while the line still fills at least about 75%
    /// of the plot. Non-positive or non-finite input yields 1.
    ///
    /// `quarterSteps` keeps only tops that split into four round steps
    /// (dropping 1.5, 2.5 and 5): Fahrenheit temperatures land on 150 and 250,
    /// whose quarters (37.5, 62.5) would label the axis 113° and 188°.
    public static func niceCeiling(_ value: Double, quarterSteps: Bool = false) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let fraction = value / base
        let ladder: [Double] =
            quarterSteps
            ? [1, 1.2, 2, 3, 4, 6, 8, 10] : [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        let rung = ladder.first { $0 >= fraction - 1e-9 } ?? 10
        return rung * base
    }

    /// `niceCeiling` for a byte axis, in the 1024-based units `ByteFormat`
    /// labels with, so the quarter gridlines read 100, 200, 300, 400 MB/s
    /// rather than the 95.4, 190.7, 286.1, 381.5 MB/s a decimal ceiling of
    /// 400,000,000 gives. Just past a unit boundary the steps are taken in
    /// the smaller unit, so 1.1 GB rounds to 1200 MB (300, 600, 900 MB) and
    /// not to 1.2 GB, whose quarters read 307.2, 614.4 and 921.6 MB.
    public static func binaryNiceCeiling(_ bytes: Double) -> Double {
        guard bytes > 0, bytes.isFinite else { return 1 }
        var unit = 1.0
        while bytes / unit >= 1024 { unit *= 1024 }
        if unit > 1, bytes / unit < 4 { unit /= 1024 }
        let value = bytes / unit
        let base = pow(10, floor(log10(value)))
        let rung = binaryLadder.first { $0 >= value / base - 1e-9 } ?? 10
        return rung * base * unit
    }

    /// Axis tops whose quarters are all round (1.6 gives 0.4, 0.8, 1.2), with
    /// rungs close enough together that a steady 85 MB/s fills half the plot.
    private static let binaryLadder: [Double] = [1, 1.2, 1.6, 2, 2.4, 3, 4, 5, 6, 8, 10]

    /// An auto-scaled axis top that a few isolated spikes cannot own.
    public struct OutlierFit: Equatable {
        /// The axis top to draw with.
        public var ceiling: Double
        /// The axis top that clears every sample, as `niceCeiling` would give.
        public var fullCeiling: Double
        /// The tallest sample left above `ceiling`, when the fit clipped one.
        public var outlierPeak: Double?
    }

    /// Normally the axis clears the tallest of `peaks` (each sample's highest
    /// value, its band top where it has one). When no more than one positive
    /// sample in a hundred (at least one) rises far above the rest, the axis
    /// fits the rest instead, so a single 350% burst no longer flattens an hour
    /// of 40% into the floor. The fit must at least halve the axis to be worth
    /// the clipping, and it never drops below a quarter of the outlier, so the
    /// noise under a spike is not blown up into a mountain range. Fewer than
    /// twenty positive samples are too few to call any of them an outlier.
    public static func outlierCeiling(
        peaks: [Double], headroom: Double = 1.1, minimum: Double = 1
    ) -> OutlierFit {
        let positive = peaks.filter { $0.isFinite && $0 > 0 }.sorted(by: >)
        let full = niceCeiling(max((positive.first ?? 0) * headroom, minimum))
        let unfitted = OutlierFit(ceiling: full, fullCeiling: full, outlierPeak: nil)
        let allowed = max(1, positive.count / 100)
        guard positive.count >= 20, let peak = positive.first else { return unfitted }
        let fitted = niceCeiling(max(positive[allowed] * headroom, peak / 4, minimum))
        guard fitted <= full / 2 else { return unfitted }
        return OutlierFit(ceiling: fitted, fullCeiling: full, outlierPeak: peak)
    }

    /// Horizontal position for a value-only live ring. The newest sample is at
    /// 1, and each retained interval occupies exactly 1 / capacity of the plot.
    public static func normalizedSlot(
        index: Int, count: Int, capacity: Int
    ) -> Double {
        precondition(capacity > 0)
        precondition(count > 0 && index >= 0 && index < count)
        let resolvedCapacity = max(capacity, count)
        let slot = resolvedCapacity - count + index + 1
        return Double(slot) / Double(resolvedCapacity)
    }
}
