import Foundation

/// One hour-tier observation pairing mean fan speed with mean CPU die
/// temperature, the raw material of the dust signal.
public struct FanTempHour: Sendable, Equatable {
    public var date: Date
    public var fanRPM: Double
    public var dieC: Double

    public init(date: Date, fanRPM: Double, dieC: Double) {
        self.date = date
        self.fanRPM = fanRPM
        self.dieC = dieC
    }
}

/// Detects fans working measurably harder for the same die temperature than
/// they did weeks ago. Dust buildup in the vents is the usual cause: airflow
/// drops, so the fan controller spends more rpm to hold the same die
/// temperature. Comparing rpm *at matched temperature bands* is what makes
/// this a drift signal rather than a workload signal; a busier month runs
/// hotter and faster, but not faster-at-the-same-temperature.
public enum ThermalDrift {
    public struct Finding: Sendable, Equatable {
        /// Fractional fan speed increase at matched die temperature (0.25 = 25%).
        public var increaseFraction: Double
        /// The absolute rpm increase behind the fraction.
        public var increaseRPM: Double
        /// How far back the baseline window reaches, in whole weeks.
        public var baselineWeeksAgo: Int
    }

    /// Both windows must carry at least this many usable hours, so a Mac that
    /// was asleep or idle for most of a window stays quiet.
    public static let minHoursPerWindow = 72
    /// Die temperature band width for matching hours between the windows.
    public static let bandWidthC = 2.5
    /// Fire only on a clear signal: at least 20 percent faster and at least
    /// 300 rpm, so idle wobble and rounding never produce a card.
    public static let minIncreaseFraction = 0.2
    public static let minIncreaseRPM = 300.0
    /// Bands where the baseline fans were essentially off are skipped: a ratio
    /// against near-zero rpm is unstable, and fans-off hours carry no airflow
    /// information.
    public static let minBandRPM = 500.0

    public static func analyze(
        recent: [FanTempHour], baseline: [FanTempHour], baselineWeeksAgo: Int
    ) -> Finding? {
        guard recent.count >= minHoursPerWindow, baseline.count >= minHoursPerWindow else {
            return nil
        }
        let recentBands = bands(recent)
        let baselineBands = bands(baseline)
        var weightedRecent = 0.0
        var weightedBaseline = 0.0
        var weight = 0
        for (band, base) in baselineBands {
            guard let current = recentBands[band] else { continue }
            let baselineMean = base.sum / Double(base.count)
            guard baselineMean >= minBandRPM else { continue }
            let recentMean = current.sum / Double(current.count)
            // Weight each band by the hours it can actually pair, so a band
            // seen once cannot swing the verdict.
            let hours = min(base.count, current.count)
            weightedRecent += recentMean * Double(hours)
            weightedBaseline += baselineMean * Double(hours)
            weight += hours
        }
        guard weight >= minHoursPerWindow / 3, weightedBaseline > 0 else { return nil }
        let recentMean = weightedRecent / Double(weight)
        let baselineMean = weightedBaseline / Double(weight)
        let increase = recentMean - baselineMean
        let fraction = increase / baselineMean
        guard fraction >= minIncreaseFraction, increase >= minIncreaseRPM else { return nil }
        return Finding(
            increaseFraction: fraction, increaseRPM: increase,
            baselineWeeksAgo: baselineWeeksAgo)
    }

    private static func bands(_ hours: [FanTempHour]) -> [Int: (sum: Double, count: Int)] {
        var result: [Int: (sum: Double, count: Int)] = [:]
        for hour in hours {
            let band = Int((hour.dieC / bandWidthC).rounded(.down))
            let entry = result[band] ?? (0, 0)
            result[band] = (entry.sum + hour.fanRPM, entry.count + 1)
        }
        return result
    }
}
