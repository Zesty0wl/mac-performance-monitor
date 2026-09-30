import Combine
import Foundation
import MacPerfMonitorCore

/// One question and its answer.
struct AskTurn: Identifiable {
    enum Phase: Equatable {
        case thinking
        /// Swift is reading history for these parts.
        case looking([AskArea])
        case answering
        case done
        case failed(String)
    }

    let id = UUID()
    let question: String
    var phase: Phase = .thinking
    var briefs: [AreaBrief] = []
    var answer = ""
    /// Tile taps and fallbacks show Swift's summaries without a model answer.
    var summaryOnly = false
    var suggestions: [String] = []

    var charts: [AskChartLink] {
        var seen = Set<AskChartLink>()
        return briefs.compactMap(\.chart).filter { seen.insert($0).inserted }
    }
}

/// Ask's state: the tile overview, the conversation, and the model engine.
/// Swift reads and judges (through `SamplerModel.askBriefs`); the engine plans
/// and explains. Nothing is saved: closing the window clears it.
@MainActor
final class AskViewModel: ObservableObject {
    @Published private(set) var overview: [AreaBrief] = []
    @Published private(set) var turns: [AskTurn] = []
    @Published private(set) var unavailableReason: AskUnavailableReason?
    /// The Apple Intelligence model answering, as macOS names it, when known.
    @Published private(set) var modelName: String?
    @Published var draft = ""

    /// Where briefs come from. The app reads them from `SamplerModel`; tests
    /// supply fixed ones.
    struct Source {
        var overview: () async throws -> [AreaBrief]
        var earliest: () async throws -> Date?
        var briefs:
            (_ areas: [AskArea], _ interval: DateInterval, _ app: String?, _ now: Date) async throws
                -> [AreaBrief]
    }

    private let source: Source
    private let openChartAction: (AskChartLink) -> Void
    private let makeEngine: @MainActor () -> AskEngine
    private lazy var engine: AskEngine = makeEngine()
    private var work: Task<Void, Never>?
    private var overviewTask: Task<Void, Never>?

    convenience init(sampler: SamplerModel, openChart: @escaping (AskChartLink) -> Void) {
        self.init(
            source: Source(
                overview: { [weak sampler] in try await sampler?.askOverview() ?? [] },
                earliest: { [weak sampler] in try await sampler?.askEarliestRecord() },
                briefs: { [weak sampler] areas, interval, app, now in
                    try await sampler?.askBriefs(
                        areas: areas, interval: interval, appName: app, now: now)
                        ?? []
                }),
            engine: { AskEngines.make() }, openChart: openChart)
    }

    init(
        source: Source, engine: @escaping @MainActor () -> AskEngine,
        openChart: @escaping (AskChartLink) -> Void = { _ in }
    ) {
        self.source = source
        self.makeEngine = engine
        self.openChartAction = openChart
    }

    var isBusy: Bool {
        guard let last = turns.last else { return false }
        switch last.phase {
        case .done, .failed: return false
        default: return true
        }
    }

    var overall: AreaBrief? { overview.first { $0.area == .overall } }
    var parts: [AreaBrief] { overview.filter { $0.area != .overall } }

    static let starters = [
        t("Why is my Mac slow?"), t("Why is the fan loud?"), t("What's using my battery?"),
        t("Is anything using too much memory?"), t("Do I have enough disk space?"),
    ]

    // MARK: Lifecycle

