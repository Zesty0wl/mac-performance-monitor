import Foundation

/// Produces typed snapshots by wrapping the system readers and computing the
/// inter-tick deltas (CPU%, counter deltas, pressure trend) that need state
/// carried between ticks.
///
/// Not thread-safe: callers run it on a single serial queue.
public final class Sampler {
    /// One tick's worth of measurement.
    public struct Snapshot: Sendable {
        public var system: SystemSample
        public var processes: [ProcessSample]
        /// Visible processes whose basic info could not be read at user level
        /// (system/other-user processes). The UI surfaces this as a coverage
        /// gap rather than faking zeros. See docs/data-layer-findings.md.
        public var unreadableProcessCount: Int
        /// System-wide CPU for this tick: total, per-core, and the P/E split.
        public var cpu: CPUSample
        /// Live battery state for this tick, or nil on a Mac with no battery.
        /// Carries the richer live-only detail (adapter, serial, voltage, time
        /// remaining) that `SystemSample`'s chartable scalars do not persist.
        public var battery: BatterySample?
        /// Live system-wide network state for this tick: the same rates carried
        /// in `system`, plus the live-only session totals and primary interface.
        /// Nil before the first interface read.
        public var network: NetworkSample?
        /// Live physical-device details. Aggregate rates are also persisted on
        /// `system`; this richer form powers the Disk popover's device list.
        public var disk: DiskSample?

        /// `cpu` defaults to `.zero` and `battery`/`network` to nil so call sites
        /// that predate those features (the persistence tests, which build
        /// snapshots directly) still compile.
        public init(
            system: SystemSample,
            processes: [ProcessSample],
            unreadableProcessCount: Int,
            cpu: CPUSample = .zero,
            battery: BatterySample? = nil,
            network: NetworkSample? = nil,
            disk: DiskSample? = nil
        ) {
            self.system = system
            self.processes = processes
            self.unreadableProcessCount = unreadableProcessCount
            self.cpu = cpu
            self.battery = battery
            self.network = network
            self.disk = disk
        }
    }

    private let processReader: ProcessReader
    private let memoryReader: SystemMemoryReader
    private let cpuReader: CPUReader
    private let batteryReader: BatteryReader
    /// System-wide network throughput reader (always on; cheap getifaddrs walk).
    private let networkReader: NetworkReader
    /// Physical block-device activity (always on; cheap IOKit property reads).
    private let diskReader: DiskReader
    /// GPU utilization reader (IOAccelerator). Only read when `tickSystem` is asked
    /// to (the menubar GPU item gates it), so it costs nothing when GPU is off.
    private let gpuReader = GPUReader()
    /// GPU + ANE power (IOReport) and die temperature / fan (SMC). Same gating as
    /// the GPU reader — only touched while the GPU item is shown.
    private let powerReader = PowerReader()
    private let smcReader = SMCReader()

    /// Optional per-process network reader, backed by a long-lived `nettop`. Nil
    /// unless the user opts into per-app network tracking; far heavier than the
    /// libproc reads, so it is off by default. Confined to the sampler queue.
    private var networkProcessReader: NetworkProcessReader?

    /// Optional root-helper-backed reader. When set, the sampler asks it to fill
    /// in the processes the unprivileged user-level reads could not see, so the
    /// snapshot can cover system and other-user processes. Nil means user-level
    /// only. Confined to the sampler's serial queue like the rest of this type.
    private var privilegedReader: PrivilegedReader?

    /// Resilience for the privileged (root helper) fill-in. The helper can stop
    /// responding — it crashes, its XPC link drops, or (in an unsigned dev build)
    /// it can never satisfy the code-signing pin at all. Calling it every heavy
    /// tick regardless then stalls the sampler queue on each blocking XPC call and
    /// churns the connection rebuild, making the app heavy and janky while
    /// coverage is already broken. So after a run of failures we go quiet for a
    /// window and retry only then; a helper that recovers is picked up
    /// automatically with no user action.
    private var privilegedFailureStreak = 0
    private var privilegedQuietUntil: Date?
    private let privilegedFailureLimit = 3
    private let privilegedBackoff: TimeInterval = 20

