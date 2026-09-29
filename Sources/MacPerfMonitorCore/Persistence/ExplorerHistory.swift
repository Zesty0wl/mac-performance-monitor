import Foundation
import GRDB

public enum ExplorerProcessMetric: String, CaseIterable, Sendable {
    case cpu, footprint, resident, virtualMemory, lifetimePeak, threads
    case fileDescriptors, sockets, pipes, vnodes, otherFiles
    case diskRead, diskWrite, network, gpu, energyImpact, energyTotal, cpuUser, cpuSystem

    var rawColumn: String {
        switch self {
        case .cpu: return "cpu_percent"
        case .footprint: return "phys_footprint"
        case .resident: return "resident_size"
        case .virtualMemory: return "virtual_size"
        case .lifetimePeak: return "lifetime_max_footprint"
        case .threads: return "thread_count"
        case .fileDescriptors: return "fd_total"
        case .sockets: return "fd_socket"
        case .pipes: return "fd_pipe"
        case .vnodes: return "fd_vnode"
        case .otherFiles: return "fd_other"
        case .diskRead: return "disk_read"
        case .diskWrite: return "disk_written"
        case .network: return "net_total"
        case .gpu: return "gpu_percent"
        case .energyImpact: return "energy_impact"
        case .energyTotal: return "energy"
        case .cpuUser: return "cpu_user"
        case .cpuSystem: return "cpu_system"
        }
    }

    var aggregateColumns: (value: String, minimum: String?, maximum: String?)? {
        switch self {
        case .cpu: return ("cpu_avg", nil, "cpu_max")
        case .footprint: return ("footprint_avg", "footprint_min", "footprint_max")
        case .fileDescriptors: return ("fd_max", nil, "fd_max")
        case .diskRead: return ("disk_read_max", nil, "disk_read_max")
        case .diskWrite: return ("disk_written_max", nil, "disk_written_max")
        case .network: return ("net_avg", nil, "net_max")
        case .gpu: return ("gpu_avg", nil, "gpu_max")
        case .energyImpact: return ("energy_avg", nil, "energy_max")
        default: return nil
        }
    }

    var isUnsigned: Bool {
        switch self {
        case .footprint, .resident, .virtualMemory, .lifetimePeak, .diskRead, .diskWrite,
            .energyTotal, .cpuUser, .cpuSystem:
            return true
        default: return false
        }
    }
}

public struct ExplorerProcess: Identifiable, Sendable, Equatable {
    public var id: ProcessIdentity
    public var name: String
    public var executablePath: String?
    public var bundleID: String?
    public var teamID: String?
    public var firstSeen: Date
    public var lastSeen: Date
    public var uid: Int
    public var architecture: String
    public var isTranslated: Bool

    public init(sample: ProcessSample) {
        id = sample.id
        name = sample.displayName
        executablePath = sample.executablePath
        bundleID = sample.bundleID
        teamID = sample.teamID
        firstSeen = sample.startTime
        lastSeen = sample.timestamp
        uid = Int(sample.uid)
        architecture = sample.architecture.rawValue
        isTranslated = sample.isTranslated
    }

    fileprivate init(row: Row) {
        id = ProcessIdentity(
            pid: row["pid"], startTime: Date(timeIntervalSince1970: row["start_time"]))
        let storedName: String = row["name"]
        executablePath = row["executable_path"]
        name = ProcessSample.resolvedDisplayName(name: storedName, executablePath: executablePath)
        bundleID = row["bundle_id"]
        teamID = row["team_id"]
        firstSeen = Date(timeIntervalSince1970: row["first_seen"])
        lastSeen = Date(timeIntervalSince1970: row["last_seen"])
        uid = row["uid"]
        architecture = row["architecture"]
        isTranslated = row["is_translated"]
    }
}

public struct ExplorerProcessPoint: Sendable, Equatable {
    public var date: Date
    public var duration: TimeInterval
    public var weight: Double
    public var values: [ExplorerProcessMetric: Double]
    public var minima: [ExplorerProcessMetric: Double]
    public var maxima: [ExplorerProcessMetric: Double]
    public var startsNewRun: Bool

