import Foundation
import GRDB

/// Configurable retention windows (PRD section 6). All windows are user-tunable
/// in Settings.
public struct RetentionPolicy: Sendable, Equatable {
    /// Raw samples retained this long.
    public var rawWindow: TimeInterval
    /// 1-minute aggregates retained this long.
    public var minuteWindow: TimeInterval
    /// The width (in seconds) of a "standard-resolution" aggregate bucket. The
    /// minute tier rolls raw samples into buckets of this size; user-configurable
    /// (default 60). The hour tier stays fixed at 3600.
    public var standardResBucket: TimeInterval
    /// 1-hour aggregates retained this long.
    public var hourWindow: TimeInterval
    /// Hard cap on the database's on-disk size in bytes, enforced after the
    /// time-based trim. When exceeded, the oldest samples are dropped — finest
    /// tier first (raw, then minute, then hour) — so size pressure costs
    /// resolution rather than the long low-res trend. Nil means no size cap.
    public var maxBytes: Int?

    public init(
        rawWindow: TimeInterval = 2 * 3600,
        minuteWindow: TimeInterval = 7 * 86_400,
        standardResBucket: TimeInterval = 60,
        hourWindow: TimeInterval = 90 * 86_400,
        maxBytes: Int? = nil
    ) {
        self.rawWindow = rawWindow
        self.minuteWindow = minuteWindow
        self.standardResBucket = standardResBucket
        self.hourWindow = hourWindow
        self.maxBytes = maxBytes
    }

    public static let `default` = RetentionPolicy()
}