    /// Invoked on the sampler queue when the privileged reader has failed
    /// `privilegedFailureLimit` times in a row — the symptom of a wedged/stale/
    /// un-launched root helper (e.g. left over from an app update). The app uses
    /// this to actively recover the helper rather than only waiting out the quiet
    /// window, so coverage is never silently stuck while the user wants it on.
    public var onPrivilegedReadFailure: (() -> Void)?

    private struct CPUState {
        var user: UInt64
        var system: UInt64
    }
    private var lastCPU: [ProcessIdentity: CPUState] = [:]

    /// Scratch buffer reused by the per-tick FD count across all processes in a
    /// scan. Confined to the sampler queue like the rest of this type.
    private let fdScratch = FDCountScratch()

    /// Previous tick's cumulative energy figures per process, for the inter-tick
    /// wakeups rate that feeds the energy-impact estimate.
    private struct EnergyState {
        var energy: UInt64
        var wakeups: UInt64
    }
    private var lastEnergy: [ProcessIdentity: EnergyState] = [:]
    private struct DiskState {
        var read: UInt64
        var written: UInt64
    }
    private var lastDisk: [ProcessIdentity: DiskState] = [:]
    /// Separate inter-tick clocks for the two paths, so the cheap system/CPU
    /// sample (`tickSystem`) can run at a faster cadence than the heavy
    /// per-process scan (`tickProcesses`) without their deltas interfering.
    private var lastSystemTime: Date?
    private var lastProcessTime: Date?

    /// Previous tick's cumulative per-core tick counters, for the CPU delta.
    /// Nil before the first read or after a reset, which yields an idle sample
    /// for that one tick rather than a spike.
    private var lastCoreTicks: [CoreTicks]?

    /// The battery read is the one non-trivial reader on the otherwise-cheap
    /// `tickSystem` path (~0.7 ms/tick, an IOKit registry walk), yet charge,
    /// health, power and temperature all move on minute timescales — 1 Hz buys
    /// nothing a menu-bar read-out or the history charts can perceive. So read it
    /// at `batteryReadInterval` and carry the last sample forward on the ticks in
    /// between, keeping the fast path essentially free without a visible change.
    private var cachedBattery: BatterySample?
    private var lastBatteryReadAt: Date?
    private let batteryReadInterval: TimeInterval = 5

    /// Per-process facts that never change for a given pid+startTime: the
    /// executable path (proc_pidpath), the Rosetta flag (sysctl), the derived
    /// architecture, and the bundle identifier (an Info.plist disk read).
    /// Caching these avoids ~3 syscalls plus a file read per process on every
    /// tick, which dominates idle CPU when the fleet has hundreds of processes.
    private struct StaticInfo {
        var executablePath: String?
        var bundleID: String?
        var teamID: String?
        var isTranslated: Bool?
        var architecture: Architecture
        /// Whether the (expensive) Team-ID code-sign lookup has actually run for
        /// this identity. False means it was deferred by the per-tick budget (see
        /// `teamIDResolvePerTick`) and should be retried on a later tick — as
        /// distinct from a genuine nil (an unsigned binary), where it is true.
        var teamIDResolved: Bool = false
    }
    private var staticCache: [ProcessIdentity: StaticInfo] = [:]

    /// Cap on how many *new* processes have their Team ID resolved per scan. The
    /// Team-ID lookup is a `SecStaticCode` inspection (~1–2 ms per distinct
    /// binary); resolving every process the first time it is seen made the first
    /// scan a ~600 ms stall on the sampler queue for ~800 processes, and any
    /// churn burst (a build spawning dozens of compilers) a smaller one. Spreading
    /// the resolution over successive ticks bounds the per-tick cost; unresolved
    /// processes carry a nil Team ID (used only for optional grouping) until their
    /// turn comes, at most a few seconds later. The other static facts — path,
    /// bundle id, Rosetta flag — are cheap and still resolved on first sight.
    private let teamIDResolvePerTick = 30

    /// Resolves a binary's code-signing Team ID once per distinct executable
    /// path (cached). Only consulted on a `staticCache` miss — i.e. the first
    /// time a process is seen — so it stays off the per-tick hot path.
    private let codeSigningResolver = CodeSigningResolver.shared

