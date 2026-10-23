import Foundation

/// The energy menu's power chart, as three stacked bands per sample: what the
/// Mac draws from the adapter, what it draws from the battery, and what the
/// adapter puts into the battery on top. The top of the lower two is the
/// whole-machine draw; the top of the stack is the adapter's total output
/// while charging. A band too thin to see is NaN, which the chart draws as a
/// gap rather than a hairline.
public struct BatteryPowerFlow: Equatable, Sendable {
    /// Band edges in watts, one entry per sample (NaN where the band is absent).
    public var adapterTop: [Double] = []
    public var batteryFloor: [Double] = []
    public var batteryTop: [Double] = []
    public var chargingFloor: [Double] = []
    public var chargingTop: [Double] = []

    /// Battery flow below this reads as idle: a held battery's gauge wobbles
    /// by a few tens of milliamps either way.
    static let idleWatts = 0.5

    public init<Samples: Sequence>(_ samples: Samples) where Samples.Element == SystemSample {
        for sample in samples {
            let battery = sample.batteryPresent ? Self.clean(sample.batteryPowerWatts) : 0
            let charging = sample.batteryIsCharging && battery >= Self.idleWatts ? battery : 0
            let discharging = !sample.batteryIsCharging && battery >= Self.idleWatts ? battery : 0
            // Without the SMC's system figure (older Macs) the battery's own
            // discharge is the best measure of the load.
            var system = Self.clean(sample.batterySystemPowerWatts)
            if system <= 0 { system = discharging }
            // On battery the system and battery figures are measured at
            // different points and differ by a little; that difference is not
            // the adapter. A real shortfall has the adapter carrying most of it.
            var fromAdapter = max(0, system - discharging)
            if discharging > 0, fromAdapter < max(1, 0.1 * system) { fromAdapter = 0 }

            adapterTop.append(fromAdapter >= Self.idleWatts ? fromAdapter : .nan)
            batteryFloor.append(discharging > 0 ? fromAdapter : .nan)
            batteryTop.append(discharging > 0 ? max(system, fromAdapter + discharging) : .nan)
            chargingFloor.append(charging > 0 ? system : .nan)
            chargingTop.append(charging > 0 ? system + charging : .nan)
        }
    }

    /// The highest point of the stack, for the chart's scale.
    public var peak: Double {
        [adapterTop, batteryTop, chargingTop].joined().filter(\.isFinite).max() ?? 0
    }

    /// The newest sample's three flows in watts (0 where absent), for the
    /// legend under the chart, so it always agrees with the right edge.
    public var latest: (fromAdapter: Double, fromBattery: Double, intoBattery: Double) {
        func band(_ top: [Double], _ floor: [Double]?) -> Double {
            guard let high = top.last, high.isFinite else { return 0 }
            return high - (floor?.last ?? 0)
        }
        return (
            band(adapterTop, nil), band(batteryTop, batteryFloor),
            band(chargingTop, chargingFloor)
        )
    }

    /// Whether there is anything to draw (an Intel Mac on the adapter reports
    /// no system power and an idle battery, which leaves the chart empty).
    public var isEmpty: Bool { peak <= 0 }

    private static func clean(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}
