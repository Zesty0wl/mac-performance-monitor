import Foundation
import GRDB

public struct AskDataRead: Sendable {
    public let result: AskToolResult
    public let identities: [String: ProcessIdentity]

    public init(result: AskToolResult, identities: [String: ProcessIdentity] = [:]) {
        self.result = result
        self.identities = identities
    }
}

extension SampleStore {
    public func readAskData(
        _ call: AskToolCall, at capturedAt: Date, process: ProcessIdentity? = nil
    ) throws -> AskDataRead {
        let domain = try call.domain(relativeTo: capturedAt)
        let data = try readAskDataResult(call, domain: domain, process: process)
        return AskDataRead(
            result: AskToolResult(
                facts: data.result.facts, limits: data.result.limits,
                processes: data.result.processes,
                timeWindows: [
                    AskEvidenceWindow(
                        start: domain.lowerBound, end: domain.upperBound, kind: .requested)
                ] + data.result.timeWindows),
            identities: data.identities)
    }

    private func readAskDataResult(
        _ call: AskToolCall, domain: ClosedRange<Date>, process: ProcessIdentity?
    ) throws -> AskDataRead {
        if call.name == .findProcesses {
            let matches = try explorerProcesses(
                from: domain.lowerBound, to: domain.upperBound, search: call.search, limit: 5)
            let references = matches.map { _ in UUID().uuidString }
            return AskDataRead(
                result: AskToolResult(
                    facts: [],
                    limits: matches.isEmpty
                        ? [t("No matching recorded process was found in this interval.")] : [],
                    processes: zip(references, matches).map {
                        AskProcessReference(reference: $0, name: $1.name)
                    }),
                identities: Dictionary(uniqueKeysWithValues: zip(references, matches.map(\.id))))
        }
        var tier = try finestGranularityCovering(from: domain.lowerBound, to: domain.upperBound)
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        if span > 2 * 86400 {
            tier = .hour
        } else if span > 2 * 3600, tier == .raw {
            tier = .minute
        }
        switch call.name {
        case .systemHistory:
            let count = try databasePool.read { database in
                let start = domain.lowerBound.timeIntervalSince1970
                let end = domain.upperBound.timeIntervalSince1970
                let minuteWatermark = try Retention.meta(database, "minute_watermark") ?? start
                let hourWatermark = try Retention.meta(database, "hour_watermark") ?? start
                return try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM (
                            SELECT timestamp FROM system_samples WHERE timestamp >= ? AND timestamp <= ?
                            UNION ALL SELECT bucket FROM system_minute WHERE ? AND bucket >= ? AND bucket <= ?
                            UNION ALL SELECT bucket FROM system_hour WHERE ? AND bucket >= ? AND bucket <= ?
                            LIMIT 8001)
                        """,
                    arguments: [
                        tier == .raw ? start : max(start, minuteWatermark), end,
                        tier != .raw,
                        tier == .hour ? max(start - 3600, hourWatermark) : start - 3600, end,
                        tier == .hour, start - 3600, end,
                    ]) ?? 0
            }
            guard count <= 8000 else {
                return AskDataRead(
                    result: AskToolResult(
                        facts: [],
                        limits: [
                            t("This interval contains too many records. Choose a shorter interval.")
                        ]), identities: [:])
            }
            let points = try systemHistory(
                from: domain.lowerBound, to: domain.upperBound, granularity: tier
            ).filter {
                $0.date >= domain.lowerBound
                    && $0.date.addingTimeInterval($0.bucketDuration) <= domain.upperBound
            }
            let summary = AskDataSummary.system(points, metric: call.metric, domain: domain)
            if [.cpu, .memory, .swap].contains(call.metric) {
                let memory = try askMemoryHistory(metric: call.metric, domain: domain)
                return AskDataRead(
                    result: AskToolResult(
                        facts: summary.facts + memory.facts, limits: memory.limits + summary.limits,
                        timeWindows: summary.timeWindows + memory.timeWindows),
                    identities: [:])
            }
            return AskDataRead(result: summary, identities: [:])
        case .topProcesses:
            return try askTopProcesses(call.metric, domain: domain, tier: tier)
        case .processHistory:
            guard let process else { throw AskInvestigationError.unknownProcess }
            let histories = try explorerProcessHistories(
                identities: [process], from: domain.lowerBound, to: domain.upperBound,
                granularity: tier, maximumPointCount: 8000)
            guard let history = histories.first else {
                return AskDataRead(
                    result: AskToolResult(
                        facts: [],
                        limits: [t("No process measurements were recorded in this interval.")]),
                    identities: [:])
            }
            return AskDataRead(
                result: AskDataSummary.process(
                    history, metric: call.metric, reference: call.processReference, domain: domain),
                identities: [call.processReference: process])
        case .findProcesses: throw AskInvestigationError.invalidToolCall
        }
    }

    private func askMemoryHistory(
        metric: AskDiagnosticMetric, domain: ClosedRange<Date>
    ) throws -> AskToolResult {
        let rows = try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT timestamp,
                        CASE WHEN pressure_sample_valid = 1 THEN
                            CASE pressure_level WHEN ? THEN 0 WHEN ? THEN 1 WHEN ? THEN 2 END END AS pressure,
                        CASE WHEN swap_sample_valid = 1 THEN CAST(swap_used AS REAL) END AS swap,
                        swap_in_rate, swap_out_rate
                    FROM system_samples WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp LIMIT 8001
                    """,
                arguments: [
                    PressureLevel.normal.rawValue, PressureLevel.warning.rawValue,
                    PressureLevel.critical.rawValue,
                    domain.lowerBound.timeIntervalSince1970,
                    domain.upperBound.timeIntervalSince1970,
                ])
        }
        guard rows.count <= 8000 else { throw AskExplanationError.contextLimit }
        let dates = rows.map { Date(timeIntervalSince1970: $0["timestamp"]) }
        var facts: [AskExplanationFact] = []
        var windows: [AskEvidenceWindow] = []
        var limits = AskDataSummary.coverage(
            dates, durations: Array(repeating: 0, count: dates.count), domain: domain)
        if metric != .swap {
            let valid = rows.filter { ($0["pressure"] as Int?) != nil }
            if let worst = valid.compactMap({ $0["pressure"] as Int? }).max(),
                let first = valid.first, let last = valid.last
            {
                windows.append(
                    AskEvidenceWindow(
                        start: Date(timeIntervalSince1970: first["timestamp"]),
                        end: Date(timeIntervalSince1970: last["timestamp"])))
                facts.append(
                    AskExplanationFact(
                        id: "pressure", name: t("Worst recorded memory pressure"),
                        value: worst == 0 ? t("Normal") : worst == 1 ? t("Warning") : t("Critical"),
                        meaning: AskDataSummary.interval(
                            Date(timeIntervalSince1970: first["timestamp"]),
                            Date(timeIntervalSince1970: last["timestamp"])) + " "
                            + t(
                                "Valid macOS pressure readings only. Normal pressure weighs against memory strain during these observations."
                            )))
            }
            if valid.count < rows.count || valid.isEmpty {
                limits.insert(
                    t(
                        "Memory pressure validity is missing for part or all of this interval. Older aggregates cannot recover it."
                    ), at: 0)
            }
        }
        if metric == .swap || metric == .memory {
            let fields =
                [
                    AskDataSummary.Field(
                        id: "swap-in", name: t("Swap read rate"),
                        values: rows.map { $0["swap_in_rate"] as Double? }, metric: .disk),
                    AskDataSummary.Field(
                        id: "swap-out", name: t("Swap write rate"),
                        values: rows.map { $0["swap_out_rate"] as Double? }, metric: .disk),
                ]
                + (metric == .swap
                    ? [
                        AskDataSummary.Field(
                            id: "swap", name: t("Swap used"),
                            values: rows.map { $0["swap"] as Double? }, metric: .memory)
                    ] : [])
            let summary = AskDataSummary.summarize(
                fields, dates: dates, durations: Array(repeating: 0, count: rows.count),
                weights: Array(repeating: 1, count: rows.count), domain: domain)
            facts += summary.facts
            limits = summary.limits + limits
            windows += summary.timeWindows
        }
        return AskToolResult(facts: facts, limits: limits, timeWindows: windows)
    }