    public init(sample: ProcessSample) {
        date = sample.timestamp
        duration = 0
        weight = 1
        values = [
            .cpu: sample.cpuPercent, .resident: Double(sample.residentSize),
            .virtualMemory: Double(sample.virtualSize),
            .lifetimePeak: Double(sample.lifetimeMaxFootprint),
            .threads: Double(sample.threadCount), .fileDescriptors: Double(sample.fdTotal),
            .sockets: Double(sample.fdSocket), .pipes: Double(sample.fdPipe),
            .vnodes: Double(sample.fdVnode), .otherFiles: Double(sample.fdOther),
            .diskRead: Double(sample.diskBytesRead), .diskWrite: Double(sample.diskBytesWritten),
            .network: sample.networkBytesPerSec, .energyImpact: sample.energyImpact,
            .energyTotal: Double(sample.energyNanojoules), .cpuUser: Double(sample.cpuTimeUser),
            .cpuSystem: Double(sample.cpuTimeSystem),
        ]
        if sample.footprintReadable { values[.footprint] = Double(sample.physFootprint) }
        values[.gpu] = sample.gpuPercent
        minima = values
        maxima = values
        startsNewRun = false
    }

    fileprivate init(row: Row, duration: TimeInterval) {
        self.duration = (row["explorer_duration"] as Double?) ?? duration
        weight = duration > 0 ? (row["samples"] as Double) : 1
        date = Date(timeIntervalSince1970: row[duration > 0 ? "bucket" : "timestamp"])
        values = [:]
        minima = [:]
        maxima = [:]
        startsNewRun = false
        for metric in ExplorerProcessMetric.allCases {
            func value(_ column: String?) -> Double? {
                guard let column else { return nil }
                if metric.isUnsigned {
                    return (row[column] as Int64?).map { Double(SQLInt.read($0)) }
                }
                return row[column] as Double?
            }
            if duration > 0, let columns = metric.aggregateColumns {
                values[metric] = value(columns.value)
                minima[metric] = value(columns.minimum)
                maxima[metric] = value(columns.maximum)
                if let average = values[metric] {
                    if let minimum = minima[metric], minimum > average { minima[metric] = nil }
                    if let maximum = maxima[metric], maximum < average { maxima[metric] = nil }
                }
            } else if duration == 0 {
                if metric == .footprint, !(row["footprint_readable"] as Bool) { continue }
                values[metric] = value(metric.rawColumn)
                minima[metric] = values[metric]
                maxima[metric] = values[metric]
            }
        }
    }
}

public struct ExplorerProcessHistory: Sendable {
    public var process: ExplorerProcess
    public var points: [ExplorerProcessPoint]

    public init(process: ExplorerProcess, points: [ExplorerProcessPoint]) {
        self.process = process
        self.points = points
    }
}

public struct ExplorerProcessObservation: Identifiable, Sendable {
    public var process: ExplorerProcess
    public var point: ExplorerProcessPoint
    public var id: ProcessIdentity { process.id }

    public init(process: ExplorerProcess, point: ExplorerProcessPoint) {
        self.process = process
        self.point = point
    }
}

public struct ExplorerStoredField: Identifiable, Sendable, Equatable {
    public var name: String
    public var value: String?
    public var id: String { name }
}

public struct ExplorerMachineRecord: Sendable {
    public var date: Date
    public var source: String
    public var fields: [ExplorerStoredField]
}

public struct ExplorerWindowData: Sendable {
    public var domain: ClosedRange<Date>
    public var granularity: HistoryWindow.Granularity
    public var system: [SystemHistoryPoint]
    public var processes: [ExplorerProcessHistory]

    public init(
        domain: ClosedRange<Date>, granularity: HistoryWindow.Granularity,
        system: [SystemHistoryPoint], processes: [ExplorerProcessHistory]
    ) {
        self.domain = domain
        self.granularity = granularity
        self.system = system
        self.processes = processes
    }
}

