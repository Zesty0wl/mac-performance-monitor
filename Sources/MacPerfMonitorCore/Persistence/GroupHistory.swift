import Foundation
import GRDB

/// One point on a process group's combined timeline: the members' summed
/// footprint, CPU and energy at a single tick (raw tier) or bucket (minute/hour
/// tiers). The blended footprint score is derived from this by `GroupFootprint`,
/// dividing by the device's CPU/RAM capacity.
public struct GroupHistoryPoint: Sendable, Identifiable, Equatable {
    public var date: Date
    /// Summed physical footprint across the group's members (bytes) — the
    /// per-tick value (raw) or the bucket mean (minute/hour).
    public var footprint: UInt64
    /// Summed peak physical footprint across members (bytes): the per-tick value
    /// (raw) or the summed per-member bucket maxima (minute/hour). Drives the
    /// "Peak" lens; equals `footprint` on the raw tier.
    public var footprintPeak: UInt64
    /// Summed CPU across members (percent of one core; can exceed 100) — the
    /// per-tick value (raw) or the bucket mean (minute/hour).
    public var cpuPercent: Double
    /// Summed peak CPU across members (percent of one core): the per-tick value
    /// (raw) or the summed per-member bucket maxima (minute/hour). Equals
    /// `cpuPercent` on the raw tier.
    public var cpuPeakPercent: Double
    /// Summed energy impact across members (relative; see `EnergyImpact`).
    public var energyImpact: Double

    public var id: Date { date }

    public init(
        date: Date, footprint: UInt64, footprintPeak: UInt64, cpuPercent: Double,
        cpuPeakPercent: Double, energyImpact: Double
    ) {
        self.date = date
        self.footprint = footprint
        self.footprintPeak = footprintPeak
        self.cpuPercent = cpuPercent
        self.cpuPeakPercent = cpuPeakPercent
        self.energyImpact = energyImpact
    }
}

/// One **program** in a process group: every instance of the same executable the
/// window recorded, merged into a single member.
///
/// A process that is quit and relaunched gets a fresh PID, and therefore a fresh
/// `processes` row and a separate member; browsers and their kin also run many
/// identical helper instances side by side. Both used to fill a group's member
/// list with near-duplicate rows that each told only part of the story. A program
/// merges them: its footprint and CPU are the **combined** value of whichever
/// instances were alive at each moment, time-averaged over the period at least
/// one of them was alive. So concurrent instances add up (twenty renderers really
/// do cost twenty renderers), while a restart is never counted twice, and the
/// figures still read as "what this program weighed while it was running".
public struct GroupMemberProgram: Sendable, Identifiable, Equatable {
    /// What makes two instances "the same program" (see `SampleStore.programKey`).
    public var key: String
    /// Every instance recorded in the window, most recently seen first.
    public var identities: [ProcessIdentity]
    /// The instance a row's actions target: the most recently seen one, which is
    /// the live process whenever the program is still running.
    public var representative: ProcessIdentity
    public var name: String
    public var executablePath: String?
    public var bundleID: String?
    /// Time-weighted mean of the program's combined footprint (bytes) across the
    /// period at least one instance was alive.
    public var averageFootprint: UInt64
    /// The highest combined footprint the program's instances reached together at
    /// any single tick or bucket.
    public var peakFootprint: UInt64
    /// Time-weighted mean of the combined CPU (percent of one core; can exceed
    /// 100), over the same period as `averageFootprint`.
    public var averageCPU: Double
    public var peakCPU: Double
    /// Mean combined energy impact (relative; see `EnergyImpact`).
    public var averageEnergy: Double
    /// Seconds of the window during which at least one instance was alive: the
    /// denominator behind the averages, and what lets the UI say "ran 10 of 60
    /// minutes" for a program that was not up the whole time.
    public var residentSeconds: TimeInterval

    public var id: String { key }
    public var instanceCount: Int { identities.count }

