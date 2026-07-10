import Combine
import Foundation
import MacPerfMonitorCore

/// Drives the `Sampler` on a background queue at the configured cadence, keeps a
/// lightweight in-memory history for live charts, and publishes the latest
/// snapshot to SwiftUI on the main thread.
///
/// This is the "ring buffer (live, in-memory)" stage of the data flow in the
/// PRD: the UI reads the latest snapshot here on the hot path, with no database
/// round-trip. Historical views (added in later milestones) query GRDB instead.
///
/// Concurrency: the `Sampler` and `timer` are only ever touched on `queue`; the
/// `@Published` state and `systemHistory` are only ever mutated on the main
/// thread. The package builds in Swift 5 language mode, so this confinement is
/// by construction rather than enforced actor isolation.
final class SamplerModel: ObservableObject {
    /// The most recent heavy snapshot, republished on the heavy cadence (~2 s).
    /// This drives the in-window UI — the process table, the system header, the
    /// detail inspector, and the dashboard. Its process data only changes on
    /// heavy ticks anyway, so it is no longer republished on the in-between fast
    /// ticks; doing so forced the whole window to re-render and re-lay-out twice
    /// as often for no new data.
    @Published private(set) var latest: Sampler.Snapshot?
    @Published private(set) var isRunning = false

    /// A full-rate (~1 s) heartbeat for the menu-bar status item only. It is a
    /// plain Combine subject, NOT a `@Published`, so firing it does not trigger
    /// the model's `objectWillChange` and therefore does not re-render every
    /// SwiftUI view that observes the model. The status item reads `smoothedCPU`
    /// (refreshed every fast tick) on this beat, so the menu-bar icon stays live
    /// at the full rate while the heavy window UI updates at the calmer 2 s rate.
    let liveTick = PassthroughSubject<Void, Never>()

    /// Identities the leak detector currently flags for sustained growth,
    /// refreshed on the retention cadence (~once a minute). Published so every
    /// process surface — the table, the menubar list, the insights consumers,
    /// the dashboard — can mark a suspected leak with one consistent icon
    /// (PRD section 8.5).
    @Published private(set) var leakingProcessIDs: Set<ProcessIdentity> = []
    /// Alert conditions that remain active after their notification edge fires.
    /// The combined menu bar uses this for its red alarm state.
    @Published private(set) var activeAlertKinds: Set<Alert.Kind> = []

    /// Identities the user force-quit through MacPerfMonitor within the retention
    /// window, so the process list can keep showing them greyed out as clear
    /// confirmation that the kill took effect instead of the row just vanishing.
    /// Published so the list restyles the moment a kill lands and again when the
    /// entry expires. Backed by `terminatedProcesses`.
    @Published private(set) var terminatedProcessIDs: Set<ProcessIdentity> = []

    /// Lightweight system-level history (pressure, taxonomy, swap) for the live
    /// charts in later milestones. Only the small `SystemSample` is retained,
    /// never the full per-process arrays, to stay within the memory budget.
    private(set) var systemHistory: RingBuffer<SystemSample>

    /// Recent per-process trail (most recent last). Carries footprint for the
    /// menubar sparklines plus CPU, file-descriptor and disk counters, so the
    /// detail view can seed all of its charts the instant a process is opened —
    /// even one that was never a top consumer and so has no persisted history.
    /// Capped per process and pruned to live processes each tick, so it stays
    /// small (well under 1 MB) regardless of process churn.
    private(set) var processTrails: [ProcessIdentity: [ProcessHistoryPoint]] = [:]

    /// Top processes for the menubar dropdowns (and the Network tab's top-apps
    /// card), refreshed on every scan. Deliberately a separate observable object
    /// — see `MenuListsModel` — so their 1 Hz refresh while a popover is open
    /// never invalidates main-window views that don't read them.
    let menuLists = MenuListsModel()
    /// How many displayed entries each menubar list holds.
    private let menuListLimit = 10

    /// The processes shown in the main table: the live list with each process's
    /// CPU replaced by its ~5 s average (so the order and figures settle), plus
    /// any recently force-quit tombstones. Refreshed on the heavy cadence, so the
    /// table reorders calmly rather than on every fast tick.
    @Published private(set) var displayProcesses: [ProcessSample] = []

    /// Bumped every time `displayProcesses` is reassigned. A cheap O(1) signal
    /// the process table watches to rebuild its sorted/filtered rows *only* when
    /// the data actually changes (every heavy tick, ~2 s, or on a kill) — never
    /// on the 1 s `latest` republish. `ProcessSample` is not `Equatable`, so the
    /// table cannot diff the array itself; this counter stands in for that.
    @Published private(set) var displayProcessesVersion = 0

    /// Recent raw CPU samples for the ~5 s smoothing window the menubar read-outs
    /// and the live core grids use, so the numbers, ordering, and bars settle
    /// instead of flickering at the full tick rate. The dashboard CPU timeline
    /// keeps the raw history, so real spikes are never hidden there.
    private var recentCPUSamples: [CPUSample] = []
    private let cpuSmoothingTicks: Int

    /// Recent network samples for the ~5 s smoothing window the menubar read-out
    /// uses, so the download/upload figures settle instead of flickering at the
    /// full tick rate. The most recent also carries the live session totals and
    /// primary interface for the menu. Touched only on the main thread.
    private var recentNetworkSamples: [NetworkSample] = []

    /// The most recent battery sample, captured every fast tick (~1 Hz). The
    /// published `latest` snapshot carries battery only on the slower heavy
    /// cadence, so the battery menubar icon + dropdown read this fast copy
    /// (`latestBattery`) to stay live at 1 Hz like the CPU/memory/network surfaces.
    /// Touched only on the main thread. nil on a Mac with no battery hardware.
    private var recentBattery: BatterySample?

    /// Recent GPU samples for the ~5 s smoothing window the menubar GPU read-out
    /// uses, so the figure settles rather than jumping each tick. Populated only
    /// while the GPU menubar item is on (`gpuSamplingEnabled`); emptied when it goes
    /// off. Touched only on the main thread; reused `cpuSmoothingTicks` as the window.
    private var recentGPUSamples: [GPUSample] = []
    /// Longer ring of GPU utilization (0–100) for the panel's usage-history
    /// sparkline (~last minute). Main thread only; emptied when GPU is off.
    private var gpuHistoryRing: [Double] = []
    private let gpuHistoryLimit = 60

    /// The per-process scan cadence — the FINEST of the UI table interval and (when
    /// logging) the high-res persist interval, since the scan feeds both. O(number
    /// of processes), so it is the app's dominant sampling cost. The cheap
    /// system/CPU sample still runs every tick for the menubar/dashboard hero.
    private var heavyEveryTicks: Int
    private var heavyTickCounter = 0
    /// The main-window UI publish cadence — the global "Refresh interval" dial.
    /// Kept SEPARATE from the scan/persist cadence so high-res (e.g. 1 s) logging
    /// doesn't force the whole in-window UI (`latest`, the table, the cards) to
    /// re-render every second. `latest` and alerts follow this; persist follows the
    /// finer scan cadence (and self-throttles to the high-res interval).
    private var tableEveryTicks: Int = 10
    private var tableTickCounter = 0
    /// The latest heavy scan's processes, carried between heavy ticks so the
    /// published snapshot always has a process list. Confined to `queue`.
    private var carriedProcesses: [ProcessSample] = []
    private var carriedUnreadable = 0
    private var hasProcessSnapshot = false
    /// Trail points spanning the ~5 s smoothing window at the heavy cadence.
    private var processSmoothingPoints: Int

    /// A process the user force-quit through MacPerfMonitor, kept briefly so the list
    /// can keep showing it greyed out. Carries the last live sample (to draw the
    /// row after the process is gone from snapshots) and the moment it was
    /// stopped (to expire the entry). Touched only on the main thread.
    private struct TerminatedProcess {
        var sample: ProcessSample
        var terminatedAt: Date
    }

    /// Recently force-quit processes, keyed by identity. Drives the greyed-out
    /// "stopped" rows; pruned to `terminatedRetention` each tick.
    private var terminatedProcesses: [ProcessIdentity: TerminatedProcess] = [:]

    /// How long a force-quit process stays visible (greyed out) in the list
    /// before its row is dropped.
    private let terminatedRetention: TimeInterval = 5 * 60

    let interval: TimeInterval

    private let sampler = Sampler()
    // `.userInitiated`, deliberately high. This QoS is one of the four legs that
    // keep the live read-outs alive while the app is a backgrounded, occluded
    // menu-bar agent: App Nap aggressively defers `.utility`/`.background` (and,
    // on macOS 26/27, even `.default`) work, coalescing this timer's fires out
    // to ~5 s and freezing the menu bar. See `start()` for the other three legs
    // (`.strict` timer, `beginActivity`, `NSAppSleepDisabled`).
    private let queue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.sampler", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    /// Held for the lifetime of sampling. On macOS 26/27 the QoS + `.strict` timer
    /// still aren't enough on their own to keep an occluded menu-bar agent's 1 Hz
    /// timer alive — this `userInitiated` activity is the third leg that, together
    /// with them, defeats App Nap. `…AllowingIdleSystemSleep` keeps the timer firing
    /// without keeping the Mac awake.
    private var samplingActivity: NSObjectProtocol?
    private var didLogFirstTick = false
    private let trailLength = 30

    /// On-disk history store, behind a lock because the app-mode switch can open
    /// or close it at runtime (menu-bar-only mode releases it) while reader
    /// methods check it from the main thread and the sampler writes from `queue`.
    /// `SampleStore` itself (a GRDB pool) is internally thread-safe; the lock only
    /// guards swapping the reference. Optional: if it cannot be opened — or
    /// logging is off — the app still runs live from the ring buffer, just
    /// without the longer dashboard ranges.
    private var _store: SampleStore?
    private let storeLock = NSLock()
    private var store: SampleStore? {
        get {
            storeLock.lock()
            defer { storeLock.unlock() }
            return _store
        }
        set {
            storeLock.lock()
            defer { storeLock.unlock() }
            _store = newValue
        }
    }
    /// Whether samples are being written to `store`. Mirrors the app's function
    /// mode (full vs menu-bar-only); flipped live via `setPersistenceEnabled`.
    /// Read and written only on `queue` after init.
    private var persistenceEnabled: Bool
    /// Live consumers of per-process data — open menu-bar popovers that show top
    /// processes, and the main window. The heavy per-process scan (and the
    /// O(process count) trail/menu/table rebuilds it feeds) runs only when this is
    /// non-zero OR history logging is on; in menu-bar-only mode with nothing open
    /// the app does zero per-process work, since the menu-bar read-outs need only
    /// the cheap system sample. Read and written only on `queue`.
    private var processConsumers = 0
    /// Open menu-bar popovers that show a live top-process list, counted per
    /// list kind. While any is open the per-process scan runs every tick (1 Hz),
    /// independent of the table cadence — so an open popover stays live without
    /// speeding up the main window or the history DB (those follow
    /// `heavyEveryTicks`) — and only the open kinds' lists are computed. Read
    /// and written only on `queue`.
    private var popoverKindConsumers: [MenuListKind: Int] = [:]
    /// When each menu list was last recomputed. Lets a reopening popover tell
    /// "at most one dial interval old" from "frozen since it last closed" and
    /// clear the latter instead of rendering dead rows. Read/written on `queue`.
    private var menuListRefreshedAt: [MenuListKind: Date] = [:]
    /// When the UI-feeding scan work (trails, menu lists) last ran. Trails
    /// freeze while nothing consumes the scan; after a real gap the frozen
    /// points must be dropped, not blended. Read/written on `queue`.
    private var lastUIScanAt: Date?
    /// Whether to read the GPU on each cheap tick. Off unless the menubar GPU item
    /// is shown, so a Mac with GPU off never walks the IOAccelerator registry.
    /// Read on `queue` in `tick`; set via `setGPUSamplingEnabled`.
    private var gpuSamplingEnabled = false
    /// Run retention/downsampling roughly once a minute, off the sampling path.
    private var ticksSinceRetention = 0
    private var retentionEveryTicks: Int
    /// Coarse WAL-checkpoint cadence (heavy ticks). Auto-checkpoint is disabled so
    /// the per-tick commit never fsyncs; this resets the WAL every ~15 s instead.
    private var ticksSinceCheckpoint = 0
    private var checkpointEveryTicks: Int
    /// When the system row + process rows were last written to the DB. The table
    /// can refresh faster than we persist (the live charts read the in-memory
    /// ring, not the DB), so a 1 s table does not multiply DB writes.
    private var lastPersistAt: Date?
    /// Persist at most this often — the high-res logging interval, recomputed when
    /// the table or high-res interval changes. Decouples the DB write frequency
    /// from the UI/scan cadence.
    private var persistMinInterval: TimeInterval = 1.9
    /// The current UI/scan "table" interval and the high-res logging interval,
    /// retained so `recomputeScanCadence` can derive the heavy-scan cadence (the
    /// finer of the two while logging) from both.
    private var tableIntervalSeconds = SamplerModel.defaultTableInterval
    private var highResIntervalSeconds = SamplerModel.defaultHighResInterval
    /// The leak scan is the heaviest periodic work (a regression over a bucketed
    /// footprint series for every process, off ~28k scanned rows). It runs only
    /// every `leakScanEveryRetentions` retention cycles (~3 min): leaks grow over
    /// many minutes, so this latency is harmless, and it keeps the per-minute
    /// retention pass cheap. On-demand loads (dashboard/Insights) still scan fresh.
    private var leakScanCountdown = 0
    private let leakScanEveryRetentions = 3
    /// Dedicated low-priority queue for the periodic leak scan, so the heavy read
    /// + regression never blocks the sampler queue (and thus sampling). The DB
    /// reads are WAL-safe from any thread.
    private let leakScanQueue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.leakscan", qos: .utility)

