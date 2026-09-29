import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

struct ExplorerLane: Identifiable {
    let definition: ExplorerLaneDefinition
    let feed: TrendFeed
    var id: String { definition.id }
}

struct ExplorerReading {
    var value: Double?
    var minimum: Double?
    var maximum: Double?
    var observedAt: Date?
    var sourceDuration: Double
}

@MainActor
final class DataExplorerModel: ObservableObject {
    static let spanDefaultsKey = "historyRange.explorerSeconds"

    @Published private(set) var domain: ClosedRange<Date>
    @Published private(set) var followsLive = true
    @Published private(set) var loading = false
    @Published private(set) var preparing = false
    @Published private(set) var error: String?
    @Published private(set) var searchResults: [ExplorerProcess] = []
    @Published private(set) var observations: [ExplorerProcessObservation] = []
    @Published private(set) var observationTime: Date?
    @Published private(set) var machineRecord: ExplorerMachineRecord?
    @Published private(set) var inspecting = false
    @Published private(set) var lanes: [ExplorerLane] = []
    @Published private(set) var enabled = ExplorerMetrics.defaultIDs
    @Published private(set) var selectedProcesses: [ExplorerProcess] = []
    @Published private(set) var loadedAt: Date?
    @Published private(set) var sourceTier: HistoryWindow.Granularity = .raw
    @Published private(set) var alertEvidence: [MacPerfMonitorCore.Alert] = []
    @Published var sourceQuery = ""
    @Published var processQuery = ""
    @Published var selectedLaneID = "cpu"
    @Published var focusedLaneID: String?
    @Published var showsInspector = true
    /// Lanes drawn to their tallest spike rather than fitted to the rest.
    @Published private(set) var fullScaleLaneIDs: Set<String> = []
    let cursor = ExplorerCursor()

    private(set) var system: [SystemHistoryPoint] = []
    private(set) var histories: [ExplorerProcessHistory] = []
    private var feeds: [String: TrendFeed] = [:]
    private weak var sampler: SamplerModel?
    private var identities: [ProcessIdentity] = []
    private var generation = 0
    private var searchGeneration = 0
    private var observationGeneration = 0
    private var active = false
    private var lastTick = Date.distantPast
    private var lastRefresh = Date.distantPast
    private var searchTask: DispatchWorkItem?
    private var scrollZoomTask: DispatchWorkItem?
    private var colors: [ProcessIdentity: Int] = [:]
    private let preparationQueue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.explorer.charts", qos: .userInitiated)
    private var preparation: DispatchWorkItem?
    private var preparationGeneration = 0
    private var needsChartReplacement = false
    private var publishedFullScale: Set<String> = []
    private var tailInFlight = false
    private let preferences: UserDefaults?

    init(now: Date = Date(), preferences: UserDefaults? = nil) {
        self.preferences = preferences
        let saved = preferences?.double(forKey: Self.spanDefaultsKey) ?? 0
        let duration =
            saved.isFinite && (20...90 * 86_400).contains(saved)
            ? saved : HistoryWindow.thirtyMinutes.seconds
        domain = now.addingTimeInterval(-duration)...now
    }

    var span: TimeInterval { domain.upperBound.timeIntervalSince(domain.lowerBound) }
    var hasHistory: Bool { sampler?.hasHistory ?? !system.isEmpty }
    var usesRecordedHistory: Bool {
        hasHistory && AppComponentsManager.loggingEnabledFromDefaults()
    }
    var definitions: [ExplorerLaneDefinition] { ExplorerMetrics.all }

    func start(sampler: SamplerModel?, identities: [ProcessIdentity]) {
        self.sampler = sampler
        active = true
        setSelection(identities, reload: false)
        if followsLive { moveLiveEdge(Date()) }
        refresh()
        search()
        if cursor.pinned, let date = cursor.date { inspect(date) }
    }

