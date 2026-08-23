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
    public static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let fraction = value / base
        let ladder: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        let rung = ladder.first { $0 >= fraction - 1e-9 } ?? 10
        return rung * base
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