extension SystemHistoryPoint {
    public init(sample: SystemSample) {
        self.init(
            date: sample.timestamp, pressurePercent: sample.pressurePercent,
            appMemory: sample.appMemory, wired: sample.wired, compressed: sample.compressed,
            cachedFiles: sample.cachedFiles, swapUsed: sample.swapUsed, cpuLoad: sample.cpuLoad,
            loadAverage1: sample.loadAverage1, loadAverage5: sample.loadAverage5,
            loadAverage15: sample.loadAverage15,
            batteryCharge: sample.batteryCharge, batteryPowerWatts: sample.batteryPowerWatts,
            batteryHealthPercent: sample.batteryHealthPercent,
            batteryTemperatureCelsius: sample.batteryTemperatureCelsius,
            networkInBytesPerSec: sample.networkInBytesPerSec,
            networkOutBytesPerSec: sample.networkOutBytesPerSec,
            diskReadBytesPerSec: sample.diskReadBytesPerSec,
            diskWriteBytesPerSec: sample.diskWriteBytesPerSec,
            diskReadOperationsPerSec: sample.diskReadOperationsPerSec,
            diskWriteOperationsPerSec: sample.diskWriteOperationsPerSec,
            diskReadLatencyMs: sample.diskReadLatencyMs,
            diskWriteLatencyMs: sample.diskWriteLatencyMs,
            diskUtilizationPercent: sample.diskUtilizationPercent,
            bootFreeBytes: sample.bootVolumeFreeBytes,
            bootTotalBytes: sample.bootVolumeTotalBytes, gpuUtilization: sample.gpuUtilization,
            gpuPowerWatts: sample.gpuPowerWatts,
            gpuMemoryBytes: sample.gpuMemoryBytes.map { Double($0) },
            gpuMemorySampleCount: sample.gpuMemoryBytes == nil ? 0 : 1,
            gpuActiveResidency: sample.gpuActiveResidency,
            gpuActiveSampleCount: sample.gpuActiveResidency == nil ? 0 : 1,
            gpuReadBandwidthGBps: sample.gpuReadBandwidthGBps,
            gpuReadBandwidthSampleCount: sample.gpuReadBandwidthGBps == nil ? 0 : 1,
            gpuWriteBandwidthGBps: sample.gpuWriteBandwidthGBps,
            gpuWriteBandwidthSampleCount: sample.gpuWriteBandwidthGBps == nil ? 0 : 1,
            gpuTotalBandwidthGBps: sample.gpuTotalBandwidthGBps,
            gpuTotalBandwidthSampleCount: sample.gpuTotalBandwidthGBps == nil ? 0 : 1,
            anePowerWatts: sample.reportedANEPowerWatts,
            anePowerSampleCount: sample.reportedANEPowerWatts == nil ? 0 : 1,
            aneTimeMillisecondsPerSecond: sample.aneTimeMillisecondsPerSecond,
            aneSampleIsPartial: sample.aneSampleIsPartial,
            aneSampleCount: sample.aneTimeMillisecondsPerSecond == nil ? 0 : 1,
            cpuDieC: sample.cpuDieC, gpuDieC: sample.gpuDieC,
            ssdTemperatureC: sample.ssdTemperatureC,
            fanRPM: sample.fanRPM, thermalPressure: sample.thermalPressure,
            cpuPCoreDieC: sample.cpuPCoreDieC, cpuECoreDieC: sample.cpuECoreDieC,
            airflowC: sample.airflowC, skinC: sample.skinC, wirelessC: sample.wirelessC,
            voltageRailC: sample.voltageRailC, otherSensorC: sample.otherSensorC)
    }
}

