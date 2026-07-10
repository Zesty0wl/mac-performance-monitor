import Foundation
import GRDB

/// Opens and migrates the MacPerfMonitor SQLite database (via GRDB) and vends the
/// shared `DatabasePool`.
public enum MacPerfMonitorDatabase {
    /// Default on-disk location: ~/Library/Application Support/MacPerformanceMonitor/macperfmonitor.sqlite
    public static func defaultURL() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Full product name to share one Application Support directory with the
        // licensing layer (LicensePaths also uses "MacPerformanceMonitor").
        let dir = base.appendingPathComponent("MacPerformanceMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("macperfmonitor.sqlite")
    }

    /// Open a pool at `url` (or in-memory when `url` is nil), running migrations.
    public static func makePool(url: URL? = nil) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            // NB: only read-safe pragmas here — prepareDatabase also runs on the
            // pool's read-only reader connections, where a write pragma (e.g.
            // `auto_vacuum`) fails. Auto-vacuum is set writer-side below.
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool: DatabasePool
        if let url {
            pool = try DatabasePool(path: url.path, configuration: config)
        } else {
            // In-memory pools are not supported by GRDB; use a temp file.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("macperfmonitor-\(UUID().uuidString).sqlite")
            pool = try DatabasePool(path: temp.path, configuration: config)
        }
        try migrator.migrate(pool)
        try? ensureIncrementalAutoVacuum(pool)
        return pool
    }

    /// Put the database into incremental auto-vacuum mode (writer-side, since the
    /// pragma cannot run on the pool's read-only connections), so the size cap can
    /// reclaim space. Changing the mode requires a one-time `VACUUM`, which cannot
    /// run inside a transaction; afterwards this is a cheap no-op. Best-effort: a
    /// failure (e.g. low disk) leaves the database usable, just non-shrinking.
    private static func ensureIncrementalAutoVacuum(_ pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            // Take WAL checkpointing off the per-commit hot path. SQLite's default
            // auto-checkpoint fires a synchronous checkpoint + fsync at every
            // commit once the WAL passes 1000 pages — which on the per-tick sample
            // inserts meant a full fsync every couple of seconds, the app's #1 CPU
            // cost. Disable it on the writer connection (meaningless on the
            // read-only readers, so it must live here, not in prepareDatabase) and
            // checkpoint explicitly once per retention pass instead (Retention.run).
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")

            let mode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
            guard mode != 2 else { return }  // 2 == INCREMENTAL, already converted
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            try db.execute(sql: "VACUUM")
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-schema") { db in
            try db.execute(sql: Schema.v1)
        }
        // Carry file descriptors and disk I/O into the minute/hour aggregates so
        // those metrics can be charted over the long (24-hour and 7-day) trend
        // spans, not just the raw 2-hour window. FD keeps the per-bucket peak;
        // disk keeps the per-bucket maximum cumulative counter (it is monotonic,
        // so the maximum is the end-of-bucket total and a rate can be derived
        // between buckets). Existing rows default to zero.
        migrator.registerMigration("v2-fd-disk-aggregates") { db in
            try db.execute(sql: Schema.v2)
        }
        // Carry total CPU into the system minute/hour aggregates so the dashboard
        // CPU timeline has data over the long (24-hour and 7-day) trend spans,
        // not just the raw 2-hour window. `cpu_avg` is the per-bucket mean,
        // `cpu_max` the per-bucket peak; both default to zero for existing rows.
        migrator.registerMigration("v3-system-cpu-aggregates") { db in
            try db.execute(sql: Schema.v3)
        }
        // Carry battery state into the system samples and aggregates (so the
        // battery charge/power/health timelines work over the long trend spans),
        // and per-process energy into the process samples and aggregates (so the
        // Battery tab's top-energy-users leaderboard can be ranked over any
        // window). Mirrors the v3 CPU columns; existing rows default to zero.
        migrator.registerMigration("v4-battery") { db in
            try db.execute(sql: Schema.v4)
        }
        // The "top consumers" leaderboard and leak board aggregate the raw tier
        // over a window, grouped by process. With only the PK (process_id,
        // timestamp) and a lone timestamp index, the planner cannot both seek the
        // timestamp range and group by process without a full PK scan plus a
        // rowid lookup per row — on a busy machine that is ~2M scattered reads of
        // the whole table every refresh, which pegged a core. This composite is
        // ordered to satisfy the GROUP BY in-place and *covers* every column the
        // aggregates touch, so the query is answered from the index alone
        // (planner: "SCAN USING COVERING INDEX", ~7x faster, no table I/O).
        migrator.registerMigration("v5-consumer-covering-index") { db in
            try db.execute(sql: Schema.v5)
        }
        // Carry network throughput into the system samples/aggregates (so the
        // download/upload timelines work over the long trend spans) and the
        // per-process throughput into the process samples/aggregates (so the
        // top-network-apps leaderboard can be ranked over any window). All rates
        // are bytes/second; mirrors the v4 battery/energy columns. Existing rows
        // default to zero, which reads as "no traffic recorded".
        migrator.registerMigration("v6-network") { db in
            try db.execute(sql: Schema.v6)
        }
        // Capture each process's code-signing Team Identifier so process groups
        // can match "everything signed by vendor X", including unbundled root
        // daemons that have no bundle id. Lives on `processes` only — group
        // aggregation resolves a set of process ids first, then filters the
        // sample/aggregate tiers by `process_id IN (…)`, so the minute/hour
        // tables need no new column. Existing rows stay null until re-seen.
        migrator.registerMigration("v7-team-id") { db in
            try db.execute(sql: Schema.v7)
        }
        // Carry per-process peak CPU into the minute/hour aggregates so a group's
        // CPU can be shown as a windowed peak (the "Peak" toggle), not only the
        // mean. `cpu_max` is the bucket's highest raw `cpu_percent`; mirrors the
        // footprint/energy/network peaks already stored beside it. Existing rows
        // default to zero; the group query coalesces a zero up to `cpu_avg`, so a
        // pre-upgrade bucket never reads back as a zero peak.
        migrator.registerMigration("v8-process-cpu-peak") { db in
            try db.execute(sql: Schema.v8)
        }
        // The 6h/24h/7d leaderboards (and the group boards on those windows)
        // aggregate the minute/hour tiers with `WHERE bucket >= ? GROUP BY
        // process_id`. The tiers' only indexes were the (process_id, bucket) PK
        // and a bare bucket index — neither covers the aggregated columns, so
        // the planner full-scanned the PK with a table lookup per row: on a
        // week-old database that is millions of rows per refresh (measured
        // ~400 ms for 24 h). These mirror the raw tier's v5 covering index but
        // lead with `bucket` so a window reads only its own range; the bounded
        // ANALYZE gives the planner the statistics to pick between them and the
        // PK skip-scan (both beat the full scan; measured ~1.8x on 24 h and
        // ~4x on 6 h against a 445 MB production database).
        migrator.registerMigration("v9-aggregate-covering-indexes") { db in
            try db.execute(sql: Schema.v9)
            try db.execute(sql: "PRAGMA analysis_limit = 1000")
            try db.execute(sql: "ANALYZE")
        }
        // Network was added after the original raw consumer index, so reading
        // `net_total` forced a table lookup for every matching raw row. Rebuild
        // that index as genuinely covering, and index process last-seen time so
        // group membership and dimension pruning do not scan the whole catalog.
        migrator.registerMigration("v10-raw-network-and-process-age-indexes") { db in
            try db.execute(sql: Schema.v10)
            try db.execute(sql: "PRAGMA analysis_limit = 1000")
            try db.execute(sql: "ANALYZE")
        }
        return migrator
    }
}

