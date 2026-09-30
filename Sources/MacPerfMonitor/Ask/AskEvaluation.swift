import Foundation
import MacPerfMonitorCore

/// `--ask-eval`: scripted questions against made-up scenarios, answered by the
/// real on-device model, printed for a person to read. It uses no recorded
/// history and changes nothing. Run it after changing a prompt or a brief, and
/// when Apple updates the model; read the answers, not just the exit code.
enum AskEvaluation {
    static let flag = "--ask-eval"

    static let questions: [(AskScenario, [String])] = [
        (.idle, ["Why is my Mac slow?", "What's the weather tomorrow?"]),
        (.busyBuild, ["Why is my Mac slow and the fan so loud?", "What should I do about it?"]),
        (.memoryGrowth, ["Is anything using too much memory?"]),
        (.fullDisk, ["Can I install a 40 GB game?"]),
        (.batteryDrain, ["Why is my battery going down so fast?", "Is Chrome the problem?"]),
        (.hotAndLoud, ["Why is my Mac so hot?"]),
    ]

    @MainActor
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains(flag) else { return false }
        Task { @MainActor in
            await run()
            exit(0)
        }
        RunLoop.main.run()
        return true
    }

    @MainActor
    static func run() async {
        let engine = AskEngines.make()
        if let reason = engine.unavailableReason {
            print("Ask is unavailable: \(reason.message)")
            return
        }
        for (scenario, script) in questions {
            print("\n=== \(scenario.rawValue): \(scenario.summary)")
            engine.reset()
            let now = Date()
            let briefs = scenario.briefs(now: now)
            var previous: String?
            for question in script {
                let started = Date()
                defer { previous = question }
                do {
                    let plan = try await engine.plan(question, previous: previous, now: now)
                    let chosen = select(plan, from: briefs)
                    var answer = ""
                    for try await text in engine.answer(question, briefs: chosen, now: now) {
                        answer = text
                    }
                    print("\nQ: \(question)")
                    print(
                        "   plan: \(plan.areas.map(\.rawValue).joined(separator: ", ")) \(plan.time)"
                            + (plan.appName.map { " app: \($0)" } ?? "")
                            + String(format: "  (%.1fs)", Date().timeIntervalSince(started)))
                    print("   charts: \(chosen.compactMap(\.chart?.title).joined(separator: ", "))")
                    print(answer.split(separator: "\n").map { "   " + $0 }.joined(separator: "\n"))
                } catch {
                    print("\nQ: \(question)\n   failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The same selection the window makes: the planned parts, or the overall
    /// brief and the parts that stood out.
    static func select(_ plan: AskPlan, from briefs: [AskArea: AreaBrief]) -> [AreaBrief] {
        guard plan.areas != [.overall] else {
            let standouts = AskArea.parts.compactMap { briefs[$0] }.filter { $0.status >= .busy }
                .sorted { $0.status > $1.status }.prefix(2)
            return [briefs[.overall]].compactMap { $0 } + standouts
        }
        return plan.areas.compactMap { briefs[$0] }
    }
}
