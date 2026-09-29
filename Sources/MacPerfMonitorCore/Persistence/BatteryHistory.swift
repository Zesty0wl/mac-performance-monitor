import CryptoKit
import Foundation
import GRDB

public enum BatteryHistoryMetric: String, CaseIterable, Sendable {
    case charge, power, flow, temperature, runtime
    case fullRuntime = "full_runtime"
    case timeToFull = "to_full"

    var column: String { "energy_" + rawValue }
}

public struct BatteryHistoryPoint: Identifiable, Equatable, Sendable {
    public enum PowerState: String, Sendable {
        case battery, charging, adapter, noBattery
    }

    public var date: Date
    public var observedAt: Date
    public var duration: TimeInterval
    public var batteryID: String?
    public var state: PowerState?
    public var estimateSource: BatteryRuntimeEstimate.Source?
    public var values: [BatteryHistoryMetric: Double]
    public var minima: [BatteryHistoryMetric: Double]
    public var maxima: [BatteryHistoryMetric: Double]
    public var counts: [BatteryHistoryMetric: Double]
    public var id: Date { date }

    public init(sample: BatterySample) {
        date = sample.timestamp
        observedAt = sample.timestamp
        duration = 0
        batteryID = sample.isPresent ? BatteryIdentity.identifier(for: sample.serialNumber) : nil
        state =
            !sample.isPresent
            ? .noBattery : (sample.isCharging ? .charging : (sample.isOnAC ? .adapter : .battery))
        values = [:]
        if sample.systemPowerWatts.isFinite, sample.systemPowerWatts > 0 {
            values[.power] = sample.systemPowerWatts
        }
        estimateSource = sample.runtimeEstimate?.source
        if sample.isPresent {
            if sample.chargePercent.isFinite, (0...100).contains(sample.chargePercent) {
                values[.charge] = sample.chargePercent
            }
            if sample.voltageMilliVolts > 0, sample.powerWatts.isFinite, sample.powerWatts >= 0 {
                values[.flow] = sample.isCharging ? sample.powerWatts : -sample.powerWatts
            }
            if let temperature = sample.temperatureCelsius, temperature.isFinite {
                values[.temperature] = temperature
            }
            if state == .battery {
                if let estimate = sample.runtimeEstimate {
                    values[.runtime] = estimate.minutesRemaining
                    values[.fullRuntime] = estimate.fullChargeMinutes
                } else if let minutes = sample.timeToEmptyMinutes, minutes >= 0 {
                    values[.runtime] = Double(minutes)
                    estimateSource = .macOS
                }
            } else if state == .charging, let minutes = sample.timeToFullMinutes, minutes >= 0 {
                values[.timeToFull] = Double(minutes)
            }
        }
        values = values.filter { $0.value.isFinite }
        minima = values
        maxima = values
        counts = values.mapValues { _ in 1 }
    }

    init(row: Row, duration: TimeInterval) {
        date = Date(timeIntervalSince1970: row["energy_date"])
        observedAt = Date(
            timeIntervalSince1970: (row["energy_observed_at"] as Double?) ?? row["energy_date"])
        self.duration = duration
        batteryID = row["energy_battery_id"]
        state = (row["energy_state"] as String?).flatMap(PowerState.init(rawValue:))
        estimateSource = (row["energy_estimate_source"] as String?).flatMap(
            BatteryRuntimeEstimate.Source.init(rawValue:))
        values = [:]
        minima = [:]
        maxima = [:]
        counts = [:]
        for metric in BatteryHistoryMetric.allCases {
            if let value = row[metric.column] as Double?, value.isFinite {
                values[metric] = value
                minima[metric] = duration == 0 ? value : row[metric.column + "_min"]
                maxima[metric] = duration == 0 ? value : row[metric.column + "_max"]
                counts[metric] = duration == 0 ? 1 : row[metric.column + "_samples"]
            }
        }
        if row["energy_observed_at"] as Double? == nil {
            for (metric, column) in [
                (BatteryHistoryMetric.charge, "legacy_charge"),
                (.temperature, "legacy_temperature"),
            ] {
                guard let value = row[column] as Double?, value.isFinite else { continue }
                if metric == .charge, !(0...100).contains(value) { continue }
                if metric == .temperature, value <= 0 { continue }
                values[metric] = value
                if duration == 0 {
                    minima[metric] = value
                    maxima[metric] = value
                    counts[metric] = 1
                }
            }
        }
    }
}

public struct BatteryDailyPoint: Identifiable, Equatable, Sendable {
    public var date: Date
    public var healthPercent: Double?
    public var cycleCount: Int?
    public var fullCapacitymAh: Int?
    public var designCapacitymAh: Int?
    public var id: Date { date }

    public init(
        date: Date, healthPercent: Double? = nil, cycleCount: Int? = nil,
        fullCapacitymAh: Int? = nil, designCapacitymAh: Int? = nil
    ) {
        self.date = date
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
        self.fullCapacitymAh = fullCapacitymAh
        self.designCapacitymAh = designCapacitymAh
    }
}

