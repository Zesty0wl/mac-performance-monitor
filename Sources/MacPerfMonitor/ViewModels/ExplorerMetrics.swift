import MacPerfMonitorCore
import SwiftUI

enum ExplorerSourceGroup: String, CaseIterable, Identifiable {
    case processor, memory, network, storage, graphics, thermals, battery, processes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .processor: return t("Processor")
        case .memory: return t("Memory")
        case .network: return t("Network")
        case .storage: return t("Disk")
        case .graphics: return t("GPU")
        case .thermals: return t("Sensors")
        case .battery: return t("Energy")
        case .processes: return t("Processes")
        }
    }
    var icon: String {
        switch self {
        case .processor, .processes: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .storage: return "internaldrive"
        case .graphics: return "display"
        case .thermals: return "thermometer.medium"
        case .battery: return "bolt"
        }
    }
}

enum ExplorerUnit {
    case percent, index, bytes, rate, count, watts, celsius, rpm, milliseconds, seconds, joules,
        thermalState, millisecondsPerSecond

    var symbol: String {
        switch self {
        case .percent: return "%"
        case .index: return "index"
        case .bytes: return "B"
        case .rate: return "B/s"
        case .count: return "count"
        case .watts: return "W"
        case .celsius: return "C"
        case .rpm: return "rpm"
        case .milliseconds: return "ms"
        case .seconds: return "s"
        case .joules: return "J"
        case .thermalState: return "state"
        case .millisecondsPerSecond: return "ms/s"
        }
    }

    func format(_ value: Double) -> String {
        guard value.isFinite else { return t("Unavailable") }
        switch self {
        case .percent: return String(format: "%.1f%%", value)
        case .index: return String(format: "%.1f / 100", value)
        case .bytes:
            return ByteFormat.string(UInt64(min(max(value, 0), Double(UInt64.max).nextDown)))
        case .rate: return ByteFormat.rate(max(value, 0))
        case .count: return value.formatted(.number.precision(.fractionLength(0...1)))
        case .watts: return String(format: "%.2f W", value)
        case .celsius: return String(format: "%.1f°C", value)
        case .rpm: return String(format: "%.0f rpm", value)
        case .milliseconds: return String(format: "%.2f ms", value)
        case .seconds: return String(format: "%.2f s", value)
        case .joules: return String(format: "%.2f J", value)
        case .millisecondsPerSecond: return MetricUnit.millisecondsPerSecond.format(value)
        case .thermalState:
            return ThermalPressureState(rawValue: Int(value.rounded()))?.label ?? t("Unavailable")
        }
    }
}

struct ExplorerSystemField {
    let name: String
    let color: Color
    let value: (SystemHistoryPoint) -> Double?
    var minimum: ((SystemHistoryPoint) -> Double?)? = nil
    var maximum: ((SystemHistoryPoint) -> Double?)? = nil
    var weight: ((SystemHistoryPoint) -> Double?)? = nil
    var peakOnly = false

    func column(_ points: [SystemHistoryPoint]) -> LiveColumn {
        LiveColumn(
            times: points.map { $0.date.timeIntervalSinceReferenceDate }[...],
            values: points.map { value($0) ?? .nan }[...],
            highs: points.map { point in
                if point.bucketDuration == 0 { return value(point) ?? .nan }
                return maximum?(point) ?? (peakOnly ? value(point) : nil) ?? .nan
            }[...],
            lows: points.map { point in
                point.bucketDuration == 0 ? (value(point) ?? .nan) : (minimum?(point) ?? .nan)
            }[...],
            weights: points.map { point in
                if value(point) == nil { return 0 }
                if point.bucketDuration == 0 { return 1 }
                if peakOnly { return .nan }
                return weight?(point) ?? (weight == nil ? Double(point.sampleCount) : .nan)
            }[...],
            durations: points.map(\.bucketDuration)[...])
    }
}

struct ExplorerLaneDefinition: Identifiable {
    enum Source {
        case system([ExplorerSystemField])
        case process(ExplorerProcessMetric)
    }
    let id: String
    let title: String
    let group: ExplorerSourceGroup
    let unit: ExplorerUnit
    let source: Source
    var fixedDomain: ClosedRange<Double>? = nil
    var note: String? = nil