enum Schema {
    static let v1 = """
        CREATE TABLE system_samples (
            timestamp REAL PRIMARY KEY,
            total_ram INTEGER NOT NULL,
            free INTEGER NOT NULL,
            active INTEGER NOT NULL,
            inactive INTEGER NOT NULL,
            wired INTEGER NOT NULL,
            speculative INTEGER NOT NULL,
            compressed INTEGER NOT NULL,
            app_memory INTEGER NOT NULL,
            cached_files INTEGER NOT NULL,
            swap_total INTEGER NOT NULL,
            swap_used INTEGER NOT NULL,
            pressure_level INTEGER NOT NULL,
            pressure_percent REAL NOT NULL,
            page_ins INTEGER NOT NULL,
            page_outs INTEGER NOT NULL,
            compressions INTEGER NOT NULL,
            decompressions INTEGER NOT NULL,
            page_ins_delta INTEGER NOT NULL,
            page_outs_delta INTEGER NOT NULL,
            compressions_delta INTEGER NOT NULL,
            decompressions_delta INTEGER NOT NULL,
            cpu_load REAL NOT NULL
        );

        CREATE TABLE processes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pid INTEGER NOT NULL,
            start_time REAL NOT NULL,
            name TEXT NOT NULL,
            executable_path TEXT,
            bundle_id TEXT,
            uid INTEGER NOT NULL,
            architecture TEXT NOT NULL,
            is_translated INTEGER NOT NULL,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            UNIQUE(pid, start_time)
        );

        CREATE TABLE process_samples (
            process_id INTEGER NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL,
            phys_footprint INTEGER NOT NULL,
            resident_size INTEGER NOT NULL,
            virtual_size INTEGER NOT NULL,
            lifetime_max_footprint INTEGER NOT NULL,
            cpu_percent REAL NOT NULL,
            cpu_user INTEGER NOT NULL,
            cpu_system INTEGER NOT NULL,
            thread_count INTEGER NOT NULL,
            fd_total INTEGER NOT NULL,
            fd_vnode INTEGER NOT NULL,
            fd_socket INTEGER NOT NULL,
            fd_pipe INTEGER NOT NULL,
            fd_other INTEGER NOT NULL,
            disk_read INTEGER NOT NULL,
            disk_written INTEGER NOT NULL,
            data_source TEXT NOT NULL,
            footprint_readable INTEGER NOT NULL,
            PRIMARY KEY (process_id, timestamp)
        );
        CREATE INDEX idx_process_samples_ts ON process_samples(timestamp);

        CREATE TABLE process_minute (
            process_id INTEGER NOT NULL,
            bucket REAL NOT NULL,
            footprint_min INTEGER NOT NULL,
            footprint_avg INTEGER NOT NULL,
            footprint_max INTEGER NOT NULL,
            cpu_avg REAL NOT NULL,
            samples INTEGER NOT NULL,
            PRIMARY KEY (process_id, bucket)
        );
        CREATE INDEX idx_process_minute_bucket ON process_minute(bucket);

        CREATE TABLE process_hour (
            process_id INTEGER NOT NULL,
            bucket REAL NOT NULL,
            footprint_min INTEGER NOT NULL,
            footprint_avg INTEGER NOT NULL,
            footprint_max INTEGER NOT NULL,
            cpu_avg REAL NOT NULL,
            samples INTEGER NOT NULL,
            PRIMARY KEY (process_id, bucket)
        );
        CREATE INDEX idx_process_hour_bucket ON process_hour(bucket);

        CREATE TABLE system_minute (
            bucket REAL PRIMARY KEY,
            pressure_avg REAL NOT NULL,
            pressure_max REAL NOT NULL,
            app_avg INTEGER NOT NULL,
            wired_avg INTEGER NOT NULL,
            compressed_avg INTEGER NOT NULL,
            cached_avg INTEGER NOT NULL,
            swap_used_avg INTEGER NOT NULL,
            samples INTEGER NOT NULL
        );

        CREATE TABLE system_hour (
            bucket REAL PRIMARY KEY,
            pressure_avg REAL NOT NULL,
            pressure_max REAL NOT NULL,
            app_avg INTEGER NOT NULL,
            wired_avg INTEGER NOT NULL,
            compressed_avg INTEGER NOT NULL,
            cached_avg INTEGER NOT NULL,
            swap_used_avg INTEGER NOT NULL,
            samples INTEGER NOT NULL
        );

        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value REAL NOT NULL
        );
        """