    func windowOpened() {
        unavailableReason = engine.unavailableReason
        modelName = engine.modelName
        overviewTask?.cancel()
        overviewTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOverview()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Closing Ask forgets the conversation, as promised in its privacy text.
    func windowClosed() {
        overviewTask?.cancel()
        overviewTask = nil
        startOver()
    }

    func refreshOverview() async {
        let started = Date()
        if let briefs = try? await source.overview() {
            overview = briefs
            AppLog.ui.notice(
                "ask overview built in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s"
            )
        }
        unavailableReason = engine.unavailableReason
        modelName = engine.modelName
    }

    func startOver() {
        work?.cancel()
        work = nil
        turns = []
        draft = ""
        engine.reset()
    }

    func stop() {
        work?.cancel()
        if let last = turns.last, isBusy {
            update(last.id) { $0.phase = $0.answer.isEmpty ? .failed(t("Stopped.")) : .done }
        }
    }

    func openChart(_ link: AskChartLink) { openChartAction(link) }

    // MARK: Asking

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return }
        draft = ""
        ask(String(question.prefix(500)))
    }

    func ask(_ question: String) {
        guard !isBusy else { return }
        let previous = turns.last?.question
        let turn = AskTurn(question: question)
        turns.append(turn)
        work = Task { [weak self] in
            guard let self else { return }
            if let reason = self.engine.unavailableReason {
                self.unavailableReason = reason
                self.update(turn.id) { $0.phase = .failed(reason.message) }
                return
            }
            do {
                let now = Date()
                let plan = try await self.engine.plan(question, previous: previous, now: now)
                try await self.answer(question, plan: plan, turn: turn.id, now: now)
            } catch is CancellationError {
            } catch {
                self.update(turn.id) { $0.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// A tile tap: the area's summary straight away from Swift, then a short
    /// explanation when the model is available.
    func explore(_ area: AskArea) {
        guard !isBusy else { return }
        let question = area.question
        let turn = AskTurn(question: question)
        turns.append(turn)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.answer(
                    question, plan: AskPlan(areas: [area]), turn: turn.id, now: Date(),
                    explain: self.engine.unavailableReason == nil)
            } catch is CancellationError {
            } catch {
                self.update(turn.id) { $0.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// Changes one turn by its identity. The conversation can be cleared at
    /// any moment (Start over, closing the window) while work for a turn is
    /// still in flight; a turn that is gone is simply not updated.
    @discardableResult
    private func update(_ id: UUID, _ change: (inout AskTurn) -> Void) -> Bool {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return false }
        change(&turns[index])
        return true
    }

    private func answer(
        _ question: String, plan: AskPlan, turn id: UUID, now: Date, explain: Bool = true
    ) async throws {
        guard update(id, { $0.phase = .looking(plan.areas) }) else { return }
        let earliest = try? await source.earliest()
        let interval = plan.time.interval(now: now, earliest: earliest)
        let briefs = try await source.briefs(plan.areas, interval, plan.appName, now)
        try Task.checkCancellation()
        let present = update(id) {
            $0.briefs = briefs
            $0.suggestions = Self.suggestions(after: briefs, asked: question)
            if !explain {
                $0.summaryOnly = true
                $0.phase = .done
            } else {
                $0.phase = .answering
            }
        }
        guard present, explain else { return }
        for try await text in engine.answer(question, briefs: briefs, now: now) {
            guard update(id, { $0.answer = text }) else { return }
        }
        update(id) { $0.phase = .done }
    }

    /// Two useful next questions: what to do when something stood out, and a
    /// neighbouring part of the Mac.
    static func suggestions(after briefs: [AreaBrief], asked: String) -> [String] {
        var ideas: [String] = []
        if briefs.contains(where: { $0.status >= .busy }) {
            ideas.append(t("What should I do about it?"))
        }
        let covered = Set(briefs.map(\.area))
        let related: [AskArea: String] = [
            .processor: t("Why is my Mac slow?"), .memory: t("Is anything using too much memory?"),
            .storage: t("Do I have enough disk space?"), .energy: t("What's using my battery?"),
            .heat: t("Why is the fan loud?"), .network: t("What's using the internet?"),
        ]
        for area in [AskArea.memory, .processor, .energy, .storage, .heat, .network]
        where !covered.contains(area) {
            if let idea = related[area], idea != asked { ideas.append(idea) }
            if ideas.count >= 2 { break }
        }
        return Array(ideas.prefix(2))
    }
}