    var isProcess: Bool {
        if case .process = source { return true }
        return false
    }
}

enum ExplorerMetrics {
    static let defaultIDs: Set<String> = [
        "cpu", "pressure", "network", "disk", "die", "process.cpu", "process.footprint",
    ]
    static let palette: [Color] = [.blue, .green, .orange, .pink, .teal, .red, .indigo, .purple]

    static var all: [ExplorerLaneDefinition] {
        var definitions: [ExplorerLaneDefinition] = [
            .init(
                id: "cpu", title: t("Total CPU"), group: .processor, unit: .percent,
                source: .system([
                    .init(
                        name: t("Total CPU"), color: .green, value: { $0.cpuLoad * 100 },
                        minimum: { $0.minima.map { $0.cpuLoad * 100 } },
                        maximum: { $0.peaks.map { $0.cpuLoad * 100 } })
                ]),
                fixedDomain: 0...100),
            .init(
                id: "load", title: t("Load averages"), group: .processor, unit: .count,
                source: .system([
                    .init(
                        name: t("1 min"), color: .blue, value: { $0.loadAverage1 },
                        maximum: { $0.peaks?.loadAverage1 }),
                    .init(name: t("5 min"), color: .teal, value: { $0.loadAverage5 }),
                    .init(name: t("15 min"), color: .orange, value: { $0.loadAverage15 }),
                ])),
            .init(
                id: "pressure", title: t("Pressure index"), group: .memory, unit: .index,
                source: .system([
                    .init(
                        name: t("Pressure index"), color: .orange, value: { $0.pressurePercent },
                        minimum: { $0.minima?.pressurePercent },
                        maximum: { $0.peaks?.pressurePercent })
                ]), fixedDomain: 0...100),
            .init(
                id: "memory", title: t("Memory composition"), group: .memory, unit: .bytes,
                source: .system([
                    .init(
                        name: t("App"), color: .blue, value: { Double($0.appMemory) },
                        minimum: { $0.minima?.appMemory }, maximum: { $0.peaks?.appMemory }),
                    .init(
                        name: t("Wired"), color: .pink, value: { Double($0.wired) },
                        minimum: { $0.minima?.wired }, maximum: { $0.peaks?.wired }),
                    .init(
                        name: t("Compressed"), color: .orange, value: { Double($0.compressed) },
                        minimum: { $0.minima?.compressed }, maximum: { $0.peaks?.compressed }),
                    .init(
                        name: t("Cached files"), color: .teal, value: { Double($0.cachedFiles) },
                        minimum: { $0.minima?.cachedFiles }, maximum: { $0.peaks?.cachedFiles }),
                ])),
            .init(
                id: "swap", title: t("Swap"), group: .memory, unit: .bytes,
                source: .system([
                    .init(
                        name: t("Swap used"), color: .indigo, value: { Double($0.swapUsed) },
                        minimum: { $0.minima?.swapUsed }, maximum: { $0.peaks?.swapUsed })
                ])),
            .init(
                id: "network", title: t("Network throughput"), group: .network, unit: .rate,
                source: .system([
                    .init(
                        name: t("Download"), color: NetworkStyle.download,
                        value: { $0.networkInBytesPerSec },
                        minimum: { $0.minima?.networkInBytesPerSec },
                        maximum: { $0.peaks?.networkInBytesPerSec }),
                    .init(
                        name: t("Upload"), color: NetworkStyle.upload,
                        value: { $0.networkOutBytesPerSec },
                        minimum: { $0.minima?.networkOutBytesPerSec },
                        maximum: { $0.peaks?.networkOutBytesPerSec }),
                ])),
            .init(
                id: "disk", title: t("Physical disk"), group: .storage, unit: .rate,
                source: .system([
                    .init(
                        name: t("Read"), color: DiskStyle.read, value: { $0.diskReadBytesPerSec },
                        minimum: { $0.minima?.diskReadBytesPerSec },
                        maximum: { $0.peaks?.diskReadBytesPerSec }),
                    .init(
                        name: t("Write"), color: DiskStyle.write,
                        value: { $0.diskWriteBytesPerSec },
                        minimum: { $0.minima?.diskWriteBytesPerSec },
                        maximum: { $0.peaks?.diskWriteBytesPerSec }),
                ])),
            .init(
                id: "iops", title: t("IOPS"), group: .storage, unit: .count,
                source: .system([
                    .init(
                        name: t("Read"), color: DiskStyle.read,
                        value: { $0.diskReadOperationsPerSec }),
                    .init(
                        name: t("Write"), color: DiskStyle.write,
                        value: { $0.diskWriteOperationsPerSec }),
                ])),
            .init(
                id: "latency", title: t("Service time"), group: .storage, unit: .milliseconds,
                source: .system([
                    .init(name: t("Read"), color: DiskStyle.read, value: { $0.diskReadLatencyMs }),
                    .init(
                        name: t("Write"), color: DiskStyle.write, value: { $0.diskWriteLatencyMs }),
                ])),
            .init(
                id: "diskBusy", title: t("Disk utilization"), group: .storage, unit: .percent,
                source: .system([
                    .init(
                        name: t("Busiest device"), color: .orange,
                        value: { $0.diskUtilizationPercent })
                ]), fixedDomain: 0...100),
            .init(
                id: "capacity", title: t("Boot volume space"), group: .storage, unit: .bytes,
                source: .system([
                    .init(
                        name: t("Free"), color: .green, value: { $0.bootFreeBytes.map(Double.init) }
                    ),
                    .init(
                        name: t("Total"), color: .secondary,
                        value: { $0.bootTotalBytes.map(Double.init) }),
                ]), note: t("Stored free-space values are interval minima.")),
            .init(
                id: "gpu", title: t("GPU utilization"), group: .graphics, unit: .percent,
                source: .system([
                    .init(
                        name: t("GPU"), color: .teal, value: { $0.gpuUtilization },
                        minimum: { $0.minima?.gpuUtilization },
                        maximum: { $0.peaks?.gpuUtilization })
                ]), fixedDomain: 0...100),
            .init(
                id: "power", title: t("GPU and Neural Engine power"), group: .graphics,
                unit: .watts,
                source: .system([
                    .init(name: t("GPU"), color: .teal, value: { $0.gpuPowerWatts }),
                    .init(
                        name: t("ANE power"), color: .pink, value: { $0.anePowerWatts },
                        minimum: { $0.minima?.anePowerWatts }, maximum: { $0.peaks?.anePowerWatts },
                        weight: { $0.anePowerSampleCount.map(Double.init) }),
                ])),
            .init(
                id: "aneTime", title: t("Neural Engine activity"), group: .graphics,
                unit: .millisecondsPerSecond,
                source: .system([
                    .init(
                        name: t("ANE time"), color: .purple,
                        value: { $0.aneTimeMillisecondsPerSecond },
                        minimum: { $0.minima?.aneTimeMillisecondsPerSecond },
                        maximum: { $0.peaks?.aneTimeMillisecondsPerSecond },
                        weight: { $0.aneSampleCount.map(Double.init) })
                ]),
                note: t(
                    "Accounted ANE time per second, not percent of compute capacity. Partial readings are lower bounds. Missing readings are gaps."
                )),
            .init(
                id: "die", title: t("Die temperatures"), group: .thermals, unit: .celsius,
                source: .system([
                    .init(
                        name: t("CPU die"), color: ThermalStyle.cpu,
                        value: { $0.bucketDuration > 0 ? $0.cpuDieAverageC : $0.cpuDieC },
                        minimum: { $0.minima?.cpuDieC }, maximum: { $0.cpuDieC },
                        weight: { $0.cpuDieSampleCount.map(Double.init) }),
                    .init(
                        name: t("GPU die"), color: ThermalStyle.gpu,
                        value: { $0.bucketDuration > 0 ? $0.gpuDieAverageC : $0.gpuDieC },
                        minimum: { $0.minima?.gpuDieC }, maximum: { $0.gpuDieC },
                        weight: { $0.gpuDieSampleCount.map(Double.init) }),
                ])),
            .init(
                id: "clusterTemp", title: t("CPU cluster temperatures"), group: .thermals,
                unit: .celsius,
                source: .system([
                    .init(
                        name: t("Performance"), color: .orange, value: { $0.cpuPCoreDieC },
                        peakOnly: true),
                    .init(
                        name: t("Efficiency"), color: .teal, value: { $0.cpuECoreDieC },
                        peakOnly: true),
                ]), note: peakNote),
            .init(
                id: "enclosure", title: t("Enclosure temperatures"), group: .thermals,
                unit: .celsius,
                source: .system([
                    .init(name: t("Airflow"), color: .teal, value: { $0.airflowC }, peakOnly: true),
                    .init(
                        name: t("Skin and board"), color: .orange, value: { $0.skinC },
                        peakOnly: true),
                    .init(
                        name: t("Voltage rails"), color: .pink, value: { $0.voltageRailC },
                        peakOnly: true),
                ]), note: peakNote),
            .init(
                id: "peripheralTemp", title: t("Storage and radio temperatures"), group: .thermals,
                unit: .celsius,
                source: .system([
                    .init(
                        name: t("SSD"), color: .blue, value: { $0.ssdTemperatureC }, peakOnly: true),
                    .init(
                        name: t("Wireless"), color: .green, value: { $0.wirelessC }, peakOnly: true),
                    .init(
                        name: t("Other"), color: .orange, value: { $0.otherSensorC }, peakOnly: true
                    ),
                ]), note: peakNote),
            .init(
                id: "fans", title: t("Fans"), group: .thermals, unit: .rpm,
                source: .system([
                    .init(
                        name: t("Fastest fan"), color: .teal, value: { $0.fanRPM }, peakOnly: true)
                ]), note: peakNote),
            .init(
                id: "thermalState", title: t("Thermal state"), group: .thermals,
                unit: .thermalState,
                source: .system([
                    .init(
                        name: t("macOS thermal state"), color: .orange,
                        value: { $0.thermalPressure.map { Double($0.rawValue) } }, peakOnly: true)
                ]), fixedDomain: 0...3,
                note: t("Stored states show the worst state in each source interval.")),
            .init(
                id: "charge", title: t("Battery charge"), group: .battery, unit: .percent,
                source: .system([
                    .init(
                        name: t("Charge"), color: .green,
                        value: { hasBattery($0) ? $0.batteryCharge : nil })
                ]), fixedDomain: 0...100),
            .init(
                id: "batteryPower", title: t("Battery power"), group: .battery, unit: .watts,
                source: .system([
                    .init(
                        name: t("Power"), color: .orange,
                        value: { hasBattery($0) ? $0.batteryPowerWatts : nil })
                ])),
            .init(
                id: "batteryHealth", title: t("Battery health"), group: .battery, unit: .percent,
                source: .system([
                    .init(
                        name: t("Health"), color: .green,
                        value: { $0.batteryHealthPercent > 0 ? $0.batteryHealthPercent : nil })
                ]), fixedDomain: 0...100),
            .init(
                id: "batteryTemp", title: t("Battery temperature"), group: .battery, unit: .celsius,
                source: .system([
                    .init(
                        name: t("Temperature"), color: .teal,
                        value: {
                            $0.batteryTemperatureCelsius > 0 ? $0.batteryTemperatureCelsius : nil
                        })
                ])),
        ]
        for metric in ExplorerProcessMetric.allCases {
            definitions.append(
                .init(
                    id: "process.\(metric.rawValue)", title: processTitle(metric),
                    group: .processes, unit: processUnit(metric), source: .process(metric),
                    note: processNote(metric)))
        }
        return definitions
    }