    private func askTopProcesses(
        _ metric: AskDiagnosticMetric, domain: ClosedRange<Date>, tier: HistoryWindow.Granularity
    ) throws -> AskDataRead {
        let columns: (String, String)
        switch metric {
        case .cpu: columns = ("cpu_percent", "cpu_max")
        case .memory:
            columns = ("CASE WHEN footprint_readable = 1 THEN phys_footprint END", "footprint_max")
        case .gpu: columns = ("gpu_percent", "gpu_max")
        case .network: columns = ("net_total", "net_max")
        case .energy: columns = ("energy_impact", "energy_max")
        case .files: columns = ("fd_total", "fd_max")
        case .disk:
            columns = (
                "CAST(disk_read AS REAL) + disk_written",
                "CAST(disk_read_max AS REAL) + disk_written_max"
            )
        default: throw AskInvestigationError.invalidToolCall
        }
        return try databasePool.read { database in
            var lower = domain.lowerBound.timeIntervalSince1970
            let upper = domain.upperBound.timeIntervalSince1970
            var parts: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            func append(_ table: String, time: String, column: String, until: Double) {
                guard lower <= until else { return }
                parts.append(
                    "SELECT process_id, \(time) AS observed, \(column) AS value FROM \(table) WHERE \(time) >= ? AND \(time) <= ?"
                )
                arguments += [lower, until]
            }
            if tier == .hour {
                let watermark = try Retention.meta(database, "hour_watermark") ?? lower
                append(
                    "process_hour", time: "bucket", column: columns.1,
                    until: min(upper, watermark.nextDown))
                lower = max(lower, watermark)
            }
            if tier != .raw {
                let watermark = try Retention.meta(database, "minute_watermark") ?? lower
                append(
                    "process_minute", time: "bucket", column: columns.1,
                    until: min(upper, watermark.nextDown))
                lower = max(lower, watermark)
            }
            append("process_samples", time: "timestamp", column: columns.0, until: upper)
            guard !parts.isEmpty else {
                return AskDataRead(
                    result: AskToolResult(
                        facts: [],
                        limits: [t("No process measurements were recorded in this interval.")]),
                    identities: [:])
            }
            let source = parts.joined(separator: " UNION ALL ")
            let count =
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM (SELECT 1 FROM (\(source)) LIMIT 50001)
                        """, arguments: StatementArguments(arguments)) ?? 0
            guard count <= 50000 else {
                return AskDataRead(
                    result: AskToolResult(
                        facts: [],
                        limits: [
                            t(
                                "This interval contains too many process records. Choose a shorter interval or a named process."
                            )
                        ]), identities: [:])
            }
            let statistic =
                metric == .disk
                ? "CASE WHEN MAX(observed) > MIN(observed) THEN (MAX(value) - MIN(value)) / (MAX(observed) - MIN(observed)) END"
                : "MAX(value)"
            let rows = try Row.fetchAll(
                database,
                sql: """
                    WITH source AS (
                        \(source)
                    ), ranked AS (
                        SELECT process_id, \(statistic) AS score, MIN(observed) AS first, MAX(observed) AS last
                        FROM source WHERE value >= 0 GROUP BY process_id
                    )
                    SELECT p.pid, p.start_time, p.name, p.executable_path, ranked.score, ranked.first, ranked.last
                    FROM ranked JOIN processes p ON p.id = ranked.process_id
                    WHERE ranked.score IS NOT NULL ORDER BY ranked.score DESC, p.id LIMIT 5
                    """, arguments: StatementArguments(arguments))
            var facts: [AskExplanationFact] = []
            var identities: [String: ProcessIdentity] = [:]
            var processes: [AskProcessReference] = []
            var windows: [AskEvidenceWindow] = []
            for row in rows {
                let value: Double = row["score"]
                guard value.isFinite, value >= 0 else { continue }
                let reference = UUID().uuidString
                let name = ProcessSample.resolvedDisplayName(
                    name: row["name"], executablePath: row["executable_path"])
                identities[reference] = ProcessIdentity(
                    pid: row["pid"], startTime: Date(timeIntervalSince1970: row["start_time"]))
                processes.append(AskProcessReference(reference: reference, name: name))
                let interval = AskDataSummary.interval(
                    Date(timeIntervalSince1970: row["first"]),
                    Date(timeIntervalSince1970: row["last"]))
                windows.append(
                    AskEvidenceWindow(
                        start: Date(timeIntervalSince1970: row["first"]),
                        end: Date(timeIntervalSince1970: row["last"])))
                facts.append(
                    AskExplanationFact(
                        id: "process-\(facts.count)", name: name,
                        value: AskDataSummary.format(value, metric: metric),
                        meaning: interval + " "
                            + (metric == .disk
                                ? t(
                                    "Mean attributed disk bytes over observed endpoints, not physical disk saturation."
                                )
                                : t(
                                    "Highest recorded value, not typical use or proof of a fault. Process CPU is a share of one core."
                                )),
                        processReference: reference))
            }
            var limits = [
                t(
                    "Rankings include recorded processes only. Missing or unreadable processes are not idle."
                )
            ]
            if tier != .raw {
                limits.append(
                    t(
                        "Older records are aggregates. Short spikes and exact timing may be unavailable."
                    ))
            }
            if metric == .network {
                limits.append(
                    t(
                        "Per-process network history is meaningful only while network tracking was enabled."
                    ))
            }
            return AskDataRead(
                result: AskToolResult(
                    facts: facts, limits: limits, processes: processes, timeWindows: windows),
                identities: identities)
        }
    }
}

private enum AskDataSummary {
    struct Field {
        let id: String
        let name: String
        let values: [Double?]
        let metric: AskDiagnosticMetric
        var suffix = ""
        var highs: [Double?]? = nil
        var weights: [Double]? = nil
        var meaning = ""
    }

    static func system(
        _ points: [SystemHistoryPoint], metric: AskDiagnosticMetric, domain: ClosedRange<Date>
    ) -> AskToolResult {
        let fields: [Field]
        switch metric {
        case .cpu:
            fields = [
                Field(
                    id: "cpu", name: t("Whole-machine CPU"),
                    values: points.map { $0.cpuLoad * 100 }, metric: .cpu,
                    highs: points.map {
                        $0.bucketDuration == 0
                            ? $0.cpuLoad * 100 : $0.peaks.map { $0.cpuLoad * 100 }
                    })
            ]
        case .memory:
            fields = [
                Field(
                    id: "compressed", name: t("Compressed memory"),
                    values: points.map { Double($0.compressed) }, metric: .memory)
            ]
        case .swap: return AskToolResult(facts: [], limits: [])
        case .disk:
            fields = [
                Field(
                    id: "busy", name: t("Busiest disk activity"),
                    values: points.map(\.diskUtilizationPercent), metric: .cpu),
                Field(
                    id: "read-latency", name: t("Disk read service time"),
                    values: points.map(\.diskReadLatencyMs), metric: .files, suffix: " ms"),
                Field(
                    id: "write-latency", name: t("Disk write service time"),
                    values: points.map(\.diskWriteLatencyMs), metric: .files, suffix: " ms"),
            ]
        case .network:
            fields = [
                Field(
                    id: "download", name: t("Download traffic"),
                    values: points.map(\.networkInBytesPerSec), metric: .network),
                Field(
                    id: "upload", name: t("Upload traffic"),
                    values: points.map(\.networkOutBytesPerSec), metric: .network),
            ]
        case .gpu:
            fields = [
                Field(
                    id: "gpu", name: t("GPU activity"), values: points.map(\.gpuUtilization),
                    metric: .gpu),
                Field(
                    id: "ane-time", name: t("ANE time"),
                    values: points.map(\.aneTimeMillisecondsPerSecond),
                    metric: .files, suffix: " ms/s",
                    highs: points.map { $0.effectivePeaks.aneTimeMillisecondsPerSecond },
                    weights: points.map {
                        Double(
                            $0.aneSampleCount ?? ($0.aneTimeMillisecondsPerSecond == nil ? 0 : 1))
                    },
                    meaning: t(
                        "Accounted ANE time per second, not percent of compute capacity. Partial readings are lower bounds. Missing readings are gaps."
                    )),
            ]
        case .thermal:
            let worst = points.compactMap(\.thermalPressure).max()
            return AskToolResult(
                facts: worst.map {
                    [
                        AskExplanationFact(
                            id: "thermal", name: t("Worst recorded thermal pressure"),
                            value: $0.label,
                            meaning: interval(
                                points.first?.date ?? domain.lowerBound,
                                points.last?.date ?? domain.upperBound))
                    ]
                } ?? [],
                limits: (worst == nil
                    ? [
                        t(
                            "No valid values for this metric were recorded in the requested interval."
                        )
                    ] : [])
                    + coverage(
                        points.map(\.date), durations: points.map(\.bucketDuration), domain: domain),
                timeWindows: points.first.flatMap { first in
                    points.last.map { [AskEvidenceWindow(start: first.date, end: $0.date)] }
                } ?? []
            )
        case .energy:
            fields = [
                Field(
                    id: "gpu-power", name: t("GPU power"), values: points.map(\.gpuPowerWatts),
                    metric: .energy, suffix: " W"),
                Field(
                    id: "ane-power", name: t("ANE power"), values: points.map(\.anePowerWatts),
                    metric: .energy, suffix: " W",
                    highs: points.map { $0.effectivePeaks.anePowerWatts },
                    weights: points.map {
                        Double($0.anePowerSampleCount ?? ($0.anePowerWatts == nil ? 0 : 1))
                    },
                    meaning: t("Reported ANE power is an estimate, not a measure of utilization.")),
            ]
        case .files: fields = []
        }
        let summary = summarize(
            fields, dates: points.map(\.date), durations: points.map(\.bucketDuration),
            weights: points.map { Double($0.sampleCount) }, domain: domain,
            machineCPU: metric == .cpu)
        var limits = summary.limits
        if metric == .gpu,
            points.contains(where: {
                $0.aneTimeMillisecondsPerSecond != nil && $0.aneSampleIsPartial != false
            })
        {
            limits.insert(
                t(
                    "ANE coverage is partial. Accounted time is a lower bound and cannot establish inactivity."
                ), at: 0)
        }
        if metric == .energy {
            limits.insert(
                t(
                    "ANE power is not used to infer activity. GPU history includes accounted ANE time when available."
                ), at: 0)
        }
        return AskToolResult(facts: summary.facts, limits: limits, timeWindows: summary.timeWindows)
    }

    static func process(
        _ history: ExplorerProcessHistory, metric: AskDiagnosticMetric, reference: String,
        domain: ClosedRange<Date>
    ) -> AskToolResult {
        let selected: ExplorerProcessMetric
        switch metric {
        case .cpu: selected = .cpu
        case .memory: selected = .footprint
        case .disk: selected = .diskWrite
        case .network: selected = .network
        case .gpu: selected = .gpu
        case .energy: selected = .energyImpact
        case .files: selected = .fileDescriptors
        default:
            return AskToolResult(
                facts: [], limits: [t("This metric is not recorded for an individual process.")])
        }
        let points = history.points.filter {
            $0.date >= domain.lowerBound
                && $0.date.addingTimeInterval($0.duration) <= domain.upperBound
        }
        if metric == .disk {
            var changes: [Double] = []
            for (previous, current) in zip(points, points.dropFirst()) {
                let duration = current.date.timeIntervalSince(previous.date)
                guard !current.startsNewRun, duration > 0,
                    duration <= max(120, previous.duration * 2),
                    let oldRead = previous.values[.diskRead],
                    let newRead = current.values[.diskRead],
                    let oldWrite = previous.values[.diskWrite],
                    let newWrite = current.values[.diskWrite],
                    newRead >= oldRead, newWrite >= oldWrite
                else { continue }
                changes.append((newRead - oldRead + newWrite - oldWrite) / duration)
            }
            let value = changes.filter { $0.isFinite && $0 >= 0 }.max()
            return AskToolResult(
                facts: value.map {
                    [
                        AskExplanationFact(
                            id: "disk-peak", name: history.process.name,
                            value: format($0, metric: .disk),
                            meaning: interval(
                                points.first?.date ?? domain.lowerBound,
                                points.last?.date ?? domain.upperBound) + " "
                                + t(
                                    "Largest observed disk rate between valid endpoints. Restarts and long gaps are excluded."
                                ), processReference: reference)
                    ]
                } ?? [],
                limits: coverage(
                    points.map(\.date), durations: points.map(\.duration), domain: domain),
                timeWindows: points.first.flatMap { first in
                    points.last.map { [AskEvidenceWindow(start: first.date, end: $0.date)] }
                } ?? [])
        }
        let field = Field(
            id: metric.rawValue, name: history.process.name,
            values: points.map { $0.values[selected] }, metric: metric,
            highs: points.map { $0.maxima[selected] })
        let summary = summarize(
            [field], dates: points.map(\.date), durations: points.map(\.duration),
            weights: points.map(\.weight), domain: domain)
        var facts = summary.facts.map {
            AskExplanationFact(
                id: $0.id, name: $0.name, value: $0.value, meaning: $0.meaning,
                processReference: reference, scope: "recorded_interval")
        }
        if let first = points.first?.values[selected], let last = points.last?.values[selected],
            first.isFinite, last.isFinite,
            (metric == .memory || metric == .files), !points.contains(where: \.startsNewRun)
        {
            let difference = last - first
            facts.append(
                AskExplanationFact(
                    id: "change", name: history.process.name,
                    value: (difference < 0 ? "-" : difference > 0 ? "+" : "")
                        + format(abs(difference), metric: metric),
                    meaning: t(
                        "Change between recorded endpoints. This alone does not establish a leak."),
                    processReference: reference))
        }
        return AskToolResult(
            facts: facts,
            limits: summary.limits + [
                t(
                    "Process samples can be sparse. Recorded averages do not prove continuous activity, and process CPU uses a one-core scale."
                )
            ], timeWindows: summary.timeWindows)
    }

    static func summarize(
        _ fields: [Field], dates: [Date], durations: [Double], weights: [Double],
        domain: ClosedRange<Date>, machineCPU: Bool = false
    ) -> AskToolResult {
        var facts: [AskExplanationFact] = []
        var windows: [AskEvidenceWindow] = []
        let times = dates.map(\.timeIntervalSince1970)
        for field in fields {
            let values = field.values.map { value in
                value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? .nan
            }
            let highs =
                field.highs?.map { $0 ?? .nan }
                ?? zip(values, durations).map { $1 == 0 ? $0 : .nan }
            let buckets = ChartStatistics.buckets(
                times: times[...], values: values[...], highs: highs[...],
                weights: (field.weights ?? weights)[...],
                durations: durations[...],
                width: max(1, domain.upperBound.timeIntervalSince(domain.lowerBound)),
                range: domain.lowerBound
                    .timeIntervalSince1970...domain.upperBound.timeIntervalSince1970,
                gapThreshold: 120)
            guard let summary = ChartStatistics.summary(buckets), let first = buckets.first,
                let last = buckets.last
            else { continue }
            let observed = interval(
                Date(timeIntervalSince1970: first.firstTime),
                Date(timeIntervalSince1970: last.lastTime))
            windows.append(
                AskEvidenceWindow(
                    start: Date(timeIntervalSince1970: first.firstTime),
                    end: Date(timeIntervalSince1970: last.lastTime)))
            for (label, value) in [("mean", summary.mean), ("largest", summary.maximum ?? .nan)]
            where value.isFinite {
                let assessment =
                    machineCPU && label == "mean" && value >= 80
                    ? t(
                        "High whole-machine CPU in the recorded interval. This is heavy load, not proof of a fault."
                    ) + " " : ""
                facts.append(
                    AskExplanationFact(
                        id: field.id + "-" + label,
                        name: label == "mean"
                            ? t("%@ (recorded mean)", field.name)
                            : t("%@ (largest recorded value)", field.name),
                        value: format(value, metric: field.metric) + field.suffix,
                        meaning: (field.meaning.isEmpty ? "" : field.meaning + " ") + assessment
                            + observed + " "
                            + t(
                                "Mean uses stored sample weights, not elapsed time. Aggregate values can hide brief spikes."
                            )))
            }
        }
        var limits = coverage(dates, durations: durations, domain: domain)
        if facts.isEmpty {
            limits.insert(
                t("No valid values for this metric were recorded in the requested interval."), at: 0
            )
        }
        return AskToolResult(facts: facts, limits: limits, timeWindows: windows)
    }

    static func coverage(
        _ dates: [Date], durations: [Double], domain: ClosedRange<Date>
    ) -> [String] {
        guard let first = dates.first, let last = dates.last else {
            return [t("No measurements were recorded in the requested interval.")]
        }
        var limits: [String] = []
        if first > domain.lowerBound.addingTimeInterval(120)
            || last.addingTimeInterval(durations.last ?? 0)
                < domain.upperBound.addingTimeInterval(-120)
            || zip(dates.indices, dates.dropFirst()).contains(where: {
                $1.timeIntervalSince(dates[$0]) > max(120, durations[$0] + 120)
            })
        {
            limits.append(
                t(
                    "Recording does not cover the whole interval. Gaps are unknown activity, not idle time."
                ))
        }
        if durations.contains(where: { $0 > 0 }) {
            limits.append(
                t("Older records are aggregates. Short spikes and exact timing may be unavailable.")
            )
        }
        return limits
    }

    static func interval(_ first: Date, _ last: Date) -> String {
        t(
            "Observed from %@ to %@.", first.formatted(date: .abbreviated, time: .standard),
            last.formatted(date: .abbreviated, time: .standard))
    }

    static func format(_ value: Double, metric: AskDiagnosticMetric) -> String {
        switch metric {
        case .cpu, .gpu: return value.formatted(.number.precision(.fractionLength(1))) + "%"
        case .memory, .swap, .disk, .network:
            let bounded = min(max(0, value), Double(Int64.max / 2))
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(bounded), countStyle: .memory)
            return bytes + (metric == .disk || metric == .network ? "/s" : "")
        default: return value.formatted(.number.precision(.fractionLength(1)))
        }
    }
}
