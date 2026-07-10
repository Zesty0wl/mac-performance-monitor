import Foundation
import GRDB

/// Writes sampler snapshots into the database (batched, one transaction per
/// tick) and reads them back for the UI. Holds an in-memory identity -> row-id
/// cache so each process needs at most one upsert per session.
public final class SampleStore {
    private let pool: DatabasePool
    private var processIDCache: [ProcessIdentity: Int64] = [:]

    /// The gate-relevant fields of the last raw row actually WRITTEN for a
    /// process, for change-gated inserts (`insertChanged`). A process whose
    /// metrics have not moved since this — and which is still inside the same
    /// heartbeat bucket — is skipped, so idle daemons (the ~94% of processes that
    /// are byte-identical second to second) stop generating a row per second.
    /// Pruned alongside `processIDCache`, and confined to the writer's queue.
    private struct WrittenRow {
        var timestamp: Double
        var cpuPercent: Double
        var physFootprint: UInt64
        var residentSize: UInt64
        var fdTotal: Int32
        var diskRead: UInt64
        var diskWritten: UInt64
        var threadCount: Int32
        var netTotal: Double
    }
    private var lastWritten: [ProcessIdentity: WrittenRow] = [:]

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public convenience init(url: URL? = nil) throws {
        self.init(pool: try MacPerfMonitorDatabase.makePool(url: url))
    }

    public var databasePool: DatabasePool { pool }

    /// The database's on-disk size in bytes (page count × page size). Excludes
    /// the small transient WAL; close enough for the Settings read-out.
    public func approximateSizeBytes() -> Int {
        (try? pool.read { db in
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            return pageCount * pageSize
        }) ?? 0
    }

    // MARK: - Writing

    /// Persist one tick. The whole snapshot is written in a single transaction.
    public func insert(_ snapshot: Sampler.Snapshot) throws {
        try writeRecoveringCaches { db in
            try self.insertSystem(snapshot.system, db: db)
            for sample in snapshot.processes {
                let processID = try self.processID(for: sample, db: db)
                try self.insertProcessSample(sample, processID: processID, db: db)
            }
        }
    }

    /// Persist only the system-level row for one tick. Used by the live app on
    /// the dashboard path, where per-process history is not yet needed and the
    /// 60 MB / 2% budget rewards writing a single row rather than ~600.
    public func insert(systemSample: SystemSample) throws {
        try writeRecoveringCaches { db in
            try self.insertSystem(systemSample, db: db)
        }
    }

    /// Persist the system row plus the given process rows in one transaction.
    /// The live app passes every visible process each tick, so per-process
    /// history exists for any process the user later charts; retention
    /// (2 h raw / 7 d minute / 90 d hour) keeps the database bounded.
    public func insert(_ system: SystemSample, processes: [ProcessSample]) throws {
        try writeRecoveringCaches { db in
            try self.insertSystem(system, db: db)
            for sample in processes {
                let processID = try self.processID(for: sample, db: db)
                try self.insertProcessSample(sample, processID: processID, db: db)
            }
        }
    }

    /// Persist the system row (always) plus only the process rows that have
    /// changed materially since each process's last-WRITTEN row — the
    /// change-gated raw write. Returns the number of process rows written.
    ///
    /// The system row is never gated: it is one small row per tick and keeps
    /// every system/pressure/CPU/memory timeline dense and exact. Process rows,
    /// which dominate the write and its retention roll-up (~800 near-identical
    /// idle-daemon rows every second), are written only when the process moved
    /// (`shouldWrite`) OR when the sample crosses into a new aggregate `bucket`.
    /// The bucket crossing is a heartbeat that guarantees at least one raw row
    /// per process per bucket, so the minute roll-up stays complete and the
    /// dimension `last_seen` keeps advancing — while the time-weighted roll-up
    /// (`Retention.rollRawToMinute`) reconstructs correct averages from the
    /// sparse rows via each row's held duration. `bucket` must match the
    /// retention `standardResBucket`.
    @discardableResult
    public func insertChanged(
        _ system: SystemSample, processes: [ProcessSample], bucket: Double
    )
        throws -> Int
    {
        try writeRecoveringCaches { db in
            try self.insertSystem(system, db: db)
            var written = 0
            for sample in processes where self.shouldWrite(sample, bucket: bucket) {
                let processID = try self.processID(for: sample, db: db)
                try self.insertProcessSample(sample, processID: processID, db: db)
                self.lastWritten[sample.id] = WrittenRow(
                    timestamp: sample.timestamp.timeIntervalSince1970,
                    cpuPercent: sample.cpuPercent,
                    physFootprint: sample.physFootprint,
                    residentSize: sample.residentSize,
                    fdTotal: sample.fdTotal,
                    diskRead: sample.diskBytesRead,
                    diskWritten: sample.diskBytesWritten,
                    threadCount: sample.threadCount,
                    netTotal: sample.networkBytesPerSec)
                written += 1
            }
            return written
        }
    }

