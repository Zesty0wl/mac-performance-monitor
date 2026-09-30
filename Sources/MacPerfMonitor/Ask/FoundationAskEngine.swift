#if canImport(FoundationModels) && compiler(>=6.4)
import Foundation
import FoundationModels
import MacPerfMonitorCore

/// Ask's model: Apple's on-device system model on macOS 27, used for two
/// narrow jobs. Planning is guided generation into a fixed shape, so the
/// answer is always a valid plan. Answering has no tools at all: the model
/// can only read the facts Swift gathered, which the prototype showed is
/// what makes the on-device model accurate.
@available(macOS 27.0, *)
@MainActor
final class FoundationAskEngine: AskEngine {
    private let model = SystemLanguageModel.default
    private var session: LanguageModelSession?

    var unavailableReason: AskUnavailableReason? {
        switch model.availability {
        case .available:
            return model.supportsLocale(AskFormatting.locale) ? nil : .unsupportedLanguage
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable: return .modelNotReady
        }
    }

    var modelName: String? {
        guard unavailableReason == nil else { return nil }
        let name = model.variant.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    func plan(_ question: String, previous: String?, now: Date) async throws -> AskPlan {
        if let reason = unavailableReason { throw AskEngineError.unavailable(reason) }
        let planner = LanguageModelSession(
            model: model, instructions: AskPrompts.plannerInstructions(now: now))
        do {
            let planned = try await planner.respond(
                to: AskPrompts.plannerPrompt(question: question, previous: previous),
                generating: PlannedQuestion.self,
                options: GenerationOptions(sampling: .greedy)
            ).content
            return planned.plan
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    func answer(
        _ question: String, briefs: [AreaBrief], now: Date
    )
        -> AsyncThrowingStream<String, Error>
    {
        let prompt = AskPrompts.answerPrompt(question: question, briefs: briefs, now: now)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    if let reason = self.unavailableReason {
                        throw AskEngineError.unavailable(reason)
                    }
                    do {
                        try await self.stream(prompt, into: continuation)
                    } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                        // A long conversation filled the context: start afresh
                        // with just this question and its facts.
                        self.session = nil
                        try await self.stream(prompt, into: continuation)
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.map(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func reset() { session = nil }

    private func stream(
        _ prompt: String, into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let session =
            self.session
            ?? LanguageModelSession(
                model: model,
                instructions: AskPrompts.answerInstructions(language: AskPrompts.languageName))
        self.session = session
        let stream = session.streamResponse(
            to: prompt, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 400))
        for try await snapshot in stream {
            continuation.yield(AskPrompts.tidy(snapshot.content))
        }
    }

    private static func map(_ error: LanguageModelSession.GenerationError) -> Error {
        switch error {
        case .guardrailViolation, .refusal: return AskEngineError.refused
        case .unsupportedLanguageOrLocale: return AskEngineError.unavailable(.unsupportedLanguage)
        case .assetsUnavailable: return AskEngineError.unavailable(.modelNotReady)
        default: return AskEngineError.failed
        }
    }
}

// MARK: The plan's shape

@available(macOS 27.0, *)
@Generable
enum PlannedArea: String {
    case processor, memory, graphics, neuralEngine, network, storage, battery, heat, overall

    var area: AskArea {
        switch self {
        case .processor: return .processor
        case .memory: return .memory
        case .graphics: return .graphics
        case .neuralEngine: return .neuralEngine
        case .network: return .network
        case .storage: return .storage
        case .battery: return .energy
        case .heat: return .heat
        case .overall: return .overall
        }
    }
}

@available(macOS 27.0, *)
@Generable
enum PlannedTimeKind: String {
    case recent, around, day
}

@available(macOS 27.0, *)
@Generable
struct PlannedQuestion {
    @Guide(
        description: "The parts of the Mac the question is about, most likely first",
        .maximumCount(3))
    var areas: [PlannedArea]
    @Guide(description: "recent, around a clock time, or a whole day")
    var time: PlannedTimeKind
    @Guide(
        description:
            "For recent: minutes back from now. 15 for right now, 60 when unsure, more only if the question asks",
        .range(5...10080))
    var minutes: Int
    @Guide(description: "For around: the hour on a 24-hour clock", .range(0...23))
    var hour: Int
    @Guide(description: "For around: the minute", .range(0...59))
    var minute: Int
    @Guide(description: "For around or day: 0 for today, 1 for yesterday", .range(0...6))
    var daysAgo: Int
    @Guide(description: "An app the question names, exactly as written, or empty")
    var app: String

    var plan: AskPlan {
        let spec: AskTimeSpec
        switch time {
        case .recent: spec = .recent(minutes: minutes)
        case .around: spec = .around(hour: hour, minute: minute, daysAgo: daysAgo)
        case .day: spec = .day(daysAgo: daysAgo)
        }
        return AskPlan(areas: areas.map(\.area), time: spec, appName: app).resolved()
    }
}
#endif
