import Foundation

extension Array where Element == SystemHistoryPoint {
    /// Break the series into contiguous runs wherever two consecutive samples
    /// are further apart than the median spacing × 15 (with a 30-second floor).
    /// This is the same heuristic MetricChart uses for per-process data: ordinary
    /// jitter and the occasional missed tick are bridged, but a genuine absence
    /// (the Mac asleep, the app not running) leaves a blank gap instead of a
    /// straight diagonal across the hole.
    public func splitIntoSegments() -> [[SystemHistoryPoint]] {
        guard !isEmpty else { return [] }
        let threshold = gapThreshold()
        var result: [[SystemHistoryPoint]] = []
        var current: [SystemHistoryPoint] = [self[0]]
        for point in dropFirst() {
            if let last = current.last,
                point.date.timeIntervalSince(last.date) > threshold
            {
                result.append(current)
                current = [point]
            } else {
                current.append(point)
            }
        }
        result.append(current)
        return result
    }

    private func gapThreshold() -> TimeInterval {
        guard count > 2 else { return .greatestFiniteMagnitude }
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(count - 1)
        for i in 1..<count {
            deltas.append(self[i].date.timeIntervalSince(self[i - 1].date))
        }
        deltas.sort()
        let median = deltas[deltas.count / 2]
        return Swift.max(median * 15, 30)
    }

