import Foundation

/// One GPU performance (clock) state and the share of an interval the GPU
/// spent in it.
public struct GPUPerformanceState: Sendable, Codable, Equatable {
    public var name: String
    /// 0...100.
    public var residency: Double

    public init(name: String, residency: Double) {
        self.name = name
        self.residency = residency
    }
}

public struct GPUBandwidthHistogram: Sendable, Codable, Equatable {
    public struct Bin: Sendable, Codable, Equatable {
        public let label: String
        public let events: Int64
    }

    public struct AverageEstimate: Sendable, Equatable {
        public let gigabytesPerSecond: Double
        public let onlyLowestBin: Bool
        public let includesHighestBin: Bool
    }

    public let bins: [Bin]
    public let totalEvents: Int64

    public init?(labels: [String], counts: [Int64]) {
        guard !labels.isEmpty, labels.count <= 128, labels.count == counts.count else { return nil }
        let labels = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(labels).count == labels.count else { return nil }
        var total: Int64 = 0
        var previousRate: Double = 0
        for (label, count) in zip(labels, counts) {
            guard label.count <= 32, label.hasSuffix("GB/s"), count >= 0,
                let rate = Double(label.dropLast(4).trimmingCharacters(in: .whitespaces)),
                rate.isFinite, rate > previousRate
            else { return nil }
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
            previousRate = rate
        }
        guard total > 0 else { return nil }
        bins = zip(labels, counts).map { Bin(label: $0.0, events: $0.1) }
        totalEvents = total
    }

    public func percent(in bin: Bin) -> Double {
        Double(bin.events) / Double(totalEvents) * 100
    }

    public var estimatedAverage: AverageEstimate? {
        guard bins.count > 1, totalEvents > 0 else { return nil }
        var weightedRate = 0.0
        for bin in bins {
            guard bin.events >= 0,
                let rate = Double(bin.label.dropLast(4).trimmingCharacters(in: .whitespaces)),
                rate.isFinite, rate > 0
            else { return nil }
            weightedRate += rate * (Double(bin.events) / Double(totalEvents))
        }
        guard weightedRate.isFinite else { return nil }
        return AverageEstimate(
            gigabytesPerSecond: weightedRate,
            onlyLowestBin: bins.first?.events == totalEvents,
            includesHighestBin: (bins.last?.events ?? 0) > 0)
    }
}

public struct GPUBandwidthSample: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let interval: TimeInterval
    public let read: GPUBandwidthHistogram?
    public let write: GPUBandwidthHistogram?
    public let combined: GPUBandwidthHistogram?

    public init?(
        timestamp: Date, interval: TimeInterval, read: GPUBandwidthHistogram? = nil,
        write: GPUBandwidthHistogram? = nil, combined: GPUBandwidthHistogram? = nil
    ) {
        guard timestamp.timeIntervalSince1970.isFinite, interval.isFinite,
            interval > 0, interval <= 30, read != nil || write != nil || combined != nil
        else { return nil }
        self.timestamp = timestamp
        self.interval = interval
        self.read = read
        self.write = write
        self.combined = combined
    }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age.isFinite && (-1...5).contains(age)
    }

    public func estimatedRates(at now: Date) -> (read: Double?, write: Double?, total: Double?) {
        guard isFresh(at: now) else { return (nil, nil, nil) }
        func rate(_ histogram: GPUBandwidthHistogram?) -> Double? {
            guard let estimate = histogram?.estimatedAverage, !estimate.onlyLowestBin else {
                return nil
            }
            return estimate.gigabytesPerSecond
        }
        return (rate(read), rate(write), rate(combined))
    }
}

/// A cheap GPU sample read from the IOAccelerator registry once per system tick.
/// On Apple silicon the integrated GPU is a single accelerator backed by unified
/// memory; the figures come straight from the driver's `PerformanceStatistics`.
public struct GPUSample: Sendable, Codable, Equatable {
    public var sampledAt: Date? = nil
    /// Overall GPU utilization, 0–100 (IOAccelerator "Device Utilization %").
    public var utilization: Double
    /// Renderer / tiler utilization, 0–100, when the driver reports them.
    public var renderUtilization: Double?
    public var tilerUtilization: Double?
    /// GPU in-use memory in bytes (unified memory on Apple silicon).
    public var inUseMemoryBytes: UInt64?
    /// GPU allocated (reserved) memory in bytes.
    public var allocatedMemoryBytes: UInt64?
    public var bandwidth: GPUBandwidthSample?
    /// GPU core count, e.g. 16 (static).
    public var coreCount: Int?
    /// The GPU / chip name, e.g. "Apple M2 Pro" (static; read once).
    public var name: String?

    // --- IOReport "Energy Model" power (watts), filled by the Sampler ---
    public var gpuPowerWatts: Double?
    public var anePowerWatts: Double?
    public var cpuPowerWatts: Double?
    public var anePowerSampledAt: Date?
    public var anePowerSampleInterval: TimeInterval?
    public var anePowerRequiresHelper: Bool?
    public var aneTimeMillisecondsPerSecond: Double?
    public var aneSampleIsPartial: Bool?

    // --- IOReport "GPU Stats", filled by the Sampler ---
    /// Share of the interval the GPU was powered and clocked (100 minus the
    /// OFF state's residency), 0...100.
    public var activeResidency: Double?
    /// Residency per performance state over the interval, lowest clock first,
    /// the OFF state excluded.
    public var performanceStates: [GPUPerformanceState]?
    /// True when thermal management (CLTM) held the GPU's clock down for part
    /// of the interval.
    public var throttled: Bool?
    /// The power manager's target as a share of the GPU's maximum power over
    /// the interval (100 = no cap in effect).
    public var powerCapPercent: Double?
    /// GPU hang recoveries since boot (IOAccelerator `recoveryCount`).
    public var recoveryCount: Int?
    // --- SMC thermal, filled by the Sampler ---
    /// GPU die temperature (°C): the hottest GPU cluster sensor, falling back
    /// to the hottest CPU die sensor on chips with no GPU-specific keys.
    public var dieTemperatureC: Double?
    public var fanRPM: Int?
    public var fanMaxRPM: Int?

    public var reportedANEPowerWatts: Double? {
        guard let anePowerSampledAt, let anePowerSampleInterval, let anePowerWatts else {
            return nil
        }
        let reading = ANEPowerReading(
            timestamp: anePowerSampledAt, interval: anePowerSampleInterval, watts: anePowerWatts)
        return reading.isFresh(at: sampledAt ?? Date()) ? anePowerWatts : nil
    }

    public init(
        utilization: Double, renderUtilization: Double? = nil, tilerUtilization: Double? = nil,
        inUseMemoryBytes: UInt64? = nil, name: String? = nil
    ) {
        self.utilization = utilization
        self.renderUtilization = renderUtilization
        self.tilerUtilization = tilerUtilization
        self.inUseMemoryBytes = inUseMemoryBytes
        self.name = name
    }
}