    /// Dedicated queue for every UI-triggered history read (`load…`). GRDB pool
    /// reads are WAL-concurrent from any thread, so nothing about them needs the
    /// sampler queue — and putting them there serialized multi-hundred-millisecond
    /// analysis scans against the 1 Hz tick, stalling sampling (and the menubar
    /// heartbeat) whenever a tab loaded, and stacking tab loads behind ticks.
    /// Serial on purpose: the TTL caches below are confined to it, and individual
    /// reads are short once cached/indexed. `.userInitiated` because these reads
    /// answer a visible interaction (a tab open, a range change).
    private let readQueue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.dbread", qos: .userInitiated)

    /// Large, uncached trace exports must not queue ahead of chart and tab
    /// reads. GRDB's WAL pool supports concurrent readers, so export gets an
    /// independent queue and reports failures instead of turning them into an
    /// empty-history message.
    private let exportReadQueue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.dbexport", qos: .userInitiated)

    /// Background queue for periodic database maintenance (the retention pass +
    /// WAL checkpoint), so the once-a-minute roll-up/trim/vacuum spike never
    /// runs inside a tick. Retention commits short per-step transactions, so a
    /// persist that lands mid-pass waits one step at most on the pool's writer.
    private let maintenanceQueue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.dbmaintenance", qos: .utility)
    /// Guards against overlapping retention passes if one runs longer than the
    /// retention cadence (e.g. a large size-cap trim). Confined to `queue`.
    private var retentionInFlight = false
    /// Invalidates background history work whenever the persistence store is
    /// enabled, disabled, or replaced. Confined to `queue`.
    private var persistenceGeneration = 0

    /// The most recent leak-board scan and when it ran, confined to `readQueue`.
    /// Every consumer — `loadLeakBoard` and the Insights bundle — reads through
    /// `currentLeakBoard(_:)`, so the scan (a two-tier query over the whole
    /// history window) runs at most once per cycle instead of separately for
    /// each caller on its own timer. The periodic scan refreshes it from
    /// `leakScanQueue` via a `readQueue` hop.
    private var cachedLeakBoard: (at: Date, entries: [LeakBoardEntry])?

    /// Just under the retention cadence, so the retention pass always sees a
    /// fresh board while callers in between share the cached one.
    private let leakBoardMaxAge: TimeInterval = 55

    /// The windowed top-consumers leaderboard is an aggregation over the raw
    /// tier. The Battery tab asks for it on a 5s timer and Insights on a 30s
    /// one, so cache by (window, metric, limit) and let the scan run at most
    /// once per `consumerMaxAge` however often — or from however many tabs — it
    /// is requested. A windowed average is imperceptibly stale over this span.
    private struct ConsumerKey: Hashable {
        let window: HistoryWindow
        let metric: ConsumerMetric
        let limit: Int
    }
    private var cachedConsumers: [ConsumerKey: (at: Date, rows: [ProcessConsumer])] = [:]
    private let consumerMaxAge: TimeInterval = 15
    /// Short-TTL cache for the Battery tab's recent-energy board (keyed by
    /// "<seconds>-<limit>"), so its ~130ms full-tier scan runs once per
    /// `consumerMaxAge` rather than on every 5s Battery-tab refresh.
    private var cachedEnergyConsumers: [String: (at: Date, rows: [ProcessConsumer])] = [:]

    /// The Groups tab's blended-footprint report is a small fan of windowed
    /// queries (member resolution + combined series + per-member aggregates).
    /// Cache by (group id, window, rules) so the cards and the detail view share
    /// one computation per `consumerMaxAge`, and an edited group invalidates its
    /// own entry (the rules are part of the key).
    private struct GroupKey: Hashable {
        let id: UUID
        let window: HistoryWindow
        let rule: GroupRule
    }
    private var cachedGroupReports: [GroupKey: (at: Date, report: GroupReport)] = [:]

    /// System-history reads gain a new raw point only every `persistMinInterval`
    /// (~1.9 s), so a just-under-that TTL returns byte-identical data while
    /// collapsing the per-tick re-reads that the Processes header, Dashboard,
    /// and Insights all fire at fast dials. Keyed by window / by whole seconds.
    /// Confined to `readQueue`.
    private var cachedSystemHistory: [HistoryWindow: (at: Date, points: [SystemHistoryPoint])] =
        [:]
    private var cachedRecentSystemHistory: [Int: (at: Date, points: [SystemHistoryPoint])] = [:]
    private let systemHistoryMaxAge: TimeInterval = 2.5

    /// Pressure events change on minute timescales (they are derived from
    /// level *steps* in the 2 h window), so a short TTL absorbs the per-tick
    /// Insights reloads without visible staleness. Confined to `readQueue`.
    private var cachedPressureEvents: (at: Date, events: [PressureEvent])?
    private let pressureEventsMaxAge: TimeInterval = 15

    /// The Insights evidence series (2 h raw history per leaking process, 30 min
    /// per top consumer). The leak series only changes when the leak board does,
    /// so it is keyed to the board's timestamp; the consumer series get the
    /// standard consumer TTL. Confined to `readQueue`.
    private var cachedLeakSeries: (boardAt: Date, series: [ProcessIdentity: [ProcessHistoryPoint]])?
    private var cachedConsumerSeries:
        (at: Date, identities: [ProcessIdentity], series: [ProcessIdentity: [(Date, UInt64)]])?

    /// The alert decision engine and its inputs, all confined to `queue`. The
    /// config is pushed in from settings via `setAlertConfig(_:)`; the leaking
    /// set is refreshed from the leak board on the retention cadence.
    private let alertEngine = AlertEngine()
    private var alertConfig = AlertConfig.default
    private var leakingIDs: Set<ProcessIdentity> = []
    private var pressureMonitor: MemoryPressureMonitor?

    /// Sink for fired alerts, invoked on the main thread. The app points this at
    /// the notification center; left as a no-op it simply does nothing.
    var onAlertsFired: ([Alert]) -> Void = { _ in }

    init(
        interval: TimeInterval = 1.0, historyCapacity: Int = 900, store: SampleStore? = nil,
        persistenceEnabled: Bool = AppModeManager.loggingEnabledFromDefaults()
    ) {
        self.interval = interval
        self.systemHistory = RingBuffer(capacity: historyCapacity)
        // The heavy per-process scan cadence (the "table" interval), user-tunable
        // (default 10 s, choices 1 s–5 min). The heavy tick — the libproc fan-out
        // over ~600 processes plus the row insert — is the app's dominant sampling
        // cost, so it runs at this slower cadence while the live menubar/charts
        // refresh every `interval` (1 s) from the cheap system sample. Inter-tick
        // deltas (cpuPercent, energyImpact) use a measured wall-clock delta, so
        // they stay correct at any cadence.
        let tableInterval = Self.configuredTableInterval()
        let highRes = Self.configuredHighResInterval()
        self.tableIntervalSeconds = tableInterval
        self.highResIntervalSeconds = highRes
        self.persistenceEnabled = persistenceEnabled
        // When logging, the per-process scan runs at least as often as high-res
        // logging demands (raw rows can be no denser than the scan); otherwise at
        // the UI table cadence. The retention/checkpoint/smoothing counters count
        // heavy ticks, so they key off this same scan cadence.
        let scan = persistenceEnabled ? min(tableInterval, highRes) : tableInterval
        self.heavyEveryTicks = max(1, Int((scan / interval).rounded()))
        self.tableEveryTicks = max(1, Int((tableInterval / interval).rounded()))
        self.retentionEveryTicks = max(1, Int((60.0 / scan).rounded()))
        self.checkpointEveryTicks = max(1, Int((15.0 / scan).rounded()))
        self.persistMinInterval = max(1.0, highRes)
        // Smooth the menubar/core-grid total CPU over ~5 s (fast-tick samples).
        self.cpuSmoothingTicks = max(1, Int((5.0 / interval).rounded()))
        self.processSmoothingPoints = max(2, Int((5.0 / scan).rounded()))
        if let store {
            self._store = store
        } else if persistenceEnabled {
            // Full mode: persist to the standard on-disk location. Failure here is
            // non-fatal — live sampling does not depend on the database.
            do {
                self._store = try SampleStore(url: MacPerfMonitorDatabase.defaultURL())
            } catch {
                AppLog.sampler.error(
                    "could not open history store: \(String(describing: error), privacy: .public)")
                self._store = nil
            }
        } else {
            // Menu-bar-only at launch: do not open (or even create) the database.
            self._store = nil
        }
    }