    static var peakNote: String {
        t(
            "Stored sensor intervals contain peaks. The average of those peaks is not a time average."
        )
    }

    private static func processNote(_ metric: ExplorerProcessMetric) -> String {
        let common = t(
            "Process averages summarize recorded observations, not continuous activity. Some fields exist only in raw history."
        )
        switch metric {
        case .fileDescriptors:
            return common + " " + t("Stored descriptor counts are interval peaks.")
        case .diskRead, .diskWrite:
            return common + " "
                + t(
                    "Disk rates use changes in cumulative counters. Resets and long gaps have no rate."
                )
        case .network, .gpu:
            return common + " " + t("Older zero values can mean attribution was not recorded.")
        default: return common
        }
    }

    private static func hasBattery(_ point: SystemHistoryPoint) -> Bool {
        point.batteryCharge > 0 || point.batteryHealthPercent > 0
            || point.batteryTemperatureCelsius > 0
    }

    static func processTitle(_ metric: ExplorerProcessMetric) -> String {
        switch metric {
        case .cpu: return t("Process CPU")
        case .footprint: return t("Memory footprint")
        case .resident: return t("Resident memory")
        case .virtualMemory: return t("Virtual memory")
        case .lifetimePeak: return t("Peak footprint")
        case .threads: return t("Threads")
        case .fileDescriptors: return t("File descriptors")
        case .sockets: return t("Sockets")
        case .pipes: return t("Pipes")
        case .vnodes: return t("Open files")
        case .otherFiles: return t("Other descriptors")
        case .diskRead: return t("Attributed disk read")
        case .diskWrite: return t("Attributed disk write")
        case .network: return t("Process network")
        case .gpu: return t("Process GPU")
        case .energyImpact: return t("Energy impact")
        case .energyTotal: return t("Cumulative energy")
        case .cpuUser: return t("User CPU time")
        case .cpuSystem: return t("System CPU time")
        }
    }

