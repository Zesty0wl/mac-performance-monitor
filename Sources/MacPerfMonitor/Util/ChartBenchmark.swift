import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

/// Offscreen, repeatable benchmark of the live chart pipeline.
///
/// Launch the app binary directly with `--benchmark-charts` and it renders the
/// Dashboard's live surfaces (the five Canvas timelines and the six metric
/// cards) for a synthetic window of samples, advancing the window one tick at
/// a time exactly as the live tab does, and reports the main-thread CPU cost of
/// each tick. No window is shown and the app exits when the run completes, so
/// it works headless (CI, an SSH session, a locked screen) and gives a number
/// that can be compared before and after a renderer change:
///
///     "build/Mac Performance Monitor.app/Contents/MacOS/Mac Performance Monitor" \
///         --benchmark-charts --scenario dashboard --points 14400 --span 3600 --ticks 40
///
/// Options (all optional):
///   --scenario  dashboard | trend | cards | menu | inspector | processes | dashboardPage
///               (default dashboard; processes is the whole Processes tab with
///               600 synthetic processes and the inspector open, so pass
///               --interval 1 to match its table cadence)
///   --points    samples in the window at the start      (default 3600)
///   --span      window length in seconds                (default 3600)
///   --interval  seconds between samples                 (default 0.25)
///   --ticks     ticks to measure after warm-up          (default 40)
///   --mode      image | host                            (default image)
///
/// `image` renders each tick through `ImageRenderer`, which exercises the full
/// Canvas drawing path deterministically. `host` drives an `NSHostingView` in an
/// ordered-out window through a published store, which also exercises the
/// SwiftUI update/diff path but may skip drawing while the window is occluded.
enum ChartBenchmark {
    /// Returns after the whole benchmark has run and printed (it never returns
    /// when the flag is absent it simply returns false immediately).
    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--benchmark-charts") else { return false }
        let options = Options(arguments: args)
        switch options.mode {
        case .image:
            ImageModeRunner(options: options).run()
        case .host:
            let runner = HostModeRunner(options: options)
            retainedRunner = runner
            runner.run()
        }
        return true
    }

    /// Keeps the host-mode runner alive across `NSApplication.run()`.
    @MainActor private static var retainedRunner: AnyObject?

    struct Options {
        enum Scenario: String {
            case dashboard, trend, cards, menu, inspector, processes, dashboardPage, gpuPage
            case hardwarePage, analyticsPage
        }
        enum Mode: String { case image, host }

        var scenario: Scenario = .dashboard
        var points = 3600
        var span: TimeInterval = 3600
        var interval: TimeInterval = 0.25
        var ticks = 40
        var mode: Mode = .image
        var width: CGFloat = 900
        /// `hardwarePage` only: the rendered page height, so a snapshot can
        /// include cards below the first screenful.
        var height: CGFloat = 1000
        /// Host mode only: write a PNG of the rendered window after the last
        /// tick, to eyeball what the AppKit surfaces actually drew.
        var snapshot: String?
        /// `dashboardPage` only: the range the page starts on (a `HistoryWindow`
        /// raw value, default one hour).
        var range: HistoryWindow = .oneHour
        /// `analyticsPage` only: how many synthetic processes are pinned to the
        /// Monitor selection, so the per-tick cost can be measured against the
        /// overlay count.
        var monitored = 3

        init(arguments: [String]) {
            func value(_ flag: String) -> String? {
                guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else {
                    return nil
                }
                return arguments[i + 1]
            }
            if let s = value("--scenario").flatMap(Scenario.init(rawValue:)) { scenario = s }
            if let p = value("--points").flatMap(Int.init) { points = p }
            if let s = value("--span").flatMap(Double.init) { span = s }
            if let i = value("--interval").flatMap(Double.init) { interval = i }
            if let t = value("--ticks").flatMap(Int.init) { ticks = t }
            if let m = value("--mode").flatMap(Mode.init(rawValue:)) { mode = m }
            if let w = value("--width").flatMap(Double.init) { width = CGFloat(w) }
            if let h = value("--height").flatMap(Double.init) { height = CGFloat(h) }
            snapshot = value("--snapshot")
            if let r = value("--range").flatMap(HistoryWindow.init(rawValue:)) { range = r }
            if let m = value("--monitored").flatMap(Int.init) { monitored = m }
        }
    }

    // MARK: - Synthetic data

    /// A deterministic pseudo-random series so runs are comparable.
    struct Generator {
        private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }

        mutating func point(at date: Date, index: Int) -> SystemHistoryPoint {
            let gb: UInt64 = 1_073_741_824
            let wave = 0.5 + 0.5 * sin(Double(index) / 180)
            let spike = next() < 0.01 ? 0.8 : 0
            return SystemHistoryPoint(
                date: date,
                pressurePercent: min(100, 25 + 40 * wave + 30 * spike),
                appMemory: UInt64(8 * Double(gb) + 2 * Double(gb) * wave),
                wired: 3 * gb,
                compressed: UInt64(Double(gb) * (0.5 + next() * 0.1)),
                cachedFiles: 4 * gb,
                swapUsed: UInt64(Double(gb) * 0.3 * wave),
                cpuLoad: min(1, 0.1 + 0.3 * wave + 0.6 * spike + next() * 0.05),
                networkInBytesPerSec: 2_000_000 * wave + 50_000_000 * spike,
                networkOutBytesPerSec: 300_000 * (1 - wave) + next() * 100_000,
                diskReadBytesPerSec: 5_000_000 * next() + 200_000_000 * spike,
                diskWriteBytesPerSec: 1_000_000 * next(),
                diskReadOperationsPerSec: 100 * next(),
                diskWriteOperationsPerSec: 40 * next(),
                gpuUtilization: min(100, 15 + 55 * wave + 80 * spike),
                gpuPowerWatts: 1.5 + 6 * wave + 10 * spike,
                anePowerWatts: spike > 0 ? 2.5 : 0.02)
        }
    }

    /// The live window exactly as the Dashboard keeps it: a columnar
    /// `SystemHistoryWindow` that gains the newest sample each tick.
    final class WindowStore: ObservableObject {
        @Published private(set) var version = 0
        private(set) var window: SystemHistoryWindow
        private(set) var memoryScale: MemoryCardScale?
        private(set) var networkYDomain: ClosedRange<Double> = 0...(10 * 1_048_576)
        private(set) var diskYDomain: ClosedRange<Double> = 0...(100 * 1_048_576)
        let span: TimeInterval
        let interval: TimeInterval
        private var generator = Generator()
        private var index = 0

        init(options: Options) {
            span = options.span
            interval = options.interval
            window = SystemHistoryWindow(span: options.span)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var seed: [SystemHistoryPoint] = []
            seed.reserveCapacity(options.points)
            for i in 0..<options.points {
                let date = now.addingTimeInterval(
                    -Double(options.points - 1 - i) * options.interval)
                seed.append(generator.point(at: date, index: i))
            }
            index = options.points
            window.replace(seed)
            memoryScale = MemoryMetrics.scale(window: window, total: 32 * 1_073_741_824)
            let networkPeak = max(
                window.peak(.networkInBytesPerSec) ?? 0, window.peak(.networkOutBytesPerSec) ?? 0)
            networkYDomain = 0...MenuChart.niceUpperBound(max(networkPeak * 1.25, 10 * 1_048_576))
            let diskPeak = max(
                window.peak(.diskReadBytesPerSec) ?? 0, window.peak(.diskWriteBytesPerSec) ?? 0)
            diskYDomain = 0...MenuChart.niceUpperBound(max(diskPeak * 1.25, 100 * 1_048_576))
        }

        var xDomain: ClosedRange<Date>? { window.xDomain }

        func tick() {
            let date = (window.latest?.date ?? Date()).addingTimeInterval(interval)
            window.append(generator.point(at: date, index: index))
            index += 1
            version &+= 1
        }
    }

    // MARK: - Scenario views

    /// The five Dashboard timelines plus the six metric cards, laid out at the
    /// Dashboard's sizes, fed from one window store.
    struct DashboardScenario: View {
        @ObservedObject var store: WindowStore
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                MetricCardsRow(
                    cards: MemoryMetrics.cards(
                        system: nil, window: store.window, scale: store.memoryScale),
                    xDomain: store.xDomain)
                PressureChart(
                    window: store.window, currentLevel: .normal, xDomain: store.xDomain,
                    showsTimeAxis: true
                )
                .frame(height: 180)
                CPUChart(
                    window: store.window, currentLevel: .light, xDomain: store.xDomain,
                    showsTimeAxis: true
                )
                .frame(height: 160)
                NetworkChart(
                    window: store.window, xDomain: store.xDomain,
                    yDomain: store.networkYDomain, showsTimeAxis: true
                )
                .frame(height: 150)
                DiskChart(
                    window: store.window, xDomain: store.xDomain, yDomain: store.diskYDomain,
                    showsTimeAxis: true
                )
                .frame(height: 150)
                SwapChart(
                    window: store.window, xDomain: store.xDomain,
                    yDomain: 0...(32 * 1_073_741_824)
                )
                .frame(height: 110)
            }
            .padding(20)
            .frame(width: width)
        }
    }

    struct TrendScenario: View {
        @ObservedObject var store: WindowStore
        let width: CGFloat

        var body: some View {
            PressureChart(
                window: store.window, currentLevel: .normal, xDomain: store.xDomain,
                showsTimeAxis: true
            )
            .frame(width: width - 40, height: 180)
            .padding(20)
        }
    }

    struct CardsScenario: View {
        @ObservedObject var store: WindowStore
        let width: CGFloat

        var body: some View {
            MetricCardsRow(
                cards: MemoryMetrics.cards(
                    system: nil, window: store.window, scale: store.memoryScale),
                xDomain: store.xDomain
            )
            .padding(20)
            .frame(width: width)
        }
    }

    struct MenuScenario: View {
        @ObservedObject var store: WindowStore
        let width: CGFloat

        var body: some View {
            let values = store.window.values(.cpuLoad).suffix(900).map { $0 * 100 }
            MenuTrendChart(
                values: values, sampleCapacity: 900, color: .green, domain: 0...100,
                ticks: [0, 50, 100], label: { "\(Int($0))" }
            )
            .frame(width: 380, height: MenuChart.height)
            .padding(12)
        }
    }

    /// The Processes inspector: five `MetricChart`s over the window's samples,
    /// as the detail pane shows for one process (normally at 1 Hz: pass
    /// `--interval 1`).
    struct InspectorScenario: View {
        @ObservedObject var store: WindowStore
        let width: CGFloat

        var body: some View {
            let times = store.window.timestamps
            func samples(_ column: SystemHistoryWindow.Column, scale: Double) -> [MetricSample] {
                let values = store.window.values(column)
                var out: [MetricSample] = []
                out.reserveCapacity(values.count)
                var ti = times.startIndex
                var vi = values.startIndex
                while ti < times.endIndex {
                    out.append(
                        MetricSample(
                            date: Date(timeIntervalSinceReferenceDate: times[ti]),
                            value: values[vi] * scale))
                    ti += 1
                    vi += 1
                }
                return out
            }
            return VStack(alignment: .leading, spacing: 16) {
                MetricChart(
                    samples: samples(.appMemory, scale: 1), tint: .blue, windowSeconds: store.span,
                    yFormat: { ByteFormat.string(UInt64(max($0, 0))) }
                )
                .equatable()
                .frame(height: 120)
                MetricChart(
                    samples: samples(.cpuLoad, scale: 100), tint: .green, minTop: 5,
                    windowSeconds: store.span, yFormat: { String(format: "%.0f%%", max($0, 0)) }
                )
                .equatable()
                .frame(height: 120)
                MetricChart(
                    samples: samples(.pressurePercent, scale: 10), tint: .purple, minTop: 10,
                    windowSeconds: store.span, yFormat: { String(format: "%.0f", max($0, 0)) }
                )
                .equatable()
                .frame(height: 120)
                MetricChart(
                    samples: samples(.diskReadBytesPerSec, scale: 1), tint: DiskStyle.read,
                    windowSeconds: store.span, yFormat: { ByteFormat.rate(max($0, 0)) }
                )
                .equatable()
                .frame(height: 120)
                MetricChart(
                    samples: samples(.diskWriteBytesPerSec, scale: 1), tint: DiskStyle.write,
                    windowSeconds: store.span, yFormat: { ByteFormat.rate(max($0, 0)) }
                )
                .equatable()
                .frame(height: 120)
            }
            .padding(16)
            .frame(width: min(width, 420))
        }
    }

    /// The Processes tab as the app mounts it: the processor header, the
    /// 600-row table, and the inspector for the first row, all fed by a real
    /// `SamplerModel` that a synthetic scan publishes into at each tick.
    struct ProcessesScenario: View {
        let store: ProcessScenarioStore
        let width: CGFloat
        @State private var selection: ProcessIdentity?

        var body: some View {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ProcessesHeader()
                    Divider()
                    ProcessesList(selection: $selection)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Group {
                    if let selection {
                        ProcessDetailView(identity: selection).id(selection)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 360)
                .padding(12)
            }
            .frame(width: width, height: 900)
            .onAppear { selection = store.firstIdentity }
            .environmentObject(store.model)
            .environment(\.samplerModel, store.model)
            .environmentObject(store.appState)
            .environmentObject(store.monitor)
            .environmentObject(store.groupStore)
            .environmentObject(store.helper)
            .environmentObject(store.appMode)
        }
    }

    /// Split out so they observe the model like `ProcessesTab` does.
    private struct ProcessesHeader: View {
        @EnvironmentObject private var model: SamplerModel
        var body: some View { SystemHeaderView(snapshot: model.latest) }
    }

    private struct ProcessesList: View {
        @EnvironmentObject private var model: SamplerModel
        @Binding var selection: ProcessIdentity?
        var body: some View {
            ProcessListView(processes: model.displayProcesses, selection: $selection)
        }
    }

    /// Drives the Processes scenario: a real model, real environment objects,
    /// and a deterministic synthetic scan of `processCount` processes whose
    /// figures move the way a live system's do (a tenth of them busy).
    @MainActor
    final class ProcessScenarioStore {
        let model: SamplerModel
        let appState = AppState()
        let monitor = MonitorSelection()
        let groupStore = ProcessGroupStore()
        let helper = HelperManager()
        let appMode = AppModeManager()
        private var generator = Generator()
        private var processes: [ProcessSample] = []
        private let base: Sampler.Snapshot
        private let interval: TimeInterval
        private let start = Date()
        private var tickIndex = 0

        init(options: Options) {
            interval = options.interval
            model = SamplerModel(interval: options.interval, persistenceEnabled: false)
            let sampler = Sampler()
            let (system, cpu, battery, network, disk, _) = sampler.tickSystem()
            base = Sampler.Snapshot(
                system: system, processes: [], unreadableProcessCount: 0, cpu: cpu,
                battery: battery, network: network, disk: disk)
            // Anchored to the wall clock: the pages mix sample dates with
            // Date() (trailing live windows, trimming), so a fixed epoch would
            // leave every synthetic sample outside the visible window. Tick i
            // lands at start + i×interval, in step with the host-mode timer.
            let start = self.start
            // The Dashboard page loads its window through the model; with no
            // store, hand it `--points` synthetic samples ending just before
            // the first tick so the charts start full.
            var seed: [SystemHistoryPoint] = []
            seed.reserveCapacity(options.points)
            for i in 0..<options.points {
                let date = start.addingTimeInterval(Double(i - options.points) * options.interval)
                seed.append(generator.point(at: date, index: i))
            }
            model.benchmarkSystemHistory = seed
            let count = max(50, min(options.points, 5000))
            for i in 0..<count {
                let gb = 1_073_741_824.0
                let gpuNames = [
                    "WindowServer", "ollama runner", "Google Chrome Helper (GPU)", "python3.12",
                    "VTDecoderXPCService", "Blender", "mediaanalysisd", "Final Cut Pro",
                ]
                processes.append(
                    ProcessSample(
                        timestamp: start, pid: Int32(100 + i),
                        ppid: i % 7 == 0 ? 1 : Int32(100 + i / 7),
                        name: i % 40 == 0 ? gpuNames[(i / 40) % gpuNames.count] : "process-\(i)",
                        executablePath: i % 3 == 0
                            ? "/Applications/App \(i).app/Contents/MacOS/app"
                            : "/usr/libexec/daemon-\(i)",
                        physFootprint: UInt64(generator.next() * 2 * gb) + 4_000_000,
                        residentSize: 10_000_000, virtualSize: 400_000_000,
                        lifetimeMaxFootprint: UInt64(2 * gb),
                        cpuPercent: 0, cpuTimeUser: 0, cpuTimeSystem: 0,
                        threadCount: Int32(2 + Int(generator.next() * 30)),
                        fdTotal: Int32(3 + Int(generator.next() * 200)), fdVnode: 1, fdSocket: 1,
                        fdPipe: 1, fdOther: 0,
                        diskBytesRead: 0, diskBytesWritten: 0,
                        isTranslated: i % 97 == 0, architecture: .arm64,
                        startTime: start.addingTimeInterval(-Double(i)), uid: 501,
                        dataSource: .directUserRead, footprintReadable: true))
            }
        }

        var firstIdentity: ProcessIdentity? { processes.first?.id }

        /// Pin `n` of the busy synthetic processes (every tenth one actually
        /// changes between ticks) to the Monitor selection, as a user would
        /// from the Analytics picker.
        func pinBusy(_ n: Int) {
            for i in stride(from: 0, to: processes.count, by: 10).prefix(n) {
                monitor.add(processes[i].id)
            }
        }

        /// Run `n` ticks backdated BEFORE the wall-clock start, so the trails
        /// are already full when a page mounts while the next live tick still
        /// lands at "now".
        func prewarm(_ n: Int) {
            tickIndex = -(n + 1)
            for _ in 0..<n { tick() }
        }

        func tick() {
            tickIndex += 1
            let now = start.addingTimeInterval(Double(tickIndex) * interval)
            for i in processes.indices {
                processes[i].timestamp = now
                // A tenth of the processes are busy: CPU wanders, footprint and
                // counters creep. The rest are byte-identical, as idle daemons are.
                guard i % 10 == 0 else { continue }
                // Every fortieth process holds a Metal context; every eightieth
                // is busy on the GPU, so the GPU page has a table to rank.
                if i % 40 == 0 {
                    let busy = i % 80 == 0
                    // max(0, …): prewarm ticks run at negative indices.
                    let nanos = UInt64(
                        max(0, Double(tickIndex)) * interval * (busy ? 0.35 : 0.002) * 1e9)
                    processes[i].gpuTimeNanos = nanos
                    processes[i].gpuPercent = busy ? 35 + generator.next() * 10 : 0.1
                    processes[i].gpuLastActive = busy ? now : now.addingTimeInterval(-600)
                }
                processes[i].cpuPercent = max(
                    0, processes[i].cpuPercent + (generator.next() - 0.5) * 8)
                processes[i].physFootprint =
                    processes[i].physFootprint &+ UInt64(generator.next() * 200_000)
                processes[i].diskBytesRead &+= UInt64(generator.next() * 1_000_000)
                processes[i].fdTotal = max(
                    1, processes[i].fdTotal + Int32(generator.next() * 3) - 1)
            }
            var snapshot = base
            snapshot.system.timestamp = now
            snapshot.cpu.timestamp = now
            snapshot.processes = processes
            // The table (and every model-observing leaf) follows the 1 s floor
            // in the app while the charts follow the dial; mirror that.
            let tableEvery = max(1, Int((1 / interval).rounded()))
            // A GPU sample per tick, so the GPU page's cards and device panel
            // have something to show.
            var gpu = GPUSample(
                utilization: 40 + 30 * sin(Double(tickIndex) / 20), renderUtilization: 38,
                tilerUtilization: 22, inUseMemoryBytes: 2_750_000_000, name: "Apple M3 Pro")
            gpu.allocatedMemoryBytes = 9_100_000_000
            gpu.coreCount = 14
            gpu.gpuPowerWatts = 2 + 4 * (gpu.utilization / 100)
            gpu.anePowerWatts = tickIndex % 40 < 20 ? 1.8 : 0
            gpu.cpuPowerWatts = 3.1
            gpu.activeResidency = 90
            gpu.performanceStates = [
                GPUPerformanceState(name: "P1", residency: 38),
                GPUPerformanceState(name: "P2", residency: 45),
                GPUPerformanceState(name: "P3", residency: 7),
            ]
            gpu.throttled = false
            gpu.powerCapPercent = 100
            gpu.recoveryCount = 0
            gpu.dieTemperatureC = 61
            gpu.fanRPM = 0
            model.publishForBenchmark(snapshot, table: tickIndex % tableEvery == 0, gpu: gpu)
        }
    }

    /// The real `DashboardView`, fed by the same model publish as the
    /// Processes scenario (which also sends the live tick the charts follow).
    struct DashboardPageScenario: View {
        let store: ProcessScenarioStore
        let width: CGFloat
        var range: HistoryWindow = .oneHour

        var body: some View {
            DashboardView(initialRange: range)
                .frame(width: width, height: 1000)
                .environmentObject(store.model)
                .environment(\.samplerModel, store.model)
                .environmentObject(store.appState)
                .environmentObject(store.monitor)
                .environmentObject(store.groupStore)
                .environmentObject(store.helper)
                .environmentObject(store.appMode)
        }
    }

    /// The real GPU tab, mounted like `DashboardPageScenario`.
    struct GPUPageScenario: View {
        let store: ProcessScenarioStore
        let width: CGFloat

        var body: some View {
            GPUView()
                .frame(width: width, height: 1100)
                .environmentObject(store.model)
                .environment(\.samplerModel, store.model)
                .environmentObject(store.appState)
                .environmentObject(store.monitor)
                .environmentObject(store.groupStore)
                .environmentObject(store.helper)
                .environmentObject(store.appMode)
        }
    }

    /// A scenario's view plus the closure that advances it one tick.
    struct Scenario {
        let view: AnyView
        let tick: () -> Void
    }

    @MainActor
    static func makeScenario(_ options: Options) -> Scenario {
        if options.scenario == .hardwarePage {
            // The real inventory, read once on appearance; the tick only
            // applies an optional selection and search once it has landed, so
            // a snapshot can show a detail page or a search result. The page
            // needs the app's environment objects (the sensors card seeds and
            // sweeps through the sampler model), served by a store that never
            // persists.
            let store = ProcessScenarioStore(options: options)
            let view = AnyView(
                HardwarePageScenario(width: options.width, height: options.height)
                    .environmentObject(store.model)
                    .environment(\.samplerModel, store.model)
                    .environmentObject(store.appState)
                    .environmentObject(store.monitor)
                    .environmentObject(store.groupStore)
                    .environmentObject(store.helper)
                    .environmentObject(store.appMode))
            let environment = ProcessInfo.processInfo.environment
            return Scenario(
                view: view,
                tick: {
                    let model = HardwareExplorerModel.shared
                    guard model.capturedAt != nil else { return }
                    if let select = environment["MPM_HARDWARE_SELECT"], model.selectedID != select {
                        model.selectedID = select
                    }
                    if let query = environment["MPM_HARDWARE_QUERY"], model.query != query {
                        model.query = query
                    }
                    // MPM_HARDWARE_SOC=ultra previews the overview with the
                    // largest chip Apple ships, to check the diagram scales.
                    if environment["MPM_HARDWARE_SOC"] == "ultra", model.previewFacts == nil {
                        var facts = HardwareFacts()
                        facts.chipName = "Apple M3 Ultra"
                        facts.performanceCores = 24
                        facts.efficiencyCores = 8
                        facts.gpuCores = 80
                        facts.neuralEngineCores = 32
                        facts.memoryBytes = 512 << 30
                        facts.memoryType = "LPDDR5, Micron"
                        model.previewFacts = facts
                    }
                })
        }
        if options.scenario == .processes || options.scenario == .dashboardPage
            || options.scenario == .gpuPage || options.scenario == .analyticsPage
        {
            let store = ProcessScenarioStore(options: options)
            let view: AnyView
            switch options.scenario {
            case .processes:
                view = AnyView(ProcessesScenario(store: store, width: options.width))
            case .gpuPage:
                view = AnyView(GPUPageScenario(store: store, width: options.width))
            case .analyticsPage:
                store.pinBusy(options.monitored)
                // Fill the per-process trails to capacity before mounting, so
                // the live charts measure with full series from the first tick.
                store.prewarm(SamplerModel.processTrailCapacity + 5)
                view = AnyView(AnalyticsPageScenario(store: store, width: options.width))
            default:
                view = AnyView(
                    DashboardPageScenario(
                        store: store, width: options.width, range: options.range))
            }
            return Scenario(view: view, tick: { store.tick() })
        }
        let store = WindowStore(options: options)
        return Scenario(view: scenarioView(options, store: store), tick: { store.tick() })
    }

    @MainActor
    static func scenarioView(_ options: Options, store: WindowStore) -> AnyView {
        switch options.scenario {
        case .dashboard: return AnyView(DashboardScenario(store: store, width: options.width))
        case .trend: return AnyView(TrendScenario(store: store, width: options.width))
        case .cards: return AnyView(CardsScenario(store: store, width: options.width))
        case .menu: return AnyView(MenuScenario(store: store, width: options.width))
        case .inspector: return AnyView(InspectorScenario(store: store, width: options.width))
        case .processes, .dashboardPage, .gpuPage, .hardwarePage, .analyticsPage:
            return AnyView(EmptyView())
        }
    }

    /// The Analytics tab (the Performance Monitor grid) with synthetic
    /// processes pinned, fed by the same store as the Processes scenario, to
    /// measure the per-tick cost of the overlaid charts against the number of
    /// monitored processes.
    struct AnalyticsPageScenario: View {
        let store: ProcessScenarioStore
        let width: CGFloat
        var body: some View {
            PerformanceMonitorView(onImport: { _ in })
                .frame(width: width, height: 900)
                .environmentObject(store.model)
                .environment(\.samplerModel, store.model)
                .environmentObject(store.appState)
                .environmentObject(store.monitor)
                .environmentObject(store.groupStore)
                .environmentObject(store.helper)
                .environmentObject(store.appMode)
        }
    }

    /// The Hardware tab at a fixed width, for snapshots of the real inventory.
    struct HardwarePageScenario: View {
        let width: CGFloat
        let height: CGFloat
        var body: some View {
            HardwareView()
                .frame(width: width, height: height)
        }
    }

    // MARK: - Measurement

    static func threadCPUNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    struct Stats {
        var samples: [Double] = []
        mutating func add(_ ms: Double) { samples.append(ms) }
        var mean: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }
        var median: Double {
            guard !samples.isEmpty else { return 0 }
            let s = samples.sorted()
            return s[s.count / 2]
        }
        var max: Double { samples.max() ?? 0 }
    }

    static func report(_ label: String, options: Options, stats: Stats, extra: String = "") {
        let hz = 1 / options.interval
        let cpuPercent = stats.mean * hz / 10
        print(
            String(
                format:
                    "%@ scenario=%@ points=%d span=%.0fs interval=%.3fs ticks=%d | "
                    + "ms/tick mean=%.2f median=%.2f max=%.2f | ~%.1f%% CPU at %.0f Hz%@",
                label, options.scenario.rawValue, options.points, options.span, options.interval,
                stats.samples.count, stats.mean, stats.median, stats.max, cpuPercent, hz, extra))
    }

    // MARK: - ImageRenderer mode

    @MainActor
    final class ImageModeRunner {
        let options: Options
        init(options: Options) { self.options = options }

        func run() {
            // AppKit text rendering wants an application context even offscreen.
            _ = NSApplication.shared
            let scenario = makeScenario(options)
            let renderer = ImageRenderer(content: scenario.view)
            renderer.scale = 2
            var pixelWidth = 0
            // Warm up: font caches, first layout, and so on.
            for _ in 0..<3 {
                scenario.tick()
                renderer.content = scenario.view
                pixelWidth = renderer.cgImage?.width ?? 0
            }
            var stats = Stats()
            var renderOnly = Stats()
            for _ in 0..<options.ticks {
                let start = threadCPUNanos()
                scenario.tick()
                let afterTick = threadCPUNanos()
                renderer.content = scenario.view
                _ = renderer.cgImage
                let end = threadCPUNanos()
                stats.add(Double(end - start) / 1e6)
                renderOnly.add(Double(end - afterTick) / 1e6)
            }
            report(
                "[image]", options: options, stats: stats,
                extra: String(
                    format: " (render-only mean %.2f ms, image width %d px)", renderOnly.mean,
                    pixelWidth))
        }
    }

    // MARK: - NSHostingView mode

    @MainActor
    final class HostModeRunner {
        let options: Options
        private var window: NSWindow?
        private var scenarioTick: (() -> Void)?
        private var timer: Timer?
        private var remaining = 0
        private var stats = Stats()
        private var lastCPU: UInt64 = 0
        private var warmupLeft = 4

        init(options: Options) { self.options = options }

        func run() {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let scenario = makeScenario(options)
            scenarioTick = scenario.tick
            let host = NSHostingView(rootView: scenario.view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: options.width, height: 1000),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.alphaValue = 0
            window.orderFrontRegardless()
            self.window = window
            host.layoutSubtreeIfNeeded()
            remaining = options.ticks
            timer = Timer.scheduledTimer(withTimeInterval: options.interval, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            app.run()
        }

        private func tick() {
            // CPU consumed by the main thread since the previous tick fired: the
            // store update, SwiftUI's transaction, layout, and the CA commit.
            let now = threadCPUNanos()
            if warmupLeft > 0 {
                warmupLeft -= 1
            } else if lastCPU > 0 {
                stats.add(Double(now - lastCPU) / 1e6)
                remaining -= 1
            }
            lastCPU = now
            if remaining <= 0 {
                timer?.invalidate()
                report("[host]", options: options, stats: stats)
                if let path = options.snapshot, let host = window?.contentView {
                    Self.writeSnapshot(of: host, to: path)
                }
                exit(0)
            }
            if Self.layerDebug, remaining == options.ticks - 3 { Self.installDisplayLogging() }
            if Self.layerDebug, remaining == options.ticks - 6 { CALayer.displayLogEnabled = false }
            scenarioTick?()
            if Self.layerDebug, remaining == options.ticks - 2,
                let root = window?.contentView?.layer
            {
                print("layers needing display after tick:")
                Self.dumpDirtyLayers(root, depth: 0)
            }
        }

        static let layerDebug = ProcessInfo.processInfo.environment["MPM_LAYERDEBUG"] == "1"

        /// Diagnostic only: log every layer Core Animation displays, so the
        /// one repainting on a tick can be named. Swizzles `-[CALayer display]`
        /// in this process for the run.
        static func installDisplayLogging() {
            guard let original = class_getInstanceMethod(CALayer.self, #selector(CALayer.display)),
                let replacement = class_getInstanceMethod(
                    CALayer.self, #selector(CALayer.loggedDisplay))
            else { return }
            method_exchangeImplementations(original, replacement)
        }

        /// List every layer marked for display, with what draws it, to find out
        /// who repaints on a tick.
        private static func dumpDirtyLayers(_ layer: CALayer, depth: Int) {
            if layer.needsDisplay() {
                let delegate = layer.delegate.map { String(describing: type(of: $0)) } ?? "nil"
                let contents = layer.contents.map { String(describing: type(of: $0)) } ?? "nil"
                print(
                    "  \(String(repeating: " ", count: depth))\(type(of: layer)) bounds=\(layer.bounds) "
                        + "format=\(layer.contentsFormat.rawValue) delegate=\(delegate) "
                        + "contents=\(contents) name=\(layer.name ?? "")")
            }
            for sub in layer.sublayers ?? [] { dumpDirtyLayers(sub, depth: depth + 1) }
        }

        /// Render the window's layer tree (SwiftUI layers and the AppKit
        /// surfaces' sublayers alike) at 2x into a PNG.
        private static func writeSnapshot(of host: NSView, to path: String) {
            CATransaction.flush()
            host.displayIfNeeded()
            let scale: CGFloat = 2
            let size = host.bounds.size
            guard size.width > 0, size.height > 0,
                let ctx = CGContext(
                    data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // The hosting view's layer tree is flipped; render it upright.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            host.layer?.render(in: ctx)
            guard let image = ctx.makeImage() else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            do {
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
                print("snapshot written to \(path)")
            } catch {
                print("snapshot failed: \(error)")
            }
        }
    }
}

extension CALayer {
    static var displayLogEnabled = true

    @objc fileprivate func loggedDisplay() {
        if Self.displayLogEnabled {
            let delegate = self.delegate.map { String(describing: type(of: $0)) } ?? "nil"
            var ancestors: [String] = []
            var root: CALayer = self
            var cursor = superlayer
            while let layer = cursor {
                if let name = layer.name, !name.isEmpty { ancestors.append(name) }
                root = layer
                cursor = layer.superlayer
            }
            let inRoot = convert(bounds, to: root)
            print(
                "display: \(type(of: self)) \(Int(bounds.width))x\(Int(bounds.height)) "
                    + "at=(\(Int(inRoot.minX)),\(Int(inRoot.minY))) format=\(contentsFormat.rawValue) "
                    + "delegate=\(delegate) name=\(name ?? "") under=\(ancestors.prefix(3).joined(separator: " < "))"
            )
        }
        loggedDisplay()
    }
}