    func investigate(_ request: AlertInvestigation) {
        guard request.isValid else { return }
        followsLive = false
        let end = min(Date(), request.end)
        domain = min(request.start, end.addingTimeInterval(-20))...end
        alertEvidence = request.records ?? []
        focusedLaneID = nil
        showsInspector = true
        enabled = ExplorerMetrics.defaultIDs.union(["memory", "swap"])
        if request.kinds.contains(.swap) {
            selectedLaneID = "swap"
        } else if request.kinds.contains(.leak) || request.kinds.contains(.processCeiling) {
            selectedLaneID = "process.footprint"
        } else if request.kinds.contains(.thermalThrottle) {
            selectedLaneID = "thermalState"
            enabled.insert("thermalState")
        } else if request.kinds.contains(.highGPU) {
            selectedLaneID = "gpu"
            enabled.insert("gpu")
        } else if request.kinds.contains(.highCPU) {
            selectedLaneID = "cpu"
        } else {
            selectedLaneID = "pressure"
        }
        setSelection(request.identities, reload: false)
        cursor.pin(min(request.time, end))
        refresh()
        search()
        inspect(min(request.time, end))
    }

    func stop() {
        active = false
        generation += 1
        searchGeneration += 1
        observationGeneration += 1
        loading = false
        inspecting = false
        searchTask?.cancel()
        scrollZoomTask?.cancel()
        preparation?.cancel()
        preparationGeneration += 1
        preparing = false
        tailInFlight = false
    }

    func setSelection(_ selected: [ProcessIdentity], reload: Bool = true) {
        guard identities != selected else { return }
        identities = Array(selected.prefix(8))
        for identity in identities where colors[identity] == nil {
            let used = Set(identities.compactMap { colors[$0] })
            colors[identity] = (0..<8).first { !used.contains($0) } ?? colors.count % 8
        }
        colors = colors.filter { identities.contains($0.key) }
        let current = sampler?.displayProcesses ?? []
        for identity in identities where !selectedProcesses.contains(where: { $0.id == identity }) {
            if let process = current.first(where: { $0.id == identity }) {
                selectedProcesses.append(ExplorerProcess(sample: process))
            } else if let process = searchResults.first(where: { $0.id == identity }) {
                selectedProcesses.append(process)
            }
        }
        selectedProcesses.removeAll { !identities.contains($0.id) }
        if reload { refresh() }
    }

    func toggleLane(_ id: String) {
        if enabled.contains(id) { enabled.remove(id) } else { enabled.insert(id) }
        rebuild(replacing: true)
    }

    func preset(_ group: ExplorerSourceGroup?) {
        enabled =
            group.map { group in Set(definitions.filter { $0.group == group }.map(\.id)) }
            ?? ExplorerMetrics.defaultIDs
        focusedLaneID = nil
        rebuild(replacing: true)
    }

    func chooseWindow(_ window: HistoryWindow) {
        alertEvidence = []
        let end = followsLive ? Date() : domain.upperBound
        domain = end.addingTimeInterval(-window.seconds)...end
        preferences?.set(window.seconds, forKey: Self.spanDefaultsKey)
        cursor.clear()
        clearObservation()
        refresh()
        search()
    }

    func showTime(_ date: Date) {
        alertEvidence = []
        followsLive = false
        let duration = span
        let end = min(Date(), date.addingTimeInterval(duration / 2))
        domain = end.addingTimeInterval(-duration)...end
        cursor.pin(date)
        refresh()
        search()
        inspect(date)
    }

    func pan(_ direction: Double) {
        alertEvidence = []
        followsLive = false
        let duration = span
        let end = min(Date(), domain.upperBound.addingTimeInterval(duration * direction))
        domain = end.addingTimeInterval(-duration)...end
        cursor.clear()
        clearObservation()
        refresh()
        search()
    }