    /// Adds file-descriptor and disk-I/O aggregate columns to the minute and
    /// hour process tiers. `fd_max` is the peak descriptor count in the bucket;
    /// `disk_read_max`/`disk_written_max` are the maximum cumulative byte
    /// counters in the bucket (monotonic, so the maximum is the end-of-bucket
    /// total). Defaulting to zero keeps pre-existing aggregate rows valid.
    static let v2 = """
        ALTER TABLE process_minute ADD COLUMN fd_max INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE process_minute ADD COLUMN disk_read_max INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE process_minute ADD COLUMN disk_written_max INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE process_hour ADD COLUMN fd_max INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE process_hour ADD COLUMN disk_read_max INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE process_hour ADD COLUMN disk_written_max INTEGER NOT NULL DEFAULT 0;
        """

    /// Adds total-CPU aggregate columns to the system minute and hour tiers.
    /// `cpu_avg` is the bucket mean and `cpu_max` the bucket peak of the raw
    /// `system_samples.cpu_load` (a 0...1 fraction). Defaulting to zero keeps
    /// pre-existing aggregate rows valid.
    static let v3 = """
        ALTER TABLE system_minute ADD COLUMN cpu_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_minute ADD COLUMN cpu_max REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_hour ADD COLUMN cpu_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_hour ADD COLUMN cpu_max REAL NOT NULL DEFAULT 0;
        """

