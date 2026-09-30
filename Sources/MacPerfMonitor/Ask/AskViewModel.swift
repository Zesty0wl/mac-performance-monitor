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
    @Published var draft = ""

    private let sampler: SamplerModel
    private let openChartAction: (AskChartLink) -> Void
    private lazy var engine: AskEngine = AskEngines.make()
    private var work: Task<Void, Never>?
    private var overviewTask: Task<Void, Never>?

    init(sampler: SamplerModel, openChart: @escaping (AskChartLink) -> Void) {
        self.sampler = sampler
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
        if let briefs = try? await sampler.askOverview() {
            overview = briefs
            AppLog.ui.notice(
                "ask overview built in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s"
            )
        }
        unavailableReason = engine.unavailableReason
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
        if let index = turns.indices.last, isBusy {
            turns[index].phase = turns[index].answer.isEmpty ? .failed(t("Stopped.")) : .done
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
        turns.append(AskTurn(question: question))
        let index = turns.count - 1
        work = Task { [weak self] in
            guard let self else { return }
            if let reason = self.engine.unavailableReason {
                self.unavailableReason = reason
                self.turns[index].phase = .failed(reason.message)
                return
            }
            do {
                let now = Date()
                let plan = try await self.engine.plan(question, previous: previous, now: now)
                try await self.answer(question, plan: plan, at: index, now: now)
            } catch is CancellationError {
            } catch {
                guard index < self.turns.count else { return }
                self.turns[index].phase = .failed(error.localizedDescription)
            }
        }
    }

    /// A tile tap: the area's summary straight away from Swift, then a short
    /// explanation when the model is available.
    func explore(_ area: AskArea) {
        guard !isBusy else { return }
        let question = area.question
        let index = turns.count - 1
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.answer(
                    question, plan: AskPlan(areas: [area]), at: index, now: Date(),
                    explain: self.engine.unavailableReason == nil)
            } catch is CancellationError {
            } catch {
                guard index < self.turns.count else { return }
                self.turns[index].phase = .failed(error.localizedDescription)
            }
        }
    }

    private func answer(
        _ question: String, plan: AskPlan, at index: Int, now: Date, explain: Bool = true
    ) async throws {
        turns[index].phase = .looking(plan.areas)
        let earliest = try? await sampler.askEarliestRecord()
        let interval = plan.time.interval(now: now, earliest: earliest)
        let briefs = try await sampler.askBriefs(
            areas: plan.areas, interval: interval, appName: plan.appName, now: now)
        try Task.checkCancellation()
        guard index < turns.count else { return }
        turns[index].briefs = briefs
        turns[index].suggestions = Self.suggestions(after: briefs, asked: question)
        guard explain else {
            turns[index].summaryOnly = true
            turns[index].phase = .done
            return
        }
        turns[index].phase = .answering
        for try await text in engine.answer(question, briefs: briefs, now: now) {
            guard index < turns.count else { return }
            turns[index].answer = text
        }
        turns[index].phase = .done
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