    static func processUnit(_ metric: ExplorerProcessMetric) -> ExplorerUnit {
        switch metric {
        case .cpu, .gpu: return .percent
        case .footprint, .resident, .virtualMemory, .lifetimePeak: return .bytes
        case .diskRead, .diskWrite, .network: return .rate
        case .energyTotal: return .joules
        case .cpuUser, .cpuSystem: return .seconds
        default: return .count
        }
    }

    static func processValues(
        _ history: [ExplorerProcessPoint], metric: ExplorerProcessMetric
    ) -> [Double] {
        history.enumerated().map { index, point in
            guard let value = point.values[metric] else { return .nan }
            switch metric {
            case .diskRead, .diskWrite:
                guard !point.startsNewRun, index > 0,
                    let previous = history[index - 1].values[metric], value >= previous
                else { return .nan }
                let elapsed = point.date.timeIntervalSince(history[index - 1].date)
                guard elapsed > 0, elapsed <= max(120, history[index - 1].duration * 2) else {
                    return .nan
                }
                return (value - previous) / elapsed
            case .energyTotal, .cpuUser, .cpuSystem: return value / 1_000_000_000
            default: return value
            }
        }
    }

    static func processColumn(
        _ history: [ExplorerProcessPoint], metric: ExplorerProcessMetric
    ) -> LiveColumn {
        let values = processValues(history, metric: metric)
        let projected =
            metric == .diskRead || metric == .diskWrite || metric == .cpuUser
            || metric == .cpuSystem || metric == .energyTotal
        var times: [Double] = []
        var expandedValues: [Double] = []
        var highs: [Double] = []
        var lows: [Double] = []
        var weights: [Double] = []
        var durations: [Double] = []
        let restartCount = history.lazy.filter(\.startsNewRun).count
        times.reserveCapacity(history.count + restartCount)
        expandedValues.reserveCapacity(history.count + restartCount)
        highs.reserveCapacity(history.count + restartCount)
        lows.reserveCapacity(history.count + restartCount)
        weights.reserveCapacity(history.count + restartCount)
        durations.reserveCapacity(history.count + restartCount)

        for (index, point) in history.enumerated() {
            if index > 0, point.startsNewRun {
                let previous = history[index - 1].date.timeIntervalSinceReferenceDate
                let current = point.date.timeIntervalSinceReferenceDate
                times.append(previous + max(0, current - previous) / 2)
                expandedValues.append(.nan)
                highs.append(.nan)
                lows.append(.nan)
                weights.append(.nan)
                durations.append(0)
            }
            let value = values[index]
            times.append(point.date.timeIntervalSinceReferenceDate)
            expandedValues.append(value)
            highs.append(
                point.duration == 0
                    ? value : (projected ? .nan : (point.maxima[metric] ?? .nan)))
            lows.append(
                point.duration == 0
                    ? value : (projected ? .nan : (point.minima[metric] ?? .nan)))
            weights.append(point.duration == 0 ? 1 : .nan)
            durations.append(point.duration)
        }
        return LiveColumn(
            times: times[...], values: expandedValues[...], highs: highs[...], lows: lows[...],
            weights: weights[...], durations: durations[...])
    }
}
