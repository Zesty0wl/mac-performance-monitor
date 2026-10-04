import AppKit
import MacPerfMonitorCore
import SwiftUI

/// Ask About This Mac: the calm front door for people new to Macs. A verdict,
/// one tile per part, a few questions to tap, and a question box. Answers link
/// to the matching charts in the main window, where the detail lives.
struct AskView: View {
    @ObservedObject var model: AskViewModel
    @FocusState private var composerFocused: Bool
    @AppStorage(AgentHandoff.noticeKey) private var agentNoticeAccepted = false
    @State private var pendingHandoff: Handoff?
    @State private var copiedNote: String?

    /// What gets copied for an AI agent.
    enum Handoff: Identifiable {
        case prompt, claude, codex
        var id: Self { self }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if model.turns.isEmpty {
                        startPage
                    } else {
                        ForEach(model.turns) { turn in
                            AskTurnView(
                                turn: turn, openChart: model.openChart,
                                ask: { model.ask($0) }, canAsk: !model.isBusy
                            )
                            .id(turn.id)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.turns.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .frame(minWidth: 560, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    agentMenuItems
                } label: {
                    Label("Hand off to an AI agent", systemImage: "terminal")
                }
                .help("Copy a prompt or a setup command for Claude Code, Codex or another AI agent")
            }
            if !model.turns.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.startOver()
                    } label: {
                        Label("Start over", systemImage: "arrow.counterclockwise")
                    }
                    .help("Clear this conversation and go back to the start")
                }
            }
        }
        .alert(
            "Hand off to an AI agent?",
            isPresented: Binding(
                get: { pendingHandoff != nil && !agentNoticeAccepted },
                set: { if !$0 { pendingHandoff = nil } })
        ) {
            Button("Copy") {
                agentNoticeAccepted = true
                if let handoff = pendingHandoff { perform(handoff) }
            }
            Button("Cancel", role: .cancel) { pendingHandoff = nil }
        } message: {
            Text(
                "An AI agent such as Claude Code or Codex will read this Mac's recorded history, including app names and how much they used, and send what it reads to its AI provider. Ask itself never sends anything off this Mac."
            )
        }
        .overlay(alignment: .bottom) {
            if let copiedNote {
                Label(copiedNote, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 110)
                    .transition(.opacity)
            }
        }
        .onAppear {
            model.windowOpened()
            composerFocused = true
        }
        .onDisappear { model.windowClosed() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            AskStatusBadge(status: model.overall?.status ?? .unknown, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask About This Mac")
                    .font(.title2.weight(.semibold))
                Text(model.overall?.headline ?? t("Checking how your Mac is doing…"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Start page

    private var startPage: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("How each part is doing")
                    .font(.headline)
                Text("Based on the last hour. Click a part to learn more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(model.parts, id: \.area) { brief in
                        AskAreaTile(brief: brief) { model.explore(brief.area) }
                    }
                }
                if model.parts.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Or ask a question")
                    .font(.headline)
                HardwareFlowLayout(spacing: 8) {
                    ForEach(AskViewModel.starters, id: \.self) { question in
                        AskSuggestionChip(text: question) { model.ask(question) }
                            .disabled(model.unavailableReason != nil)
                    }
                }
            }
            agentCard
        }
    }

    // MARK: AI agents

    private var agentCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text("Dig deeper with an AI agent").font(.callout.weight(.semibold))
                Text(
                    "Claude Code, Codex and other AI agents can read this Mac's history too and investigate in depth. They send what they read to their provider."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Copy prompt") { request(.prompt) }
                    Menu("Set up once") {
                        Button("Claude Code") { request(.claude) }
                        Button("Codex") { request(.codex) }
                    }
                    .fixedSize()
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
    }

    @ViewBuilder private var agentMenuItems: some View {
        Button(model.turns.isEmpty ? "Copy prompt" : "Copy prompt with this conversation") {
            request(.prompt)
        }
        Divider()
        Button("Copy Claude Code setup") { request(.claude) }
        Button("Copy Codex setup") { request(.codex) }
    }

    /// The first hand-off explains where the data goes; later ones just copy.
    private func request(_ handoff: Handoff) {
        pendingHandoff = handoff
        if agentNoticeAccepted { perform(handoff) }
    }

    private func perform(_ handoff: Handoff) {
        pendingHandoff = nil
        switch handoff {
        case .claude:
            AgentHandoff.copy(AgentHandoff.claudeSetup)
            showCopied(t("Copied. Paste it into Terminal, then ask Claude Code about your Mac."))
        case .codex:
            AgentHandoff.copy(AgentHandoff.codexSetup)
            showCopied(t("Copied. Paste it into Terminal, then ask Codex about your Mac."))
        case .prompt:
            let turn = model.turns.last(where: { $0.phase == .done })
            Task {
                AgentHandoff.copy(await AgentHandoff.prompt(continuing: turn))
                showCopied(t("Copied. Paste it into Claude Code, Codex or another AI agent."))
            }
        }
    }

    private func showCopied(_ note: String) {
        withAnimation { copiedNote = note }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if copiedNote == note { copiedNote = nil } }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let reason = model.unavailableReason {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(reason.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if reason.opensSettings {
                        Button("Open Settings") { AskView.openAppleIntelligenceSettings() }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask anything about your Mac", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .onSubmit { model.send() }
                    .disabled(model.unavailableReason != nil)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18).fill(
                            Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator))
                if model.isBusy {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop")
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        model.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Ask")
                    .accessibilityLabel("Ask")
                }
            }
            Text(
                model.modelName.map {
                    t(
                        "Answers by Apple Intelligence (%@), running on this Mac. They can be wrong, so check the facts behind them.",
                        $0)
                }
                    ?? t(
                        "Answers by Apple Intelligence, running on this Mac. They can be wrong, so check the facts behind them."
                    )
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var canSend: Bool {
        model.unavailableReason == nil && !model.isBusy
            && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func openAppleIntelligenceSettings() {
        let url =
            URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
            ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Pieces

/// A status as a coloured symbol, never colour alone: each status has its own
/// shape, and the word is always nearby for VoiceOver and for everyone else.
struct AskStatusBadge: View {
    let status: AskStatus
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(status.color.gradient))
            .accessibilityLabel(status.title)
    }
}

struct AskStatusPill: View {
    let status: AskStatus

    var body: some View {
        // Always one line: the tile's title gives way before the pill wraps.
        Text(status.title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(status.color)
            .background(Capsule().fill(status.color.opacity(0.14)))
    }
}

struct AskAreaTile: View {
    let brief: AreaBrief
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: brief.area.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(brief.status.color)
                        .frame(width: 22)
                    Text(brief.area.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    AskStatusPill(status: brief.status)
                }
                Text(brief.headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(hovering ? 0.7 : 0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(brief.area.explanation)
        .accessibilityLabel(
            Text(verbatim: "\(brief.area.title), \(brief.status.title). \(brief.headline)")
        )
        .accessibilityHint("Shows more about this part of your Mac")
    }
}

struct AskSuggestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25)))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

