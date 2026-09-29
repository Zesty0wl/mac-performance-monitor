import Foundation
import GRDB

extension SampleStore {
    public func usageTimeline(
        for identity: ProcessIdentity, window: HistoryWindow, now: Date = Date()
    ) throws -> UsageTimeline.ObservedHistory {
        let until = now.timeIntervalSince1970
        let since = until - window.seconds
        guard since.isFinite, until.isFinite, identity.startTime.timeIntervalSince1970.isFinite
        else { return .init(intervals: [], bucketSeconds: 60) }

        return try databasePool.read { db in
            let configuredBucket = try Retention.meta(db, "minute_bucket_seconds") ?? 60
            let minuteBucket =
                configuredBucket.isFinite && configuredBucket > 0
                ? min(configuredBucket, 3600) : 60
            let width = window.granularity == .hour ? 3600 : max(60, minuteBucket)
            guard
                let processID = try Int64.fetchOne(
                    db, sql: "SELECT id FROM processes WHERE pid = ? AND start_time = ?",
                    arguments: [identity.pid, identity.startTime.timeIntervalSince1970])
            else { return .init(intervals: [], bucketSeconds: width) }

            var tables = [("process_samples", "timestamp")]
            if window.granularity != .raw { tables.append(("process_minute", "bucket")) }
            if window.granularity == .hour { tables.append(("process_hour", "bucket")) }
            var intervals: [UsageTimeline.Interval] = []
            for (table, timeColumn) in tables {
                let buckets = try Double.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT CAST(\(timeColumn) / ? AS INTEGER) * ? AS observed_bucket
                        FROM \(table)
                        WHERE process_id = ? AND \(timeColumn) >= ? AND \(timeColumn) <= ?
                        ORDER BY observed_bucket
                        LIMIT 20001
                        """, arguments: [width, width, processID, since - width, until])
                guard buckets.count <= 20000 else {
                    throw ProcessHistoryReadError.pointLimitExceeded(20000)
                }
                intervals += buckets.map { bucket in
                    UsageTimeline.Interval(
                        kind: .observedRunning,
                        start: max(Date(timeIntervalSince1970: bucket), identity.startTime),
                        end: Date(timeIntervalSince1970: bucket + width))
                }
            }
            return UsageTimeline.ObservedHistory(
                intervals: UsageTimeline.normalized(
                    intervals, within: Date(timeIntervalSince1970: since)...now),
                bucketSeconds: width)
        }
    }
}
