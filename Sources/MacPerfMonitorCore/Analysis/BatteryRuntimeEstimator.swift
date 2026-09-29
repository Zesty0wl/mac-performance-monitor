import Foundation

public struct BatteryRuntimeEstimate: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case macOS, recentUse
    }

    public var minutesRemaining: Double
    public var fullChargeMinutes: Double?
    public var source: Source

    public init(minutesRemaining: Double, fullChargeMinutes: Double?, source: Source) {
        self.minutesRemaining = minutesRemaining
        self.fullChargeMinutes = fullChargeMinutes
        self.source = source
    }
}

public struct BatteryRuntimeEstimator {
    private struct Reading {
        var date: Date
        var current: Double
    }

    private var readings: [Reading] = []
    private var pack: String?

    public init() {}

    public mutating func update(_ sample: BatterySample?) -> BatteryRuntimeEstimate? {
        guard let sample, sample.isPresent, !sample.isOnAC, !sample.isCharging,
            sample.timestamp.timeIntervalSince1970.isFinite
        else {
            readings.removeAll(keepingCapacity: true)
            pack = nil
            return nil
        }
        let identifier = BatteryIdentity.identifier(for: sample.serialNumber)
        if identifier != pack {
            readings.removeAll(keepingCapacity: true)
            pack = identifier
        }
        if let last = readings.last {
            let elapsed = sample.timestamp.timeIntervalSince(last.date)
            if elapsed <= 0 || elapsed > 30 { readings.removeAll(keepingCapacity: true) }
        }
        if sample.amperageMilliAmps < 0 {
            readings.append(
                Reading(date: sample.timestamp, current: -Double(sample.amperageMilliAmps)))
            readings.removeAll { sample.timestamp.timeIntervalSince($0.date) > 300 }
            if readings.count > 128 { readings.removeFirst(readings.count - 128) }
        } else {
            readings.removeAll(keepingCapacity: true)
        }

        if let minutes = sample.timeToEmptyMinutes, (0...10_080).contains(minutes) {
            var full: Double?
            if let current = sample.currentCapacitymAh, let capacity = sample.maxCapacitymAh,
                current > 0, capacity >= current, sample.chargePercent >= 10
            {
                full = Self.validMinutes(Double(minutes) * Double(capacity) / Double(current))
            }
            return BatteryRuntimeEstimate(
                minutesRemaining: Double(minutes), fullChargeMinutes: full, source: .macOS)
        }

        guard readings.count >= 7, let first = readings.first, let last = readings.last,
            last.date.timeIntervalSince(first.date) >= 180,
            let remaining = sample.currentCapacitymAh, let capacity = sample.maxCapacitymAh,
            remaining > 0, capacity >= remaining, sample.voltageMilliVolts > 0
        else { return nil }
        var weighted = 0.0
        var squared = 0.0
        var duration = 0.0
        for index in readings.indices.dropFirst() {
            let elapsed = readings[index].date.timeIntervalSince(readings[index - 1].date)
            let current = readings[index].current
            let previous = readings[index - 1].current
            weighted += (current + previous) / 2 * elapsed
            squared += (current * current + previous * previous) / 2 * elapsed
            duration += elapsed
        }
        guard duration > 0 else { return nil }
        let mean = weighted / duration
        let deviation = sqrt(max(0, squared / duration - mean * mean))
        guard mean >= 50, deviation / mean <= 0.5,
            let minutes = Self.validMinutes(Double(remaining) / mean * 60)
        else { return nil }
        return BatteryRuntimeEstimate(
            minutesRemaining: minutes,
            fullChargeMinutes: Self.validMinutes(Double(capacity) / mean * 60), source: .recentUse)
    }

    private static func validMinutes(_ value: Double) -> Double? {
        value.isFinite && (0...10_080).contains(value) ? value : nil
    }
}
