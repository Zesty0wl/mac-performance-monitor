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