    private struct SystemCounters {
        var pageIns: UInt64
        var pageOuts: UInt64
        var compressions: UInt64
        var decompressions: UInt64
    }
    private var lastCounters: SystemCounters?
    private var lastPressureLoad: UInt64?  // compressed + swapUsed, for trend

    /// Bytes-per-second growth of (compressed + swap) treated as full trend.
    private let trendScaleBytesPerSec: Double = 50_000_000

    public init(
        processReader: ProcessReader = ProcessReader(),
        memoryReader: SystemMemoryReader = SystemMemoryReader(),
        cpuReader: CPUReader = CPUReader(),
        batteryReader: BatteryReader = BatteryReader(),
        networkReader: NetworkReader = NetworkReader(),
        diskReader: DiskReader = DiskReader()
    ) {
        self.processReader = processReader
        self.memoryReader = memoryReader
        self.cpuReader = cpuReader
        self.batteryReader = batteryReader
        self.networkReader = networkReader
        self.diskReader = diskReader
    }

    /// Install (or remove) the privileged reader used to fill coverage gaps.
    /// Call on the same serial queue the sampler ticks on.
    public func setPrivilegedReader(_ reader: PrivilegedReader?) {
        privilegedReader = reader
        // Fresh reader (or coverage turned off): clear any backoff so a newly
        // enabled/repaired helper is tried at once.
        privilegedFailureStreak = 0
        privilegedQuietUntil = nil
    }

    /// Install (or remove) the per-process network reader (a running `nettop`).
    /// Passing a reader starts per-app network attribution; nil stops it and
    /// clears the inter-tick delta state so the next enable starts clean. Call on
    /// the sampler's serial queue, like `setPrivilegedReader`.
    public func setNetworkProcessReader(_ reader: NetworkProcessReader?) {
        networkProcessReader?.stop()
        networkProcessReader = reader
        reader?.start()
    }

    /// Capture one full tick: the cheap system/CPU sample plus the heavy
    /// per-process scan. Used by the CLI and tests; the live app calls
    /// `tickSystem` and `tickProcesses` separately on different cadences.
    public func tick(now: Date = Date()) -> Snapshot {
        let (system, cpu, battery, network, disk, _) = tickSystem(now: now)
        let (processes, unreadable) = tickProcesses(now: now)
        return Snapshot(
            system: system, processes: processes, unreadableProcessCount: unreadable, cpu: cpu,
            battery: battery, network: network, disk: disk)
    }

    /// The cheap system-wide sample: total/per-core CPU and the memory/pressure
    /// figures. It does no per-process enumeration, so it is safe to call at a
    /// fast (sub-second) cadence to keep the menubar live without the cost of
    /// scanning every process. Maintains its own inter-tick clock.
    public func tickSystem(
        now: Date = Date(), readGPU: Bool = false
    )
        -> (
            system: SystemSample, cpu: CPUSample, battery: BatterySample?, network: NetworkSample?,
            disk: DiskSample?, gpu: GPUSample?
        )
    {
        let wallDeltaSeconds = lastSystemTime.map { now.timeIntervalSince($0) } ?? 0
        let cpu = sampleCPU(now: now)
        // Decimated: re-read the battery at most every `batteryReadInterval`,
        // carrying the last sample forward otherwise (see `cachedBattery`). Gated
        // on time regardless of the result, so a battery-less Mac (nil read) also
        // stops polling every tick rather than only when a sample is present.
        let readBattery =
            lastBatteryReadAt.map { now.timeIntervalSince($0) >= batteryReadInterval } ?? true
        if readBattery {
            cachedBattery = batteryReader.read(now: now)
            lastBatteryReadAt = now
        }
        let battery = cachedBattery
        let network = networkReader.read(now: now)
        let disk = diskReader.read(now: now)
        // Gated: only walk the IOAccelerator registry when something shows GPU.
        var gpu = readGPU ? gpuReader.read() : nil
        if readGPU, gpu != nil {
            // Fold in IOReport power and SMC thermal — the same cheap, gated path.
            if let power = powerReader.read(now: now) {
                gpu?.gpuPowerWatts = power.gpuWatts
                gpu?.anePowerWatts = power.aneWatts
                gpu?.cpuPowerWatts = power.cpuWatts
            }
            if let thermal = smcReader.read(now: now) {
                gpu?.dieTemperatureC = thermal.dieTemperatureC
                gpu?.fanRPM = thermal.fanRPM
                gpu?.fanMaxRPM = thermal.fanMaxRPM
            }
        }
        let system = sampleSystem(
            now: now, wallDeltaSeconds: wallDeltaSeconds, cpuLoad: cpu.totalUsage, battery: battery,
            network: network, disk: disk)
        lastSystemTime = now
        return (system, cpu, battery, network, disk, gpu)
    }