/// One question and its answer card.
struct AskTurnView: View {
    let turn: AskTurn
    let openChart: (AskChartLink) -> Void
    let ask: (String) -> Void
    let canAsk: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 60)
                Text(turn.question)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    )
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 14) {
                AskSourceLabel(summaryOnly: turn.summaryOnly)
                progress
                if !turn.answer.isEmpty {
                    Text(turn.answer)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if turn.summaryOnly {
                    ForEach(turn.briefs, id: \.area) { AskBriefSummary(brief: $0) }
                }
                if case .failed(let message) = turn.phase {
                    Label(message, systemImage: "exclamationmark.bubble")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if turn.phase == .done, !turn.charts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("See it on a chart")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HardwareFlowLayout(spacing: 8) {
                            ForEach(turn.charts, id: \.self) { chart in
                                AskChartButton(link: chart) { openChart(chart) }
                            }
                        }
                    }
                }
                if turn.phase == .done, !turn.summaryOnly, !turn.briefs.isEmpty {
                    DisclosureGroup("What I looked at") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(turn.briefs, id: \.area) {
                                AskBriefSummary(brief: $0, detailed: true)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.callout)
                }
                if turn.phase == .done, !turn.suggestions.isEmpty {
                    HardwareFlowLayout(spacing: 8) {
                        ForEach(turn.suggestions, id: \.self) { idea in
                            AskSuggestionChip(text: idea) { ask(idea) }.disabled(!canAsk)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06)))
        }
    }

    @ViewBuilder private var progress: some View {
        switch turn.phase {
        case .thinking:
            AskProgressLine(text: t("Thinking about your question…"))
        case .looking(let areas):
            AskProgressLine(
                text: t(
                    "Looking at %@…",
                    ListFormatter.localizedString(byJoining: areas.map(\.title))))
        case .answering where turn.answer.isEmpty:
            AskProgressLine(text: t("Writing an answer…"))
        default:
            EmptyView()
        }
    }
}

/// Who wrote an answer: Apple Intelligence, or the app's own readings when
/// the model was not used.
struct AskSourceLabel: View {
    let summaryOnly: Bool

    var body: some View {
        Label(
            summaryOnly ? t("From your Mac's readings") : t("Apple Intelligence"),
            systemImage: summaryOnly ? "gauge.with.dots.needle.50percent" : "apple.intelligence"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

struct AskProgressLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct AskChartButton: View {
    let link: AskChartLink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(link.title, systemImage: "chart.xyaxis.line")
        }
        .buttonStyle(.bordered)
        .help("Open this chart in the main window")
    }
}

/// A brief in plain text: its status and headline, and on request the facts,
/// apps, notes and gaps behind it.
struct AskBriefSummary: View {
    let brief: AreaBrief
    var detailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AskStatusBadge(status: brief.status, size: 18)
                Text(brief.area.title).font(.callout.weight(.semibold))
                AskStatusPill(status: brief.status)
            }
            Text(brief.headline).fixedSize(horizontal: false, vertical: true)
            let facts = detailed ? brief.facts : Array(brief.facts.prefix(3))
            ForEach(facts, id: \.self) { bullet($0) }
            if detailed, let normal = brief.normal {
                bullet(t("Normal for this Mac: %@", normal))
            }
            ForEach(brief.apps, id: \.self) { app in
                bullet("\(app.name): \(app.usage)")
            }
            ForEach(brief.notable, id: \.self) { bullet($0, symbol: "exclamationmark.circle") }
            if detailed {
                ForEach(brief.gaps, id: \.self) { bullet($0, symbol: "questionmark.circle") }
            }
            if !detailed {
                ForEach(brief.advice, id: \.self) { bullet($0, symbol: "lightbulb") }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func bullet(_ text: String, symbol: String = "circle.fill") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "circle.fill" ? 4 : 11))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension AskStatus {
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .calm: return .green
        case .busy: return .blue
        case .unusual: return .orange
        case .attention: return .red
        }
    }

    var symbol: String {
        switch self {
        case .unknown: return "questionmark"
        case .calm: return "checkmark"
        case .busy: return "gauge.with.needle"
        case .unusual: return "exclamationmark"
        case .attention: return "exclamationmark.triangle"
        }
    }
}
