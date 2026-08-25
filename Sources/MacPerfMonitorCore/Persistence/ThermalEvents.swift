import Foundation
import GRDB

/// A moment when macOS's thermal pressure stepped up into serious or critical
/// (the throttling states), with the process that was the largest CPU consumer
/// at that instant. The CPU attribution is the actionable half: "my fans are
/// loud" almost always ends at a process name.
public struct ThermalEvent: Sendable, Identifiable, Equatable {
    public var date: Date
    /// The state pressure rose into (serious or critical).
    public var state: ThermalPressureState
    public var dominantIdentity: ProcessIdentity?
    public var dominantName: String?
    /// CPU share of the dominant process at the event (Activity Monitor
    /// convention: percent of one core, so multi-threaded work exceeds 100).
    public var dominantCPUPercent: Double

    public var id: Date { date }

    public init(
        date: Date,
        state: ThermalPressureState,
        dominantIdentity: ProcessIdentity?,
        dominantName: String?,
        dominantCPUPercent: Double
    ) {
        self.date = date
        self.state = state
        self.dominantIdentity = dominantIdentity
        self.dominantName = dominantName
        self.dominantCPUPercent = dominantCPUPercent
    }
}

extension SampleStore {
    /// Hour-tier fan/die pairs for the thermal drift analysis: every
    /// `system_hour` bucket in the interval that carries both a fan speed and
    /// a CPU die temperature, oldest first.
    public func fanTempHours(from: Date, to: Date) throws -> [FanTempHour] {
        try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT bucket, fan_rpm_avg, cpu_die_avg FROM system_hour
                    WHERE bucket >= ? AND bucket < ?
                      AND fan_rpm_avg IS NOT NULL AND cpu_die_avg IS NOT NULL
                    ORDER BY bucket ASC
                    """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]
            ).map { row in
                FanTempHour(
                    date: Date(timeIntervalSince1970: row[0]), fanRPM: row[1], dieC: row[2])
            }
        }
    }

    /// Thermal throttling events in the window, most recent first. An event is
    /// recorded each time the thermal pressure state steps up into
    /// serious-or-higher. The dominant process is the largest CPU consumer
    /// logged as of the event's tick, with the same carry-forward-within-one-
    /// heartbeat-bucket attribution as `pressureEvents` (process rows are
    /// change-gated, so most processes have no row at the exact event second;
    /// the staleness bound keeps dead processes from being crowned). Like
    /// pressure events, the window is clamped to raw retention.
    public func thermalEvents(
        window: TimeInterval = 2 * 3600, bucket: TimeInterval = 60, now: Date = Date()
    ) throws -> [ThermalEvent] {
        let since = now.addingTimeInterval(-min(window, 2 * 3600))
        return try databasePool.read { db in
            let sampleRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT timestamp, thermal_state FROM system_samples
                    WHERE timestamp >= ? AND thermal_state IS NOT NULL
                    ORDER BY timestamp ASC
                    """, arguments: [since.timeIntervalSince1970])
            var steps: [(ts: Double, state: ThermalPressureState)] = []
            var previous: ThermalPressureState?
            for row in sampleRows {
                guard let state = ThermalPressureState(rawValue: row[1]) else { continue }
                let ts: Double = row[0]
                if let prev = previous, state > prev, state.isThrottling {
                    steps.append((ts, state))
                }
                previous = state
            }
            guard !steps.isEmpty else { return [] }

            let lastStepTs = steps.map(\.ts).max() ?? since.timeIntervalSince1970
            let procRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT ps.timestamp AS ts, p.pid AS pid, p.start_time AS pstart,
                           p.name AS name, ps.cpu_percent AS cpu
                    FROM process_samples ps
                    JOIN processes p ON p.id = ps.process_id
                    WHERE ps.timestamp >= ? AND ps.timestamp <= ?
                    ORDER BY ps.timestamp ASC
                    """, arguments: [since.timeIntervalSince1970, lastStepTs])

            struct Carried {
                var ts: Double
                var cpu: Double
                var name: String
            }
            var current: [ProcessIdentity: Carried] = [:]
            var dominantByTS: [Double: (identity: ProcessIdentity, name: String, cpu: Double)] =
                [:]
            var ri = 0
            let staleWindow = max(bucket, 1)
            for step in steps {
                while ri < procRows.count, (procRows[ri]["ts"] as Double) <= step.ts {
                    let pid: Int32 = procRows[ri]["pid"]
                    let start: Double = procRows[ri]["pstart"]
                    let id = ProcessIdentity(
                        pid: pid, startTime: Date(timeIntervalSince1970: start))
                    current[id] = Carried(
                        ts: procRows[ri]["ts"], cpu: procRows[ri]["cpu"],
                        name: procRows[ri]["name"])
                    ri += 1
                }
                let floorTs = step.ts - staleWindow
                var best: (identity: ProcessIdentity, name: String, cpu: Double)?
                for (id, c) in current where c.ts >= floorTs {
                    if best == nil || c.cpu > best!.cpu {
                        best = (identity: id, name: c.name, cpu: c.cpu)
                    }
                }
                dominantByTS[step.ts] = best
            }

            return
                steps
                .map { step in
                    let dominant = dominantByTS[step.ts]
                    return ThermalEvent(
                        date: Date(timeIntervalSince1970: step.ts),
                        state: step.state,
                        dominantIdentity: dominant?.identity,
                        dominantName: dominant?.name,
                        dominantCPUPercent: dominant?.cpu ?? 0
                    )
                }
                .sorted { $0.date > $1.date }
        }
    }
}