    /// The heavy per-process scan: enumerate every visible process, read its
    /// task info, footprint, and file descriptors, and compute its inter-tick
    /// CPU. Expensive enough that the app runs it at a slower cadence than
    /// `tickSystem`; it keeps its own clock so the CPU deltas stay correct.
    public func tickProcesses(
        now: Date = Date()
    )
        -> (processes: [ProcessSample], unreadableProcessCount: Int)
    {
        let wallDeltaSeconds = lastProcessTime.map { now.timeIntervalSince($0) } ?? 0
        let wallDeltaNanos = wallDeltaSeconds * 1_000_000_000

        // Per-app network rates (bytes/sec) come from the nettop reader's own
        // background loop — it runs the (sometimes multi-second) nettop one-shot off
        // this hot path and caches per-PID rates. Read them non-blocking; empty when
        // the reader is off or before its first interval. Keeping nettop off the
        // sampler queue is what stops a slow nettop from throttling the whole app.
        let networkRates = networkProcessReader?.latestRates() ?? [:]

        let pids = processReader.listPIDs()
        var processes: [ProcessSample] = []
        processes.reserveCapacity(pids.count)
        var newCPU: [ProcessIdentity: CPUState] = [:]
        newCPU.reserveCapacity(pids.count)
        var newEnergy: [ProcessIdentity: EnergyState] = [:]
        newEnergy.reserveCapacity(pids.count)
        var newDisk: [ProcessIdentity: DiskState] = [:]
        newDisk.reserveCapacity(pids.count)
        var newStaticCache: [ProcessIdentity: StaticInfo] = [:]
        newStaticCache.reserveCapacity(pids.count)
        var unreadablePIDs: [pid_t] = []
        // Per-scan budget for the expensive Team-ID code-sign resolution, so a
        // burst of newly-seen processes is spread over ticks (see the field).
        var teamIDBudget = teamIDResolvePerTick

        for pid in pids {
            guard let info = processReader.taskAllInfo(pid) else {
                unreadablePIDs.append(pid)
                continue
            }
            let rusage = processReader.rusage(pid)
            // Count-only on the hot path: only fdTotal is displayed/persisted-as-
            // read; the type split is read on demand via openFileDescriptors.
            let fd =
                processReader.fdCount(pid, scratch: fdScratch)
                .map { FDBreakdown(total: $0) } ?? FDBreakdown()
            processes.append(
                buildSample(
                    now: now,
                    wallDeltaNanos: wallDeltaNanos,
                    pid: pid,
                    info: info,
                    rusage: rusage,
                    fd: fd,
                    source: .directUserRead,
                    networkRates: networkRates,
                    newCPU: &newCPU,
                    newEnergy: &newEnergy,
                    newDisk: &newDisk,
                    newStaticCache: &newStaticCache,
                    teamIDBudget: &teamIDBudget
                ))
        }

        // Fill coverage gaps with the privileged helper when available: the
        // PIDs the user-level read could not see (system and other-user
        // processes) are read as root and merged in. Whatever the helper still
        // cannot read stays counted as unreadable so the UI is honest.
        var unreadable = unreadablePIDs.count
        let withinQuietWindow = privilegedQuietUntil.map { now < $0 } ?? false
        if let privilegedReader, !unreadablePIDs.isEmpty, !withinQuietWindow {
            let reads = privilegedReader.readProcesses(pids: unreadablePIDs)
            if reads.isEmpty {
                // Root should be able to read these system/other-user processes,
                // so an empty result means the helper is unreachable or wedged.
                // After a few in a row, go quiet to stop the per-tick stall and
                // XPC-connection churn; it retries once the window passes.
                privilegedFailureStreak += 1
                if privilegedFailureStreak >= privilegedFailureLimit {
                    privilegedQuietUntil = now.addingTimeInterval(privilegedBackoff)
                    privilegedFailureStreak = 0
                    // Ask the app to actively recover the helper (re-bootstrap it),
                    // not just wait out the quiet window — so a broken helper is
                    // repaired without the user toggling coverage off and on.
                    onPrivilegedReadFailure?()
                }
            } else {
                privilegedFailureStreak = 0
                privilegedQuietUntil = nil
                for pid in unreadablePIDs {
                    guard let raw = reads[pid], let info = raw.task else { continue }
                    processes.append(
                        buildSample(
                            now: now,
                            wallDeltaNanos: wallDeltaNanos,
                            pid: pid,
                            info: info,
                            rusage: raw.rusage,
                            fd: raw.fd ?? FDBreakdown(),
                            source: .privilegedHelper,
                            networkRates: networkRates,
                            newCPU: &newCPU,
                            newEnergy: &newEnergy,
                            newDisk: &newDisk,
                            newStaticCache: &newStaticCache,
                            teamIDBudget: &teamIDBudget
                        ))
                    unreadable -= 1
                }
            }
        }

        lastCPU = newCPU
        lastEnergy = newEnergy
        lastDisk = newDisk
        staticCache = newStaticCache
        lastProcessTime = now

        return (processes, unreadable)
    }