    /// Begin sampling. Fires an immediate first tick, then repeats at `interval`.
    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            // macOS 26/27 App Nap is more aggressive than what Stats targets: a plain
            // GCD timer on a `.default`/`.utility` queue gets coalesced out to ~5 s
            // and freezes the menu bar. Keeping it at 1 Hz here takes three things
            // together — a `.userInitiated` queue (above), the `.strict` timer flag
            // below, AND the `samplingActivity` assertion; dropping any one still lets
            // App Nap throttle it (measured). Stats needs none of this on its targets,
            // but it does not stay live on macOS 26/27 without it.
            if self.samplingActivity == nil {
                self.samplingActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: "Live menu-bar performance read-outs")
            }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval, leeway: .milliseconds(80))
            // Drain an autorelease pool every tick. The handler runs on a
            // long-lived serial queue whose worker thread never exits, so without
            // an explicit pool the autoreleased temporaries each tick creates pile
            // up on that thread's top-level pool forever — above all the ~600
            // per-process executable-path lookups, which are NSString-backed
            // (`NSPathStore2`). With the window open (so the process scan runs)
            // that was a steady ~300 MB/hour growth; menu-bar-only idle (no scan)
            // didn't leak, which is why it looked tied to the visible window.
            timer.setEventHandler { [weak self] in autoreleasepool { self?.tick() } }
            self.timer = timer
            timer.resume()
            // Event-driven pressure alerts: fire an immediate tick the moment
            // the kernel signals warning/critical, rather than waiting for the
            // next scheduled sample. Force the heavy path so the alert engine
            // (which only runs on heavy ticks) evaluates the spike at once.
            if self.pressureMonitor == nil {
                let monitor = MemoryPressureMonitor(queue: self.queue) { [weak self] in
                    autoreleasepool { self?.tick(forceHeavy: true) }
                }
                monitor.start()
                self.pressureMonitor = monitor
            }
        }
        DispatchQueue.main.async { self.isRunning = true }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.pressureMonitor?.stop()
            self?.pressureMonitor = nil
            if let activity = self?.samplingActivity {
                ProcessInfo.processInfo.endActivity(activity)
                self?.samplingActivity = nil
            }
        }
        DispatchQueue.main.async { self.isRunning = false }
    }

    /// Fire a sampler tick right now, off the regular timer cadence, so a freshly
    /// opened menu-bar popover shows up-to-date read-outs immediately instead of
    /// waiting up to a full tick — longer still when App Nap has coalesced the
    /// timer while the menubar-only app was idle. Cheap: the immediate tick takes
    /// only the light system/CPU/battery/network sample unless a heavy scan was
    /// already due. No-op when sampling is stopped (e.g. a lapsed trial).
    func requestImmediateTick() {
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            // A plain tick, NOT forceHeavy: the caller registered its consumer
            // first (MenuClock and the window handlers guarantee the order), so
            // an open popover's 1 Hz scan runs, and a reopening window forces
            // the table due via `addProcessConsumer`'s 0→1 transition. Forcing
            // the heavy path here instead made every popover open republish the
            // main window off-dial and reset the refresh-dial phase.
            self.tick()
        }
    }

    /// Push the latest alert preferences onto the sampler queue, where the
    /// engine reads them. Called from settings whenever the config changes.
    func setAlertConfig(_ config: AlertConfig) {
        queue.async { self.alertConfig = config }
    }

    /// Install (or clear) the privileged helper-backed reader on the sampler.
    /// Hops to the sampler queue, where the `Sampler` is exclusively touched, so
    /// the reader is swapped safely between ticks. Passing nil reverts to
    /// user-level-only coverage.
    func setPrivilegedReader(_ reader: PrivilegedReader?) {
        queue.async { [weak self] in self?.sampler.setPrivilegedReader(reader) }
    }

    /// Install a handler the sampler invokes when the privileged (root helper)
    /// reader keeps failing — the app uses it to auto-recover the helper. Delivered
    /// on the main thread, where `HelperManager` lives.
    func setPrivilegedReadFailureHandler(_ handler: @escaping () -> Void) {
        queue.async { [weak self] in
            self?.sampler.onPrivilegedReadFailure = { DispatchQueue.main.async { handler() } }
        }
    }

    /// UserDefaults key for the per-app network tracking opt-in, shared with
    /// Settings. Off by default — `nettop` is heavier than the libproc reads.
    static let perAppNetworkDefaultsKey = "trackPerAppNetwork"

    /// Whether the per-app network reader is currently installed. Confined to
    /// `queue`, so toggling is idempotent and never spawns a second nettop.
    private var perAppNetworkEnabled = false

    /// Turn per-app network attribution on or off. Hops to the sampler queue,
    /// where the `Sampler` is exclusively touched, and starts/stops the long-lived
    /// `nettop` behind it. Called from the app on launch and whenever the Settings
    /// toggle changes. When turned off, clears the menubar network list.
    func setPerAppNetworkTracking(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, enabled != self.perAppNetworkEnabled else { return }
            self.perAppNetworkEnabled = enabled
            self.sampler.setNetworkProcessReader(enabled ? NetworkProcessReader() : nil)
            if !enabled {
                DispatchQueue.main.async { self.menuLists.update(.network, with: []) }
            }
        }
    }

    // MARK: - Table / sampling interval

    /// UserDefaults key for the global refresh interval in seconds, shared by the
    /// toolbar control and Settings. The menu-bar read-outs always stay at 1 Hz;
    /// this sets how often the heavy per-process scan runs AND how often the whole
    /// in-window UI (table, charts, cards) re-renders — it is the app's main CPU
    /// lever. Default 10 s, deliberately light; the user can speed it up per need.
    static let tableIntervalKey = "tableIntervalSeconds"
    static let defaultTableInterval: Double = 10.0
    static let tableIntervalChoices: [Double] = [1, 2, 5, 10, 30, 60, 300]

    /// Compact label for an interval, e.g. "1s" … "30s", "1m", "5m".
    static func tableIntervalLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m"
    }

    private static func configuredTableInterval() -> Double {
        let v = UserDefaults.standard.double(forKey: tableIntervalKey)
        return tableIntervalChoices.contains(v) ? v : defaultTableInterval
    }

    // MARK: - Logging resolution tiers
    //
    // History is logged in two user-configurable tiers plus a fixed low-res tier:
    //   • High-res  → raw tables. Frequency = how often a raw sample is written;
    //                 age = how long raw is kept (RetentionPolicy.rawWindow).
    //   • Standard  → minute-aggregate tables. Frequency = the aggregate bucket
    //                 width; age is ADDITIVE — the detailed horizon is high age +
    //                 standard age (RetentionPolicy.minuteWindow = high + standard).
    //   • Long-term → hour aggregates, fixed 60-minute buckets kept 90 days.
    // Defaults preserve the prior behaviour (≈10s/2h raw, 60s/7d minute) so an
    // upgrade doesn't silently change anyone's database size.

    /// How often a raw (high-resolution) sample is written to disk, in seconds.
    static let highResIntervalKey = "logging.highResIntervalSeconds"
    static let defaultHighResInterval: Double = 10
    static let highResIntervalChoices: [Double] = [1, 2, 5, 10, 30]

    /// How long raw samples are kept, in seconds (→ `RetentionPolicy.rawWindow`).
    static let highResAgeKey = "logging.highResAgeSeconds"
    static let defaultHighResAge: Double = 2 * 3600
    static let highResAgeChoices: [Double] = [
        3600, 2 * 3600, 6 * 3600, 12 * 3600, 24 * 3600, 2 * 86_400,
    ]

    /// The standard-resolution aggregate bucket width, in seconds.
    static let standardResIntervalKey = "logging.standardResIntervalSeconds"
    static let defaultStandardResInterval: Double = 60
    static let standardResIntervalChoices: [Double] = [30, 60, 120, 300, 600]

    /// The additional (beyond high-res) age for the standard-resolution tier, in
    /// seconds. Detailed history = high age + this.
    static let standardResAgeKey = "logging.standardResAgeSeconds"
    static let defaultStandardResAge: Double = 7 * 86_400
    static let standardResAgeChoices: [Double] = [
        86_400, 3 * 86_400, 7 * 86_400, 14 * 86_400, 30 * 86_400, 60 * 86_400,
    ]

    /// The fixed long-term (hour) tier retention, in seconds.
    static let longTermAge: Double = 90 * 86_400

    /// Hard ceiling on total stored sample rows (all tiers, both domains) above
    /// which retention rollups, the planner `PRAGMA optimize`, and the windowed
    /// covering-index scans start to cost seconds. Anchored to this repo's own
    /// numbers: a ~445 MB production DB is "millions of rows"; 25M is ~2× that
    /// headroom while staying below what the 5 GB byte cap alone would permit —
    /// so it is the *performance* guard the size cap can't express. The Settings
    /// tier pickers clamp their options so a projected total can't exceed it.
    static let maxTotalSamples = 25_000_000

    private static func configured(
        _ key: String, _ choices: [Double], _ fallback: Double
    ) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return choices.contains(v) ? v : fallback
    }
    static func configuredHighResInterval() -> Double {
        configured(highResIntervalKey, highResIntervalChoices, defaultHighResInterval)
    }
    static func configuredHighResAge() -> Double {
        configured(highResAgeKey, highResAgeChoices, defaultHighResAge)
    }
    static func configuredStandardResInterval() -> Double {
        configured(standardResIntervalKey, standardResIntervalChoices, defaultStandardResInterval)
    }
    static func configuredStandardResAge() -> Double {
        configured(standardResAgeKey, standardResAgeChoices, defaultStandardResAge)
    }

    /// Apply a new table/scan interval at runtime, from the Settings control.
    /// Hops to the sampler queue, where the cadence counters are read on the tick.
    func setTableInterval(_ seconds: Double) {
        let s = Self.tableIntervalChoices.contains(seconds) ? seconds : Self.defaultTableInterval
        queue.async { [weak self] in
            guard let self else { return }
            self.tableIntervalSeconds = s
            self.recomputeScanCadence()
        }
    }

    /// Apply a new high-resolution logging interval at runtime, from Settings. This
    /// is the raw-tier write frequency; when finer than the table interval it also
    /// speeds up the per-process scan so raw rows can be that dense.
    func setHighResInterval(_ seconds: Double) {
        let s =
            Self.highResIntervalChoices.contains(seconds) ? seconds : Self.defaultHighResInterval
        queue.async { [weak self] in
            guard let self else { return }
            self.highResIntervalSeconds = s
            self.recomputeScanCadence()
        }
    }

    /// Recompute the heavy-scan cadence and its per-heavy-tick counters from the
    /// current table + high-res intervals and whether logging is on. The scan is
    /// the finer of the two while logging (raw rows can be no denser than the
    /// scan), else the UI table interval. Must run on `queue`.
    private func recomputeScanCadence() {
        let scan =
            persistenceEnabled
            ? min(tableIntervalSeconds, highResIntervalSeconds) : tableIntervalSeconds
        heavyEveryTicks = max(1, Int((scan / interval).rounded()))
        // The main-window UI publishes at the table dial, independent of the finer
        // scan/persist cadence.
        tableEveryTicks = max(1, Int((tableIntervalSeconds / interval).rounded()))
        // retention/checkpoint count persist() calls (one per scan-due tick), so
        // they key off the scan cadence.
        retentionEveryTicks = max(1, Int((60.0 / scan).rounded()))
        checkpointEveryTicks = max(1, Int((15.0 / scan).rounded()))
        processSmoothingPoints = max(2, Int((5.0 / scan).rounded()))
        persistMinInterval = max(1.0, highResIntervalSeconds)
        heavyTickCounter = 0
        tableTickCounter = 0
    }

    /// Turn history logging to the on-disk database on or off at runtime, from
    /// the app-mode switch (full ↔ menu-bar-only). Enabling opens the store
    /// (creating the file if needed) and resumes per-tick writes; disabling
    /// checkpoints and releases it, so menu-bar-only mode holds no database
    /// handle and the file stops growing — the file itself is kept, so switching
    /// back to full preserves the existing history. Confined to `queue`, the
    /// thread that writes to and now owns the lifetime of `store`.
    func setPersistenceEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, enabled != self.persistenceEnabled else { return }
            self.persistenceEnabled = enabled
            self.persistenceGeneration &+= 1
            if enabled {
                if self.store == nil {
                    do {
                        self.store = try SampleStore(url: MacPerfMonitorDatabase.defaultURL())
                    } catch {
                        AppLog.sampler.error(
                            "could not open history store: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
                // Resume promptly rather than mid-cycle.
                self.lastPersistAt = nil
                self.ticksSinceCheckpoint = 0
                self.ticksSinceRetention = 0
            } else {
                // Flush the WAL into the main file, then release the pool so
                // menu-bar-only mode is genuinely database-free.
                self.store?.checkpoint()
                self.store = nil
                self.readQueue.async { [weak self] in self?.clearHistoryCaches() }
                self.leakingIDs.removeAll()
                DispatchQueue.main.async { self.leakingProcessIDs.removeAll() }
            }
            // The scan cadence depends on whether logging is on (it speeds up to
            // feed high-res logging when enabled), so recompute it here too.
            self.recomputeScanCadence()
        }
    }

    /// Turn GPU sampling on or off. The menubar GPU item calls this when it
    /// installs / removes itself, so the IOAccelerator registry is read only while
    /// the GPU read-out is actually shown — nothing otherwise.
    func setGPUSamplingEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.gpuSamplingEnabled = enabled }
    }

    /// Register a live consumer of per-process data (an open menu-bar popover that
    /// shows top processes, or the main window). While any consumer is registered
    /// the heavy per-process scan runs at the table cadence; with none — and no
    /// history logging — the scan is skipped entirely. Registering the first
    /// consumer forces a heavy scan on the next tick so the just-opened surface
    /// shows processes without waiting up to a full table interval; pair with
    /// `requestImmediateTick()` for an instant refresh. Balance every call with
    /// `removeProcessConsumer()`.
    func addProcessConsumer() {
        queue.async { [weak self] in
            guard let self else { return }
            self.processConsumers += 1
            if self.processConsumers == 1 {
                // Due immediately, so the next tick (or `requestImmediateTick`) both
                // SCANS and PUBLISHES — force the table cadence too, otherwise a
                // reopening window shows an empty process list until the next
                // table-cadence tick (up to the whole Refresh interval away).
                self.heavyTickCounter = self.heavyEveryTicks
                self.tableTickCounter = self.tableEveryTicks
            }
        }
    }

    /// Drop a per-process consumer registered with `addProcessConsumer()`. When the
    /// last one goes the heavy scan stops on the following tick (unless logging is
    /// on); the last scanned lists are simply left in place, unobserved.
    func removeProcessConsumer() {
        queue.async { [weak self] in
            guard let self else { return }
            self.processConsumers = max(0, self.processConsumers - 1)
        }
    }

    /// Register an open menu-bar popover that shows a live top-process list. While
    /// any is registered the per-process scan and the menu lists run every tick
    /// (1 Hz) so the panel stays live; the main window and the history DB stay on the
    /// table cadence regardless. Pair `requestImmediateTick()` for an instant first
    /// refresh, and balance every call with `removePopoverProcessConsumer()`.
    func addPopoverProcessConsumer(_ kind: MenuListKind) {
        queue.async { [weak self] in
            guard let self else { return }
            let prior = self.popoverKindConsumers[kind, default: 0]
            self.popoverKindConsumers[kind] = prior + 1
            // A list that hasn't recomputed within the dial interval holds dead
            // rows from the last time this popover was open — possibly hours
            // ago, PIDs recycled. Clear it so the just-opened panel renders
            // empty for the ~100 ms until the immediate tick's scan lands,
            // rather than offering kill/inspect on stale processes.
            let staleAfter = Double(self.heavyEveryTicks) * self.interval + 5
            if prior == 0,
                Date().timeIntervalSince(self.menuListRefreshedAt[kind] ?? .distantPast)
                    > staleAfter
            {
                DispatchQueue.main.async { self.menuLists.update(kind, with: []) }
            }
        }
    }

    /// Drop a popover consumer registered with `addPopoverProcessConsumer(_:)`.
    /// When the last one goes the 1 Hz scan reverts to the table cadence (or
    /// stops, if nothing else consumes processes) on the following tick.
    func removePopoverProcessConsumer(_ kind: MenuListKind) {
        queue.async { [weak self] in
            guard let self else { return }
            self.popoverKindConsumers[kind] = max(0, (self.popoverKindConsumers[kind] ?? 0) - 1)
        }
    }

    /// Runs on `queue`. Always takes the cheap system/CPU sample so the menubar
    /// and dashboard hero stay live; runs the heavy per-process scan (and the
    /// persistence, trail, menu, and table refreshes that depend on it) only
    /// every `heavyEveryTicks` — or immediately when `forceHeavy` is set, used by
    /// the kernel pressure event so an alert is not delayed. Then hops to main to
    /// publish.
    private func tick(forceHeavy: Bool = false) {
        let (system, cpu, battery, network, gpu) = sampler.tickSystem(readGPU: gpuSamplingEnabled)

        heavyTickCounter += 1
        tableTickCounter += 1
        // Three independent cadences over one per-process scan:
        //   • An open menu-bar popover shows a live top-process list, so while one is
        //     open the scan and the menu lists run EVERY tick (1 Hz).
        //   • The in-window table and the history DB follow the table cadence — the
        //     app's global refresh dial — so an open popover never changes the main
        //     window's rate (`heavyTickCounter` resets, and the window/DB work runs,
        //     only on a table-due tick).
        //   • With nothing consuming processes (menu-bar-only, nothing open) the scan
        //     is skipped entirely; the menu bar lives on the cheap system sample.
        // The network dropdown consumes the scan only while per-app attribution
        // is on — off, it renders live rates from the cheap system sample and no
        // process list, so its open popover must not force the 1 Hz scan.
        var openPopoverKinds = Set(popoverKindConsumers.filter { $0.value > 0 }.keys)
        if !perAppNetworkEnabled { openPopoverKinds.remove(.network) }
        let popoverOpen = !openPopoverKinds.isEmpty
        let needProcesses = persistenceEnabled || processConsumers > 0 || popoverOpen
        // Two cadences: the fine SCAN (feeds persistence + trails + popover) runs at
        // `heavyEveryTicks`; the main-window UI publish/alerts run at the coarser
        // `tableEveryTicks` (the global Refresh dial), so 1 s logging never forces
        // the in-window table/cards to re-render every second.
        let scanDue = forceHeavy || !hasProcessSnapshot || heavyTickCounter >= heavyEveryTicks
        let tableDue = forceHeavy || !hasProcessSnapshot || tableTickCounter >= tableEveryTicks
        let runScan = needProcesses && (popoverOpen || scanDue || tableDue)
        if runScan {
            let result = sampler.tickProcesses()
            carriedProcesses = result.processes
            carriedUnreadable = result.unreadableProcessCount
            hasProcessSnapshot = true
            let snapshot = Sampler.Snapshot(
                system: system, processes: result.processes,
                unreadableProcessCount: result.unreadableProcessCount, cpu: cpu, battery: battery,
                network: network)
            if !didLogFirstTick {
                didLogFirstTick = true
                AppLog.sampler.notice(
                    "first tick: \(result.processes.count, privacy: .public) processes, \(result.unreadableProcessCount, privacy: .public) unreadable, pressure \(Int(system.pressurePercent.rounded()), privacy: .public)%"
                )
            }
            // Persist follows the fine scan cadence and self-throttles the DB write
            // to the high-res interval; alert evaluation follows the table cadence.
            if scanDue {
                heavyTickCounter = 0
                persist(snapshot)
            }
            if tableDue {
                tableTickCounter = 0
                evaluateAlerts(snapshot)
            }
        }

        // Publish a snapshot with the fresh system/CPU and the latest process
        // list (carried unchanged between scans — a cheap array retain, no copy),
        // so menubar/dashboard system figures stay live at the fast rate.
        let snapshot = Sampler.Snapshot(
            system: system, processes: carriedProcesses,
            unreadableProcessCount: carriedUnreadable, cpu: cpu, battery: battery, network: network)
        let processes = carriedProcesses
        // In full mode the scan runs for the database even with every window and
        // popover closed — but the main-thread trail/menu/table rebuilds it used
        // to feed exist purely for UI. Skip them when nothing is consuming: an
        // opening surface registers its consumer and requests an immediate tick,
        // so its data is at most one tick away.
        let uiWantsProcesses = processConsumers > 0 || popoverOpen
        let didScan = runScan && uiWantsProcesses
        let didTable = runScan && tableDue && uiWantsProcesses
        // Which top lists to compute this tick: each open popover's kind at
        // 1 Hz, plus — on table-due ticks, when the scan already ran and four
        // sorts of ~600 rows are noise — every list. So the Network tab's
        // top-apps card updates at the table cadence (never the popover's
        // 1 Hz), and a popover reopened while anything keeps the scan alive is
        // at most one dial interval stale.
        var menuKinds = openPopoverKinds
        if didTable {
            menuKinds.formUnion(MenuListKind.allCases)
            if !perAppNetworkEnabled { menuKinds.remove(.network) }
        }
        // Trails freeze while nothing consumes the scan (full-mode recording
        // keeps running regardless); after a real gap the frozen points would
        // contaminate the smoothed-CPU rankings and sparklines, so drop them
        // instead of blending hour-old data with the fresh sample.
        var resetTrails = false
        if didScan {
            let scanNow = Date()
            if let last = lastUIScanAt,
                scanNow.timeIntervalSince(last) > max(3 * Double(heavyEveryTicks) * interval, 30)
            {
                resetTrails = true
            }
            lastUIScanAt = scanNow
            for kind in menuKinds { menuListRefreshedAt[kind] = scanNow }
        }
        let dropStaleTrails = resetTrails
        DispatchQueue.main.async {
            self.systemHistory.append(system)
            self.appendRecentCPU(cpu)
            self.appendRecentNetwork(network)
            self.recentBattery = battery
            // GPU is sampled only while the menubar GPU item is on; smooth it like
            // CPU so the icon figure settles, and drop the history when it goes off.
            if let gpu {
                self.recentGPUSamples.append(gpu)
                if self.recentGPUSamples.count > self.cpuSmoothingTicks {
                    self.recentGPUSamples.removeFirst(
                        self.recentGPUSamples.count - self.cpuSmoothingTicks)
                }
                self.gpuHistoryRing.append(gpu.utilization)
                if self.gpuHistoryRing.count > self.gpuHistoryLimit {
                    self.gpuHistoryRing.removeFirst(
                        self.gpuHistoryRing.count - self.gpuHistoryLimit)
                }
            } else if !self.recentGPUSamples.isEmpty {
                self.recentGPUSamples = []
                self.gpuHistoryRing = []
            }
            // Full-rate heartbeat: keeps the menu-bar icon live (it reads the
            // just-updated `smoothedCPU`) without re-rendering any SwiftUI view.
            self.liveTick.send()
            if didScan {
                // Trails + menu lists refresh on every scan → 1 Hz while a popover
                // is open, so its top-process list stays live.
                if dropStaleTrails { self.processTrails.removeAll() }
                self.updateTrails(with: processes)
                let smoothed = self.smoothedCPUMap(for: processes)
                self.refreshMenuLists(processes, smoothed: smoothed, kinds: menuKinds)
                // The in-window table re-renders only on the table cadence, so an
                // open popover never changes the main window's refresh rate.
                if didTable {
                    self.latest = snapshot
                    self.pruneTerminated()
                    self.rebuildDisplayProcesses(live: processes, smoothed: smoothed)
                }
            }
        }
    }

    /// Keep the trailing ~5 s of CPU samples for display smoothing.
    private func appendRecentCPU(_ cpu: CPUSample) {
        recentCPUSamples.append(cpu)
        if recentCPUSamples.count > cpuSmoothingTicks {
            recentCPUSamples.removeFirst(recentCPUSamples.count - cpuSmoothingTicks)
        }
    }

    /// Keep the trailing ~5 s of network samples for menubar read-out smoothing.
    /// Reuses the CPU smoothing window (same fast-tick cadence). A nil sample
    /// (interface list unreadable) is ignored rather than dropping the buffer.
    private func appendRecentNetwork(_ network: NetworkSample?) {
        guard let network else { return }
        recentNetworkSamples.append(network)
        if recentNetworkSamples.count > cpuSmoothingTicks {
            recentNetworkSamples.removeFirst(recentNetworkSamples.count - cpuSmoothingTicks)
        }
    }

    /// The most recent network sample (live session totals + primary interface),
    /// or nil until the first interface read lands.
    var latestNetwork: NetworkSample? { recentNetworkSamples.last }

    /// The freshest GPU sample (utilization, render/tiler, in-use memory, name), or
    /// nil when the GPU item is off or before the first read. Drives the popover.
    var latestGPU: GPUSample? { recentGPUSamples.last }

    /// GPU utilization (0–100) history for the panel's usage-history sparkline.
    var gpuUtilizationHistory: [Double] { gpuHistoryRing }

    /// GPU utilization (0–100) smoothed over the ~5 s window, so the menubar icon
    /// figure settles rather than jumping each tick. nil when GPU is off.
    var smoothedGPUUtilization: Double? {
        guard !recentGPUSamples.isEmpty else { return nil }
        return recentGPUSamples.reduce(0.0) { $0 + $1.utilization }
            / Double(recentGPUSamples.count)
    }

    /// The freshest system sample, appended every fast tick (~1 Hz). The published
    /// `latest` snapshot only refreshes on the slower heavy cadence, so menu-bar
    /// popovers that want a 1 Hz read-out (memory used, pressure) read this. O(1).
    var liveSystem: SystemSample? { systemHistory.last }

    /// The most recent battery sample, refreshed every fast tick (~1 Hz) — the
    /// battery analogue of `liveSystem`/`latestNetwork`, so the battery menubar
    /// read-outs stay live at 1 Hz instead of the slower heavy `latest` cadence.
    var latestBattery: BatterySample? { recentBattery }

    /// Download/upload throughput averaged over the trailing smoothing window
    /// (~5 s), so the menubar figures settle rather than flick on every tick. Nil
    /// until the first sample lands.
    var smoothedNetworkRates: (inBytesPerSec: Double, outBytesPerSec: Double)? {
        guard !recentNetworkSamples.isEmpty else { return nil }
        let n = Double(recentNetworkSamples.count)
        let inSum = recentNetworkSamples.reduce(0.0) { $0 + $1.inBytesPerSec }
        let outSum = recentNetworkSamples.reduce(0.0) { $0 + $1.outBytesPerSec }
        return (inSum / n, outSum / n)
    }

    /// The recent total-throughput trail (bytes/sec, most recent last), for the
    /// network menubar sparkline. Sums download + upload from the system history.
    func networkTrail() -> [Double] {
        systemHistory.elements().map { $0.networkInBytesPerSec + $0.networkOutBytesPerSec }
    }

    /// Recent download / upload trails (bytes/sec, most recent last), for the
    /// menubar up/down chart that shows both directions distinctly.
    func networkInTrail() -> [Double] {
        systemHistory.elements().map(\.networkInBytesPerSec)
    }
    func networkOutTrail() -> [Double] {
        systemHistory.elements().map(\.networkOutBytesPerSec)
    }

    /// Refresh the requested menubar top-process lists (called on every scan).
    /// Only the kinds a live surface is showing are computed — each list is an
    /// O(n log n) rank over ~600 processes, and at the popover's 1 Hz cadence
    /// computing all four for one open dropdown tripled the cost. The CPU list
    /// is ranked and shown by each process's ~5 s average CPU, so a momentary
    /// spike does not reshuffle the order or flick a figure between one and two
    /// digits. Runs on the main thread.
    private func refreshMenuLists(
        _ processes: [ProcessSample], smoothed: [ProcessIdentity: Double],
        kinds: Set<MenuListKind>
    ) {
        if kinds.contains(.footprint) {
            menuLists.update(
                .footprint, with: Ranking.topByFootprint(processes, limit: menuListLimit))
        }
        if kinds.contains(.cpu) {
            // Rank by smoothed CPU, then copy only the top few (avoid copying all
            // ~600 samples just to override one field).
            let smoothedCPUs = processes.map { smoothed[$0.id] ?? $0.cpuPercent }
            let topIndices = smoothedCPUs.indices
                .sorted { smoothedCPUs[$0] > smoothedCPUs[$1] }
                .prefix(menuListLimit)
            menuLists.update(
                .cpu,
                with: topIndices.map { i in
                    var copy = processes[i]
                    copy.cpuPercent = smoothedCPUs[i]
                    return copy
                })
        }
        if kinds.contains(.energy) {
            menuLists.update(
                .energy,
                with: Array(
                    processes.sorted { $0.energyImpact > $1.energyImpact }.prefix(menuListLimit)))
        }
        if kinds.contains(.network) {
            // Per-app network: only when the opt-in reader is feeding data. Skip
            // the sort entirely when nothing has any throughput so an idle network
            // does not surface a meaningless list of zeros.
            let netActive = processes.contains { $0.networkBytesPerSec > 0 }
            menuLists.update(
                .network,
                with: netActive
                    ? Array(
                        processes.sorted { $0.networkBytesPerSec > $1.networkBytesPerSec }
                            .prefix(menuListLimit))
                    : [])
        }
    }

    /// Rebuild the main table's process list: every live process with its CPU
    /// replaced by the ~5 s average (so the table's CPU column and CPU-sorted
    /// order settle), plus tombstones for recently force-quit processes. Runs on
    /// the main thread; called on the heavy cadence and whenever a kill lands.
    private func rebuildDisplayProcesses(
        live: [ProcessSample], smoothed: [ProcessIdentity: Double]? = nil
    ) {
        var result = live.map { process -> ProcessSample in
            var copy = process
            copy.cpuPercent =
                smoothed?[process.id]
                ?? smoothedProcessCPU(process.id, fallback: process.cpuPercent)
            return copy
        }
        if !terminatedProcesses.isEmpty {
            let liveIDs = Set(result.map(\.id))
            result += terminatedProcesses.values
                .filter { !liveIDs.contains($0.sample.id) }
                .map(\.sample)
        }
        displayProcesses = result
        displayProcessesVersion &+= 1
    }

    /// A process's mean CPU (percent of one core) over the smoothing window, from
    /// its in-memory trail; falls back to the live value when no trail exists yet.
    /// Sums the trailing window in place — no `.suffix().map()` temp arrays, which
    /// at ~600 processes per heavy tick was needless allocator churn.
    private func smoothedProcessCPU(_ identity: ProcessIdentity, fallback: Double) -> Double {
        guard let trail = processTrails[identity], !trail.isEmpty else { return fallback }
        let n = min(processSmoothingPoints, trail.count)
        var sum = 0.0
        for i in (trail.count - n)..<trail.count { sum += trail[i].cpuPercent }
        return sum / Double(n)
    }

    /// The smoothed CPU for every process in one pass, keyed by identity, so the
    /// heavy tick computes it once and shares it between the menu lists and the
    /// table rebuild instead of recomputing per process in each.
    private func smoothedCPUMap(for processes: [ProcessSample]) -> [ProcessIdentity: Double] {
        var map = [ProcessIdentity: Double](minimumCapacity: processes.count)
        for p in processes { map[p.id] = smoothedProcessCPU(p.id, fallback: p.cpuPercent) }
        return map
    }

    /// Run the alert engine over the full snapshot (all processes, so the
    /// per-process ceiling sees everything) and forward any newly-fired alerts
    /// to the main-thread sink. Runs on `queue`.
    private func evaluateAlerts(_ snapshot: Sampler.Snapshot) {
        let alerts = alertEngine.evaluate(
            system: snapshot.system,
            processes: snapshot.processes,
            leakingProcesses: leakingIDs,
            config: alertConfig,
            cpu: snapshot.cpu)
        let activeKinds = alertEngine.activeKinds
        let sink = onAlertsFired
        DispatchQueue.main.async { [weak self] in
            if self?.activeAlertKinds != activeKinds {
                self?.activeAlertKinds = activeKinds
            }
            if !alerts.isEmpty { sink(alerts) }
        }
    }

    /// Persist the system row plus the heavy-hitter (and tracked) process rows,
    /// and run periodic retention, all on `queue` so the UI thread never touches
    /// the database. Failures are logged, not fatal.
    private func persist(_ snapshot: Sampler.Snapshot) {
        guard persistenceEnabled, let store else { return }
        // Persist at most every `persistMinInterval`, decoupled from the table
        // cadence: at a 1 s table this writes ~every 2 s instead of every tick, so
        // a faster table does not multiply the ~600-row insert + WAL cost. The
        // live charts read the in-memory ring, not the DB, so they stay 1 Hz; only
        // the long-range history granularity follows this (≈2 s, imperceptible).
        let now = Date()
        let shouldPersist =
            lastPersistAt.map { now.timeIntervalSince($0) >= persistMinInterval } ?? true
        if shouldPersist {
            lastPersistAt = now
            do {
                // Change-gated write: the system row always lands (it keeps every
                // system timeline dense), but a process row is written only when
                // it moved or crosses into a new aggregate bucket. Idle daemons —
                // the ~94% of processes that are byte-identical second to second —
                // stop writing a row per second, which is what makes dense 1 s
                // logging affordable (insert −83%, roll-up + DB ~16× lighter). The
                // heartbeat bucket must equal retention's standard-res bucket so
                // every process still has a raw row in every minute bucket; the
                // time-weighted roll-up reconstructs correct averages from the
                // sparse rows. Any process the user later charts still resolves —
                // the chart connects its written points across the held gaps.
                try store.insertChanged(
                    snapshot.system, processes: snapshot.processes,
                    bucket: Self.configuredStandardResInterval())
            } catch {
                AppLog.sampler.error(
                    "sample insert failed: \(String(describing: error), privacy: .public)")
            }
        }
        ticksSinceCheckpoint += 1
        if ticksSinceCheckpoint >= checkpointEveryTicks {
            ticksSinceCheckpoint = 0
            // Off the tick path: TRUNCATE can wait briefly on active readers.
            maintenanceQueue.async { store.checkpoint() }
        }
        ticksSinceRetention += 1
        if ticksSinceRetention >= retentionEveryTicks, !retentionInFlight {
            ticksSinceRetention = 0
            retentionInFlight = true
            let policy = Self.retentionPolicy()
            // The identities alive right now — after the pass these are the only
            // id-cache entries kept (a live process's row can never be pruned,
            // so its cached id stays valid; see `pruneProcessIDCache`).
            let liveIDs = Set(snapshot.processes.map(\.id))
            maintenanceQueue.async { [weak self] in
                do {
                    try Retention.run(store.databasePool, policy: policy)
                } catch {
                    AppLog.sampler.error(
                        "retention failed: \(String(describing: error), privacy: .public)")
                }
                self?.queue.async {
                    guard let self else { return }
                    self.retentionInFlight = false
                    store.pruneProcessIDCache(keeping: liveIDs)
                    // Keep `last_seen` advancing for the processes the cache
                    // just kept — their upsert is skipped on every persist, and
                    // group membership filters on `last_seen`.
                    store.touchLastSeen(keeping: liveIDs)
                    // Refresh the set of leaking processes for the alert engine
                    // and the UI highlight — but only every few retention cycles,
                    // since the leak scan is the heaviest periodic work and leaks
                    // grow slowly.
                    if self.leakScanCountdown == 0 {
                        self.leakScanCountdown = self.leakScanEveryRetentions - 1
                        self.scheduleLeakScan(store)
                    } else {
                        self.leakScanCountdown -= 1
                    }
                }
            }
        }
    }

    /// Run the leak-board scan on its own queue, then fan the result out: the
    /// read cache lives on `readQueue`, the alert engine's leaking set on
    /// `queue`, and the published row highlight on main.
    private func scheduleLeakScan(_ store: SampleStore) {
        let generation = persistenceGeneration
        leakScanQueue.async { [weak self] in
            let entries = (try? store.leakBoard()) ?? []
            guard let self else { return }
            self.queue.async {
                guard generation == self.persistenceGeneration,
                    self.persistenceEnabled, self.store === store
                else { return }
                self.readQueue.async {
                    self.cachedLeakBoard = (Date(), entries)
                    self.cachedLeakSeries = nil
                }
                self.leakingIDs = Set(entries.map(\.identity))
                let published = self.leakingIDs
                DispatchQueue.main.async { self.leakingProcessIDs = published }
            }
        }
    }

    /// Append the latest sample for each live process and prune dead PIDs.
    /// Runs on the main thread alongside the `latest` publish. Mutates the
    /// trails in place (via the dictionary's modify accessor) rather than
    /// rebuilding the dictionary and copying every trail array: at ~600
    /// processes every 2 seconds the copy-on-write churn of the read-modify-
    /// store pattern was close to half a megabyte of allocations per tick.
    private func updateTrails(with processes: [ProcessSample]) {
        let present = Set(processes.map(\.id))
        let dead = processTrails.keys.filter { !present.contains($0) }
        for key in dead {
            processTrails.removeValue(forKey: key)
        }
        for process in processes where process.footprintReadable {
            processTrails[process.id, default: []].append(
                ProcessHistoryPoint(
                    date: process.timestamp,
                    footprint: process.physFootprint,
                    cpuPercent: process.cpuPercent,
                    fdTotal: Int(process.fdTotal),
                    diskRead: process.diskBytesRead,
                    diskWritten: process.diskBytesWritten,
                    networkBytesPerSec: process.networkBytesPerSec
                ))
            if let count = processTrails[process.id]?.count, count > trailLength {
                processTrails[process.id]?.removeFirst(count - trailLength)
            }
        }
    }

    /// Drop force-quit entries older than `terminatedRetention`, so the greyed
    /// "stopped" rows fade from the list a few minutes after the kill. Runs on
    /// the main thread alongside the `latest` publish.
    private func pruneTerminated(now: Date = Date()) {
        guard !terminatedProcesses.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-terminatedRetention)
        let countBefore = terminatedProcesses.count
        terminatedProcesses = terminatedProcesses.filter { $0.value.terminatedAt >= cutoff }
        if terminatedProcesses.count != countBefore {
            terminatedProcessIDs = Set(terminatedProcesses.keys)
        }
    }

    /// Top processes by footprint from the latest snapshot (readable only).
    func topByFootprint(limit: Int = 10) -> [ProcessSample] {
        guard let latest else { return [] }
        return Ranking.topByFootprint(latest.processes, limit: limit)
    }

    /// The latest system-wide CPU sample (total, per-core, P/E split), or nil
    /// until the first delta-bearing tick lands.
    var latestCPU: CPUSample? { latest?.cpu }

    /// CPU averaged over the trailing smoothing window (~5 s): total, per-core,
    /// and the P/E split. Used by the menubar read-out, the menubar icon, and the
    /// live core grids so they settle rather than flicker. Nil until the first
    /// sample lands. The dashboard CPU timeline deliberately uses raw history.
    var smoothedCPU: CPUSample? { Self.averaged(recentCPUSamples) }

    /// Per-field mean of a run of CPU samples, preserving the most recent core
    /// layout. Samples whose core count differs from the latest (e.g. the seed
    /// sample with no cores) are excluded from the per-core mean.
    private static func averaged(_ samples: [CPUSample]) -> CPUSample? {
        guard let last = samples.last else { return nil }
        let coreCount = last.cores.count
        let usable = coreCount > 0 ? samples.filter { $0.cores.count == coreCount } : []
        let base = usable.isEmpty ? samples : usable
        let n = Double(base.count)
        func mean(_ value: (CPUSample) -> Double) -> Double {
            base.reduce(0.0) { $0 + value($1) } / n
        }
        var cores = last.cores
        if !usable.isEmpty {
            let m = Double(usable.count)
            cores = (0..<coreCount).map { i in
                CoreUsage(
                    index: i,
                    kind: last.cores[i].kind,
                    usage: usable.reduce(0.0) { $0 + $1.cores[i].usage } / m,
                    user: usable.reduce(0.0) { $0 + $1.cores[i].user } / m,
                    system: usable.reduce(0.0) { $0 + $1.cores[i].system } / m)
            }
        }
        let total = mean { $0.totalUsage }
        return CPUSample(
            timestamp: last.timestamp,
            totalUsage: total,
            userFraction: mean { $0.userFraction },
            systemFraction: mean { $0.systemFraction },
            idleFraction: max(0, 1 - total),
            cores: cores,
            performanceUsage: mean { $0.performanceUsage },
            efficiencyUsage: mean { $0.efficiencyUsage },
            performanceCoreCount: last.performanceCoreCount,
            efficiencyCoreCount: last.efficiencyCoreCount,
            loadAverage1: last.loadAverage1,
            loadAverage5: last.loadAverage5,
            loadAverage15: last.loadAverage15)
    }

    /// Top processes by CPU percentage from the latest snapshot.
    func topByCPU(limit: Int = 10) -> [ProcessSample] {
        guard let latest else { return [] }
        return Ranking.topByCPU(latest.processes, limit: limit)
    }

    /// The recent total-CPU trail (0...100 percentages), for the menubar/dashboard
    /// CPU sparkline. Derived from the in-memory system history, which now carries
    /// the live total CPU on every tick.
    func cpuLoadTrail() -> [Double] {
        systemHistory.elements().map { $0.cpuLoad * 100 }
    }

    /// Recent battery-charge trail (0...100, most recent last), for the energy
    /// menubar charge line. Plotted on a fixed 0...100 scale so the slope reads
    /// as the charge-vs-drain rate.
    func batteryChargeTrail() -> [Double] {
        systemHistory.elements().map(\.batteryCharge)
    }

    /// Recent whole-machine power-draw trail (watts, most recent last), for the
    /// energy menubar power bars shown on desktops (which have no charge line).
    func systemPowerTrail() -> [Double] {
        systemHistory.elements().map(\.batterySystemPowerWatts)
    }

    /// The recent per-process CPU trail (percent of one core, most recent last),
    /// for the menubar CPU list sparklines.
    func cpuTrail(for identity: ProcessIdentity) -> [Double] {
        (processTrails[identity] ?? []).map(\.cpuPercent)
    }

    /// MacPerfMonitor's own footprint and CPU, read from the latest snapshot by pid —
    /// the app monitoring itself, which the performance budget calls for
    /// ("MacPerfMonitor must be able to monitor itself to prove it"). Nil until the
    /// first sample lands.
    var selfUsage: (footprint: UInt64, cpuPercent: Double)? {
        let me = getpid()
        guard let sample = latest?.processes.first(where: { $0.pid == me }) else { return nil }
        return (sample.physFootprint, sample.cpuPercent)
    }

    /// The recent footprint trail for a process, for the menubar sparklines.
    func trail(for identity: ProcessIdentity) -> [Double] {
        (processTrails[identity] ?? []).map { Double($0.footprint) }
    }

    /// The recent full-metric trail for a process, so the detail view can seed
    /// its charts before any persisted history has accrued.
    func trailSamples(for identity: ProcessIdentity) -> [ProcessHistoryPoint] {
        processTrails[identity] ?? []
    }

    /// The latest live sample for a process, if it is still running.
    func currentSample(for identity: ProcessIdentity) -> ProcessSample? {
        latest?.processes.first { $0.id == identity }
    }

    /// Record that the user force-quit a process, so the list keeps showing it
    /// greyed out for a few minutes as visible confirmation the kill took
    /// effect. Captures the last live sample (passed in by the caller, or looked
    /// up from the current snapshot) so the row can still be drawn once the
    /// process drops out of subsequent snapshots. Call on the main thread.
    func markTerminated(_ identity: ProcessIdentity, lastSample: ProcessSample? = nil) {
        guard let sample = lastSample ?? currentSample(for: identity) else { return }
        terminatedProcesses[identity] = TerminatedProcess(sample: sample, terminatedAt: Date())
        terminatedProcessIDs = Set(terminatedProcesses.keys)
        // Refresh the table at once so the killed row greys immediately rather
        // than waiting for the next heavy tick.
        rebuildDisplayProcesses(live: latest?.processes ?? [])
    }

    /// Whether on-disk history is available for the longer dashboard ranges.
    var hasHistory: Bool { store != nil }

    /// UserDefaults key for the user's database size cap, in megabytes. Shared
    /// with Settings. 0 or absent means use `defaultDatabaseMaxMB`.
    static let databaseMaxMBKey = "database.maxMB"
    /// Default database size cap when the user has not chosen one (1 GB), enough
    /// to comfortably hold the 7-day minute tier for a typical machine.
    static let defaultDatabaseMaxMB = 1000

    /// The retention policy for a maintenance pass: the fixed time windows plus
    /// the user's size cap read live from UserDefaults (safe off the main thread).
    private static func retentionPolicy() -> RetentionPolicy {
        var policy = RetentionPolicy.default
        let highAge = configuredHighResAge()
        // Additive: raw covers the recent high-res window; the minute tier covers
        // the whole detailed horizon (high age + standard age), overlapping raw for
        // the recent part; the hour tier stays fixed at 90 days.
        policy.rawWindow = highAge
        policy.minuteWindow = highAge + configuredStandardResAge()
        policy.standardResBucket = configuredStandardResInterval()
        policy.hourWindow = longTermAge
        let mb = UserDefaults.standard.integer(forKey: databaseMaxMBKey)
        let effectiveMB = mb > 0 ? mb : defaultDatabaseMaxMB
        // Decimal MB to match the Settings slider's label (which shows e.g.
        // "1.0 GB" for 1000). Enforcing binary MiB here put the real cap ~5% above
        // the labelled value, so a DB sitting just under the label never trimmed.
        policy.maxBytes = effectiveMB * 1_000_000
        return policy
    }

    /// The live retention windows the Analytics chart uses to pick which tier
    /// covers a visible span, matching what a maintenance pass would enforce.
    struct RetentionWindows: Sendable, Equatable {
        var highResInterval: TimeInterval
        var rawWindow: TimeInterval
        var standardResBucket: TimeInterval
        var minuteWindow: TimeInterval
        var hourWindow: TimeInterval
    }
    static func currentRetentionWindows() -> RetentionWindows {
        let highAge = configuredHighResAge()
        return RetentionWindows(
            highResInterval: configuredHighResInterval(),
            rawWindow: highAge,
            standardResBucket: configuredStandardResInterval(),
            minuteWindow: highAge + configuredStandardResAge(),
            hourWindow: longTermAge)
    }

    /// The database's current on-disk size in bytes, for the Settings read-out.
    /// Two PRAGMAs, but still a database read with no business on the main
    /// thread — delivered like every other loader.
    func loadDatabaseSize(completion: @escaping (Int?) -> Void) {
        guard let store else {
            completion(nil)
            return
        }
        readQueue.async {
            let bytes = store.approximateSizeBytes()
            DispatchQueue.main.async { completion(bytes) }
        }
    }

    /// The number of processes logged per high-res tick right now (the live
    /// snapshot's process count), for the Settings size projection. Falls back to a
    /// typical busy-machine count before the first sample lands.
    var loggedProcessCount: Int { latest?.processes.count ?? 600 }

    /// Project the total stored sample rows for a tier configuration: one system
    /// row plus `processCount` process rows per interval, across the raw tier (high
    /// age at high frequency), the additive minute tier (high + standard age at the
    /// standard bucket) and the fixed 90-day hour tier.
    static func projectedSampleRows(
        highInterval: Double, highAge: Double,
        standardInterval: Double, standardAge: Double,
        processCount: Int
    ) -> Int {
        let perTick = Double(1 + max(0, processCount))
        let procs = Double(max(0, processCount))
        // The raw tier is change-gated (SampleStore.insertChanged): a process
        // writes a raw row only when it changes plus one per-bucket heartbeat, so
        // it is NOT `procs × highAge/highInterval`. Project it as the (ungated)
        // system row every high-res tick, plus one heartbeat per process per
        // standard bucket, plus a conservative change fraction of the dense count.
        // ~6% of processes change per second in practice; 20% here so the size
        // cap errs toward caution rather than the ~16× over-count a dense
        // assumption gives, which needlessly shrank the retention windows. The
        // minute/hour tiers are one row per process per bucket regardless of
        // gating, so they are unchanged.
        let changeRate = 0.20
        let rawSystem = highAge / max(1, highInterval)
        let rawHeartbeat = procs * (highAge / max(1, standardInterval))
        let rawChange = procs * changeRate * (highAge / max(1, highInterval))
        let raw = rawSystem + rawHeartbeat + rawChange
        let minute = perTick * ((highAge + standardAge) / max(1, standardInterval))
        let hour = perTick * (longTermAge / 3600)
        return Int((raw + minute + hour).rounded())
    }

    /// Estimate on-disk bytes per stored sample row from the current database,
    /// capturing this machine's real index + free-page overhead. Falls back to a
    /// conservative default until the DB has enough rows to measure. Delivered on
    /// the main thread like the other loaders.
    func loadBytesPerRow(completion: @escaping (Double) -> Void) {
        guard let store else {
            completion(250)
            return
        }
        readQueue.async {
            let bytes = store.approximateSizeBytes()
            let stats = try? store.stats()
            let rows =
                stats.map {
                    $0.processSamples + $0.systemSamples + $0.processMinute + $0.processHour
                        + $0.systemMinute + $0.systemHour
                } ?? 0
            let perRow = rows > 1000 ? Double(bytes) / Double(rows) : 250
            DispatchQueue.main.async { completion(max(60, perRow)) }
        }
    }

    /// Load the system history for a dashboard range off the main thread, then
    /// deliver it back on the main thread. Reads are fast (indexed by time and
    /// point-bounded by granularity), so this stays well inside the budget.
    /// `downsampledTo` thins the series to at most that many chart points on the
    /// read queue, so the main thread receives a render-ready array instead of
    /// re-bucketing the full raw window itself on every refresh.
    func loadSystemHistory(
        _ window: HistoryWindow,
        downsampledTo maxPoints: Int? = nil,
        completion: @escaping ([SystemHistoryPoint]) -> Void
    ) {
        guard let store else {
            completion([])
            return
        }
        readQueue.async {
            var points = self.cachedSystemHistory(store, window: window)
            if let maxPoints {
                points = points.chartDownsampled(span: window.seconds, to: maxPoints)
            }
            DispatchQueue.main.async { completion(points) }
        }
    }

    /// `systemHistory` behind the short TTL: a new raw point lands only every
    /// `persistMinInterval`, so within the TTL the re-read is byte-identical.
    /// Must run on `readQueue` (the cache is confined to it).
    private func cachedSystemHistory(
        _ store: SampleStore, window: HistoryWindow
    ) -> [SystemHistoryPoint] {
        if let hit = cachedSystemHistory[window],
            Date().timeIntervalSince(hit.at) < systemHistoryMaxAge
        {
            return hit.points
        }
        let points = (try? store.systemHistory(window)) ?? []
        cachedSystemHistory[window] = (Date(), points)
        return points
    }

    /// Load the last two hours of raw system history (the Processes-tab header
    /// trend sparklines) off the main thread, then deliver it back on the main
    /// thread. The raw retention window is two hours, so this is the full raw
    /// span regardless of the dashboard's selected range.
    func loadRecentSystemHistory(
        seconds: TimeInterval = 2 * 3600,
        downsampledTo maxPoints: Int? = nil,
        completion: @escaping ([SystemHistoryPoint]) -> Void
    ) {
        guard let store else {
            completion([])
            return
        }
        readQueue.async {
            var points = self.cachedRecentSystemHistory(store, seconds: seconds)
            if let maxPoints {
                points = points.chartDownsampled(span: seconds, to: maxPoints)
            }
            DispatchQueue.main.async { completion(points) }
        }
    }

    /// `recentSystemHistory` behind the same short TTL, shared by the Processes
    /// header and the Insights bundle so the ~3,800-row scan runs once per TTL
    /// however many surfaces ask. Must run on `readQueue`.
    private func cachedRecentSystemHistory(
        _ store: SampleStore, seconds: TimeInterval
    ) -> [SystemHistoryPoint] {
        let key = Int(seconds)
        if let hit = cachedRecentSystemHistory[key],
            Date().timeIntervalSince(hit.at) < systemHistoryMaxAge
        {
            return hit.points
        }
        let points = (try? store.recentSystemHistory(seconds: seconds)) ?? []
        cachedRecentSystemHistory[key] = (Date(), points)
        return points
    }

    /// Load the raw per-process history for the detail view off the main thread,
    /// then deliver it back on the main thread.
    func loadProcessHistory(
        _ identity: ProcessIdentity,
        window: HistoryWindow,
        completion: @escaping ([ProcessHistoryPoint]) -> Void
    ) {
        guard let store else {
            completion([])
            return
        }
        readQueue.async {
            let points = (try? store.processHistory(for: identity, window: window)) ?? []
            DispatchQueue.main.async { completion(points) }
        }
    }

    /// Load only the per-process rows persisted since `after`, off the main
    /// thread, then deliver them on the main thread. The detail view appends
    /// these to the history it already holds, so the charts extend continuously
    /// each tick without re-reading the whole window or stitching in live data.
    func loadNewProcessHistory(
        _ identity: ProcessIdentity,
        after: Date,
        completion: @escaping ([ProcessHistoryPoint]) -> Void
    ) {
        guard let store else {
            completion([])
            return
        }
        readQueue.async {
            let points = (try? store.processHistory(for: identity, since: after)) ?? []
            DispatchQueue.main.async { completion(points) }
        }
    }

    /// Read the live list of open file descriptors for a process off the main
    /// thread, then deliver it on the main thread. This resolves each
    /// descriptor's path or socket endpoint (a syscall per descriptor), so it is
    /// on-demand only — driven by opening the detail inspector's file list, not
    /// the sampling path. Delivers nil on a hard read error; an empty array
    /// means either no descriptors or a process the user may not inspect.
    func loadOpenFiles(
        for identity: ProcessIdentity,
        completion: @escaping ([OpenFileDescriptor]?) -> Void
    ) {
        let pid = identity.pid
        readQueue.async {
            let fds = ProcessReader().openFileDescriptors(pid)
            DispatchQueue.main.async { completion(fds) }
        }
    }

    /// Load history for several processes at once (the Performance Monitor's
    /// multi-process overlay) off the main thread, then deliver it back on the
    /// main thread. One read transaction serves every selected process; 1h reads
    /// raw, the longer windows read the minute/hour aggregates so a week stays
    /// cheap.
    func loadProcessHistories(
        _ identities: [ProcessIdentity],
        window: HistoryWindow,
        completion: @escaping ([ProcessIdentity: [ProcessHistoryPoint]]) -> Void
    ) {
        guard let store, !identities.isEmpty else {
            completion([:])
            return
        }
        readQueue.async {
            let map = (try? store.processHistories(for: identities, window: window)) ?? [:]
            DispatchQueue.main.async { completion(map) }
        }
    }

    /// Load an arbitrary interval of per-process history at an explicit tier
    /// (the Monitor's zoom detail: a zoomed slice re-reads from the finest tier
    /// whose retention still covers it). Uncached — slices are ad hoc and the
    /// bounded reads are small.
    func loadProcessHistoriesSlice(
        _ identities: [ProcessIdentity],
        granularity: HistoryWindow.Granularity,
        from: Date,
        to: Date,
        completion: @escaping ([ProcessIdentity: [ProcessHistoryPoint]]) -> Void
    ) {
        guard let store, !identities.isEmpty else {
            completion([:])
            return
        }
        readQueue.async {
            let map =
                (try? store.processHistories(
                    for: identities, granularity: granularity, from: from, to: to)) ?? [:]
            DispatchQueue.main.async { completion(map) }
        }
    }

    func loadProcessHistoriesForExport(
        _ identities: [ProcessIdentity],
        granularity: HistoryWindow.Granularity,
        from: Date,
        to: Date,
        maximumPointCount: Int,
        isCancelled: @escaping @Sendable () -> Bool,
        completion:
            @escaping (
                Result<[ProcessIdentity: [ProcessHistoryPoint]], Error>
            ) -> Void
    ) {
        guard let store, !identities.isEmpty else {
            completion(.success([:]))
            return
        }
        exportReadQueue.async {
            let result = Result {
                try store.processHistories(
                    for: identities, granularity: granularity, from: from, to: to,
                    maximumPointCount: maximumPointCount, isCancelled: isCancelled)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The finest tier that actually has data covering `from…to`, so the Analytics
    /// chart can render a span at its true available resolution rather than the
    /// tier its fixed window would pick. Delivered on the main thread.
    func loadFinestGranularity(
        from: Date, to: Date,
        completion: @escaping (HistoryWindow.Granularity) -> Void
    ) {
        guard let store else {
            completion(.hour)
            return
        }
        readQueue.async {
            let g = (try? store.finestGranularityCovering(from: from, to: to)) ?? .hour
            DispatchQueue.main.async { completion(g) }
        }
    }

    // MARK: - History tab (M6)

    /// Load the top-consumers leaderboard for the History tab off the main
    /// thread, then deliver it back on the main thread.
    func loadTopConsumers(
        window: HistoryWindow,
        metric: ConsumerMetric,
        limit: Int = 20,
        completion: @escaping ([ProcessConsumer]) -> Void
    ) {
        guard let store else {
            completion([])
            return
        }
        readQueue.async {
            let rows = self.cachedTopConsumers(
                store, window: window, metric: metric, limit: limit)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Load the top energy users over the last `seconds` (a short, smoothing
    /// window) off the main thread, then deliver them on the main thread. Used by
    /// the Battery tab's flow diagram so its app branches track recent draw
    /// without the per-tick jitter of the raw live snapshot.
    func loadRecentEnergyConsumers(
        seconds: TimeInterval, limit: Int = 8,
        completion: @escaping ([ProcessConsumer]) -> Void
    ) {
        guard let store else {
            completion([])
            return
        }
        readQueue.async {
            let key = "\(Int(seconds))-\(limit)"
            if let hit = self.cachedEnergyConsumers[key],
                Date().timeIntervalSince(hit.at) < self.consumerMaxAge
            {
                DispatchQueue.main.async { completion(hit.rows) }
                return
            }
            let rows = (try? store.topEnergyConsumers(lastSeconds: seconds, limit: limit)) ?? []
            self.cachedEnergyConsumers[key] = (Date(), rows)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// `topConsumers` behind the short-TTL cache: returns a recent result for the
    /// same (window, metric, limit) when one exists, else runs the raw-tier scan
    /// and memoizes it. Must run on `readQueue` (the cache is confined to it).
    private func cachedTopConsumers(
        _ store: SampleStore, window: HistoryWindow, metric: ConsumerMetric, limit: Int
    ) -> [ProcessConsumer] {
        let key = ConsumerKey(window: window, metric: metric, limit: limit)
        if let hit = cachedConsumers[key], Date().timeIntervalSince(hit.at) < consumerMaxAge {
            return hit.rows
        }
        let rows = (try? store.topConsumers(window: window, metric: metric, limit: limit)) ?? []
        cachedConsumers[key] = (Date(), rows)
        return rows
    }

    // MARK: - Groups tab

    /// Load a process group's blended-footprint report off the main thread, then
    /// deliver it back on the main thread. The report carries the group's score
    /// (% of device capacity), its per-member contributions (which sum to the
    /// score), the combined timeline, and the summed energy aside. `glossary` is
    /// passed in (rather than read here) so the resolution stays a pure function
    /// of the caller's current glossary.
    func loadGroupReport(
        group: ProcessGroup,
        window: HistoryWindow,
        glossary: ProcessGlossary,
        weights: GroupFootprint.Weights = .default,
        completion: @escaping (GroupReport) -> Void
    ) {
        let device = Self.currentDevice()
        guard let store else {
            completion(GroupReport(device: device))
            return
        }
        readQueue.async {
            let report = self.cachedGroupReport(
                store, group: group, window: window, glossary: glossary, device: device,
                weights: weights)
            DispatchQueue.main.async { completion(report) }
        }
    }

    /// Load the Team IDs recorded on this machine for the rule editor's picker,
    /// each labelled by its signing organization (read from the certificate, the
    /// same source as the Codesign inspector) with a bundle-id / name fallback.
    /// All off the main thread (the certificate reads are a touch slow).
    func loadTeamIDDirectory(completion: @escaping ([TeamIDEntry]) -> Void) {
        guard let store else {
            completion([])
            return
        }
        readQueue.async {
            let seeds = (try? store.recordedTeamIDs()) ?? []
            // Only the seed query is database work. The SecStaticCode
            // certificate reads below run tens of ms per distinct team on a
            // cold cache — on the serial read queue they would head-of-line
            // block every chart/board load until the loop drains.
            DispatchQueue.global(qos: .userInitiated).async {
                let resolver = CodeSigningResolver.shared
                let entries =
                    seeds.map { seed -> TeamIDEntry in
                        let label =
                            resolver.organization(forExecutablePath: seed.executablePath)
                            ?? Self.vendorFromBundleID(seed.bundleID)
                            ?? ProcessSample.resolvedDisplayName(
                                name: seed.name, executablePath: seed.executablePath)
                        return TeamIDEntry(teamID: seed.teamID, label: label)
                    }
                    .sorted {
                        $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                    }
                DispatchQueue.main.async { completion(entries) }
            }
        }
    }

    /// "com.anthropic.claude-code" → "Anthropic": the reverse-DNS vendor segment,
    /// capitalised. A cheap fallback label when the signature org isn't available.
    private static func vendorFromBundleID(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let vendor = String(parts[1])
        guard !vendor.isEmpty else { return nil }
        return vendor.prefix(1).uppercased() + vendor.dropFirst()
    }

    /// The device's capacity constants. Logical-core count is fixed for the
    /// process; total RAM is read straight from `ProcessInfo`, so the figure is
    /// available even before the first system sample lands.
    static func currentDevice() -> GroupFootprint.Device {
        GroupFootprint.Device(
            cores: CPUTopology.current.logicalCores,
            totalRAM: ProcessInfo.processInfo.physicalMemory)
    }

    /// `buildGroupReport` behind the short-TTL cache. Must run on `readQueue`.
    private func cachedGroupReport(
        _ store: SampleStore, group: ProcessGroup, window: HistoryWindow,
        glossary: ProcessGlossary, device: GroupFootprint.Device, weights: GroupFootprint.Weights
    ) -> GroupReport {
        let key = GroupKey(id: group.id, window: window, rule: group.rule)
        if let hit = cachedGroupReports[key], Date().timeIntervalSince(hit.at) < consumerMaxAge {
            return hit.report
        }
        let report = Self.buildGroupReport(
            store, rule: group.rule, window: window, glossary: glossary, device: device,
            weights: weights)
        cachedGroupReports = cachedGroupReports.filter {
            $0.key.id != group.id || $0.key.window != window || $0.key == key
        }
        cachedGroupReports[key] = (Date(), report)
        return report
    }

    /// Release all arrays sourced from the history database. Confined to
    /// `readQueue`, like every cache it clears, and called when logging is
    /// disabled so menu-bar-only mode does not retain data it can no longer use.
    private func clearHistoryCaches() {
        cachedLeakBoard = nil
        cachedConsumers.removeAll(keepingCapacity: false)
        cachedEnergyConsumers.removeAll(keepingCapacity: false)
        cachedGroupReports.removeAll(keepingCapacity: false)
        cachedSystemHistory.removeAll(keepingCapacity: false)
        cachedRecentSystemHistory.removeAll(keepingCapacity: false)
        cachedPressureEvents = nil
        cachedLeakSeries = nil
        cachedConsumerSeries = nil
    }

    private static func buildGroupReport(
        _ store: SampleStore, rule: GroupRule, window: HistoryWindow,
        glossary: ProcessGlossary, device: GroupFootprint.Device, weights: GroupFootprint.Weights
    ) -> GroupReport {
        let ids =
            (try? store.groupMemberIDs(rule: rule, window: window, glossary: glossary)) ?? []
        let members = (try? store.groupMemberConsumers(processIDs: ids, window: window)) ?? []
        let series = (try? store.groupSeries(processIDs: ids, window: window)) ?? []
        let decomposition = GroupFootprint.decompose(
            consumers: members, device: device, weights: weights)
        let totalEnergy = members.reduce(0.0) { $0 + $1.averageEnergy }
        return GroupReport(
            device: device, decomposition: decomposition, members: members, series: series,
            totalEnergy: totalEnergy)
    }

    /// The cached leak board, recomputed only when stale. Must run on `readQueue`.
    private func currentLeakBoard(_ store: SampleStore) -> [LeakBoardEntry] {
        if let cached = cachedLeakBoard, Date().timeIntervalSince(cached.at) < leakBoardMaxAge {
            return cached.entries
        }
        let entries = (try? store.leakBoard()) ?? []
        cachedLeakBoard = (Date(), entries)
        return entries
    }

    /// Load the leak board off the main thread, then deliver it back on the main
    /// thread. Also republishes `leakingProcessIDs` so the suspected-leak
    /// highlight on the process table, menu bar, and Insights stays in lockstep
    /// with the board the dashboard shows, rather than waiting for the next
    /// (roughly per-minute) retention refresh. Without this, a fresh launch can
    /// show the dashboard leak card while none of the rows are flagged yet.
    func loadLeakBoard(completion: @escaping ([LeakBoardEntry]) -> Void) {
        guard let store else {
            completion([])
            return
        }
        readQueue.async {
            let rows = self.currentLeakBoard(store)
            let ids = Set(rows.map(\.identity))
            DispatchQueue.main.async {
                if self.leakingProcessIDs != ids {
                    self.leakingProcessIDs = ids
                }
                completion(rows)
            }
        }
    }

    /// Load the pressure-event list off the main thread, then deliver it back on
    /// the main thread.
    func loadPressureEvents(completion: @escaping ([PressureEvent]) -> Void) {
        guard let store else {
            completion([])
            return
        }
        readQueue.async {
            let events = self.cachedPressureEvents(store)
            DispatchQueue.main.async { completion(events) }
        }
    }

    /// `pressureEvents` behind its short TTL (the derivation scans the 2 h raw
    /// system window and probes the dominant process per level step). Must run
    /// on `readQueue`.
    private func cachedPressureEvents(_ store: SampleStore) -> [PressureEvent] {
        if let hit = cachedPressureEvents,
            Date().timeIntervalSince(hit.at) < pressureEventsMaxAge
        {
            return hit.events
        }
        // Pass the heartbeat bucket so the dominant-process carry-forward matches
        // how sparsely change-gated rows are written (see pressureEvents).
        let events =
            (try? store.pressureEvents(bucket: Self.configuredStandardResInterval())) ?? []
        cachedPressureEvents = (Date(), events)
        return events
    }

    /// Everything the Insights tab draws from one load: the ranked insight
    /// cards plus the raw findings and series behind them, gathered in a single
    /// queue hop so the page updates atomically.
    struct InsightsBundle {
        var insights: [InsightEngine.Insight] = []
        var leaks: [LeakBoardEntry] = []
        /// Raw footprint series per leaking process, for the evidence sparklines.
        var leakSeries: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
        var events: [PressureEvent] = []
        /// Raw system history over the last two hours, for the pressure timeline.
        var pressureHistory: [SystemHistoryPoint] = []
    }

    /// Load the Insights tab's bundle off the main thread, then deliver it back
    /// on the main thread. Runs the leak board, pressure events, system history,
    /// and step/attribution series reads in one queue hop and feeds them through
    /// `InsightEngine`. Republishes `leakingProcessIDs` just as `loadLeakBoard`
    /// does, so the leak highlight stays in lockstep everywhere. Call on the
    /// main thread (reads the live snapshot for the Rosetta cost).
    func loadInsightsBundle(completion: @escaping (InsightsBundle) -> Void) {
        guard let store else {
            completion(InsightsBundle())
            return
        }
        let system = latest?.system
        let cpu = latest?.cpu
        let rosetta = RosettaCost.compute(latest?.processes ?? [])
        readQueue.async {
            var bundle = InsightsBundle()
            bundle.leaks = self.currentLeakBoard(store)
            bundle.events = self.cachedPressureEvents(store)
            bundle.pressureHistory = self.cachedRecentSystemHistory(store, seconds: 2 * 3600)
            // Thinned for the evidence sparklines: a leak's growth shape needs
            // a couple of hundred points, not the raw 3,600-sample window. The
            // series is keyed to the leak board's timestamp — it only changes
            // when the board does, so per-tick reloads between board refreshes
            // reuse it instead of re-reading 2 h of raw rows per leak.
            let boardAt = self.cachedLeakBoard?.at ?? .distantPast
            if let hit = self.cachedLeakSeries, hit.boardAt == boardAt {
                bundle.leakSeries = hit.series
            } else {
                bundle.leakSeries =
                    ((try? store.processHistories(
                        for: bundle.leaks.map(\.identity), seconds: 2 * 3600)) ?? [:])
                    .mapValues { points in
                        let stride = Swift.max(1, points.count / 240)
                        return points.enumerated().compactMap {
                            $0.offset % stride == 0 ? $0.element : nil
                        }
                    }
                self.cachedLeakSeries = (boardAt, bundle.leakSeries)
            }

            // The heavy-memory and heavy-CPU insight cards rank the same one-hour
            // window by different metrics. Each `topConsumers` call scans the raw
            // tier, so aggregate the window once and slice both leaderboards in
            // memory rather than paying for two identical scans. A process can top
            // CPU without topping footprint, so the single read must be unranked
            // (the per-process aggregate row carries every metric).
            let windowConsumers = self.cachedTopConsumers(
                store, window: .oneHour, metric: .averageFootprint, limit: .max)
            let consumers = Array(
                windowConsumers.sorted { $0.averageFootprint > $1.averageFootprint }.prefix(8))
            // The 30-min evidence series for those consumers, on the consumer TTL:
            // between expiries the reload reuses the cached read for the same set.
            let consumerIdentities = consumers.map(\.identity)
            let consumerSeries: [ProcessIdentity: [(Date, UInt64)]]
            if let hit = self.cachedConsumerSeries, hit.identities == consumerIdentities,
                Date().timeIntervalSince(hit.at) < self.consumerMaxAge
            {
                consumerSeries = hit.series
            } else {
                let consumerHistories =
                    (try? store.processHistories(
                        for: consumerIdentities, seconds: 30 * 60)) ?? [:]
                consumerSeries = consumerHistories.mapValues { points in
                    points.map { ($0.date, $0.footprint) }
                }
                self.cachedConsumerSeries = (Date(), consumerIdentities, consumerSeries)
            }
            // Top CPU consumers over the last hour, for the heavy-CPU insight.
            let cpuConsumers = Array(
                windowConsumers.sorted { $0.averageCPU > $1.averageCPU }.prefix(5))
            // Top network consumers over the last hour, for the heavy-network
            // insight. All zero (and so inert) unless per-app tracking is on.
            let networkConsumers = Array(
                windowConsumers.sorted { $0.averageNetwork > $1.averageNetwork }.prefix(5))

            bundle.insights = InsightEngine.insights(
                InsightEngine.Inputs(
                    totalRAM: system?.totalRAM ?? 0,
                    currentPressure: system?.pressureLevel ?? .normal,
                    systemHistory: bundle.pressureHistory,
                    leaks: bundle.leaks,
                    events: bundle.events,
                    consumers: consumers,
                    consumerSeries: consumerSeries,
                    rosetta: rosetta,
                    cpu: cpu,
                    cpuConsumers: cpuConsumers,
                    networkConsumers: networkConsumers
                ))

            let ids = Set(bundle.leaks.map(\.identity))
            DispatchQueue.main.async {
                if self.leakingProcessIDs != ids {
                    self.leakingProcessIDs = ids
                }
                completion(bundle)
                FDWatchdog.check(after: "insights run")
            }
        }
    }

    /// The Rosetta cost from the live snapshot, with the translated processes
    /// sorted by footprint. Computed from `latest` (all ~600 processes, freshest
    /// data) rather than the persisted top-50 subset, since translated processes
    /// are often small and would be missed by a footprint-ranked subset.
    func rosettaSummary() -> (cost: RosettaCost, processes: [ProcessSample]) {
        let processes = latest?.processes ?? []
        let cost = RosettaCost.compute(processes)
        let translated =
            processes
            .filter { $0.isTranslated }
            .sorted { $0.physFootprint > $1.physFootprint }
        return (cost, translated)
    }
}