    /// Adds battery state to the system tiers and per-process energy to the
    /// process tiers. On `system_samples`: charge %, power (W), charging flag,
    /// health %, cycle count, temperature (°C), and a present flag (so history
    /// distinguishes a real reading from a battery-less Mac). The system
    /// minute/hour tiers carry the chartable means plus a cycle-count max. On
    /// `process_samples`: the cumulative energy counter and the per-tick
    /// energy-impact figure; the process minute/hour tiers carry its mean and
    /// peak. Defaulting to zero keeps pre-existing rows valid.
    static let v4 = """
        ALTER TABLE system_samples ADD COLUMN battery_present INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE system_samples ADD COLUMN battery_charge REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_samples ADD COLUMN battery_power REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_samples ADD COLUMN battery_charging INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE system_samples ADD COLUMN battery_health REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_samples ADD COLUMN battery_cycles INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE system_samples ADD COLUMN battery_temp REAL NOT NULL DEFAULT 0;

        ALTER TABLE system_minute ADD COLUMN battery_charge_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_minute ADD COLUMN battery_power_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_minute ADD COLUMN battery_health_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_minute ADD COLUMN battery_cycles_max INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE system_minute ADD COLUMN battery_temp_avg REAL NOT NULL DEFAULT 0;

        ALTER TABLE system_hour ADD COLUMN battery_charge_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_hour ADD COLUMN battery_power_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_hour ADD COLUMN battery_health_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_hour ADD COLUMN battery_cycles_max INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE system_hour ADD COLUMN battery_temp_avg REAL NOT NULL DEFAULT 0;

        ALTER TABLE process_samples ADD COLUMN energy INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE process_samples ADD COLUMN energy_impact REAL NOT NULL DEFAULT 0;

        ALTER TABLE process_minute ADD COLUMN energy_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE process_minute ADD COLUMN energy_max REAL NOT NULL DEFAULT 0;
        ALTER TABLE process_hour ADD COLUMN energy_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE process_hour ADD COLUMN energy_max REAL NOT NULL DEFAULT 0;
        """

    /// Covering index for the windowed per-process aggregates over the raw tier
    /// (`HistoryQuery.rawConsumers`, `LeakBoard`'s raw fast path). Leading with
    /// `process_id` lets the GROUP BY drain in index order (no temp b-tree);
    /// `timestamp` next bounds each group's window; the trailing columns are
    /// every field those queries read, so the scan never touches the table.
    static let v5 = """
        CREATE INDEX idx_process_samples_consumer
            ON process_samples(process_id, timestamp, footprint_readable,
                               phys_footprint, cpu_percent, energy_impact);
        """

