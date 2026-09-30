import Foundation
import GRDB

/// Read-only SQL views for AI agents (Claude Code, Codex, and `mpm`), so they
/// can reason over this Mac's history without learning the storage layout.
///
/// The raw tables are tuned for writing, not reading: system rows have 87
/// columns, history lives in three overlapping tiers (per second, per minute,
/// per hour), CPU is a 0 to 1 fraction for the Mac but a percent of one core
/// for a process, and rates are bytes per second. An agent querying them
/// directly gets plausible, wrong answers. These views stitch the tiers,
/// convert units, name things plainly, and classify processes the same way
/// Ask does. They are the contract; the tables behind them may change.
///
/// Views are dropped and recreated every time the database opens, so they
/// always match the current schema and never block a migration.
public enum AgentViews {
    /// Bumped whenever a view's columns change meaning. Agents are told it.
    public static let version = 1

    public struct Column: Sendable {
        public let name: String
        public let detail: String
    }

    public struct View: Sendable {
        public let name: String
        public let purpose: String
        public let columns: [Column]
        let sql: String
    }

    public static let all: [View] = [
        coverage, mac, system, systemByMinute, processes, processUsage, batteryDaily,
    ]

    /// Recreates every view. Cheap: a view is only its definition. A
    /// read-only connection (`mpm`) installs them as temporary views, which
    /// live only in that connection and never touch the file.
    public static func install(_ db: Database, temporary: Bool = false) throws {
        let kind = temporary ? "TEMP VIEW" : "VIEW"
        for view in all {
            try db.execute(
                sql:
                    "DROP \(temporary ? "VIEW IF EXISTS temp." : "VIEW IF EXISTS main.")\(view.name)"
            )
            try db.execute(sql: "CREATE \(kind) \(view.name) AS \(view.sql)")
        }
    }

