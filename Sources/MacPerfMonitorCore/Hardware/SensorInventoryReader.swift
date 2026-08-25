import Foundation

/// The full sensor inventory as a live channel for app-side surfaces (the
/// Hardware overview's heat strips): a public facade over the internal SMC
/// reader. The first read pays the full key discovery (a few hundred
/// milliseconds); repeats re-read only the discovered keys, cheap enough to
/// follow the app's refresh cycle while a sensor surface is visible. Not
/// thread safe: confine one instance to a single queue.
/// One named sensor reading, for surfaces that need per-sensor identity (the
/// live detail sheet), not just the per-domain summaries.
public struct SensorValue: Sendable, Equatable, Identifiable {
    public var key: String
    public var celsius: Double
    public var group: String
    public var id: String { key }
}

extension HardwareFacts.SensorGroup {
    /// The recorded series for a display group, so a sensor chart can seed
    /// itself from the log instead of starting empty on every launch. Nil for
    /// groups with no persisted column (nothing is invented).
    public static func recordedValue(
        _ group: String, in point: SystemHistoryPoint
    ) -> Double? {
        switch group {
        case SMCReader.groupCPUPCores: return point.cpuPCoreDieC
        case SMCReader.groupCPUECores: return point.cpuECoreDieC
        case SMCReader.groupGPU: return point.gpuDieC
        case SMCReader.groupSSD: return point.ssdTemperatureC
        case SMCReader.groupBattery:
            return point.batteryTemperatureCelsius > 0 ? point.batteryTemperatureCelsius : nil
        case SMCReader.groupAirflow: return point.airflowC
        case SMCReader.groupSkin: return point.skinC
        case SMCReader.groupWireless: return point.wirelessC
        case SMCReader.groupVoltageRails: return point.voltageRailC
        case SMCReader.groupOther: return point.otherSensorC
        default: return nil
        }
    }

    /// The fan series' key in the same lookup, kept beside the groups so the
    /// Fans chart seeds the same way.
    public static let fansKey = "Fans"

    /// Every display group, in the order surfaces should present them.
    public static let displayOrder: [String] = SMCReader.sensorGroupOrder
}

public final class SensorInventoryReader {
    private let reader = SMCReader()

    public init() {}

    /// Display-ordered groups with readings hottest first, fan speeds, and
    /// the individual named readings behind the groups. All empty on Macs
    /// with no readable SMC.
    public func read() -> (
        groups: [HardwareFacts.SensorGroup], fans: [Int], sensors: [SensorValue]
    ) {
        let inventory = reader.sensorInventory()
        let facts = HardwareNativeReaders.sensorFacts(inventory)
        let sensors = inventory.sensors.map {
            SensorValue(key: $0.key, celsius: $0.celsius, group: $0.group)
        }
        return (facts.groups, facts.fans, sensors)
    }
}