    /// Adds network throughput (bytes/second) to the system and process tiers.
    /// On `system_samples`: instantaneous download/upload rates. The system
    /// minute/hour tiers carry each direction's bucket mean and peak. On
    /// `process_samples`: the per-process total throughput; the process
    /// minute/hour tiers carry its mean and peak. Defaulting to zero keeps
    /// pre-existing rows valid (they read as no recorded traffic).
    static let v6 = """
        ALTER TABLE system_samples ADD COLUMN net_in REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_samples ADD COLUMN net_out REAL NOT NULL DEFAULT 0;

        ALTER TABLE system_minute ADD COLUMN net_in_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_minute ADD COLUMN net_in_max REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_minute ADD COLUMN net_out_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_minute ADD COLUMN net_out_max REAL NOT NULL DEFAULT 0;

        ALTER TABLE system_hour ADD COLUMN net_in_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_hour ADD COLUMN net_in_max REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_hour ADD COLUMN net_out_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE system_hour ADD COLUMN net_out_max REAL NOT NULL DEFAULT 0;

        ALTER TABLE process_samples ADD COLUMN net_total REAL NOT NULL DEFAULT 0;

        ALTER TABLE process_minute ADD COLUMN net_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE process_minute ADD COLUMN net_max REAL NOT NULL DEFAULT 0;
        ALTER TABLE process_hour ADD COLUMN net_avg REAL NOT NULL DEFAULT 0;
        ALTER TABLE process_hour ADD COLUMN net_max REAL NOT NULL DEFAULT 0;
        """

    /// Adds the code-signing Team Identifier to the process identity row. Only
    /// the `processes` table needs it: group membership resolves to a set of
    /// `processes.id`, after which the sample/aggregate tiers are filtered by
    /// `process_id`. Nullable, so pre-existing rows (and unsigned binaries) read
    /// as "no team", and the upsert backfills it the next time a process is seen.
    static let v7 = """
        ALTER TABLE processes ADD COLUMN team_id TEXT;
        """

    /// Adds a per-process peak-CPU column to the minute and hour process tiers,
    /// mirroring `footprint_max` / `energy_max` / `net_max`. `cpu_max` is the
    /// bucket's highest raw `process_samples.cpu_percent` (percent of one core).
    /// Defaulting to zero keeps pre-existing aggregate rows valid; the group
    /// query coalesces a zero up to `cpu_avg`, so an old bucket never reads back
    /// as a zero peak.
    static let v8 = """
        ALTER TABLE process_minute ADD COLUMN cpu_max REAL NOT NULL DEFAULT 0;
        ALTER TABLE process_hour ADD COLUMN cpu_max REAL NOT NULL DEFAULT 0;
        """

    /// Covering indexes for the windowed per-process aggregates over the
    /// minute/hour tiers (`HistoryQuery.aggregateConsumers`, the group boards).
    /// Leading with `bucket` bounds the scan to the requested window (the v5 raw
    /// index leads with `process_id` instead because the raw tier is only ever
    /// two hours deep — here the tiers span days to months, so the window range
    /// is what matters); the trailing columns are every field those queries
    /// read, so the scan never touches the table. Maintained on writes that
    /// happen once a minute/hour, so the write amplification is negligible.
    static let v9 = """
        CREATE INDEX idx_process_minute_consumer
            ON process_minute(bucket, process_id, samples, footprint_avg,
                              footprint_max, cpu_avg, energy_avg, net_avg);
        CREATE INDEX idx_process_hour_consumer
            ON process_hour(bucket, process_id, samples, footprint_avg,
                            footprint_max, cpu_avg, energy_avg, net_avg);
        """

    static let v10 = """
        DROP INDEX idx_process_samples_consumer;
        CREATE INDEX idx_process_samples_consumer
            ON process_samples(process_id, timestamp, footprint_readable,
                               phys_footprint, cpu_percent, energy_impact, net_total);
        CREATE INDEX idx_processes_last_seen ON processes(last_seen);
        """
}

/// Small helpers for the lossless UInt64 <-> Int64 storage convention. Memory
/// figures are always well under Int64.max, so clamping never loses data.
enum SQLInt {
    static func store(_ value: UInt64) -> Int64 { Int64(clamping: value) }
    static func read(_ value: Int64) -> UInt64 { value < 0 ? 0 : UInt64(value) }
}