extension SampleStore {
    public func explorerMachineRecordAt(
        _ date: Date, granularity: HistoryWindow.Granularity, rawFreshness: TimeInterval = 15
    ) throws -> ExplorerMachineRecord? {
        try databasePool.read { db in
            let table: String
            let timeColumn: String
            let resolution: Double
            switch granularity {
            case .raw:
                table = "system_samples"
                timeColumn = "timestamp"
                resolution = rawFreshness
            case .minute:
                table = "system_minute"
                timeColumn = "bucket"
                resolution = try Retention.meta(db, "minute_bucket_seconds") ?? 60
            case .hour:
                table = "system_hour"
                timeColumn = "bucket"
                resolution = 3600
            }
            let time = date.timeIntervalSince1970
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM \(table) WHERE \(timeColumn) <= ?
                        ORDER BY \(timeColumn) DESC LIMIT 1
                        """, arguments: [time])
            else { return nil }
            let observed: Double = row[timeColumn]
            let duration =
                granularity == .raw
                ? resolution : ((row["bucket_seconds"] as Double?) ?? resolution)
            guard granularity == .raw ? time - observed <= duration : time < observed + duration
            else { return nil }
            let fields = row.map { name, value -> ExplorerStoredField in
                let text: String?
                switch value.storage {
                case .null: text = nil
                case .int64(let value): text = String(value)
                case .double(let value): text = value.isFinite ? String(value) : nil
                case .string(let value): text = value
                case .blob: text = nil
                }
                return ExplorerStoredField(name: name, value: text)
            }
            return ExplorerMachineRecord(
                date: Date(timeIntervalSince1970: observed), source: table, fields: fields)
        }
    }

    public func explorerProcessesAt(
        _ date: Date, granularity: HistoryWindow.Granularity,
        rawFreshness: TimeInterval = 60, limit: Int = 200
    ) throws -> [ExplorerProcessObservation] {
        try databasePool.read { db in
            let time = date.timeIntervalSince1970
            let table: String
            let timeColumn: String
            let duration: Double
            let cpu: String
            switch granularity {
            case .raw:
                table = "process_samples"
                timeColumn = "timestamp"
                duration = 0
                cpu = "cpu_percent"
            case .minute:
                table = "process_minute"
                timeColumn = "bucket"
                duration = try Self.explorerMinuteWidth(db, at: time)
                cpu = "cpu_avg"
            case .hour:
                table = "process_hour"
                timeColumn = "bucket"
                duration = 3600
                cpu = "cpu_avg"
            }
            let cutoff = time - max(duration, rawFreshness)
            let sourceDuration =
                granularity == .minute
                ? "COALESCE((SELECT bucket_seconds FROM system_minute WHERE bucket = s.bucket), \(duration))"
                : String(duration)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH latest AS (
                        SELECT process_id, MAX(\(timeColumn)) AS observed
                        FROM \(table) WHERE \(timeColumn) >= ? AND \(timeColumn) <= ?
                        GROUP BY process_id
                    )
                    SELECT p.*, s.*, \(sourceDuration) AS explorer_duration FROM latest
                    JOIN \(table) s ON s.process_id = latest.process_id AND s.\(timeColumn) = latest.observed
                    JOIN processes p ON p.id = s.process_id
                    ORDER BY s.\(cpu) DESC, p.id LIMIT ?
                    """, arguments: [cutoff, time, max(1, min(limit, 1000))])
            return rows.compactMap { row in
                let point = ExplorerProcessPoint(row: row, duration: duration)
                if point.duration > 0, date >= point.date.addingTimeInterval(point.duration) {
                    return nil
                }
                return ExplorerProcessObservation(process: ExplorerProcess(row: row), point: point)
            }
        }
    }

    public func explorerProcesses(
        from: Date, to: Date, search: String = "", limit: Int = 300
    ) throws -> [ExplorerProcess] {
        guard from <= to else { return [] }
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM processes
                    WHERE first_seen <= ? AND last_seen >= ?
                      AND (? = '' OR instr(lower(name || ' ' || COALESCE(executable_path, '') || ' ' || pid), lower(?)) > 0)
                    ORDER BY last_seen DESC, id DESC LIMIT ?
                    """,
                arguments: [
                    to.timeIntervalSince1970, from.timeIntervalSince1970,
                    search, search, max(1, min(limit, 1000)),
                ]
            )
            .map(ExplorerProcess.init(row:))
        }
    }

    public func explorerProcessHistories(
        identities: [ProcessIdentity], from: Date, to: Date,
        granularity: HistoryWindow.Granularity, maximumPointCount: Int = 60_000
    ) throws -> [ExplorerProcessHistory] {
        guard from <= to, !identities.isEmpty else { return [] }
        return try databasePool.read { db in
            var result: [ExplorerProcessHistory] = []
            var remaining = max(0, maximumPointCount)
            let minuteWidth = try Self.explorerMinuteWidth(db, at: from.timeIntervalSince1970)
            let minuteWatermark =
                try Retention.meta(db, "minute_watermark") ?? from.timeIntervalSince1970
            let hourWatermark =
                try Retention.meta(db, "hour_watermark") ?? from.timeIntervalSince1970
            for identity in Array(Set(identities)).sorted(by: { $0.pid < $1.pid }).prefix(8) {
                guard
                    let row = try Row.fetchOne(
                        db, sql: "SELECT * FROM processes WHERE pid = ? AND start_time = ?",
                        arguments: [identity.pid, identity.startTime.timeIntervalSince1970])
                else { continue }
                let paddedFrom =
                    from.timeIntervalSince1970
                    - (granularity == .hour ? 3600 : (granularity == .minute ? minuteWidth : 0))
                let upper = to.timeIntervalSince1970
                let runs = try Self.processLineageRuns(
                    db, for: identity, from: paddedFrom, to: upper)
                var points: [ExplorerProcessPoint] = []
                for run in runs {
                    var runPoints: [ExplorerProcessPoint] = []
                    var lower = paddedFrom
                    func read(_ table: String, duration: Double, until: Double) throws {
                        guard lower <= until else { return }
                        let timeColumn = duration == 0 ? "timestamp" : "bucket"
                        let sourceDuration =
                            table == "process_minute"
                            ? "COALESCE((SELECT bucket_seconds FROM system_minute WHERE bucket = source.bucket), \(duration))"
                            : String(duration)
                        let rows = try Row.fetchAll(
                            db,
                            sql: """
                                SELECT source.*, \(sourceDuration) AS explorer_duration FROM \(table) source WHERE process_id = ?
                                  AND \(timeColumn) >= ? AND \(timeColumn) <= ?
                                ORDER BY \(timeColumn) LIMIT ?
                                """, arguments: [run.databaseID, lower, until, remaining + 1])
                        guard rows.count <= remaining else {
                            throw ProcessHistoryReadError.pointLimitExceeded(maximumPointCount)
                        }
                        remaining -= rows.count
                        runPoints += rows.map {
                            ExplorerProcessPoint(row: $0, duration: duration)
                        }
                    }
                    if granularity == .hour {
                        try read(
                            "process_hour", duration: 3600,
                            until: min(upper, hourWatermark.nextDown))
                        lower = max(lower, hourWatermark)
                    }
                    if granularity != .raw {
                        try read(
                            "process_minute", duration: minuteWidth,
                            until: min(upper, minuteWatermark.nextDown))
                        lower = max(lower, minuteWatermark)
                    }
                    try read("process_samples", duration: 0, until: upper)
                    runPoints.removeAll {
                        $0.date < from
                            && ($0.duration == 0
                                || $0.date.addingTimeInterval($0.duration) <= from)
                    }
                    if !points.isEmpty, !runPoints.isEmpty { runPoints[0].startsNewRun = true }
                    points += runPoints
                }
                result.append(
                    ExplorerProcessHistory(process: ExplorerProcess(row: row), points: points))
            }
            return result
        }
    }

    private static func explorerMinuteWidth(_ db: Database, at time: Double) throws -> Double {
        let fallback = try Retention.meta(db, "minute_bucket_seconds") ?? 60
        return try Double.fetchOne(
            db,
            sql: """
                SELECT COALESCE(bucket_seconds, ?) FROM system_minute
                WHERE bucket <= ? ORDER BY bucket DESC LIMIT 1
                """, arguments: [fallback, time]) ?? fallback
    }
}