    func zoom(_ factor: Double, anchorFraction: Double? = nil) {
        guard factor.isFinite, factor > 0, anchorFraction?.isFinite ?? true else { return }
        followsLive = false
        let fraction = min(max(anchorFraction ?? 0.5, 0), 1)
        let anchor =
            anchorFraction == nil
            ? (cursor.date ?? domain.lowerBound.addingTimeInterval(span / 2))
            : domain.lowerBound.addingTimeInterval(span * fraction)
        let resolution = max(
            system.map(\.bucketDuration).max() ?? 0,
            histories.flatMap(\.points).map(\.duration).max() ?? 0)
        let duration = min(90 * 86_400, max(20, resolution, span * factor))
        let end = min(Date(), anchor.addingTimeInterval(duration * (1 - fraction)))
        domain = end.addingTimeInterval(-duration)...end
        preferences?.set(duration, forKey: Self.spanDefaultsKey)
        if anchorFraction != nil {
            generation += 1
            preparationGeneration += 1
            preparation?.cancel()
            preparing = false
            needsChartReplacement = true
            searchGeneration += 1
            searchTask?.cancel()
            scrollZoomTask?.cancel()
            for lane in lanes {
                var model = lane.feed.model
                model.xDomain = domain
                model.statisticsInterval = ChartStatistics.interval(
                    span: duration, minimum: resolution)
                lane.feed.publish(model, replacingHistory: true)
            }
            guard active, sampler != nil else { return }
            loading = true
            let request = generation
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.active, request == self.generation else { return }
                self.refresh()
                self.search()
            }
            scrollZoomTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
            return
        }
        refresh()
        search()
    }

    func toggleLive() {
        followsLive.toggle()
        if followsLive {
            alertEvidence = []
            cursor.clear()
            clearObservation()
            moveLiveEdge(Date())
            refresh()
            search()
        }
    }

    func inspect(_ date: Date) {
        followsLive = false
        cursor.pin(date)
        observationTime = date
        observations = []
        machineRecord = nil
        observationGeneration += 1
        let request = observationGeneration
        guard let sampler else { return }
        if !usesRecordedHistory, let snapshot = sampler.latest,
            snapshot.system.timestamp <= date,
            date.timeIntervalSince(snapshot.system.timestamp)
                <= max(60, SamplerModel.configuredStandardResInterval())
        {
            observations = snapshot.processes.map {
                ExplorerProcessObservation(
                    process: ExplorerProcess(sample: $0), point: ExplorerProcessPoint(sample: $0))
            }.sorted { ($0.point.values[.cpu] ?? 0) > ($1.point.values[.cpu] ?? 0) }
            return
        }
        inspecting = true
        sampler.loadExplorerProcessesAt(date) { [weak self] result in
            guard let self, request == self.observationGeneration, self.active else { return }
            self.inspecting = false
            switch result {
            case .success(let rows): self.observations = rows
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        sampler.loadExplorerMachineRecordAt(date) { [weak self] result in
            guard let self, request == self.observationGeneration, self.active else { return }
            switch result {
            case .success(let record): self.machineRecord = record
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    private func clearObservation() {
        observationGeneration += 1
        observations = []
        observationTime = nil
        machineRecord = nil
        inspecting = false
    }

    func unpinTime() {
        cursor.clear()
        clearObservation()
    }

    func stepCursor(_ direction: Double) {
        let step = max(
            1, system.map(\.bucketDuration).max() ?? 0, SamplerModel.configuredHighResInterval())
        let current = cursor.date ?? domain.upperBound
        let dates = system.map(\.date) + histories.flatMap { $0.points.map(\.date) }
        let next =
            direction > 0
            ? dates.filter { $0 > current }.min() : dates.filter { $0 < current }.max()
        let date = next ?? current.addingTimeInterval(step * direction)
        if domain.contains(date) { inspect(date) } else { showTime(date) }
    }

    func refresh() {
        scrollZoomTask?.cancel()
        scrollZoomTask = nil
        guard active, let sampler else { return }
        generation += 1
        let request = generation
        let requestedDomain = domain
        let ids = identities
        loading = true
        error = nil
        sampler.loadExplorerWindow(domain: requestedDomain, identities: ids) { [weak self] result in
            guard let self, self.active, request == self.generation else { return }
            self.loading = false
            switch result {
            case .success(let data):
                let resolution = max(
                    data.system.map(\.bucketDuration).max() ?? 0,
                    data.processes.flatMap(\.points).map(\.duration).max() ?? 0)
                if !self.followsLive, resolution > self.span {
                    let start =
                        floor(self.domain.lowerBound.timeIntervalSince1970 / resolution)
                        * resolution
                    let end =
                        ceil(self.domain.upperBound.timeIntervalSince1970 / resolution) * resolution
                    self.domain =
                        Date(
                            timeIntervalSince1970: start)...Date(
                            timeIntervalSince1970: max(start + resolution, end))
                    self.refresh()
                    return
                }
                self.sourceTier = data.granularity
                self.system = data.system
                self.histories = data.processes
                self.selectedProcesses = ids.compactMap { identity in
                    data.processes.first(where: { $0.process.id == identity })?.process
                        ?? self.selectedProcesses.first(where: { $0.id == identity })
                }
                self.loadedAt = Date()
                self.lastRefresh = Date()
                if self.followsLive, !self.usesRecordedHistory { self.appendLive() }
                self.rebuild(replacing: true)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func search(debounce: Bool = false) {
        searchTask?.cancel()
        searchGeneration += 1
        let request = searchGeneration
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.active, let sampler = self.sampler else { return }
            sampler.searchExplorerProcesses(domain: self.domain, query: self.processQuery) {
                [weak self] result in
                guard let self, self.active, request == self.searchGeneration else { return }
                switch result {
                case .success(let rows):
                    var merged = rows
                    if self.followsLive {
                        let live = sampler.displayProcesses.filter { sample in
                            self.processQuery.isEmpty
                                || sample.displayName.localizedCaseInsensitiveContains(
                                    self.processQuery)
                                || String(sample.pid).contains(self.processQuery)
                        }
                        for sample in live where !merged.contains(where: { $0.id == sample.id }) {
                            merged.append(ExplorerProcess(sample: sample))
                        }
                    }
                    self.searchResults = merged.sorted { $0.lastSeen > $1.lastSeen }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.25 : 0), execute: task)
    }

    func tick() {
        guard active, followsLive, Date().timeIntervalSince(lastTick) >= 2 else { return }
        lastTick = Date()
        moveLiveEdge(Date())
        if usesRecordedHistory {
            appendRecordedTail()
        } else {
            appendLive()
            rebuild(replacing: false)
        }
        if Date().timeIntervalSince(lastRefresh) >= 30 {
            lastRefresh = Date()
            search()
        }
    }

    private func appendRecordedTail() {
        guard !loading, !tailInFlight, let sampler else { return }
        tailInFlight = true
        let request = generation
        let end = domain.upperBound
        let start = max(
            domain.lowerBound, (system.last?.date ?? domain.lowerBound).addingTimeInterval(-120))
        sampler.loadExplorerWindow(domain: start...end, identities: identities) {
            [weak self] result in
            guard let self else { return }
            self.tailInFlight = false
            guard self.active, self.followsLive, request == self.generation else { return }
            switch result {
            case .success(let data):
                self.mergeRecordedTail(data)
                self.error = nil
                self.loadedAt = Date()
                self.rebuild(replacing: false)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func mergeRecordedTail(_ data: ExplorerWindowData) {
        for point in data.system where point.date > (system.last?.date ?? .distantPast) {
            system.append(point)
        }
        system.removeAll { $0.date.addingTimeInterval($0.bucketDuration) < domain.lowerBound }
        for history in data.processes where identities.contains(history.process.id) {
            if let index = histories.firstIndex(where: { $0.process.id == history.process.id }) {
                for point in history.points
                where point.date > (histories[index].points.last?.date ?? .distantPast) {
                    histories[index].points.append(point)
                }
            } else {
                histories.append(history)
            }
        }
        for index in histories.indices {
            histories[index].points.removeAll {
                $0.date.addingTimeInterval($0.duration) < domain.lowerBound
            }
        }
    }

    func seed(_ data: ExplorerWindowData, selected: [ExplorerProcess], enabled: Set<String>) {
        domain = data.domain
        sourceTier = data.granularity
        system = data.system
        histories = data.processes
        selectedProcesses = selected
        identities = selected.map(\.id)
        self.enabled = enabled
        followsLive = false
        loadedAt = Date()
        for (index, identity) in identities.enumerated() { colors[identity] = index % 8 }
        rebuild(replacing: true, synchronously: true)
    }

    func color(for identity: ProcessIdentity) -> Color {
        ExplorerMetrics.palette[colors[identity] ?? 0]
    }

    private func moveLiveEdge(_ date: Date) {
        let duration = span
        domain = date.addingTimeInterval(-duration)...date
    }

    private func appendLive() {
        guard let sampler else { return }
        if let sample = sampler.liveSystem, sample.timestamp > (system.last?.date ?? .distantPast) {
            system.append(SystemHistoryPoint(sample: sample))
        }
        system.removeAll { $0.date < domain.lowerBound }
        for sample in sampler.latest?.processes ?? [] where identities.contains(sample.id) {
            if let index = histories.firstIndex(where: { $0.process.id == sample.id }) {
                if sample.timestamp > (histories[index].points.last?.date ?? .distantPast) {
                    var point = ExplorerProcessPoint(sample: sample)
                    let hasCurrentRun = histories[index].points.contains {
                        $0.startsNewRun || $0.date >= sample.startTime
                            || ($0.duration > 0
                                && $0.date.addingTimeInterval($0.duration) > sample.startTime)
                    }
                    if !histories[index].points.isEmpty, !hasCurrentRun {
                        point.startsNewRun = true
                    }
                    histories[index].points.append(point)
                    histories[index].points.removeAll { $0.date < domain.lowerBound }
                }
            } else {
                histories.append(
                    ExplorerProcessHistory(
                        process: ExplorerProcess(sample: sample),
                        points: [ExplorerProcessPoint(sample: sample)]))
            }
        }
    }

    private func rebuild(replacing: Bool, synchronously: Bool = false) {
        preparation?.cancel()
        preparationGeneration += 1
        let request = preparationGeneration
        needsChartReplacement = needsChartReplacement || replacing
        if replacing { preparing = true }
        let definitions = definitions.filter { enabled.contains($0.id) }
        let system = system
        let histories = histories
        let identities = identities
        let domain = domain
        let colors = Dictionary(uniqueKeysWithValues: identities.map { ($0, color(for: $0)) })
        let fullScale = fullScaleLaneIDs
        let highResolution = SamplerModel.configuredHighResInterval()
        let standardResolution = SamplerModel.configuredStandardResInterval()
        let publish: @MainActor ([(ExplorerLaneDefinition, TrendModel)]) -> Void = {
            [weak self] models in
            guard let self, request == self.preparationGeneration else { return }
            self.publish(models, replacing: self.needsChartReplacement, fullScale: fullScale)
            self.needsChartReplacement = false
            self.preparing = false
        }
        if synchronously {
            publish(
                Self.prepare(
                    definitions: definitions, system: system, histories: histories,
                    identities: identities, colors: colors, domain: domain, fullScale: fullScale,
                    highResolution: highResolution, standardResolution: standardResolution))
        } else {
            let work = DispatchWorkItem {
                let models = Self.prepare(
                    definitions: definitions, system: system, histories: histories,
                    identities: identities, colors: colors, domain: domain, fullScale: fullScale,
                    highResolution: highResolution, standardResolution: standardResolution)
                DispatchQueue.main.async { publish(models) }
            }
            preparation = work
            preparationQueue.async(execute: work)
        }
    }

    nonisolated private static func prepare(
        definitions: [ExplorerLaneDefinition], system: [SystemHistoryPoint],
        histories: [ExplorerProcessHistory],
        identities: [ProcessIdentity], colors: [ProcessIdentity: Color], domain: ClosedRange<Date>,
        fullScale: Set<String>, highResolution: Double, standardResolution: Double
    ) -> [(ExplorerLaneDefinition, TrendModel)] {
        let sourceWidth = max(
            system.map(\.bucketDuration).max() ?? 0,
            histories.flatMap(\.points).map(\.duration).max() ?? 0)
        let interval = ChartStatistics.interval(
            span: domain.upperBound.timeIntervalSince(domain.lowerBound), minimum: sourceWidth)
        let gap = ChartGap.threshold(expectedSpacing: max(5, highResolution))
        var result: [(ExplorerLaneDefinition, TrendModel)] = []
        for definition in definitions {
            var model = TrendModel()
            model.xDomain = domain
            model.statisticsInterval = interval
            model.gapThreshold = gap
            model.showsTimeAxis = true
            model.leftGutter = 66
            model.yFormat = definition.unit.format
            model.detailFormat = definition.unit.format
            model.valueUnit = definition.unit.symbol
            if case .index = definition.unit { model.yFormat = { String(format: "%.0f", $0) } }
            if case .thermalState = definition.unit {
                model.discrete = true
                model.yTicks = [0, 1, 2, 3]
            }
            model.yDomain = definition.fixedDomain
            model.statisticsNote = definition.note
            model.accessibilityLabel = definition.title
            switch definition.source {
            case .system(let fields):
                model.series = fields.map { field in
                    TrendSurfaceSeries(
                        column: field.column(system), color: field.color, name: field.name)
                }
            case .process(let metric):
                model.gapThreshold = max(60, standardResolution) * 1.5
                model.series = identities.compactMap { identity -> TrendSurfaceSeries? in
                    guard let history = histories.first(where: { $0.process.id == identity }) else {
                        return nil
                    }
                    let column = ExplorerMetrics.processColumn(history.points, metric: metric)
                    return TrendSurfaceSeries(
                        column: column, color: colors[identity] ?? .blue,
                        name: t("%@ · PID %d", history.process.name, identity.pid))
                }
            }
            if case .celsius = definition.unit {
                let values = model.series.flatMap {
                    Array($0.column.values) + Array($0.column.highs ?? [])
                }.filter(\.isFinite)
                if let minimum = values.min(), let maximum = values.max() {
                    model.yDomain = ChartDomain.fitted(
                        min: minimum, max: maximum, minimumSpan: 30, padding: 5, floor: 0)
                } else {
                    model.yDomain = 20...100
                }
            }
            if model.yDomain == nil {
                let fit = LiveChartGeometry.outlierCeiling(peaks: samplePeaks(model.series))
                model.outlierPeak = fit.outlierPeak
                model.yDomain =
                    0...(fullScale.contains(definition.id) ? fit.fullCeiling : fit.ceiling)
            }
            result.append((definition, model))
        }
        return result
    }

    /// Each sample's highest scaled value across a lane's series: its band top
    /// where it has one, else the value itself.
    nonisolated private static func samplePeaks(_ series: [TrendSurfaceSeries]) -> [Double] {
        var peaks: [Double] = []
        peaks.reserveCapacity(series.reduce(0) { $0 + $1.column.values.count })
        for s in series {
            let values = s.column.values
            let highs = s.column.highs.map(Array.init)
            for (offset, value) in values.enumerated() {
                var peak = value
                if let highs, offset < highs.count, highs[offset].isFinite {
                    peak = peak.isFinite ? max(peak, highs[offset]) : highs[offset]
                }
                peaks.append(peak * s.scale)
            }
        }
        return peaks
    }

    func toggleFullScale(_ laneID: String) {
        if fullScaleLaneIDs.remove(laneID) == nil { fullScaleLaneIDs.insert(laneID) }
        rebuild(replacing: false)
    }

    private func publish(
        _ models: [(ExplorerLaneDefinition, TrendModel)], replacing: Bool, fullScale: Set<String>
    ) {
        var result: [ExplorerLane] = []
        for (definition, prepared) in models {
            var model = prepared
            let feed = feeds[definition.id] ?? TrendFeed()
            // A scale switch must be free to shrink the axis, so it skips the
            // grow-only union that keeps a live axis steady.
            let rescaled =
                fullScale.contains(definition.id) != publishedFullScale.contains(definition.id)
            if !replacing, !rescaled, definition.fixedDomain == nil,
                let previous = feed.model.yDomain
            {
                let next = model.yDomain ?? previous
                model.yDomain =
                    min(
                        previous.lowerBound, next.lowerBound)...max(
                        previous.upperBound, next.upperBound)
            }
            feed.publish(model, replacingHistory: replacing)
            feeds[definition.id] = feed
            result.append(ExplorerLane(definition: definition, feed: feed))
        }
        publishedFullScale = fullScale
        let order = [
            "cpu", "process.cpu", "pressure", "memory", "process.footprint", "network",
            "process.network",
            "disk", "process.diskRead", "process.diskWrite", "gpu", "process.gpu", "die",
        ]
        lanes = result.sorted { first, second in
            let firstRank =
                order.firstIndex(of: first.id)
                ?? (order.count + (result.firstIndex(where: { $0.id == first.id }) ?? 0))
            let secondRank =
                order.firstIndex(of: second.id)
                ?? (order.count + (result.firstIndex(where: { $0.id == second.id }) ?? 0))
            return firstRank < secondRank
        }
    }

    static func reading(
        _ series: TrendSurfaceSeries, at date: Date, freshness: Double
    ) -> ExplorerReading {
        let column = series.column
        let target = date.timeIntervalSinceReferenceDate
        var low = 0
        var high = column.count
        while low < high {
            let middle = (low + high) / 2
            if column.times[column.times.startIndex + middle] <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return ExplorerReading(sourceDuration: 0) }
        let index = low - 1
        let time = column.times[column.times.startIndex + index]
        let duration = column.durations.map { $0[$0.startIndex + index] } ?? 0
        let coverage = duration > 0 ? duration : freshness
        guard target - time <= coverage, duration == 0 || target < time + duration else {
            return ExplorerReading(sourceDuration: duration)
        }
        func number(_ values: ArraySlice<Double>?) -> Double? {
            guard let values else { return nil }
            let value = values[values.startIndex + index] * series.scale
            return value.isFinite ? value : nil
        }
        let value = number(column.values)
        return ExplorerReading(
            value: value, minimum: number(column.lows), maximum: number(column.highs),
            observedAt: Date(timeIntervalSinceReferenceDate: time), sourceDuration: duration)
    }
}