    // MARK: - CPU sampling

    /// Build the system-wide CPU sample for this tick: read the cumulative
    /// per-core tick counters, difference them against the previous read to get
    /// instantaneous per-core utilisation, then aggregate into the total and the
    /// performance/efficiency cluster figures. The first tick (or the one after
    /// a reset, or any core-count change) has no previous read to difference, so
    /// it reports an idle sample and seeds the state for the next tick.
    private func sampleCPU(now: Date) -> CPUSample {
        let topo = CPUTopology.current
        let load = cpuReader.loadAverage()

        func sample(
            cores: [CoreUsage], total: Double, user: Double, system: Double,
            performance: Double, efficiency: Double, pCount: Int, eCount: Int
        ) -> CPUSample {
            CPUSample(
                timestamp: now,
                totalUsage: total, userFraction: user, systemFraction: system,
                idleFraction: max(0, 1 - total),
                cores: cores,
                performanceUsage: performance, efficiencyUsage: efficiency,
                performanceCoreCount: pCount, efficiencyCoreCount: eCount,
                loadAverage1: load.0, loadAverage5: load.1, loadAverage15: load.2)
        }

        guard let current = cpuReader.sampleCoreTicks() else {
            lastCoreTicks = nil
            return sample(
                cores: [], total: 0, user: 0, system: 0, performance: 0, efficiency: 0,
                pCount: topo.performanceCoreCount, eCount: topo.efficiencyCoreCount)
        }
        defer { lastCoreTicks = current }

        guard let previous = lastCoreTicks, previous.count == current.count else {
            return sample(
                cores: [], total: 0, user: 0, system: 0, performance: 0, efficiency: 0,
                pCount: topo.performanceCoreCount, eCount: topo.efficiencyCoreCount)
        }

        var cores: [CoreUsage] = []
        cores.reserveCapacity(current.count)
        var sumUsage = 0.0, sumUser = 0.0, sumSystem = 0.0
        var perfSum = 0.0, effSum = 0.0
        var perfCount = 0, effCount = 0
        for i in 0..<current.count {
            let u = CPUMath.coreUsage(current: current[i], previous: previous[i])
            let kind = i < topo.coreKinds.count ? topo.coreKinds[i] : .performance
            cores.append(
                CoreUsage(index: i, kind: kind, usage: u.usage, user: u.user, system: u.system))
            sumUsage += u.usage
            sumUser += u.user
            sumSystem += u.system
            if kind == .efficiency {
                effSum += u.usage
                effCount += 1
            } else {
                perfSum += u.usage
                perfCount += 1
            }
        }
        let n = Double(current.count)
        return sample(
            cores: cores,
            total: sumUsage / n, user: sumUser / n, system: sumSystem / n,
            performance: perfCount > 0 ? perfSum / Double(perfCount) : 0,
            efficiency: effCount > 0 ? effSum / Double(effCount) : 0,
            pCount: perfCount, eCount: effCount)
    }

