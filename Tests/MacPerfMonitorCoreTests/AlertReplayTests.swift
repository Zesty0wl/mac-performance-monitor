import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class AlertReplayTests: XCTestCase {
    func testRecordedSwapReplayReadOnlyWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["MACPERF_ALERT_REPLAY_DATABASE"] else {
            throw XCTSkip(
                "Set MACPERF_ALERT_REPLAY_DATABASE to replay recorded swap without notifications")
        }
        var configuration = Configuration()
        configuration.readonly = true
        let pool = try DatabasePool(path: path, configuration: configuration)
        let (ram, rows) = try pool.read { database in
            let ram =
                try Int64.fetchOne(
                    database,
                    sql: "SELECT total_ram FROM system_samples ORDER BY timestamp DESC LIMIT 1")
                ?? 0
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT bucket, swap_used_avg, pressure_max, pressure_avg, COALESCE(bucket_seconds,60) AS seconds
                    FROM system_minute WHERE bucket >= (SELECT MAX(bucket) FROM system_minute) - 172800
                    ORDER BY bucket
                    """)
            return (ram, rows)
        }
        let engine = AlertEngine()
        let config = AlertConfig(
            criticalPressureEnabled: false, swapEnabled: true, leakEnabled: false)
        var notices: [Alert] = []
        for row in rows {
            let date = Date(
                timeIntervalSince1970: (row["bucket"] as Double) + (row["seconds"] as Double))
            let peak: Double = row["pressure_max"]
            var sample = Make.system(
                timestamp: date, swapUsed: SQLInt.read(row["swap_used_avg"]),
                pressure: peak >= 67 ? .critical : (peak >= 34 ? .warning : .normal))
            sample.totalRAM = SQLInt.read(ram)
            sample.pressurePercent = row["pressure_avg"]
            let result = engine.evaluate(
                system: sample, processes: [], config: config, expectedInterval: 60)
            XCTAssertTrue(result.allSatisfy { ($0.evidence?.end ?? $0.date) <= date })
            notices += result
        }
        print(
            "ALERT REPLAY: \(rows.count) retained minute means, \(notices.count) candidate swap notices; paging counters unavailable for this legacy history"
        )
        for alert in notices {
            guard let evidence = alert.evidence else { continue }
            print(
                String(
                    format: "ALERT REPLAY %@: %.2f -> %.2f GiB, %@",
                    evidence.end.formatted(date: .numeric, time: .shortened),
                    evidence.baseline / 1_073_741_824, evidence.current / 1_073_741_824,
                    alert.previousNotification == nil ? "new" : "worsening"))
        }
        let formatter = ISO8601DateFormatter()
        let burst = try XCTUnwrap(formatter.date(from: "2026-09-09T08:16:00Z"))
        if let first = rows.first, let last = rows.last,
            (first["bucket"] as Double) <= burst.timeIntervalSince1970,
            (last["bucket"] as Double) >= burst.timeIntervalSince1970 + 600
        {
            XCTAssertTrue(
                notices.contains { alert in
                    let end = alert.evidence?.end ?? alert.date
                    return end >= burst && end <= burst.addingTimeInterval(720)
                }, "The audited ten-minute growth episode must be detected")
        }
        let night = try XCTUnwrap(formatter.date(from: "2026-09-09T19:00:00Z"))
        let overnightNotices = notices.filter { alert in
            let end = alert.evidence?.end ?? alert.date
            return end >= night && end < night.addingTimeInterval(12 * 3600)
        }
        print("ALERT REPLAY settled overnight: \(overnightNotices.count) candidate notices")
    }

    func testSteadyWorkloadStaysQuietWithBoundedLiveEvidence() {
        let monitor = ProcessGrowthMonitor()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let started = Date()
        for step in 0...80 {
            let date = start.addingTimeInterval(Double(step) * 30)
            let processes = (0..<700).map { index in
                Make.process(
                    timestamp: date, pid: Int32(100 + index), startTime: start,
                    footprint: UInt64(100 + index) * 1024 * 1024)
            }
            XCTAssertTrue(
                monitor.evaluate(
                    processes, totalRAM: 18 * 1024 * 1024 * 1024,
                    now: date, maximumGap: 120
                ).conditions.isEmpty)
        }
        let seconds = Date().timeIntervalSince(started)
        print(
            String(
                format:
                    "ALERT REPLAY steady workload: 700 processes, 81 updates, %.3f s total, %.2f ms per 30 s update",
                seconds, seconds * 1000 / 81))
    }
}
