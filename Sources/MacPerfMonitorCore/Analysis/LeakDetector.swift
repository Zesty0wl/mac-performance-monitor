import Foundation

/// Finds sustained, recent footprint growth. A finding is not a leak diagnosis.
public enum LeakDetector {
    public struct Config: Sendable {
        /// Minimum span of growth data required before judging (seconds).
        /// Deliberately long: a freshly launched app's memory climbs steeply and
        /// smoothly while it loads, caches warm and JIT settles — a near-perfect
        /// straight line that looks exactly like a leak over a short window.
        /// Requiring growth to be *sustained* over a long span lets that launch
        /// ramp plateau first, so the plateau breaks the linear fit and only a
        /// genuine, still-ongoing leak qualifies. It also means a process must
        /// have lived at least this long to be judged, so nothing is flagged
        /// mid-launch.
        public var minimumDuration: TimeInterval
        /// Minimum growth rate to care about (bytes/second).
        public var minimumSlope: Double
        /// Minimum R^2: growth must be consistent, not a one-off jump.
        public var minimumRSquared: Double
        /// Minimum number of samples.
        public var minimumSamples: Int
        /// Minimum total growth across the window (bytes), a noise floor.
        public var minimumTotalGrowth: UInt64
        public var minimumRelativeGrowth: Double
        public var maximumGap: TimeInterval
        public var recentDuration: TimeInterval

        public init(
            minimumDuration: TimeInterval = 20 * 60,  // 20 minutes — past warm-up
            minimumSlope: Double = 8 * 1024,  // ~8 KB/s
            minimumRSquared: Double = 0.85,
            minimumSamples: Int = 12,
            minimumTotalGrowth: UInt64 = 32 * 1024 * 1024,  // 32 MB
            minimumRelativeGrowth: Double = 0.05,
            maximumGap: TimeInterval = 180,
            recentDuration: TimeInterval = 5 * 60
        ) {
            self.minimumDuration = minimumDuration
            self.minimumSlope = minimumSlope
            self.minimumRSquared = minimumRSquared
            self.minimumSamples = minimumSamples
            self.minimumTotalGrowth = minimumTotalGrowth
            self.minimumRelativeGrowth = minimumRelativeGrowth
            self.maximumGap = maximumGap
            self.recentDuration = recentDuration
        }

        public static let `default` = Config()
    }

    public struct Finding: Sendable, Equatable {
        /// Growth rate in bytes/second.
        public var slopeBytesPerSecond: Double
        /// Consistency of the trend (0...1).
        public var rSquared: Double
        /// Span of the analysed window in seconds.
        public var durationSeconds: TimeInterval
        /// Total growth across the window in bytes.
        public var totalGrowth: UInt64
        /// 0...1 pattern score, blending fit and slope. Not a leak probability.
        public var confidence: Double
    }

    /// Analyse a footprint time-series. Returns a `Finding` when the series meets
    /// every growth and data-quality threshold, otherwise nil.
    public static func analyze(series: [(Date, UInt64)], config: Config = .default) -> Finding? {
        guard series.count >= config.minimumSamples else { return nil }
        let sorted = series.sorted { $0.0 < $1.0 }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        let duration = last.0.timeIntervalSince(first.0)
        guard duration >= config.minimumDuration else { return nil }
        guard
            zip(sorted, sorted.dropFirst()).allSatisfy({ earlier, later in
                let spacing = later.0.timeIntervalSince(earlier.0)
                return spacing > 0 && spacing <= config.maximumGap
            })
        else { return nil }

        let t0 = first.0.timeIntervalSince1970
        let points = sorted.map { (x: $0.0.timeIntervalSince1970 - t0, y: Double($0.1)) }
        guard var fit = LinearRegression.fit(points) else { return nil }
        var troughs = [first]
        for index in 1..<sorted.count {
            let current = sorted[index]
            if Double(current.1) < Double(sorted[index - 1].1) * 0.98,
                index == sorted.count - 1 || current.1 <= sorted[index + 1].1
            {
                troughs.append(current)
            }
        }
        let envelope =
            troughs.count >= 3
            ? LinearRegression.fit(
                troughs.map {
                    (x: $0.0.timeIntervalSince1970 - t0, y: Double($0.1))
                }) : nil
        if let envelope, envelope.slope >= config.minimumSlope,
            envelope.rSquared >= config.minimumRSquared
        {
            fit = envelope
        }
        let recent = sorted.filter { last.0.timeIntervalSince($0.0) <= config.recentDuration }
        let recentFit = LinearRegression.fit(
            recent.map {
                (x: $0.0.timeIntervalSince1970 - t0, y: Double($0.1))
            })
        let recentTroughs = troughs.suffix(3)
        let recentEnvelope =
            recentTroughs.count == 3
                && last.0.timeIntervalSince(recentTroughs.last!.0) <= config.recentDuration
            ? LinearRegression.fit(
                recentTroughs.map { (x: $0.0.timeIntervalSince1970 - t0, y: Double($0.1)) }) : nil
        guard recent.count >= 3,
            (recentFit?.slope ?? 0) >= config.minimumSlope
                || (recentEnvelope?.slope ?? 0) >= config.minimumSlope
        else { return nil }

        guard fit.slope >= config.minimumSlope, fit.rSquared >= config.minimumRSquared else {
            return nil
        }

        let totalGrowth: UInt64 = last.1 > first.1 ? last.1 - first.1 : 0
        guard totalGrowth >= config.minimumTotalGrowth,
            Double(totalGrowth) >= Double(first.1) * config.minimumRelativeGrowth
        else { return nil }

        // Confidence: consistency weighted with how far slope exceeds the floor.
        let slopeHeadroom = min(fit.slope / (config.minimumSlope * 8), 1.0)
        let confidence = max(0, min(0.6 * fit.rSquared + 0.4 * slopeHeadroom, 1.0))

        return Finding(
            slopeBytesPerSecond: fit.slope,
            rSquared: fit.rSquared,
            durationSeconds: duration,
            totalGrowth: totalGrowth,
            confidence: confidence
        )
    }
}