    /// The full name to show, recovering a kernel-truncated `p_comm` from the
    /// executable path just as the live process list does.
    public var displayName: String {
        ProcessSample.resolvedDisplayName(name: name, executablePath: executablePath)
    }

    public init(
        key: String,
        identities: [ProcessIdentity],
        representative: ProcessIdentity,
        name: String,
        executablePath: String?,
        bundleID: String?,
        averageFootprint: UInt64,
        peakFootprint: UInt64,
        averageCPU: Double,
        peakCPU: Double,
        averageEnergy: Double,
        residentSeconds: TimeInterval
    ) {
        self.key = key
        self.identities = identities
        self.representative = representative
        self.name = name
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.averageFootprint = averageFootprint
        self.peakFootprint = peakFootprint
        self.averageCPU = averageCPU
        self.peakCPU = peakCPU
        self.averageEnergy = averageEnergy
        self.residentSeconds = residentSeconds
    }
}

/// A group's combined timeline and its merged per-program member list, produced
/// together from one read of the window (see `SampleStore.groupBreakdown`).
public struct GroupBreakdown: Sendable, Equatable {
    /// The group's combined footprint/CPU/energy per tick (raw) or bucket
    /// (minute/hour), oldest first.
    public var series: [GroupHistoryPoint]
    /// The group's members, one row per program, heaviest average footprint
    /// first.
    public var programs: [GroupMemberProgram]

    public init(series: [GroupHistoryPoint] = [], programs: [GroupMemberProgram] = []) {
        self.series = series
        self.programs = programs
    }
}