/// Periodic maintenance: rolls raw samples into 1-minute aggregates, minute into
/// hour, and trims each tier to its retention window. Runs off the sampling path.
///
/// Aggregation is incremental and idempotent via watermarks stored in `meta`, so
/// it only ever scans buckets it has not already finalised.
public enum Retention {
    /// Run one maintenance pass.
    ///
    /// Each step commits its own short transaction rather than sharing one big
    /// one: the pass runs on a background maintenance queue while the sampler's
    /// per-tick persist may be waiting on the pool's writer, so bounding each
    /// writer-lock hold keeps that wait to a single step. A crash mid-pass
    /// loses nothing — the watermark design makes every step idempotent, and
    /// the next pass completes whatever was cut short.
    public static func run(
        _ pool: DatabasePool, now: Date = Date(), policy: RetentionPolicy = .default
    ) throws {
        let nowTS = now.timeIntervalSince1970
        try pool.write { db in
            try realignMinuteBucketIfNeeded(db, bucket: policy.standardResBucket)
            try rollRawToMinute(db, nowTS: nowTS, bucket: policy.standardResBucket)
        }
        try pool.write { db in try rollMinuteToHour(db, nowTS: nowTS) }
        try trim(pool, nowTS: nowTS, policy: policy)
        // Return time-trimmed free pages to the OS every pass — auto_vacuum
        // INCREMENTAL never reclaims them on its own, so a file that grew then
        // trimmed would stay large. Bounded per pass so the write stays short.
        try pool.write { db in try db.execute(sql: "PRAGMA incremental_vacuum(2000)") }
        if let maxBytes = policy.maxBytes {
            try enforceSizeLimit(pool, maxBytes: maxBytes)
        }
        // Keep the planner's statistics fresh with a bounded incremental
        // ANALYZE. Without statistics the windowed leaderboards fall back to
        // full-tier scans instead of the v9 covering indexes / PK skip-scans.
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA analysis_limit = 400")
            try db.execute(sql: "PRAGMA optimize")
        }
    }

    // MARK: - Size cap

    /// Pool-level size-cap enforcement for the live maintenance pass: each
    /// deletion batch commits its own transaction, so even a large cap
    /// reduction (up to `maxDeletePerPass` rows per pass) never holds the
    /// writer lock for more than one batch while the sampler's persist waits.
    static func enforceSizeLimit(_ pool: DatabasePool, maxBytes: Int) throws {
        // Cheap early-out without taking the writer at all.
        let overCap = try pool.read { db in
            try usedBytes(db) > maxBytes
        }
        guard overCap else { return }
        var converged = false
        var safety = 50  // 500,000 rows / 10,000-row batch
        while !converged, safety > 0 {
            safety -= 1
            converged = try pool.write { db in
                try enforceSizeLimitStep(db, maxBytes: maxBytes)
            }
        }
    }

    /// Total pages in use (excluding the freelist) times the page size.
    private static func usedBytes(_ db: Database) throws -> Int {
        let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
        let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
        let freelist = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        return max(0, pageCount - freelist) * pageSize
    }

    /// One bounded deletion step for the pool-level path. Deletes up to one
    /// batch from the finest non-empty tier that is still over cap. Returns
    /// true when the database is within `maxBytes` (or nothing is left to
    /// delete), i.e. the caller can stop.
    private static func enforceSizeLimitStep(_ db: Database, maxBytes: Int) throws -> Bool {
        // Bounded vacuum, like run()'s per-pass reclaim: the argless form
        // relocates the ENTIRE freelist in this write transaction — after a
        // big trim that is seconds of writer-lock hold, exactly what the
        // batching here exists to avoid. Whatever a bounded pass leaves, the
        // next minutely retention pass reclaims.
        guard try usedBytes(db) > maxBytes else {
            try db.execute(sql: "PRAGMA incremental_vacuum(2000)")
            return true
        }
        let tiers: [(table: String, column: String)] = [
            ("process_samples", "timestamp"),
            ("system_samples", "timestamp"),
            ("process_minute", "bucket"),
            ("system_minute", "bucket"),
            ("process_hour", "bucket"),
            ("system_hour", "bucket"),
        ]
        for tier in tiers {
            try db.execute(
                sql: """
                    DELETE FROM \(tier.table) WHERE rowid IN (
                        SELECT rowid FROM \(tier.table) ORDER BY \(tier.column) ASC LIMIT ?
                    )
                    """, arguments: [10_000])
            if db.changesCount > 0 {
                try db.execute(sql: "PRAGMA incremental_vacuum(2000)")
                return try usedBytes(db) <= maxBytes
            }
        }
        return true  // every tier empty; nothing more to delete
    }

    /// Trim the oldest samples until the database's used size is within
    /// `maxBytes`, finest tier first (raw → minute → hour), then reclaim the
    /// freed pages. Each pass deletes at most `maxDeletePerPass` rows so one run
    /// can never lock the writer for long after a big cap reduction; the next
    /// scheduled pass continues until the database has converged.
    static func enforceSizeLimit(_ db: Database, maxBytes: Int) throws {
        let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
        func usedBytes() throws -> Int {
            let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let freelist = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            return max(0, pageCount - freelist) * pageSize
        }
        guard try usedBytes() > maxBytes else { return }

        // Oldest first within each tier; the finest tier is sacrificed first.
        let tiers: [(table: String, column: String)] = [
            ("process_samples", "timestamp"),
            ("system_samples", "timestamp"),
            ("process_minute", "bucket"),
            ("system_minute", "bucket"),
            ("process_hour", "bucket"),
            ("system_hour", "bucket"),
        ]
        let batch = 10_000
        let maxDeletePerPass = 500_000
        var deletedThisPass = 0

        tierLoop: for tier in tiers {
            while try usedBytes() > maxBytes, deletedThisPass < maxDeletePerPass {
                try db.execute(
                    sql: """
                        DELETE FROM \(tier.table) WHERE rowid IN (
                            SELECT rowid FROM \(tier.table) ORDER BY \(tier.column) ASC LIMIT ?
                        )
                        """, arguments: [batch])
                let deleted = db.changesCount
                deletedThisPass += deleted
                if deleted == 0 { break }  // this tier is empty; fall through to next
            }
            if try usedBytes() <= maxBytes || deletedThisPass >= maxDeletePerPass {
                break tierLoop
            }
        }

        // Return the freed pages to the OS so the file actually shrinks (needs
        // incremental auto-vacuum; a no-op otherwise, but the freed pages are
        // then reused by future inserts so the file still stops growing).
        try db.execute(sql: "PRAGMA incremental_vacuum")
    }

    // MARK: - Raw -> minute

    /// If the configured standard-res bucket width changed, advance the minute
    /// watermark up to the next boundary of the NEW width before rolling. Without
    /// this, a coarser new bucket key can collide with an existing finer-bucket
    /// row and the roll's `ON CONFLICT DO UPDATE` would overwrite it — silently
    /// losing that sliver of minute-tier detail. Raw still holds the skipped
    /// span. Idempotent: the active width is recorded in `meta`, so an unchanged
    /// width is a no-op and a first run on a legacy DB just records 60.
    static func realignMinuteBucketIfNeeded(_ db: Database, bucket: Double) throws {
        let stored = try meta(db, "minute_bucket_seconds")
        guard stored != bucket else { return }
        if let watermark = try meta(db, "minute_watermark"), watermark > 0, bucket > 0 {
            let aligned = (watermark / bucket).rounded(.up) * bucket
            if aligned != watermark { try setMeta(db, "minute_watermark", aligned) }
        }
        try setMeta(db, "minute_bucket_seconds", bucket)
    }

    static func rollRawToMinute(_ db: Database, nowTS: Double, bucket: Double = 60) throws {
        let watermark = try meta(db, "minute_watermark") ?? 0
        // The standard-res bucket width in whole seconds, interpolated into the
        // GROUP BY below. It is a controlled preset (60/120/300…), never user
        // free-text, so string-interpolating it into the SQL is safe.
        let b = Int(bucket)
        // Buckets strictly before the current one are complete.
        let completeUpTo = (nowTS / bucket).rounded(.down) * bucket
        guard completeUpTo > watermark else { return }

        // Process rows are change-gated (SampleStore.insertChanged): a row is
        // written only when the process moves or crosses into a new bucket, so
        // the raw tier is SPARSE and a plain AVG()/COUNT() over rows would be a
        // sample-mean biased toward whatever the process did most often, not a
        // time-mean. Instead weight each row by `dt` — how long its value was in
        // effect, i.e. until the next row for that process, clamped to the bucket
        // end (LEAD over the process's ordered rows). The heartbeat guarantees a
        // row at each bucket boundary, so within a complete bucket the dts sum to
        // the bucket width and the weighted mean equals the true time-average;
        // `samples` becomes that covered duration (≈ bucket width for a fully
        // present process, less when it was born/died mid-bucket), which is the
        // time-weight the minute→hour and windowed-leaderboard queries already
        // consume via SUM(x_avg * samples) / SUM(samples). The system tier stays
        // dense (its rows are never gated), so its plain AVG/COUNT is unchanged.
        try db.execute(
            sql: """
                INSERT INTO process_minute (process_id, bucket, footprint_min, footprint_avg, footprint_max, cpu_avg, cpu_max, samples, fd_max, disk_read_max, disk_written_max, energy_avg, energy_max, net_avg, net_max)
                SELECT process_id, b,
                       MIN(phys_footprint),
                       CAST(SUM(phys_footprint * dt) / SUM(dt) AS INTEGER),
                       MAX(phys_footprint),
                       SUM(cpu_percent * dt) / SUM(dt),
                       MAX(cpu_percent),
                       -- covered duration in seconds = the time-weight. Floored at
                       -- 1: a bucket with any row represents at least a sliver of
                       -- coverage, and a 0 here would make the downstream
                       -- SUM(x*samples)/SUM(samples) weighting divide by zero for a
                       -- process whose only bucket rounded below half a second.
                       MAX(1, CAST(ROUND(SUM(dt)) AS INTEGER)),
                       MAX(fd_total),
                       MAX(disk_read),
                       MAX(disk_written),
                       SUM(energy_impact * dt) / SUM(dt),
                       MAX(energy_impact),
                       SUM(net_total * dt) / SUM(dt),
                       MAX(net_total)
                FROM (
                    SELECT process_id, phys_footprint, cpu_percent, energy_impact, net_total,
                           fd_total, disk_read, disk_written,
                           CAST(timestamp / \(b) AS INTEGER) * \(b) AS b,
                           MIN(
                             COALESCE(
                               LEAD(timestamp) OVER (PARTITION BY process_id ORDER BY timestamp),
                               (CAST(timestamp / \(b) AS INTEGER) + 1) * \(b)),
                             (CAST(timestamp / \(b) AS INTEGER) + 1) * \(b)
                           ) - timestamp AS dt
                    FROM process_samples
                    WHERE timestamp >= ? AND timestamp < ?
                )
                GROUP BY process_id, b
                ON CONFLICT(process_id, bucket) DO UPDATE SET
                  footprint_min = excluded.footprint_min,
                  footprint_avg = excluded.footprint_avg,
                  footprint_max = excluded.footprint_max,
                  cpu_avg = excluded.cpu_avg,
                  cpu_max = excluded.cpu_max,
                  samples = excluded.samples,
                  fd_max = excluded.fd_max,
                  disk_read_max = excluded.disk_read_max,
                  disk_written_max = excluded.disk_written_max,
                  energy_avg = excluded.energy_avg,
                  energy_max = excluded.energy_max,
                  net_avg = excluded.net_avg,
                  net_max = excluded.net_max
                """, arguments: [watermark, completeUpTo])

        try db.execute(
            sql: """
                INSERT INTO system_minute (bucket, pressure_avg, pressure_max, app_avg, wired_avg, compressed_avg, cached_avg, swap_used_avg, cpu_avg, cpu_max, samples, battery_charge_avg, battery_power_avg, battery_health_avg, battery_cycles_max, battery_temp_avg, net_in_avg, net_in_max, net_out_avg, net_out_max)
                SELECT CAST(timestamp / \(b) AS INTEGER) * \(b) AS b,
                       AVG(pressure_percent), MAX(pressure_percent),
                       CAST(AVG(app_memory) AS INTEGER), CAST(AVG(wired) AS INTEGER),
                       CAST(AVG(compressed) AS INTEGER), CAST(AVG(cached_files) AS INTEGER),
                       CAST(AVG(swap_used) AS INTEGER), AVG(cpu_load), MAX(cpu_load), COUNT(*),
                       AVG(battery_charge), AVG(battery_power), AVG(battery_health),
                       MAX(battery_cycles), AVG(battery_temp),
                       AVG(net_in), MAX(net_in), AVG(net_out), MAX(net_out)
                FROM system_samples
                WHERE timestamp >= ? AND timestamp < ?
                GROUP BY b
                ON CONFLICT(bucket) DO UPDATE SET
                  pressure_avg = excluded.pressure_avg, pressure_max = excluded.pressure_max,
                  app_avg = excluded.app_avg, wired_avg = excluded.wired_avg,
                  compressed_avg = excluded.compressed_avg, cached_avg = excluded.cached_avg,
                  swap_used_avg = excluded.swap_used_avg,
                  cpu_avg = excluded.cpu_avg, cpu_max = excluded.cpu_max,
                  samples = excluded.samples,
                  battery_charge_avg = excluded.battery_charge_avg,
                  battery_power_avg = excluded.battery_power_avg,
                  battery_health_avg = excluded.battery_health_avg,
                  battery_cycles_max = excluded.battery_cycles_max,
                  battery_temp_avg = excluded.battery_temp_avg,
                  net_in_avg = excluded.net_in_avg, net_in_max = excluded.net_in_max,
                  net_out_avg = excluded.net_out_avg, net_out_max = excluded.net_out_max
                """, arguments: [watermark, completeUpTo])

        try setMeta(db, "minute_watermark", completeUpTo)
    }

    // MARK: - Minute -> hour

    static func rollMinuteToHour(_ db: Database, nowTS: Double) throws {
        let watermark = try meta(db, "hour_watermark") ?? 0
        let completeUpTo = (nowTS / 3600).rounded(.down) * 3600
        guard completeUpTo > watermark else { return }

        try db.execute(
            sql: """
                INSERT INTO process_hour (process_id, bucket, footprint_min, footprint_avg, footprint_max, cpu_avg, cpu_max, samples, fd_max, disk_read_max, disk_written_max, energy_avg, energy_max, net_avg, net_max)
                SELECT process_id,
                       CAST(bucket / 3600 AS INTEGER) * 3600 AS b,
                       MIN(footprint_min),
                       CAST(SUM(footprint_avg * samples) / SUM(samples) AS INTEGER),
                       MAX(footprint_max),
                       SUM(cpu_avg * samples) / SUM(samples),
                       MAX(cpu_max),
                       SUM(samples),
                       MAX(fd_max),
                       MAX(disk_read_max),
                       MAX(disk_written_max),
                       SUM(energy_avg * samples) / SUM(samples),
                       MAX(energy_max),
                       SUM(net_avg * samples) / SUM(samples),
                       MAX(net_max)
                FROM process_minute
                WHERE bucket >= ? AND bucket < ?
                GROUP BY process_id, b
                ON CONFLICT(process_id, bucket) DO UPDATE SET
                  footprint_min = excluded.footprint_min,
                  footprint_avg = excluded.footprint_avg,
                  footprint_max = excluded.footprint_max,
                  cpu_avg = excluded.cpu_avg,
                  cpu_max = excluded.cpu_max,
                  samples = excluded.samples,
                  fd_max = excluded.fd_max,
                  disk_read_max = excluded.disk_read_max,
                  disk_written_max = excluded.disk_written_max,
                  energy_avg = excluded.energy_avg,
                  energy_max = excluded.energy_max,
                  net_avg = excluded.net_avg,
                  net_max = excluded.net_max
                """, arguments: [watermark, completeUpTo])

        try db.execute(
            sql: """
                INSERT INTO system_hour (bucket, pressure_avg, pressure_max, app_avg, wired_avg, compressed_avg, cached_avg, swap_used_avg, cpu_avg, cpu_max, samples, battery_charge_avg, battery_power_avg, battery_health_avg, battery_cycles_max, battery_temp_avg, net_in_avg, net_in_max, net_out_avg, net_out_max)
                SELECT CAST(bucket / 3600 AS INTEGER) * 3600 AS b,
                       SUM(pressure_avg * samples) / SUM(samples), MAX(pressure_max),
                       CAST(SUM(app_avg * samples) / SUM(samples) AS INTEGER),
                       CAST(SUM(wired_avg * samples) / SUM(samples) AS INTEGER),
                       CAST(SUM(compressed_avg * samples) / SUM(samples) AS INTEGER),
                       CAST(SUM(cached_avg * samples) / SUM(samples) AS INTEGER),
                       CAST(SUM(swap_used_avg * samples) / SUM(samples) AS INTEGER),
                       SUM(cpu_avg * samples) / SUM(samples), MAX(cpu_max),
                       SUM(samples),
                       SUM(battery_charge_avg * samples) / SUM(samples),
                       SUM(battery_power_avg * samples) / SUM(samples),
                       SUM(battery_health_avg * samples) / SUM(samples),
                       MAX(battery_cycles_max),
                       SUM(battery_temp_avg * samples) / SUM(samples),
                       SUM(net_in_avg * samples) / SUM(samples), MAX(net_in_max),
                       SUM(net_out_avg * samples) / SUM(samples), MAX(net_out_max)
                FROM system_minute
                WHERE bucket >= ? AND bucket < ?
                GROUP BY b
                ON CONFLICT(bucket) DO UPDATE SET
                  pressure_avg = excluded.pressure_avg, pressure_max = excluded.pressure_max,
                  app_avg = excluded.app_avg, wired_avg = excluded.wired_avg,
                  compressed_avg = excluded.compressed_avg, cached_avg = excluded.cached_avg,
                  swap_used_avg = excluded.swap_used_avg,
                  cpu_avg = excluded.cpu_avg, cpu_max = excluded.cpu_max,
                  samples = excluded.samples,
                  battery_charge_avg = excluded.battery_charge_avg,
                  battery_power_avg = excluded.battery_power_avg,
                  battery_health_avg = excluded.battery_health_avg,
                  battery_cycles_max = excluded.battery_cycles_max,
                  battery_temp_avg = excluded.battery_temp_avg,
                  net_in_avg = excluded.net_in_avg, net_in_max = excluded.net_in_max,
                  net_out_avg = excluded.net_out_avg, net_out_max = excluded.net_out_max
                """, arguments: [watermark, completeUpTo])

        try setMeta(db, "hour_watermark", completeUpTo)
    }

    // MARK: - Trim

    /// Apply time cutoffs in short transactions. A user can reduce a mature
    /// database's retention by days, making millions of rows eligible at once;
    /// one unbounded DELETE would hold SQLite's sole writer throughout. Rotate
    /// across tiers in 10k-row commits and cap one maintenance pass so sample
    /// writes can interleave and later passes continue convergence.
    private static func trim(
        _ pool: DatabasePool, nowTS: Double, policy: RetentionPolicy
    ) throws {
        let tiers: [(table: String, column: String, cutoff: Double)] = [
            ("process_samples", "timestamp", nowTS - policy.rawWindow),
            ("system_samples", "timestamp", nowTS - policy.rawWindow),
            ("process_minute", "bucket", nowTS - policy.minuteWindow),
            ("system_minute", "bucket", nowTS - policy.minuteWindow),
            ("process_hour", "bucket", nowTS - policy.hourWindow),
            ("system_hour", "bucket", nowTS - policy.hourWindow),
        ]
        let batchSize = 10_000
        let maximumDeletesPerPass = 500_000
        var deleted = 0
        var active = Array(tiers.indices)

        while !active.isEmpty, deleted < maximumDeletesPerPass {
            var remaining: [Int] = []
            for index in active where deleted < maximumDeletesPerPass {
                let tier = tiers[index]
                let limit = min(batchSize, maximumDeletesPerPass - deleted)
                let removed = try pool.write { db -> Int in
                    try db.execute(
                        sql: """
                            DELETE FROM \(tier.table) WHERE rowid IN (
                                SELECT rowid FROM \(tier.table)
                                WHERE \(tier.column) < ?
                                ORDER BY \(tier.column) ASC
                                LIMIT ?
                            )
                            """, arguments: [tier.cutoff, limit])
                    return db.changesCount
                }
                deleted += removed
                if removed == limit { remaining.append(index) }
            }
            active = remaining
        }

        try pool.write { db in
            try pruneDimensionsIfDue(db, nowTS: nowTS, hourCutoff: nowTS - policy.hourWindow)
        }
    }

    static func trim(_ db: Database, nowTS: Double, policy: RetentionPolicy) throws {
        let rawCutoff = nowTS - policy.rawWindow
        let minuteCutoff = nowTS - policy.minuteWindow
        let hourCutoff = nowTS - policy.hourWindow

        try db.execute(
            sql: "DELETE FROM process_samples WHERE timestamp < ?", arguments: [rawCutoff])
        try db.execute(
            sql: "DELETE FROM system_samples WHERE timestamp < ?", arguments: [rawCutoff])
        try db.execute(
            sql: "DELETE FROM process_minute WHERE bucket < ?", arguments: [minuteCutoff])
        try db.execute(sql: "DELETE FROM system_minute WHERE bucket < ?", arguments: [minuteCutoff])
        try db.execute(sql: "DELETE FROM process_hour WHERE bucket < ?", arguments: [hourCutoff])
        try db.execute(sql: "DELETE FROM system_hour WHERE bucket < ?", arguments: [hourCutoff])

        try pruneDimensionsIfDue(db, nowTS: nowTS, hourCutoff: hourCutoff)
    }

    private static func pruneDimensionsIfDue(
        _ db: Database, nowTS: Double, hourCutoff: Double
    ) throws {
        // Drop dimension rows for processes that no longer have any samples and
        // have not been seen within the hour window. Each NOT EXISTS probe uses
        // the process-first primary key on its tier, while v10's last_seen index
        // limits candidates before those probes. Watermarked to every 10 minutes.
        // `lastPrune > nowTS` means the watermark was written under a clock
        // that has since been corrected backward — run (and rewrite it) rather
        // than starving the prune until real time passes the future stamp.
        let lastPrune = try meta(db, "dimension_prune_at") ?? 0
        if nowTS - lastPrune >= 600 || lastPrune > nowTS {
            try db.execute(
                sql: """
                                        DELETE FROM processes AS p
                                        WHERE p.last_seen < ?
                                            AND NOT EXISTS (
                                                SELECT 1 FROM process_samples AS s WHERE s.process_id = p.id
                                            )
                                            AND NOT EXISTS (
                                                SELECT 1 FROM process_minute AS m WHERE m.process_id = p.id
                                            )
                                            AND NOT EXISTS (
                                                SELECT 1 FROM process_hour AS h WHERE h.process_id = p.id
                                            )
                    """, arguments: [hourCutoff])
            try setMeta(db, "dimension_prune_at", nowTS)
        }
    }

    // MARK: - Meta watermarks

    static func meta(_ db: Database, _ key: String) throws -> Double? {
        try Double.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    static func setMeta(_ db: Database, _ key: String, _ value: Double) throws {
        try db.execute(
            sql:
                "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, value])
    }
}