    /// Build one process sample from its already-fetched reads, computing the
    /// inter-tick CPU delta and reusing the per-identity static cache. Shared by
    /// the direct user-level path and the privileged-helper fill-in so both
    /// produce identical rows apart from `dataSource`. The executable path and
    /// Rosetta flag are read here (reliable at user level for every process).
    private func buildSample(
        now: Date,
        wallDeltaNanos: Double,
        pid: pid_t,
        info: TaskAllInfo,
        rusage: RUsage?,
        fd: FDBreakdown,
        source: SampleSource,
        networkRates: [Int32: Double],
        newCPU: inout [ProcessIdentity: CPUState],
        newEnergy: inout [ProcessIdentity: EnergyState],
        newDisk: inout [ProcessIdentity: DiskState],
        newStaticCache: inout [ProcessIdentity: StaticInfo],
        teamIDBudget: inout Int
    ) -> ProcessSample {
        let identity = ProcessIdentity(pid: pid, startTime: info.startTime)

        var diskReadBytesPerSec = 0.0
        var diskWriteBytesPerSec = 0.0
        if let rusage {
            let diskNow = DiskState(
                read: rusage.diskBytesRead,
                written: rusage.diskBytesWritten)
            newDisk[identity] = diskNow
            if let prior = lastDisk[identity], wallDeltaNanos > 0 {
                let seconds = wallDeltaNanos / 1_000_000_000
                if diskNow.read >= prior.read {
                    diskReadBytesPerSec = Double(diskNow.read - prior.read) / seconds
                }
                if diskNow.written >= prior.written {
                    diskWriteBytesPerSec = Double(diskNow.written - prior.written) / seconds
                }
            }
        }

        let cpuNow = CPUState(user: info.cpuTimeUser, system: info.cpuTimeSystem)
        newCPU[identity] = cpuNow

        var cpuPercent = 0.0
        if let prev = lastCPU[identity], wallDeltaNanos > 0 {
            let deltaUser = CPUMath.delta(cpuNow.user, prev.user)
            let deltaSystem = CPUMath.delta(cpuNow.system, prev.system)
            cpuPercent = CPUMath.percent(
                cpuDeltaNanos: deltaUser &+ deltaSystem,
                wallDeltaNanos: wallDeltaNanos
            )
        }

        // Energy: carry the cumulative kernel counter, and derive an inter-tick
        // wakeups rate that, with CPU, feeds the relative energy-impact estimate
        // (see EnergyImpact). The estimate keeps a single consistent scale across
        // every process, unlike the raw energy counter which is often 0.
        let energyNow = rusage?.energyNanojoules ?? 0
        let wakeupsNow = rusage?.idleWakeups ?? 0
        newEnergy[identity] = EnergyState(energy: energyNow, wakeups: wakeupsNow)
        var wakeupsPerSec = 0.0
        if let prev = lastEnergy[identity], wallDeltaNanos > 0 {
            let deltaWakeups = CPUMath.delta(wakeupsNow, prev.wakeups)
            wakeupsPerSec = Double(deltaWakeups) / (wallDeltaNanos / 1_000_000_000)
        }

        // Static facts (path, Rosetta, architecture, bundle id) never change for
        // a live pid+startTime, so compute them once and reuse. The Team-ID
        // code-sign lookup is the one expensive resolution, so it is throttled to
        // `teamIDBudget` new resolutions per scan and retried on later ticks —
        // the rest of the facts are always resolved on first sight.
        let staticInfo: StaticInfo
        if let cached = staticCache[identity], cached.teamIDResolved {
            // Fully resolved on an earlier tick — reuse verbatim.
            staticInfo = cached
        } else if let partial = staticCache[identity] {
            // Seen before, but the Team-ID lookup was deferred by the budget.
            // Keep the cheap facts already known; retry only the code-sign lookup.
            if teamIDBudget > 0 {
                teamIDBudget -= 1
                staticInfo = StaticInfo(
                    executablePath: partial.executablePath,
                    bundleID: partial.bundleID,
                    teamID: codeSigningResolver.teamID(forExecutablePath: partial.executablePath),
                    isTranslated: partial.isTranslated,
                    architecture: partial.architecture,
                    teamIDResolved: true)
            } else {
                staticInfo = partial
            }
        } else {
            // First sighting: resolve the cheap facts now; take the expensive
            // Team-ID lookup only while this scan's budget lasts, else defer it.
            let translated = processReader.isTranslated(pid)
            let path = processReader.path(pid)
            let resolveTeam = teamIDBudget > 0
            if resolveTeam { teamIDBudget -= 1 }
            staticInfo = StaticInfo(
                executablePath: path,
                bundleID: Self.bundleID(fromPath: path),
                teamID: resolveTeam ? codeSigningResolver.teamID(forExecutablePath: path) : nil,
                isTranslated: translated,
                architecture: processReader.architecture(translated: translated),
                teamIDResolved: resolveTeam)
        }
        newStaticCache[identity] = staticInfo

        return ProcessSample(
            timestamp: now,
            pid: pid,
            ppid: info.ppid,
            name: info.name,
            executablePath: staticInfo.executablePath,
            bundleID: staticInfo.bundleID,
            teamID: staticInfo.teamID,
            physFootprint: rusage?.physFootprint ?? 0,
            residentSize: info.residentSize,
            virtualSize: info.virtualSize,
            lifetimeMaxFootprint: rusage?.lifetimeMaxFootprint ?? 0,
            cpuPercent: cpuPercent,
            cpuTimeUser: info.cpuTimeUser,
            cpuTimeSystem: info.cpuTimeSystem,
            threadCount: info.threadCount,
            fdTotal: fd.total,
            fdVnode: fd.vnode,
            fdSocket: fd.socket,
            fdPipe: fd.pipe,
            fdOther: fd.other,
            diskBytesRead: rusage?.diskBytesRead ?? 0,
            diskBytesWritten: rusage?.diskBytesWritten ?? 0,
            diskReadBytesPerSec: diskReadBytesPerSec,
            diskWriteBytesPerSec: diskWriteBytesPerSec,
            energyNanojoules: energyNow,
            energyImpact: EnergyImpact.estimate(
                cpuPercent: cpuPercent,
                idleWakeupsPerSec: wakeupsPerSec,
                isTranslated: staticInfo.isTranslated ?? false),
            networkBytesPerSec: networkRates[pid] ?? 0,
            isTranslated: staticInfo.isTranslated ?? false,
            architecture: staticInfo.architecture,
            startTime: info.startTime,
            uid: info.uid,
            dataSource: source,
            footprintReadable: rusage != nil
        )
    }

