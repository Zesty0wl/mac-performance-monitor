import Foundation

/// What the battery is doing, resolved from one sample into the case a person
/// cares about: how long it lasts, how long until it is charged, or why it is
/// not charging although the Mac is plugged in.
public enum BatteryChargeStatus: Equatable, Sendable {
    /// Running on the battery. Minutes left, nil while still estimating.
    case onBattery(minutesLeft: Double?)
    /// Charging towards `targetPercent` (100, or a hold's limit), with the
    /// minutes to get there when known.
    case charging(targetPercent: Int, minutes: Double?)
    /// Plugged in, held at a limit by macOS.
    case onHold(ChargeHold)
    /// Plugged in and charged.
    case charged
    /// Plugged in, but the battery is covering part of the load because the
    /// adapter cannot supply it all.
    case adapterShortfall(batteryWatts: Double)
    /// Plugged in and not charging, for a reason macOS does not publish.
    case notCharging

    /// Battery flow (watts) below which a plugged-in battery counts as idle:
    /// the gauge reads a few tens of milliamps either way while held.
    static let idleWatts = 1.0

    public init(_ sample: BatterySample) {
        guard sample.isOnAC else {
            let minutes =
                sample.runtimeEstimate?.minutesRemaining
                ?? sample.timeToEmptyMinutes.map(Double.init)
            self = .onBattery(minutesLeft: minutes.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
            return
        }
        let hold = sample.chargeHold
        if sample.isCharging {
            if let hold, Double(hold.limitPercent) > sample.chargePercent {
                self = .charging(
                    targetPercent: hold.limitPercent,
                    minutes: Self.minutesToReach(Double(hold.limitPercent), sample))
            } else {
                self = .charging(
                    targetPercent: 100, minutes: sample.timeToFullMinutes.map(Double.init))
            }
            return
        }
        // A hold also covers easing down to the limit from above it, when
        // macOS lets the battery run the Mac until it reaches the cap.
        if let hold, sample.chargePercent >= Double(hold.limitPercent) - 2 {
            self = .onHold(hold)
            return
        }
        if sample.amperageMilliAmps < 0, sample.powerWatts >= Self.idleWatts {
            self = .adapterShortfall(batteryWatts: sample.powerWatts)
            return
        }
        if sample.isFullyCharged || sample.chargePercent >= 99 {
            self = .charged
            return
        }
        self = .notCharging
    }

    /// Minutes to charge to `target` percent at the present charging
    /// current: a straight-line estimate, which holds well below 80 %, where
    /// lithium cells charge at a near-constant current.
    static func minutesToReach(_ target: Double, _ sample: BatterySample) -> Double? {
        guard let capacity = sample.maxCapacitymAh, capacity > 0, sample.amperageMilliAmps > 0
        else { return nil }
        let needed = (target - sample.chargePercent) / 100 * Double(capacity)
        guard needed > 0 else { return nil }
        let minutes = needed / Double(sample.amperageMilliAmps) * 60
        return minutes.isFinite && minutes <= 24 * 60 ? minutes : nil
    }
}