extension SampleStore {
    /// Resolve a group's rules to the set of `processes.id` active in the window.
    ///
    /// teamID/bundle/path predicates could be pushed into SQL, but category and
    /// vendor predicates depend on the glossary (a Swift lookup, not a column),
    /// so membership is settled in Swift over the window's candidate rows. A
    /// window holds a few hundred process rows at most, so this single scan plus
    /// in-memory match is cheap, and it keeps live and historical membership
    /// identical.
    public func groupMemberIDs(
        rule: GroupRule,
        window: HistoryWindow,
        glossary: ProcessGlossary?,
        now: Date = Date()
    ) throws -> [Int64] {
        guard rule.hasCondition else { return [] }
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        return try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, bundle_id, executable_path, team_id
                    FROM processes
                    WHERE last_seen >= ?
                    """, arguments: [since])
            var ids: [Int64] = []
            for row in rows {
                let id: Int64 = row["id"]
                let name: String = row["name"]
                let bundle: String? = row["bundle_id"]
                let path: String? = row["executable_path"]
                let team: String? = row["team_id"]
                let candidate = GroupMatcher.Candidate(
                    name: name, bundleID: bundle, executablePath: path, teamID: team)
                if GroupMatcher.matches(candidate, rule: rule, glossary: glossary) {
                    ids.append(id)
                }
            }
            return ids
        }
    }

    /// The group's combined timeline over the window: per tick (raw) or per
    /// bucket (minute/hour), the members' summed footprint/CPU/energy, oldest
    /// first. Returns empty when the group has no members. See `groupBreakdown`,
    /// which computes this alongside the per-program member list in one pass.
    public func groupSeries(
        processIDs: [Int64],
        window: HistoryWindow,
        bucketSeconds: TimeInterval = 60,
        now: Date = Date()
    ) throws -> [GroupHistoryPoint] {
        try groupBreakdown(
            processIDs: processIDs, window: window, bucketSeconds: bucketSeconds, now: now
        ).series
    }

    /// The group's combined timeline **and** its members merged one row per
    /// program, from a single read of the window.
    ///
    /// Both halves come out of the same walk over the members' rows because they
    /// are the same sum viewed two ways: the timeline is the group's combined
    /// value at each moment, and a program's figure is its own instances'
    /// combined value at each moment. Computing them apart is what let them
    /// disagree.
    ///
    /// The minute/hour tiers are dense (the write-side heartbeat guarantees
    /// every live member a row in every bucket), so a bucket's rows are the whole
    /// truth and summing them is exact. The raw tier is change-gated and
    /// therefore SPARSE: a member writes only where its value moved (plus that
    /// heartbeat), so members do not share tick timestamps and summing only the
    /// rows stamped at one instant would undercount badly. There, each member's
    /// last value is carried forward to the ticks between its rows, but only for
    /// `bucketSeconds`, one heartbeat. Past that the member is dropped, because a
    /// live process always has a row within one heartbeat and a dead one does
    /// not. Without that bound a process that exited early in the window kept
    /// contributing its final footprint to the group for the rest of it, so a
    /// group whose members restart often (the very case that produced duplicate
    /// rows) read far heavier than it was.
    ///
    /// - Parameter bucketSeconds: the write-side heartbeat / standard-resolution
    ///   bucket width. Must match the value passed to `insertChanged`, since it
    ///   is both the carry-forward bound above and the minute tier's bucket width.
    public func groupBreakdown(
        processIDs: [Int64],
        window: HistoryWindow,
        bucketSeconds: TimeInterval = 60,
        now: Date = Date()
    ) throws -> GroupBreakdown {
        guard !processIDs.isEmpty else { return GroupBreakdown() }
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        let dimensions = try programDimensions(processIDs: processIDs)
        guard !dimensions.isEmpty else { return GroupBreakdown() }
        let members = Dictionary(grouping: dimensions.values, by: \.key)

        switch window.granularity {
        case .raw:
            return try rawBreakdown(
                processIDs: processIDs, since: since, dimensions: dimensions, members: members,
                staleAfter: max(bucketSeconds, 1))
        case .minute:
            return try aggregateBreakdown(
                table: "process_minute", processIDs: processIDs, since: since, members: members,
                bucketWidth: max(bucketSeconds, 1))
        case .hour:
            return try aggregateBreakdown(
                table: "process_hour", processIDs: processIDs, since: since, members: members,
                bucketWidth: 3600)
        }
    }

    /// What makes two process instances "the same program": the executable path,
    /// which survives quitting and relaunching and is shared by an app's many
    /// identical helper instances. Unbundled or unreadable binaries fall back to
    /// the bundle id and finally the process name, so every instance lands in
    /// exactly one program.
    static func programKey(executablePath: String?, bundleID: String?, name: String) -> String {
        if let path = executablePath, !path.isEmpty { return path }
        if let bundle = bundleID, !bundle.isEmpty { return bundle }
        return name
    }

    /// The naming/identity half of a program, resolved once from the small
    /// `processes` dimension table: which instances belong to it and what to call
    /// it. Keyed by `processes.id` so the sample walks can attribute a row to its
    /// program without re-joining.
    private struct ProgramDimension {
        var key: String
        var identity: ProcessIdentity
        var name: String
        var executablePath: String?
        var bundleID: String?
        var lastSeen: Double
    }

    private func programDimensions(processIDs: [Int64]) throws -> [Int64: ProgramDimension] {
        let placeholders = Array(repeating: "?", count: processIDs.count).joined(separator: ",")
        return try databasePool.read { db in
            var result: [Int64: ProgramDimension] = [:]
            result.reserveCapacity(processIDs.count)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, pid, start_time, name, bundle_id, executable_path, last_seen
                    FROM processes WHERE id IN (\(placeholders))
                    """, arguments: StatementArguments(processIDs))
            for row in rows {
                let id: Int64 = row[0]
                let pid: Int32 = row[1]
                let start: Double = row[2]
                let name: String = row[3]
                let bundle: String? = row[4]
                let path: String? = row[5]
                let lastSeen: Double = row[6]
                result[id] = ProgramDimension(
                    key: Self.programKey(executablePath: path, bundleID: bundle, name: name),
                    identity: ProcessIdentity(
                        pid: pid, startTime: Date(timeIntervalSince1970: start)),
                    name: name, executablePath: path, bundleID: bundle, lastSeen: lastSeen)
            }
            return result
        }
    }

    /// Running totals for one program while a window is walked: the combined
    /// value its live instances hold right now, and the time-weighted
    /// accumulators that become its averages.
    private struct ProgramAccumulator {
        var liveCount = 0
        var footprint: UInt64 = 0
        var cpu = 0.0
        var energy = 0.0

        var weightedFootprint = 0.0
        var weightedCPU = 0.0
        var weightedEnergy = 0.0
        var duration = 0.0
        var peakFootprint: UInt64 = 0
        var peakCPU = 0.0

        /// Fold the currently-held combined value into the averages for the
        /// `dt` seconds it stood.
        mutating func hold(_ dt: Double) {
            guard liveCount > 0, dt > 0 else { return }
            weightedFootprint += Double(footprint) * dt
            weightedCPU += cpu * dt
            weightedEnergy += energy * dt
            duration += dt
        }

        mutating func markPeak() {
            peakFootprint = max(peakFootprint, footprint)
            peakCPU = max(peakCPU, cpu)
        }
    }

    /// Assemble the finished program rows, heaviest average footprint first.
    /// Instances are listed most-recently-seen first, so the representative (what
    /// a row's actions target) is the live one whenever the program is running.
    /// Programs whose instances are all named in the window's `processes` rows
    /// but have no samples left in the tier backing it are dropped rather than
    /// listed as a row of zeroes.
    private static func finishPrograms(
        _ accumulators: [String: ProgramAccumulator],
        members: [String: [ProgramDimension]]
    ) -> [GroupMemberProgram] {
        members.compactMap { key, dimensions -> GroupMemberProgram? in
            let instances = dimensions.sorted { $0.lastSeen > $1.lastSeen }
            guard let newest = instances.first,
                let a = accumulators[key], a.duration > 0
            else { return nil }
            let scale = 1 / a.duration
            return GroupMemberProgram(
                key: key,
                identities: instances.map(\.identity),
                representative: newest.identity,
                name: newest.name,
                executablePath: newest.executablePath,
                bundleID: newest.bundleID,
                averageFootprint: UInt64((a.weightedFootprint * scale).rounded()),
                peakFootprint: a.peakFootprint,
                averageCPU: a.weightedCPU * scale,
                peakCPU: a.peakCPU,
                averageEnergy: a.weightedEnergy * scale,
                residentSeconds: a.duration)
        }
        .sorted { $0.averageFootprint > $1.averageFootprint }
    }

    /// The sparse raw tier: walk the members' rows in time order, carrying each
    /// one's last value forward (bounded by `staleAfter`, one heartbeat) so every
    /// distinct tick holds the whole group's combined value, and time-weight each
    /// program's combined value by how long it stood.
    private func rawBreakdown(
        processIDs: [Int64],
        since: Double,
        dimensions: [Int64: ProgramDimension],
        members: [String: [ProgramDimension]],
        staleAfter: Double
    ) throws -> GroupBreakdown {
        let placeholders = Array(repeating: "?", count: processIDs.count).joined(separator: ",")
        var args: [any DatabaseValueConvertible] = []
        for id in processIDs { args.append(id) }
        args.append(since)

        let rows = try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ps.timestamp AS ts, ps.process_id AS member,
                           ps.phys_footprint AS fp, ps.cpu_percent AS cpu, ps.energy_impact AS energy
                    FROM process_samples ps
                    WHERE ps.process_id IN (\(placeholders)) AND ps.timestamp >= ?
                      AND ps.footprint_readable = 1
                    ORDER BY ps.timestamp ASC
                    """, arguments: StatementArguments(args))
        }
        guard !rows.isEmpty else { return GroupBreakdown() }

        // Programs are indexed rather than keyed by string: every tick sweeps all
        // of them to fold the interval just passed into their averages, and an
        // array walk keeps that sweep allocation-free.
        var keys: [String] = []
        var indexOfKey: [String: Int] = [:]
        var accumulators: [ProgramAccumulator] = []
        for key in members.keys {
            indexOfKey[key] = keys.count
            keys.append(key)
            accumulators.append(ProgramAccumulator())
        }

        /// One member's carried value: what it last reported, and when.
        struct Carried {
            var ts: Double
            var program: Int
            var footprint: UInt64
            var cpu: Double
            var energy: Double
        }
        var carried: [Int64: Carried] = [:]
        carried.reserveCapacity(processIDs.count)
        // Staleness queue: every row's (timestamp, member) in arrival order. A
        // member is dropped when the head's timestamp is still its latest one and
        // has fallen more than a heartbeat behind; superseded entries are skipped.
        var expiry: [(ts: Double, member: Int64)] = []
        expiry.reserveCapacity(rows.count)
        var expiryHead = 0

        func detach(_ value: Carried) {
            var a = accumulators[value.program]
            a.liveCount -= 1
            if a.liveCount <= 0 {
                // Reset rather than subtract the last member out, so a long window
                // cannot accumulate floating-point drift across thousands of rows.
                a.liveCount = 0
                a.footprint = 0
                a.cpu = 0
                a.energy = 0
            } else {
                a.footprint = a.footprint > value.footprint ? a.footprint - value.footprint : 0
                a.cpu -= value.cpu
                a.energy -= value.energy
            }
            accumulators[value.program] = a
        }

        func attach(_ value: Carried) {
            var a = accumulators[value.program]
            a.liveCount += 1
            a.footprint &+= value.footprint
            a.cpu += value.cpu
            a.energy += value.energy
            accumulators[value.program] = a
        }

        func holdAll(_ dt: Double) {
            guard dt > 0 else { return }
            for k in accumulators.indices { accumulators[k].hold(dt) }
        }

        var series: [GroupHistoryPoint] = []
        /// The time up to which every program's held value has been folded into
        /// its averages. Nil until the first tick establishes a starting point.
        var settled: Double?
        var i = 0
        let n = rows.count

        while i < n {
            let ts: Double = rows[i]["ts"]

            if var t = settled {
                // Members that stopped reporting exited at their own deadline,
                // one heartbeat past their last row, not at whichever tick
                // happens to come next. So the interval since the previous tick is
                // folded in piece by piece, settling each expiry where it falls.
                // Crediting a dead member all the way to the next tick is exactly
                // how a process that exited early keeps inflating the numbers.
                while expiryHead < expiry.count {
                    let stale = expiry[expiryHead]
                    guard let value = carried[stale.member], value.ts == stale.ts else {
                        expiryHead += 1  // superseded by a later row from the same member
                        continue
                    }
                    let deadline = stale.ts + staleAfter
                    if deadline >= ts { break }
                    holdAll(deadline - t)
                    t = deadline
                    expiryHead += 1
                    carried.removeValue(forKey: stale.member)
                    detach(value)
                }
                holdAll(ts - t)
            }

            // Fold in every row stamped at this exact tick (members sampled
            // together in one snapshot share the tick timestamp).
            while i < n, (rows[i]["ts"] as Double) == ts {
                let member: Int64 = rows[i]["member"]
                if let program = dimensions[member].flatMap({ indexOfKey[$0.key] }) {
                    let value = Carried(
                        ts: ts, program: program,
                        footprint: SQLInt.read(rows[i]["fp"]),
                        cpu: rows[i]["cpu"] as Double,
                        energy: rows[i]["energy"] as Double)
                    if let previous = carried[member] { detach(previous) }
                    carried[member] = value
                    attach(value)
                    expiry.append((ts: ts, member: member))
                }
                i += 1
            }

            var groupFootprint: UInt64 = 0
            var groupCPU = 0.0
            var groupEnergy = 0.0
            for k in accumulators.indices {
                accumulators[k].markPeak()
                guard accumulators[k].liveCount > 0 else { continue }
                groupFootprint &+= accumulators[k].footprint
                groupCPU += accumulators[k].cpu
                groupEnergy += accumulators[k].energy
            }
            // The raw step function IS the value at each tick, so peak == value.
            series.append(
                GroupHistoryPoint(
                    date: Date(timeIntervalSince1970: ts),
                    footprint: groupFootprint,
                    footprintPeak: groupFootprint,
                    cpuPercent: groupCPU,
                    cpuPeakPercent: groupCPU,
                    energyImpact: groupEnergy))
            settled = ts
        }

        // The final tick has no successor to measure against, so it takes a
        // nominal second, the same convention as `rawConsumers`, and for the same
        // reason: it must not stretch the last value across the rest of the window.
        holdAll(1)

        var byKey: [String: ProgramAccumulator] = [:]
        byKey.reserveCapacity(keys.count)
        for (k, key) in keys.enumerated() { byKey[key] = accumulators[k] }
        return GroupBreakdown(
            series: series, programs: Self.finishPrograms(byKey, members: members))
    }

    /// The dense minute/hour tiers: every live member has a row in every bucket,
    /// so one grouped read gives each program's combined value per bucket
    /// directly. Rows are grouped by the naming triple rather than by the merge
    /// key so the key stays defined in exactly one place (`programKey`); triples
    /// that resolve to the same program are folded together here.
    private func aggregateBreakdown(
        table: String,
        processIDs: [Int64],
        since: Double,
        members: [String: [ProgramDimension]],
        bucketWidth: TimeInterval
    ) throws -> GroupBreakdown {
        let placeholders = Array(repeating: "?", count: processIDs.count).joined(separator: ",")
        var args: [any DatabaseValueConvertible] = []
        for id in processIDs { args.append(id) }
        args.append(since)

        let rows = try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT t.bucket AS ts,
                           p.executable_path AS path, p.bundle_id AS bundle, p.name AS name,
                           CAST(SUM(t.footprint_avg) AS INTEGER) AS fp,
                           CAST(SUM(t.footprint_max) AS INTEGER) AS fp_peak,
                           SUM(t.cpu_avg) AS cpu,
                           SUM(MAX(t.cpu_max, t.cpu_avg)) AS cpu_peak,
                           SUM(t.energy_avg) AS energy
                    FROM \(table) t
                    JOIN processes p ON p.id = t.process_id
                    WHERE t.process_id IN (\(placeholders)) AND t.bucket >= ?
                    GROUP BY path, bundle, name, ts
                    ORDER BY ts ASC
                    """, arguments: StatementArguments(args))
        }
        guard !rows.isEmpty else { return GroupBreakdown() }

        var accumulators: [String: ProgramAccumulator] = [:]
        var series: [GroupHistoryPoint] = []
        var i = 0
        let n = rows.count

        while i < n {
            let ts: Double = rows[i]["ts"]
            var bucket: [String: (fp: UInt64, fpPeak: UInt64, cpu: Double, cpuPeak: Double, energy: Double)] =
                [:]
            while i < n, (rows[i]["ts"] as Double) == ts {
                let key = Self.programKey(
                    executablePath: rows[i]["path"], bundleID: rows[i]["bundle"],
                    name: rows[i]["name"])
                var entry = bucket[key] ?? (0, 0, 0, 0, 0)
                entry.fp &+= SQLInt.read(rows[i]["fp"])
                entry.fpPeak &+= SQLInt.read(rows[i]["fp_peak"])
                entry.cpu += rows[i]["cpu"] as Double
                entry.cpuPeak += rows[i]["cpu_peak"] as Double
                entry.energy += rows[i]["energy"] as Double
                bucket[key] = entry
                i += 1
            }

            var groupFootprint: UInt64 = 0
            var groupFootprintPeak: UInt64 = 0
            var groupCPU = 0.0
            var groupCPUPeak = 0.0
            var groupEnergy = 0.0
            for (key, entry) in bucket {
                groupFootprint &+= entry.fp
                groupFootprintPeak &+= entry.fpPeak
                groupCPU += entry.cpu
                groupCPUPeak += entry.cpuPeak
                groupEnergy += entry.energy

                var a = accumulators[key] ?? ProgramAccumulator()
                a.liveCount = 1
                a.footprint = entry.fp
                a.cpu = entry.cpu
                a.energy = entry.energy
                a.hold(bucketWidth)
                a.peakFootprint = max(a.peakFootprint, entry.fpPeak)
                a.peakCPU = max(a.peakCPU, entry.cpuPeak)
                accumulators[key] = a
            }
            series.append(
                GroupHistoryPoint(
                    date: Date(timeIntervalSince1970: ts),
                    footprint: groupFootprint,
                    footprintPeak: groupFootprintPeak,
                    cpuPercent: groupCPU,
                    cpuPeakPercent: groupCPUPeak,
                    energyImpact: groupEnergy))
        }

        return GroupBreakdown(
            series: series, programs: Self.finishPrograms(accumulators, members: members))
    }

    /// Per-**instance** windowed aggregate for a group's members, ranked by
    /// `metric`. Reuses the top-consumer queries with the group's id set, so each
    /// PID is its own row and each row's average covers only its own lifetime.
    ///
    /// The Groups UI reads `groupBreakdown` instead, which merges a program's
    /// instances into one member; this stays for callers that genuinely want the
    /// per-PID view.
    public func groupMemberConsumers(
        processIDs: [Int64],
        window: HistoryWindow,
        metric: ConsumerMetric = .averageFootprint,
        limit: Int = 100,
        now: Date = Date()
    ) throws -> [ProcessConsumer] {
        guard !processIDs.isEmpty else { return [] }
        let since = now.addingTimeInterval(-window.seconds).timeIntervalSince1970
        switch window.granularity {
        case .raw:
            return try rawConsumers(
                since: since, orderColumn: metric.orderColumn, limit: limit,
                processIDs: processIDs)
        case .minute:
            return try aggregateConsumers(
                table: "process_minute", since: since, orderColumn: metric.orderColumn,
                limit: limit, processIDs: processIDs)
        case .hour:
            return try aggregateConsumers(
                table: "process_hour", since: since, orderColumn: metric.orderColumn,
                limit: limit, processIDs: processIDs)
        }
    }

    /// Every distinct code-signing Team ID recorded in the process history on this
    /// machine, with one representative process each — the dynamic source for the
    /// rule editor's Team ID picker (Apple platform binaries carry no Team ID, so
    /// this is the third-party software seen on the device).
    public func recordedTeamIDs() throws -> [TeamIDSeed] {
        try databasePool.read { db in
            // One representative per Team ID, preferring a non-empty bundle id and
            // executable path (so the label/codesign lookup has something to work
            // with even when some rows for that Team ID are bundle-less helpers).
            try Row.fetchAll(
                db,
                sql: """
                    SELECT team_id,
                           MAX(name) AS name,
                           MAX(NULLIF(bundle_id, '')) AS bundle_id,
                           MAX(NULLIF(executable_path, '')) AS executable_path
                    FROM processes
                    WHERE team_id IS NOT NULL AND team_id != ''
                    GROUP BY team_id
                    """
            ).map { row in
                TeamIDSeed(
                    teamID: row["team_id"], name: row["name"],
                    bundleID: row["bundle_id"], executablePath: row["executable_path"])
            }
        }
    }
}

/// A distinct Team ID recorded on this machine, plus a representative process for
/// labelling it in the picker.
public struct TeamIDSeed: Sendable, Hashable {
    public let teamID: String
    public let name: String
    public let bundleID: String?
    public let executablePath: String?

    public init(teamID: String, name: String, bundleID: String?, executablePath: String?) {
        self.teamID = teamID
        self.name = name
        self.bundleID = bundleID
        self.executablePath = executablePath
    }
}