    /// Cache entries are created while the SQL transaction is still open. If a
    /// later row aborts that transaction, those IDs and change-gate snapshots no
    /// longer describe committed state, so discard them before the next tick.
    private func writeRecoveringCaches<T>(
        _ updates: (Database) throws -> T
    ) throws -> T {
        do {
            return try pool.write(updates)
        } catch {
            processIDCache.removeAll(keepingCapacity: true)
            lastWritten.removeAll(keepingCapacity: true)
            throw error
        }
    }

    /// Whether a process row must be written this tick: a first sighting, a
    /// crossing into a new aggregate bucket (the heartbeat), or a material change
    /// since the last-written row. The thresholds filter measurement jitter so a
    /// genuinely idle daemon is skipped; anything doing real work trips a gate.
    /// Energy impact is deliberately NOT gated — it is a smooth function of CPU
    /// (already gated) plus noisy idle-wakeup counts, so gating on it would force
    /// a write every tick for idle-but-waking daemons and defeat the whole point;
    /// the heartbeat rows keep the energy board approximately right.
    private func shouldWrite(_ s: ProcessSample, bucket: Double) -> Bool {
        guard let prev = lastWritten[s.id] else { return true }  // first sighting
        let ts = s.timestamp.timeIntervalSince1970
        // Heartbeat: at least one row per process per aggregate bucket.
        if bucket > 0, floor(ts / bucket) != floor(prev.timestamp / bucket) { return true }
        if abs(s.cpuPercent - prev.cpuPercent) > 0.5 { return true }
        if absDiff(s.physFootprint, prev.physFootprint) > 512 * 1024 { return true }
        if absDiff(s.residentSize, prev.residentSize) > 1024 * 1024 { return true }
        if s.fdTotal != prev.fdTotal { return true }
        if s.diskBytesRead != prev.diskRead || s.diskBytesWritten != prev.diskWritten {
            return true
        }
        if s.threadCount != prev.threadCount { return true }
        if s.networkBytesPerSec != prev.netTotal { return true }
        return false
    }

    private func absDiff(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : b - a }

    /// Drop the in-memory identity → row-id cache. Called after retention may
    /// have removed process dimension rows, so the next insert re-resolves ids
    /// rather than trusting a row id that no longer exists.
    public func clearProcessIDCache() {
        processIDCache.removeAll(keepingCapacity: true)
        lastWritten.removeAll(keepingCapacity: true)
    }

    /// Evict cached identity → row-id mappings except the given live set.
    /// Called after each retention pass instead of `clearProcessIDCache()`: the
    /// dimension prune only ever deletes rows for processes gone longer than
    /// the whole hour-tier window, so an id for a currently-live process can
    /// never be stale — while wholesale clearing forced ~600 `processes`
    /// re-upserts on the next persist tick, every minute. Like the cache
    /// itself, must be called on the writer's queue.
    public func pruneProcessIDCache(keeping live: Set<ProcessIdentity>) {
        processIDCache = processIDCache.filter { live.contains($0.key) }
        // The change-gate's last-written snapshots follow the same lifecycle: a
        // dead process will never be sampled again, so its entry only wastes
        // memory. Keeping the live set bounds it exactly like the id cache.
        lastWritten = lastWritten.filter { live.contains($0.key) }
    }

    /// Refresh `last_seen` for live processes whose dimension upsert the id
    /// cache short-circuits. Group membership (`groupMemberIDs`) and the
    /// dimension prune both filter on `last_seen`, so it must keep advancing
    /// for a process that never leaves the cache — otherwise a continuously
    /// running process falls out of every group once the app has been up
    /// longer than the group window. One batched UPDATE per retention pass
    /// replaces the ~600 re-upserts the old wholesale cache clear forced every
    /// minute. Like the cache itself, must be called on the writer's queue.
    public func touchLastSeen(keeping live: Set<ProcessIdentity>, now: Date = Date()) {
        let ids = live.compactMap { processIDCache[$0] }
        guard !ids.isEmpty else { return }
        let ts = now.timeIntervalSince1970
        try? pool.write { db in
            var start = 0
            while start < ids.count {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let placeholders = repeatElement("?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "UPDATE processes SET last_seen = ? WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(
                        [ts as DatabaseValueConvertible]
                            + chunk.map { $0 as DatabaseValueConvertible }))
                start += chunk.count
            }
        }
    }

