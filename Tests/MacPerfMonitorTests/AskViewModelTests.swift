import MacPerfMonitorCore
import XCTest

@testable import MacPerfMonitor

/// The conversation's bookkeeping. A tile tap once crashed because the turn it
/// updated was never added; these pin that every path adds its turn and that
/// work finishing after the conversation was cleared changes nothing.
@MainActor
final class AskViewModelTests: XCTestCase {
    private func brief(_ area: AskArea) -> AreaBrief {
        AreaBrief(
            area: area, start: Date().addingTimeInterval(-3600), end: Date(), status: .busy,
            headline: "Busy.",
            chart: AskChartLink(title: area.title, laneIDs: ["cpu"], start: Date(), end: Date()))
    }

    private func model(
        delay: Double = 0, engine: @escaping @MainActor () -> AskEngine = { UnavailableAskEngine() }
    )
        -> AskViewModel
    {
        AskViewModel(
            source: AskViewModel.Source(
                overview: { [] }, earliest: { nil },
                briefs: { areas, _, _, _ in
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    return areas.map {
                        AreaBrief(
                            area: $0, start: Date(), end: Date(), status: .busy, headline: "Busy.")
                    }
                }),
            engine: engine)
    }

    private func settle(_ model: AskViewModel) async {
        for _ in 0..<200 where model.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testTileTapWithoutTheModelShowsTheSummary() async {
        let model = model()
        model.explore(.processor)
        XCTAssertEqual(model.turns.count, 1)
        XCTAssertEqual(model.turns.first?.question, AskArea.processor.question)
        await settle(model)
        XCTAssertEqual(model.turns.first?.phase, .done)
        XCTAssertEqual(model.turns.first?.summaryOnly, true)
        XCTAssertEqual(model.turns.first?.briefs.map(\.area), [.processor])
    }

    func testTypedQuestionWithoutTheModelSaysWhy() async {
        let model = model()
        model.ask("Why is my Mac slow?")
        await settle(model)
        guard case .failed(let message) = model.turns.first?.phase else {
            return XCTFail("expected a failure explaining why")
        }
        XCTAssertEqual(message, AskUnavailableReason.needsNewerMacOS.message)
    }

    func testStartingOverWhileWorkIsInFlightDoesNotCrash() async {
        let model = model(delay: 0.2)
        model.explore(.memory)
        model.startOver()
        XCTAssertTrue(model.turns.isEmpty)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.turns.isEmpty)
        model.explore(.storage)
        await settle(model)
        XCTAssertEqual(model.turns.map(\.question), [AskArea.storage.question])
    }

    func testAnswerStreamsIntoTheTurnWithItsCharts() async {
        let model = model(engine: { FakeEngine() })
        model.ask("Why is my Mac slow?")
        await settle(model)
        let turn = model.turns.first
        XCTAssertEqual(turn?.phase, .done)
        XCTAssertEqual(turn?.answer, "Your Mac is busy.")
        XCTAssertEqual(turn?.briefs.map(\.area), [.processor, .memory])
        XCTAssertEqual(turn?.summaryOnly, false)
    }
}

@MainActor
private final class FakeEngine: AskEngine {
    var unavailableReason: AskUnavailableReason? { nil }
    var modelName: String? { "Test Model" }
    func plan(_ question: String, previous: String?, now: Date) async throws -> AskPlan {
        AskPlan(areas: [.processor, .memory])
    }
    func answer(
        _ question: String, briefs: [AreaBrief], now: Date
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("Your Mac")
            continuation.yield("Your Mac is busy.")
            continuation.finish()
        }
    }
    func reset() {}
}