    /// Collapse a dense system-history series to roughly `maxCount` points for
    /// charting, bucketed by ABSOLUTE TIME on a fixed grid (`span / maxCount`
    /// wide, anchored to the epoch) rather than by array index. This is what
    /// keeps a live chart's shape STABLE: the bucket a sample falls into depends
    /// only on its timestamp, not on how many samples are in the array, so
    /// appending the newest sample (or trimming the oldest) only ever changes the
    /// rightmost bucket. The historical shape holds still and the series simply
    /// slides left as time advances, instead of every bucket's contents (and the
    /// whole shape) shifting on each tick, which is what an index-based
    /// `count / maxCount` split does the moment `count` changes.
    ///
    /// `span` is the selected window's length (e.g. `range.seconds`). Deriving
    /// the width from this FIXED span (not the data's own min-to-max extent,
    /// which grows every tick) is essential to that stability; each bucket's
    /// point is dated to its grid start so the x-positions never wander.
    ///
    /// Byte fields are averaged per bucket; `pressurePercent` keeps the bucket
    /// peak so the spikes the pressure charts exist to show (and the Insights
    /// event markers point at) are preserved rather than averaged away.
    public func chartDownsampled(span: TimeInterval, to maxCount: Int) -> [SystemHistoryPoint] {
        guard count > maxCount, maxCount > 0, span > 0 else { return self }
        let width = span / Double(maxCount)
        func bucketIndex(_ p: SystemHistoryPoint) -> Double {
            (p.date.timeIntervalSince1970 / width).rounded(.down)
        }
        var result: [SystemHistoryPoint] = []
        result.reserveCapacity(maxCount + 1)
        var i = 0
        while i < count {
            let b = bucketIndex(self[i])
            var j = i + 1
            while j < count, bucketIndex(self[j]) == b { j += 1 }
            let slice = self[i..<j]
            let n = Double(slice.count)
            func mean(_ value: (SystemHistoryPoint) -> UInt64) -> UInt64 {
                UInt64(slice.reduce(0.0) { $0 + Double(value($1)) } / n)
            }
            func dmean(_ value: (SystemHistoryPoint) -> Double) -> Double {
                slice.reduce(0.0) { $0 + value($1) } / n
            }
            // Mean over only the points that carry a value; nil (an interval
            // with no IO, or no boot capacity recorded yet) must not drag the
            // average toward zero, and an all-nil bucket must stay nil so the
            // chart draws a gap.
            func omean(_ value: (SystemHistoryPoint) -> Double?) -> Double? {
                let present = slice.compactMap(value)
                guard !present.isEmpty else { return nil }
                return present.reduce(0, +) / Double(present.count)
            }
            // Peak over only the points that carry a value; all-nil stays nil
            // so the chart gaps. Temperatures use this rather than omean: a
            // plain average erases the spikes, which are the point of thermal
            // history.
            func omax(_ value: (SystemHistoryPoint) -> Double?) -> Double? {
                slice.compactMap(value).max()
            }
            var point = SystemHistoryPoint(
                // Grid-anchored start of the bucket: a fixed point that does
                // not move as samples land in this or any other bucket.
                date: Date(timeIntervalSince1970: b * width),
                pressurePercent: slice.map(\.pressurePercent).max() ?? 0,
                appMemory: mean { $0.appMemory },
                wired: mean { $0.wired },
                compressed: mean { $0.compressed },
                cachedFiles: mean { $0.cachedFiles },
                swapUsed: mean { $0.swapUsed },
                // CPU is inherently spiky, so average rather than peak per
                // bucket; a max-collapsed line would read as permanently high.
                cpuLoad: dmean { $0.cpuLoad },
                // Carry the battery scalars through too: omitting them
                // defaulted them to 0, which collapsed the Battery tab's
                // charge/power lines to a flat zero on any downsampled range.
                batteryCharge: dmean { $0.batteryCharge },
                batteryPowerWatts: dmean { $0.batteryPowerWatts },
                batteryHealthPercent: dmean { $0.batteryHealthPercent },
                batteryTemperatureCelsius: dmean { $0.batteryTemperatureCelsius },
                // Network is bursty, so average per bucket (a max-collapsed
                // line would read as permanently saturated), like CPU.
                networkInBytesPerSec: dmean { $0.networkInBytesPerSec },
                networkOutBytesPerSec: dmean { $0.networkOutBytesPerSec },
                // Disk throughput is bursty too, so average per bucket like
                // network. Carrying these through is the same fix the battery
                // and network scalars already got: leaving them out defaulted
                // them to 0 and flattened the Disk tab's read/write trend on
                // any range whose point count exceeded the chart cap.
                diskReadBytesPerSec: dmean { $0.diskReadBytesPerSec },
                diskWriteBytesPerSec: dmean { $0.diskWriteBytesPerSec },
                diskReadOperationsPerSec: dmean { $0.diskReadOperationsPerSec },
                diskWriteOperationsPerSec: dmean { $0.diskWriteOperationsPerSec },
                diskReadLatencyMs: omean { $0.diskReadLatencyMs },
                diskWriteLatencyMs: omean { $0.diskWriteLatencyMs },
                diskUtilizationPercent: omean { $0.diskUtilizationPercent },
                // Free space wants its low water mark, not its average: the
                // moment the disk nearly filled is the moment that matters.
                bootFreeBytes: slice.compactMap(\.bootFreeBytes).min(),
                bootTotalBytes: slice.compactMap(\.bootTotalBytes).last,
                // Carry the GPU figures through: omitting them defaulted
                // them to nil and blanked the GPU tab's history on any
                // downsampled range, the same class of drop the battery
                // and disk scalars had. Bursty like CPU, so average.
                gpuUtilization: omean { $0.gpuUtilization },
                gpuPowerWatts: omean { $0.gpuPowerWatts },
                anePowerWatts: omean { $0.anePowerWatts },
                cpuDieC: omax { $0.cpuDieC },
                gpuDieC: omax { $0.gpuDieC },
                ssdTemperatureC: omax { $0.ssdTemperatureC },
                fanRPM: omax { $0.fanRPM },
                // Worst pressure in the bucket, for the same reason.
                thermalPressure: slice.compactMap(\.thermalPressure).max(),
                cpuPCoreDieC: omax { $0.cpuPCoreDieC },
                cpuECoreDieC: omax { $0.cpuECoreDieC },
                airflowC: omax { $0.airflowC },
                skinC: omax { $0.skinC },
                wirelessC: omax { $0.wirelessC },
                voltageRailC: omax { $0.voltageRailC },
                otherSensorC: omax { $0.otherSensorC }
            )
            // The bucket's peak is the highest peak among its members (a raw
            // member's peak being itself), so a band drawn over the result
            // still reaches the real spike.
            point.peaks = slice.dropFirst().reduce(slice[i].effectivePeaks) {
                $0.merged(with: $1.effectivePeaks)
            }
            result.append(point)
            i = j
        }
        return result
    }
}