    /// Checkpoint the WAL and truncate it back to empty. Auto-checkpoint is
    /// disabled (Database.makePool) so the WAL never checkpoints on the per-tick
    /// commit hot path; instead the sampler calls this on a coarse cadence to keep
    /// the WAL file bounded. TRUNCATE resets the file to zero; best-effort, so a
    /// pass that overlaps a reader simply no-ops and the next one catches up.
    public func checkpoint() {
        try? pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
    }

    // The three write statements run for every row of every persist tick
    // (~600 process rows + 1 system row every ~2 s), so they go through
    // `db.cachedStatement` rather than `db.execute`: the latter re-prepares
    // (`sqlite3_prepare`) the 20-plus-column SQL on every call, which at ~600
    // rows/tick was the single largest fixed cost of recording. The cache is
    // per-connection and the pool has one writer, so each statement is
    // compiled exactly once per app run.

    private func insertSystem(_ s: SystemSample, db: Database) throws {
        let statement = try db.cachedStatement(
            sql: """
                INSERT OR REPLACE INTO system_samples
                (timestamp, total_ram, free, active, inactive, wired, speculative, compressed,
                 app_memory, cached_files, swap_total, swap_used, pressure_level, pressure_percent,
                 page_ins, page_outs, compressions, decompressions,
                 page_ins_delta, page_outs_delta, compressions_delta, decompressions_delta, cpu_load,
                 battery_present, battery_charge, battery_power, battery_charging, battery_health,
                 battery_cycles, battery_temp, net_in, net_out)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
        try statement.execute(
            arguments: [
                s.timestamp.timeIntervalSince1970,
                SQLInt.store(s.totalRAM), SQLInt.store(s.free), SQLInt.store(s.active),
                SQLInt.store(s.inactive), SQLInt.store(s.wired), SQLInt.store(s.speculative),
                SQLInt.store(s.compressed), SQLInt.store(s.appMemory), SQLInt.store(s.cachedFiles),
                SQLInt.store(s.swapTotal), SQLInt.store(s.swapUsed), s.pressureLevel.rawValue,
                s.pressurePercent,
                SQLInt.store(s.pageIns), SQLInt.store(s.pageOuts),
                SQLInt.store(s.compressions), SQLInt.store(s.decompressions),
                SQLInt.store(s.pageInsDelta), SQLInt.store(s.pageOutsDelta),
                SQLInt.store(s.compressionsDelta), SQLInt.store(s.decompressionsDelta),
                s.cpuLoad,
                s.batteryPresent, s.batteryCharge, s.batteryPowerWatts, s.batteryIsCharging,
                s.batteryHealthPercent, s.batteryCycleCount, s.batteryTemperatureCelsius,
                s.networkInBytesPerSec, s.networkOutBytesPerSec,
            ])
    }

    private func processID(for s: ProcessSample, db: Database) throws -> Int64 {
        if let cached = processIDCache[s.id] { return cached }
        let statement = try db.cachedStatement(
            sql: """
                INSERT INTO processes
                (pid, start_time, name, executable_path, bundle_id, team_id, uid, architecture, is_translated, first_seen, last_seen)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(pid, start_time) DO UPDATE SET
                  last_seen = excluded.last_seen,
                  name = excluded.name,
                  executable_path = excluded.executable_path,
                  bundle_id = excluded.bundle_id,
                  team_id = COALESCE(excluded.team_id, processes.team_id),
                  architecture = excluded.architecture,
                  is_translated = excluded.is_translated
                RETURNING id
                """)
        let id = try Int64.fetchOne(
            statement,
            arguments: [
                s.pid, s.startTime.timeIntervalSince1970, s.name, s.executablePath, s.bundleID,
                s.teamID, Int64(s.uid), s.architecture.rawValue, s.isTranslated,
                s.timestamp.timeIntervalSince1970, s.timestamp.timeIntervalSince1970,
            ])
        guard let id else { throw DatabaseError(message: "failed to upsert process row") }
        processIDCache[s.id] = id
        return id
    }

    private func insertProcessSample(_ s: ProcessSample, processID: Int64, db: Database) throws {
        let statement = try db.cachedStatement(
            sql: """
                INSERT OR REPLACE INTO process_samples
                (process_id, timestamp, phys_footprint, resident_size, virtual_size, lifetime_max_footprint,
                 cpu_percent, cpu_user, cpu_system, thread_count,
                 fd_total, fd_vnode, fd_socket, fd_pipe, fd_other,
                 disk_read, disk_written, data_source, footprint_readable, energy, energy_impact,
                 net_total)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
        try statement.execute(
            arguments: [
                processID, s.timestamp.timeIntervalSince1970,
                SQLInt.store(s.physFootprint), SQLInt.store(s.residentSize),
                SQLInt.store(s.virtualSize), SQLInt.store(s.lifetimeMaxFootprint),
                s.cpuPercent, SQLInt.store(s.cpuTimeUser), SQLInt.store(s.cpuTimeSystem),
                Int64(s.threadCount),
                Int64(s.fdTotal), Int64(s.fdVnode), Int64(s.fdSocket), Int64(s.fdPipe),
                Int64(s.fdOther),
                SQLInt.store(s.diskBytesRead), SQLInt.store(s.diskBytesWritten),
                s.dataSource.rawValue, s.footprintReadable,
                SQLInt.store(s.energyNanojoules), s.energyImpact,
                s.networkBytesPerSec,
            ])
    }

    // MARK: - Reading

    /// The most recent system sample, if any.
    public func latestSystemSample() throws -> SystemSample? {
        try pool.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT * FROM system_samples ORDER BY timestamp DESC LIMIT 1")
            else { return nil }
            return Self.decodeSystem(row)
        }
    }