    /// Reset inter-tick state (e.g. after a long pause) so the next tick reports
    /// zero deltas rather than a spike.
    public func reset() {
        lastCPU.removeAll()
        lastEnergy.removeAll()
        lastDisk.removeAll()
        staticCache.removeAll()
        lastSystemTime = nil
        lastProcessTime = nil
        lastCounters = nil
        lastPressureLoad = nil
        lastCoreTicks = nil
        cachedBattery = nil
        lastBatteryReadAt = nil
        networkReader.reset()
        diskReader.reset()
        privilegedFailureStreak = 0
        privilegedQuietUntil = nil
    }

    // MARK: - System sampling

    /// Build the system memory sample. `cpuLoad` is the live total CPU fraction
    /// (0...1) computed in `sampleCPU`; carrying it here keeps `SystemSample`'s
    /// `cpuLoad` a true instantaneous figure (it used to be a since-boot average)
    /// and feeds the persisted system-history CPU timeline.
    private func sampleSystem(
        now: Date, wallDeltaSeconds: TimeInterval, cpuLoad: Double, battery: BatterySample?,
        network: NetworkSample?, disk: DiskSample?
    ) -> SystemSample {
        let totalRAM = memoryReader.totalRAM
        let vm = memoryReader.sampleVM()
        let swap = memoryReader.sampleSwap()
        let level = memoryReader.pressureLevel()

        let compressed = vm?.compressed ?? 0
        let swapUsed = swap?.used ?? 0

        // Pressure trend from the growth rate of compressed + swap.
        var trendSignal = 0.0
        let load = compressed &+ swapUsed
        if let previous = lastPressureLoad, wallDeltaSeconds > 0 {
            let growth = load > previous ? Double(load - previous) : 0
            let rate = growth / wallDeltaSeconds
            trendSignal = max(0, min(rate / trendScaleBytesPerSec, 1))
        }
        lastPressureLoad = load

        let pressurePercent = PressureIndex.compute(
            level: level,
            compressed: compressed,
            swapUsed: swapUsed,
            totalRAM: totalRAM,
            trendSignal: trendSignal
        )

        // Counter deltas.
        let counters = SystemCounters(
            pageIns: vm?.pageIns ?? 0,
            pageOuts: vm?.pageOuts ?? 0,
            compressions: vm?.compressions ?? 0,
            decompressions: vm?.decompressions ?? 0
        )
        var deltas = SystemCounters(pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0)
        if let prev = lastCounters {
            deltas.pageIns = CPUMath.delta(counters.pageIns, prev.pageIns)
            deltas.pageOuts = CPUMath.delta(counters.pageOuts, prev.pageOuts)
            deltas.compressions = CPUMath.delta(counters.compressions, prev.compressions)
            deltas.decompressions = CPUMath.delta(counters.decompressions, prev.decompressions)
        }
        lastCounters = counters

        let appMemory = Taxonomy.appMemory(
            internalBytes: vm?.internal ?? 0,
            purgeableBytes: vm?.purgeable ?? 0
        )
        let cachedFiles = Taxonomy.cachedFiles(
            externalBytes: vm?.external ?? 0,
            purgeableBytes: vm?.purgeable ?? 0
        )

        return SystemSample(
            timestamp: now,
            totalRAM: totalRAM,
            free: vm?.free ?? 0,
            active: vm?.active ?? 0,
            inactive: vm?.inactive ?? 0,
            wired: vm?.wired ?? 0,
            speculative: vm?.speculative ?? 0,
            compressed: compressed,
            appMemory: appMemory,
            cachedFiles: cachedFiles,
            swapTotal: swap?.total ?? 0,
            swapUsed: swapUsed,
            pressureLevel: level,
            pressurePercent: pressurePercent,
            pageIns: counters.pageIns,
            pageOuts: counters.pageOuts,
            compressions: counters.compressions,
            decompressions: counters.decompressions,
            pageInsDelta: deltas.pageIns,
            pageOutsDelta: deltas.pageOuts,
            compressionsDelta: deltas.compressions,
            decompressionsDelta: deltas.decompressions,
            cpuLoad: cpuLoad,
            batteryPresent: battery?.isPresent ?? false,
            batteryCharge: battery?.chargePercent ?? 0,
            batteryPowerWatts: battery?.powerWatts ?? 0,
            batterySystemPowerWatts: battery?.systemPowerWatts ?? 0,
            batteryIsCharging: battery?.isCharging ?? false,
            batteryHealthPercent: battery?.healthPercent ?? 0,
            batteryCycleCount: battery?.cycleCount ?? 0,
            batteryTemperatureCelsius: battery?.temperatureCelsius ?? 0,
            networkInBytesPerSec: network?.inBytesPerSec ?? 0,
            networkOutBytesPerSec: network?.outBytesPerSec ?? 0,
            diskReadBytesPerSec: disk?.readBytesPerSec ?? 0,
            diskWriteBytesPerSec: disk?.writeBytesPerSec ?? 0,
            diskReadOperationsPerSec: disk?.readOperationsPerSec ?? 0,
            diskWriteOperationsPerSec: disk?.writeOperationsPerSec ?? 0
        )
    }

    /// Derive a best-effort bundle identifier from an executable path inside a
    /// `.app` bundle. Nil for plain executables.
    static func bundleID(fromPath path: String?) -> String? {
        guard let path else { return nil }
        // .../Foo.app/Contents/MacOS/Foo -> read Info.plist if present.
        guard let appRange = path.range(of: ".app/Contents/MacOS/") else { return nil }
        let appBundlePath = String(path[..<appRange.lowerBound]) + ".app"
        let infoPlist = appBundlePath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: infoPlist),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any],
            let bundleID = dict["CFBundleIdentifier"] as? String
        else { return nil }
        return bundleID
    }
}
