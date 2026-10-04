import AppKit
import MacPerfMonitorCore

/// Handing an investigation to an AI coding agent (Claude Code, Codex): the
/// prompt that teaches it this app's data, and the one-line MCP setups. The
/// agent runs outside the app and sends what it reads to its own provider, so
/// Ask asks once before the first copy.
enum AgentHandoff {
    static let noticeKey = "ask.agentNoticeAccepted"

    /// `--scope user` registers it for every folder; Claude Code's default
    /// scope is the folder the command happens to run in.
    static let claudeSetup =
        "claude mcp add --scope user mac-performance-monitor -- \"\(AgentGuide.mpmPath)\" mcp"
    static let codexSetup =
        "codex mcp add mac-performance-monitor -- \"\(AgentGuide.mpmPath)\" mcp"

    /// The prompt, with the latest Ask question and its facts when there is one.
    static func prompt(continuing turn: AskTurn?) async -> String {
        let url = MacPerfMonitorDatabase.defaultURL()
        let coverage = await Task.detached(priority: .userInitiated) { () -> String? in
            (try? AgentStore(url: url))?.coverageText
        }.value
        var context: String?
        if let turn, !turn.briefs.isEmpty {
            context = """
                I asked Mac Performance Monitor: "\(turn.question)"

                It looked at \(turn.briefs.first.map { AskFormatting.period($0.start, $0.end, now: Date()) } ?? "recent history") and found:

                \(turn.briefs.map(\.promptText).joined(separator: "\n\n"))

                \(turn.answer.isEmpty ? "" : "Its short answer was:\n\(turn.answer)\n\n")Please dig deeper: check \
                these findings against the history, look for causes it may have missed, and tell me what to do.
                """
        }
        return AgentGuide.prompt(databasePath: url.path, coverage: coverage, context: context)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension AgentStore {
    fileprivate var coverageText: String? { try? coverage().render(as: "table") }
}