    /// Facts about this Mac that turn raw numbers into shares, kept in `meta`
    /// (numbers only) so views can use them.
    public static func recordMacFacts(
        _ db: Database, cpuCores: Int, performanceCores: Int, efficiencyCores: Int,
        memoryBytes: UInt64
    ) throws {
        let facts: [(String, Double)] = [
            ("agent.cpu_cores", Double(cpuCores)),
            ("agent.performance_cores", Double(performanceCores)),
            ("agent.efficiency_cores", Double(efficiencyCores)),
            ("agent.memory_bytes", Double(memoryBytes)),
            ("agent.views_version", Double(version)),
        ]
        for (key, value) in facts {
            try db.execute(
                sql:
                    "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value])
        }
    }

    // MARK: Shared SQL

    /// The recorded core count, or this Mac's own: views are recreated on the
    /// Mac whose data they read, so the fallback is always the right Mac.
    private static let cores =
        "COALESCE((SELECT value FROM meta WHERE key = 'agent.cpu_cores'), \(ProcessInfo.processInfo.processorCount))"
    private static let gb = "1073741824.0"
    private static let mb = "1048576.0"

    private static func local(_ column: String) -> String {
        "datetime(\(column), 'unixepoch', 'localtime')"
    }

    private static func thermal(_ column: String) -> String {
        """
        CASE \(column) WHEN 0 THEN 'nominal' WHEN 1 THEN 'fair' WHEN 2 THEN 'serious' \
        WHEN 3 THEN 'critical' END
        """
    }

    /// The app bundle a process lives in: "Google Chrome" for its helpers.
    static func appName(_ path: String) -> String {
        let prefix = "substr(\(path), 1, instr(\(path), '.app/') - 1)"
        return """
            CASE WHEN instr(\(path), '.app/') > 0 THEN \
            replace(\(prefix), rtrim(\(prefix), replace(\(prefix), '/', '')), '') END
            """
    }

    /// Same classification as `AskProcessKind.classify`.
    private static func kind(_ path: String) -> String {
        let system = [
            "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/",
            "/Library/Apple/",
        ]
        .map { "\(path) LIKE '\($0)%'" }.joined(separator: " OR ")
        return """
            CASE WHEN \(path) IS NULL OR \(path) = '' OR \(path) = '\(SustainedCPU.launcherPath)' \
            THEN 'background' \
            WHEN \(system) THEN 'macos' WHEN instr(\(path), '.app/') > 0 THEN 'app' \
            ELSE 'background' END
            """
    }

    private static let systemColumns: [Column] = [
        Column(
            name: "ts",
            detail:
                "Start of the reading, Unix seconds (UTC). Filter on this column; it is indexed."),
        Column(name: "time_local", detail: "The same moment as local date and time text."),
        Column(
            name: "resolution_seconds",
            detail:
                "How much time the row covers: about 1 for live readings, 60 or 3600 for older summaries."
        ),
        Column(
            name: "cpu_percent",
            detail: "Whole-Mac processor use, 0 to 100 (all cores together). Average over the row."),
        Column(name: "cpu_peak_percent", detail: "Highest processor use within the row."),
        Column(
            name: "memory_pressure",
            detail:
                "macOS memory pressure index 0 to 100: under 34 is fine, 34 to 66 is compressing memory, 67 and over is swapping and slow."
        ),
        Column(name: "memory_pressure_peak", detail: "Highest memory pressure within the row."),
        Column(name: "app_memory_gb", detail: "Memory used by apps, GB."),
        Column(name: "compressed_gb", detail: "Memory macOS has compressed to make room, GB."),
        Column(
            name: "swap_used_gb",
            detail: "Disk space in use as extra memory, GB. Growth matters more than size."),
        Column(
            name: "network_in_kb_s", detail: "Network download rate, KB per second, all interfaces."
        ),
        Column(name: "network_out_kb_s", detail: "Network upload rate, KB per second."),
        Column(name: "disk_read_mb_s", detail: "Disk read rate, MB per second."),
        Column(name: "disk_write_mb_s", detail: "Disk write rate, MB per second."),
        Column(
            name: "disk_busy_percent", detail: "Share of time the busiest disk was busy, 0 to 100."),
        Column(name: "gpu_percent", detail: "Graphics chip use, 0 to 100. NULL when not sampled."),
        Column(
            name: "neural_engine_percent",
            detail:
                "Share of time the Neural Engine was active, 0 to 100. Needs macOS 27; NULL when not measured."
        ),
        Column(
            name: "cpu_temp_c",
            detail: "CPU die temperature, Celsius. NULL when the sensor is not read."),
        Column(
            name: "fan_rpm",
            detail: "Fan speed, rpm. 0 means off; NULL on Macs without a reported fan."),
        Column(
            name: "thermal_state",
            detail: "macOS heat level: nominal, fair, serious (slowing the chip) or critical."),
        Column(
            name: "battery_percent",
            detail: "Battery charge 0 to 100. NULL on Macs without a battery."),
        Column(name: "battery_watts", detail: "Power flowing in or out of the battery, watts."),
        Column(
            name: "startup_disk_free_gb", detail: "Free space on the startup disk, GB (decimal)."),
    ]

    private static func rawSystemArm() -> String {
        """
        SELECT timestamp AS ts, \(local("timestamp")) AS time_local, 1.0 AS resolution_seconds,
            cpu_load * 100 AS cpu_percent, cpu_load * 100 AS cpu_peak_percent,
            pressure_percent AS memory_pressure, pressure_percent AS memory_pressure_peak,
            app_memory / \(gb) AS app_memory_gb, compressed / \(gb) AS compressed_gb,
            swap_used / \(gb) AS swap_used_gb, net_in / 1024.0 AS network_in_kb_s,
            net_out / 1024.0 AS network_out_kb_s, disk_read / \(mb) AS disk_read_mb_s,
            disk_write / \(mb) AS disk_write_mb_s, disk_util AS disk_busy_percent, gpu_util AS gpu_percent,
            ane_time / 10.0 AS neural_engine_percent, cpu_die AS cpu_temp_c, fan_rpm,
            \(thermal("thermal_state")) AS thermal_state,
            CASE WHEN battery_present = 1 THEN battery_charge END AS battery_percent,
            CASE WHEN battery_present = 1 THEN battery_power END AS battery_watts,
            boot_free / 1e9 AS startup_disk_free_gb
        FROM system_samples
        """
    }

    private static func tierSystemArm(_ table: String) -> String {
        """
        SELECT bucket AS ts, \(local("bucket")) AS time_local, bucket_seconds AS resolution_seconds,
            cpu_avg * 100 AS cpu_percent, cpu_max * 100 AS cpu_peak_percent,
            pressure_avg AS memory_pressure, pressure_max AS memory_pressure_peak,
            app_avg / \(gb) AS app_memory_gb, compressed_avg / \(gb) AS compressed_gb,
            swap_used_avg / \(gb) AS swap_used_gb, net_in_avg / 1024.0 AS network_in_kb_s,
            net_out_avg / 1024.0 AS network_out_kb_s, disk_read_avg / \(mb) AS disk_read_mb_s,
            disk_write_avg / \(mb) AS disk_write_mb_s, disk_util_avg AS disk_busy_percent,
            gpu_util_avg AS gpu_percent, ane_time_avg / 10.0 AS neural_engine_percent,
            cpu_die_avg AS cpu_temp_c, fan_rpm_avg AS fan_rpm,
            \(thermal("thermal_state_max")) AS thermal_state,
            CASE WHEN battery_charge_avg > 0 THEN battery_charge_avg END AS battery_percent,
            CASE WHEN battery_charge_avg > 0 THEN battery_power_avg END AS battery_watts,
            boot_free_avg / 1e9 AS startup_disk_free_gb
        FROM \(table)
        """
    }

    // MARK: Views

    static let system = View(
        name: "agent_system",
        purpose: """
            Whole-Mac readings over time at the finest detail kept: about one row a second for the \
            last few hours, one a minute for about a week before that, one an hour for older history. \
            Use for "what was the Mac doing between X and Y". Aggregate with resolution_seconds as the weight.
            """,
        columns: systemColumns,
        sql: """
            \(rawSystemArm())
            UNION ALL
            \(tierSystemArm("system_minute"))
            WHERE bucket < COALESCE((SELECT MIN(timestamp) FROM system_samples), 1e12)
            UNION ALL
            \(tierSystemArm("system_hour"))
            WHERE bucket < COALESCE((SELECT MIN(bucket) FROM system_minute),
                (SELECT MIN(timestamp) FROM system_samples), 1e12)
            """)

    static let systemByMinute = View(
        name: "agent_system_by_minute",
        purpose: """
            The same readings at one row a minute (one an hour for the oldest history). Much smaller \
            than agent_system; prefer it for anything longer than an hour or two.
            """,
        columns: systemColumns,
        sql: """
            \(tierSystemArm("system_minute"))
            UNION ALL
            \(tierSystemArm("system_hour"))
            WHERE bucket < COALESCE((SELECT MIN(bucket) FROM system_minute), 1e12)
            """)

    static let processes = View(
        name: "agent_processes",
        purpose: """
            Every process the app has recorded, one row per run. A restarted app gets a new \
            process_key. kind says whether it is an app (quittable), part of macOS, or a background process.
            """,
        columns: [
            Column(
                name: "process_key",
                detail: "Identifies one run of a process. Join agent_process_usage on it."),
            Column(
                name: "pid", detail: "Process ID. macOS reuses these, so never join on pid alone."),
            Column(
                name: "name",
                detail: "Process name as macOS reports it (may be shortened to 15 characters)."),
            Column(
                name: "app",
                detail:
                    "The app it belongs to, from its bundle path (\"Google Chrome\" for Chrome's helpers). NULL outside an app."
            ),
            Column(name: "kind", detail: "app, macos or background."),
            Column(name: "bundle_id", detail: "Bundle identifier, when it has one."),
            Column(name: "executable_path", detail: "Full path to the executable."),
            Column(name: "started_local", detail: "When this run started, local time."),
            Column(name: "first_seen_local", detail: "When the app first recorded it, local time."),
            Column(name: "last_seen_local", detail: "When the app last recorded it, local time."),
            Column(name: "started_ts", detail: "When this run started, Unix seconds."),
            Column(name: "last_seen_ts", detail: "When the app last recorded it, Unix seconds."),
            Column(
                name: "runs_under_rosetta",
                detail: "1 when it is an Intel app translated by Rosetta."),
            Column(name: "architecture", detail: "arm64, x86_64 or unknown."),
        ],
        sql: """
            SELECT id AS process_key, pid, name, \(appName("executable_path")) AS app,
                \(kind("executable_path")) AS kind, bundle_id, executable_path,
                \(local("start_time")) AS started_local, \(local("first_seen")) AS first_seen_local,
                \(local("last_seen")) AS last_seen_local, start_time AS started_ts, last_seen AS last_seen_ts,
                is_translated AS runs_under_rosetta, architecture
            FROM processes
            """)

    static let processUsage = View(
        name: "agent_process_usage",
        purpose: """
            What each process used, one row per process per minute (per hour for older history). \
            The current minute appears once it completes. Averages cover only the time the process \
            was running; to rank apps over a period, SUM cpu_share_of_mac_percent * resolution_seconds \
            and divide by the period's length.
            """,
        columns: [
            Column(name: "process_key", detail: "Joins agent_processes."),
            Column(name: "name", detail: "Process name."),
            Column(name: "app", detail: "The app it belongs to, or NULL."),
            Column(name: "kind", detail: "app, macos or background."),
            Column(
                name: "ts", detail: "Start of the minute or hour, Unix seconds. Filter on this."),
            Column(name: "time_local", detail: "The same moment, local time."),
            Column(name: "resolution_seconds", detail: "60 or 3600."),
            Column(
                name: "cpu_percent_of_one_core",
                detail: "Average CPU as a percent of ONE core; can exceed 100 on a multi-core Mac."),
            Column(
                name: "cpu_peak_percent_of_one_core",
                detail: "Highest CPU in the row, percent of one core."),
            Column(
                name: "cpu_share_of_mac_percent",
                detail: "Average CPU as a share of the whole Mac, 0 to 100."),
            Column(
                name: "memory_mb",
                detail: "Average memory footprint, MB (what Activity Monitor calls Memory)."),
            Column(name: "memory_peak_mb", detail: "Highest footprint in the row, MB."),
            Column(name: "gpu_percent", detail: "Average share of the graphics chip, 0 to 100."),
            Column(
                name: "network_kb_s",
                detail:
                    "Average network traffic, KB per second, when per-app network tracking is on; 0 otherwise."
            ),
            Column(
                name: "energy_impact",
                detail: "Average energy impact score (relative, as in Activity Monitor)."),
            Column(
                name: "disk_read_total_bytes",
                detail:
                    "Bytes read since the process started (a running total, so take differences)."),
            Column(
                name: "disk_written_total_bytes",
                detail: "Bytes written since the process started (running total)."),
        ],
        sql: """
            SELECT u.process_id AS process_key, p.name, p.app, p.kind, u.bucket AS ts,
                \(local("u.bucket")) AS time_local, 60.0 AS resolution_seconds,
                u.cpu_avg AS cpu_percent_of_one_core, u.cpu_max AS cpu_peak_percent_of_one_core,
                u.cpu_avg / \(cores) AS cpu_share_of_mac_percent,
                u.footprint_avg / \(mb) AS memory_mb, u.footprint_max / \(mb) AS memory_peak_mb,
                u.gpu_avg AS gpu_percent, u.net_avg / 1024.0 AS network_kb_s, u.energy_avg AS energy_impact,
                u.disk_read_max AS disk_read_total_bytes, u.disk_written_max AS disk_written_total_bytes
            FROM process_minute u JOIN agent_processes p ON p.process_key = u.process_id
            UNION ALL
            SELECT u.process_id, p.name, p.app, p.kind, u.bucket, \(local("u.bucket")), 3600.0,
                u.cpu_avg, u.cpu_max, u.cpu_avg / \(cores), u.footprint_avg / \(mb), u.footprint_max / \(mb),
                u.gpu_avg, u.net_avg / 1024.0, u.energy_avg, u.disk_read_max, u.disk_written_max
            FROM process_hour u JOIN agent_processes p ON p.process_key = u.process_id
            WHERE u.bucket < COALESCE((SELECT MIN(bucket) FROM process_minute), 1e12)
            """)

    static let coverage = View(
        name: "agent_coverage",
        purpose:
            "What history exists: each tier's first and last reading. Check this before concluding nothing happened.",
        columns: [
            Column(name: "tier", detail: "live (about one row a second), minute or hour."),
            Column(name: "first_local", detail: "Oldest reading kept, local time."),
            Column(name: "last_local", detail: "Newest reading, local time."),
            Column(name: "rows", detail: "How many rows the tier holds."),
        ],
        sql: """
            SELECT 'live' AS tier, \(local("MIN(timestamp)")) AS first_local, \(local("MAX(timestamp)")) AS last_local,
                COUNT(*) AS rows FROM system_samples
            UNION ALL
            SELECT 'minute', \(local("MIN(bucket)")), \(local("MAX(bucket)")), COUNT(*) FROM system_minute
            UNION ALL
            SELECT 'hour', \(local("MIN(bucket)")), \(local("MAX(bucket)")), COUNT(*) FROM system_hour
            """)

    static let mac = View(
        name: "agent_mac",
        purpose: "Facts about this Mac the app records at launch: core counts and memory.",
        columns: [
            Column(
                name: "fact",
                detail:
                    "cpu_cores, performance_cores, efficiency_cores, memory_bytes or views_version."
            ),
            Column(name: "value", detail: "The number."),
        ],
        sql: """
            SELECT substr(key, 7) AS fact, value FROM meta WHERE key LIKE 'agent.%'
            """)

    static let batteryDaily = View(
        name: "agent_battery_daily",
        purpose: "Battery health once a day, for long-term wear.",
        columns: [
            Column(name: "day", detail: "The date, YYYY-MM-DD."),
            Column(
                name: "health_percent",
                detail: "Full charge capacity as a share of design capacity."),
            Column(name: "cycle_count", detail: "Charge cycles so far."),
            Column(name: "full_capacity_mah", detail: "Full charge capacity, mAh."),
            Column(name: "design_capacity_mah", detail: "Design capacity, mAh."),
        ],
        sql: """
            SELECT date(day, 'unixepoch') AS day, health_percent, cycle_count, full_capacity_mah,
                design_capacity_mah FROM battery_daily
            """)
}
