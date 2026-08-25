import Foundation

/// The full sensor inventory as a live channel for app-side surfaces (the
/// Hardware overview's heat strips): a public facade over the internal SMC
/// reader. The first read pays the full key discovery (a few hundred
/// milliseconds); repeats re-read only the discovered keys, cheap enough to
/// follow the app's refresh cycle while a sensor surface is visible. Not
/// thread safe: confine one instance to a single queue.
public final class SensorInventoryReader {
    private let reader = SMCReader()

    public init() {}

    /// Display-ordered groups with readings hottest first, plus fan speeds.
    /// Both empty on Macs with no readable SMC.
    public func read() -> (groups: [HardwareFacts.SensorGroup], fans: [Int]) {
        HardwareNativeReaders.sensorFacts(reader.sensorInventory())
    }
}