public enum BatteryIdentity {
    public static func identifier(for serial: String?) -> String? {
        guard let serial else { return nil }
        let normalized = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 512 else { return nil }
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

extension SampleStore {
    public func recordDailyBattery(_ battery: BatterySample) throws {
        try databasePool.write { db in try Self.recordDailyBattery(battery, db: db) }
    }

    static func recordDailyBattery(_ battery: BatterySample, db: Database) throws {
        guard battery.isPresent,
            let identifier = BatteryIdentity.identifier(for: battery.serialNumber)
        else { return }
        let timestamp = battery.timestamp.timeIntervalSince1970
        guard timestamp.isFinite, timestamp > 0 else { return }
        let health = battery.healthPercent.flatMap {
            $0.isFinite && (0...100).contains($0) ? $0 : nil
        }
        let cycles = battery.cycleCount.flatMap { $0 >= 0 ? $0 : nil }
        let full = battery.maxCapacitymAh.flatMap { $0 > 0 ? $0 : nil }
        let design = battery.designCapacitymAh.flatMap { $0 > 0 ? $0 : nil }
        guard health != nil || cycles != nil || full != nil || design != nil else { return }
        let day = floor(timestamp / 86_400) * 86_400
        try db.cachedStatement(
            sql: """
                INSERT INTO battery_daily
                    (battery_id, day, observed_at, health_percent, cycle_count, full_capacity_mah, design_capacity_mah)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(battery_id, day) DO UPDATE SET
                    observed_at = excluded.observed_at,
                    health_percent = COALESCE(excluded.health_percent, battery_daily.health_percent),
                    cycle_count = COALESCE(excluded.cycle_count, battery_daily.cycle_count),
                    full_capacity_mah = COALESCE(excluded.full_capacity_mah, battery_daily.full_capacity_mah),
                    design_capacity_mah = COALESCE(excluded.design_capacity_mah, battery_daily.design_capacity_mah)
                WHERE excluded.observed_at >= battery_daily.observed_at
                    AND excluded.observed_at - battery_daily.observed_at >= 60
                """
        ).execute(arguments: [identifier, day, timestamp, health, cycles, full, design])
    }

    static func recordBatteryHistory(
        _ sample: BatterySample?, timestamp: Date, db: Database
    ) throws {
        guard let sample,
            sample.timestamp <= timestamp,
            timestamp.timeIntervalSince(sample.timestamp) <= 60
        else { return }
        let point = BatteryHistoryPoint(sample: sample)
        let metrics = BatteryHistoryMetric.allCases
        let assignments = metrics.map { "\($0.column) = ?" }.joined(separator: ", ")
        var arguments: [any DatabaseValueConvertible] = [
            point.batteryID, point.state?.rawValue, point.estimateSource?.rawValue,
            point.observedAt.timeIntervalSince1970,
        ]
        arguments += metrics.map { point.values[$0] as (any DatabaseValueConvertible) }
        arguments.append(timestamp.timeIntervalSince1970)
        try db.cachedStatement(
            sql: """
                UPDATE system_samples SET energy_battery_id = ?, energy_state = ?,
                    energy_estimate_source = ?, energy_observed_at = ?, \(assignments)
                WHERE timestamp = ?
                """
        ).execute(arguments: StatementArguments(arguments))
        try recordDailyBattery(sample, db: db)
    }

    public func batteryHistory(
        _ window: HistoryWindow, now: Date = Date()
    ) throws -> [BatteryHistoryPoint] {
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        let until = now.timeIntervalSince1970
        guard since.isFinite, until.isFinite else { return [] }
        return try databasePool.read { db in
            var points: [BatteryHistoryPoint] = []
            let minuteWidth = try Retention.meta(db, "minute_bucket_seconds") ?? 60
            var lower = since
            func read(_ table: String, duration: Double, through end: Double) throws {
                guard lower <= end else { return }
                let timeColumn = duration == 0 ? "timestamp" : "bucket"
                let metrics = BatteryHistoryMetric.allCases.flatMap { metric in
                    duration == 0
                        ? [metric.column]
                        : [
                            metric.column, metric.column + "_min", metric.column + "_max",
                            metric.column + "_samples",
                        ]
                }.joined(separator: ", ")
                let width = duration == 0 ? "0" : "COALESCE(bucket_seconds, \(duration))"
                let legacy =
                    duration == 0
                    ? "CASE WHEN battery_present = 1 THEN battery_charge END AS legacy_charge, CASE WHEN battery_present = 1 THEN battery_temp END AS legacy_temperature"
                    : "CASE WHEN battery_health_avg > 0 THEN battery_charge_avg END AS legacy_charge, CASE WHEN battery_health_avg > 0 THEN battery_temp_avg END AS legacy_temperature"
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT \(timeColumn) AS energy_date, energy_observed_at, energy_battery_id,
                            energy_state, energy_estimate_source, \(width) AS energy_duration, \(metrics), \(legacy)
                        FROM \(table) WHERE \(timeColumn) >= ? AND \(timeColumn) <= ?
                        ORDER BY \(timeColumn)
                        """, arguments: [lower, end])
                points += rows.map { BatteryHistoryPoint(row: $0, duration: $0["energy_duration"]) }
            }
            if window.granularity == .hour {
                lower -= 3600
                let watermark = try Retention.meta(db, "hour_watermark") ?? since
                try read("system_hour", duration: 3600, through: min(until, watermark.nextDown))
                lower = max(since, watermark)
            }
            if window.granularity != .raw {
                if window.granularity == .minute {
                    lower =
                        try Double.fetchOne(
                            db, sql: "SELECT MAX(bucket) FROM system_minute WHERE bucket < ?",
                            arguments: [since]) ?? since
                }
                let watermark = try Retention.meta(db, "minute_watermark") ?? since
                try read(
                    "system_minute", duration: minuteWidth, through: min(until, watermark.nextDown))
                lower = max(since, watermark)
            }
            try read("system_samples", duration: 0, through: until)
            return points.filter { $0.date.timeIntervalSince1970 + $0.duration >= since }
        }
    }

    static func rollBatteryHistory(
        _ db: Database, source: String, destination: String, bucket: Int,
        since: Double, until: Double
    ) throws {
        let raw = source == "system_samples"
        let time = raw ? "timestamp" : "bucket"
        var expressions = [
            "MAX(energy_observed_at) AS energy_observed_at",
            "CASE WHEN COUNT(DISTINCT energy_battery_id) = 1 THEN MIN(energy_battery_id) END AS energy_battery_id",
            "CASE WHEN COUNT(energy_state) = COUNT(*) AND MIN(energy_state) = MAX(energy_state) THEN MIN(energy_state) END AS energy_state",
            "CASE WHEN COUNT(DISTINCT energy_estimate_source) = 1 THEN MIN(energy_estimate_source) END AS energy_estimate_source",
        ]
        var columns = [
            "energy_observed_at", "energy_battery_id", "energy_state", "energy_estimate_source",
        ]
        for metric in BatteryHistoryMetric.allCases {
            let column = metric.column
            let weight = raw ? "1" : column + "_samples"
            let samePack = "COUNT(DISTINCT energy_battery_id) <= 1"
            let consistentState =
                "COUNT(energy_state) = COUNT(*) AND MIN(energy_state) = MAX(energy_state)"
            let gate: String
            switch metric {
            case .power: gate = "1"
            case .runtime, .fullRuntime, .timeToFull: gate = samePack + " AND " + consistentState
            default: gate = samePack
            }
            expressions += [
                "CASE WHEN \(gate) THEN SUM(\(column) * \(weight)) / NULLIF(SUM(CASE WHEN \(column) IS NOT NULL THEN \(weight) END), 0) END AS \(column)",
                "CASE WHEN \(gate) THEN MIN(\(raw ? column : column + "_min")) END AS \(column)_min",
                "CASE WHEN \(gate) THEN MAX(\(raw ? column : column + "_max")) END AS \(column)_max",
                "CASE WHEN \(gate) THEN SUM(CASE WHEN \(column) IS NOT NULL THEN \(weight) END) END AS \(column)_samples",
            ]
            columns += [column, column + "_min", column + "_max", column + "_samples"]
        }
        let assignments = columns.map { "\($0) = incoming.\($0)" }.joined(separator: ", ")
        try db.execute(
            sql: """
                UPDATE \(destination) AS target SET \(assignments)
                FROM (SELECT CAST(\(time) / \(bucket) AS INTEGER) * \(bucket) AS energy_bucket,
                    \(expressions.joined(separator: ", "))
                    FROM \(source) WHERE \(time) >= ? AND \(time) < ? GROUP BY energy_bucket) AS incoming
                WHERE target.bucket = incoming.energy_bucket
                """, arguments: [since, until])
    }

    public func batteryDailyHistory(
        for identifier: String, since: Date? = nil, through: Date = Date()
    ) throws -> [BatteryDailyPoint] {
        guard through.timeIntervalSince1970.isFinite else { return [] }
        let lower = since?.timeIntervalSince1970 ?? 0
        guard lower.isFinite, lower <= through.timeIntervalSince1970 else { return [] }
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT observed_at, health_percent, cycle_count, full_capacity_mah, design_capacity_mah
                    FROM battery_daily
                    WHERE battery_id = ? AND observed_at >= ? AND observed_at <= ?
                    ORDER BY day ASC
                    """, arguments: [identifier, lower, through.timeIntervalSince1970]
            ).map { row in
                BatteryDailyPoint(
                    date: Date(timeIntervalSince1970: row[0]), healthPercent: row[1],
                    cycleCount: row[2], fullCapacitymAh: row[3], designCapacitymAh: row[4])
            }
        }
    }
}