    /// System samples at raw granularity at or after `since`, oldest first.
    public func systemSamples(since: Date) throws -> [SystemSample] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM system_samples WHERE timestamp >= ? ORDER BY timestamp ASC",
                arguments: [since.timeIntervalSince1970]
            )
            .map(Self.decodeSystem)
        }
    }

    /// Each process's most recent row, joined to its identity — the current
    /// snapshot across all processes. Process rows are change-gated, so there is
    /// no single tick at which every process wrote; taking `MAX(timestamp)` over
    /// the whole table and matching it would return only the handful that changed
    /// on the very last tick. Instead take the latest row *per process* (its
    /// last-written value, carried forward), which is the true current state.
    public func latestProcessSamples() throws -> [ProcessSample] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ps.*, p.pid AS p_pid, p.start_time AS p_start, p.name AS p_name,
                           p.executable_path AS p_path, p.bundle_id AS p_bundle, p.uid AS p_uid,
                           p.architecture AS p_arch, p.is_translated AS p_translated
                    FROM process_samples ps
                    JOIN processes p ON p.id = ps.process_id
                    JOIN (
                        SELECT process_id, MAX(timestamp) AS mts
                        FROM process_samples GROUP BY process_id
                    ) latest ON latest.process_id = ps.process_id AND latest.mts = ps.timestamp
                    """
            ).map(Self.decodeProcess)
        }
    }

    /// Footprint time-series (timestamp, bytes) for a process at raw granularity.
    public func footprintSeries(
        for identity: ProcessIdentity, since: Date
    ) throws -> [(Date, UInt64)] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT ps.timestamp AS ts, ps.phys_footprint AS fp
                    FROM process_samples ps
                    JOIN processes p ON p.id = ps.process_id
                    WHERE p.pid = ? AND p.start_time = ? AND ps.timestamp >= ?
                    ORDER BY ts ASC
                    """,
                arguments: [
                    identity.pid, identity.startTime.timeIntervalSince1970,
                    since.timeIntervalSince1970,
                ])
            return rows.map { row in
                let ts: Double = row["ts"]
                let fp: Int64 = row["fp"]
                return (Date(timeIntervalSince1970: ts), SQLInt.read(fp))
            }
        }
    }

    /// Row counts per table, for diagnostics and DB-size monitoring.
    public struct Stats: Sendable {
        public var processSamples: Int
        public var systemSamples: Int
        public var processMinute: Int
        public var processHour: Int
        public var systemMinute: Int
        public var systemHour: Int
        public var processes: Int
    }

    public func stats() throws -> Stats {
        try pool.read { db in
            func n(_ table: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return Stats(
                processSamples: try n("process_samples"),
                systemSamples: try n("system_samples"),
                processMinute: try n("process_minute"),
                processHour: try n("process_hour"),
                systemMinute: try n("system_minute"),
                systemHour: try n("system_hour"),
                processes: try n("processes")
            )
        }
    }

    // MARK: - Decoding

    static func decodeSystem(_ row: Row) -> SystemSample {
        let ts: Double = row["timestamp"]
        let level: Int = row["pressure_level"]
        return SystemSample(
            timestamp: Date(timeIntervalSince1970: ts),
            totalRAM: SQLInt.read(row["total_ram"]),
            free: SQLInt.read(row["free"]),
            active: SQLInt.read(row["active"]),
            inactive: SQLInt.read(row["inactive"]),
            wired: SQLInt.read(row["wired"]),
            speculative: SQLInt.read(row["speculative"]),
            compressed: SQLInt.read(row["compressed"]),
            appMemory: SQLInt.read(row["app_memory"]),
            cachedFiles: SQLInt.read(row["cached_files"]),
            swapTotal: SQLInt.read(row["swap_total"]),
            swapUsed: SQLInt.read(row["swap_used"]),
            pressureLevel: PressureLevel(rawLevel: level),
            pressurePercent: row["pressure_percent"],
            pageIns: SQLInt.read(row["page_ins"]),
            pageOuts: SQLInt.read(row["page_outs"]),
            compressions: SQLInt.read(row["compressions"]),
            decompressions: SQLInt.read(row["decompressions"]),
            pageInsDelta: SQLInt.read(row["page_ins_delta"]),
            pageOutsDelta: SQLInt.read(row["page_outs_delta"]),
            compressionsDelta: SQLInt.read(row["compressions_delta"]),
            decompressionsDelta: SQLInt.read(row["decompressions_delta"]),
            cpuLoad: row["cpu_load"],
            batteryPresent: (row["battery_present"] as Int64) != 0,
            batteryCharge: row["battery_charge"],
            batteryPowerWatts: row["battery_power"],
            batteryIsCharging: (row["battery_charging"] as Int64) != 0,
            batteryHealthPercent: row["battery_health"],
            batteryCycleCount: row["battery_cycles"],
            batteryTemperatureCelsius: row["battery_temp"],
            networkInBytesPerSec: row["net_in"],
            networkOutBytesPerSec: row["net_out"]
        )
    }

    static func decodeProcess(_ row: Row) -> ProcessSample {
        let ts: Double = row["timestamp"]
        let start: Double = row["p_start"]
        let archRaw: String = row["p_arch"]
        let path: String? = row["p_path"]
        let bundle: String? = row["p_bundle"]
        let source: String = row["data_source"]
        return ProcessSample(
            timestamp: Date(timeIntervalSince1970: ts),
            pid: row["p_pid"],
            ppid: 0,
            name: row["p_name"],
            executablePath: path,
            bundleID: bundle,
            physFootprint: SQLInt.read(row["phys_footprint"]),
            residentSize: SQLInt.read(row["resident_size"]),
            virtualSize: SQLInt.read(row["virtual_size"]),
            lifetimeMaxFootprint: SQLInt.read(row["lifetime_max_footprint"]),
            cpuPercent: row["cpu_percent"],
            cpuTimeUser: SQLInt.read(row["cpu_user"]),
            cpuTimeSystem: SQLInt.read(row["cpu_system"]),
            threadCount: row["thread_count"],
            fdTotal: row["fd_total"],
            fdVnode: row["fd_vnode"],
            fdSocket: row["fd_socket"],
            fdPipe: row["fd_pipe"],
            fdOther: row["fd_other"],
            diskBytesRead: SQLInt.read(row["disk_read"]),
            diskBytesWritten: SQLInt.read(row["disk_written"]),
            energyNanojoules: SQLInt.read(row["energy"]),
            energyImpact: row["energy_impact"],
            networkBytesPerSec: row["net_total"],
            isTranslated: (row["p_translated"] as Int) != 0,
            architecture: Architecture(rawValue: archRaw) ?? .unknown,
            startTime: Date(timeIntervalSince1970: start),
            uid: uid_t(truncatingIfNeeded: row["p_uid"] as Int64),
            dataSource: SampleSource(rawValue: source) ?? .directUserRead,
            footprintReadable: (row["footprint_readable"] as Int) != 0
        )
    }
}
