import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

struct AskPreviewView: View {
    @ObservedObject var model: AskPreviewModel
    let openEvidence: (AskEvidence?, AskTopic) -> Void
    var openNextStep: ((AskNextStep, AskEvidence?) -> Void)? = nil

    @AppStorage(AskPreviewPreferences.enabledKey) private var enabled = false
    @AppStorage(AskPreviewPreferences.onDeviceKey) private var useAI = false
    @AppStorage(AskPreviewPreferences.explanationsKey) private var generateExplanations = false
    @AppStorage(AskPreviewPreferences.backendKey) private var backend = AskInferenceBackend.apple
        .rawValue
    @State private var showSettings = false
    @State private var showMeasurements = false
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Ask About This Mac")
                    .font(.title2.weight(.semibold))
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Clear question and report")
                .accessibilityLabel("Clear question and report")
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: showSettings && enabled ? "checkmark" : "slider.horizontal.3")
                }
                .help(showSettings && enabled ? t("Show reports") : t("Preview settings"))
                .accessibilityLabel(
                    showSettings && enabled ? t("Show reports") : t("Preview settings"))
            }
            .padding(20)
            Divider()

            if !enabled || showSettings {
                Form { AskPreviewSettingsSection() }
                    .formStyle(.grouped)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(useAI && generateExplanations ? "Investigate" : "Current reports")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(AskTopic.allCases) { topic in
                            Button {
                                model.askAbout(topic)
                            } label: {
                                Text(topic.question)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.link)
                            .disabled(model.isWorking)
                        }
                        if useAI && generateExplanations {
                            Divider()
                            Menu {
                                ForEach(AskTopic.allCases) { topic in
                                    Button(topic.title) { model.showReport(topic) }
                                }
                            } label: {
                                Label("Current reports", systemImage: "doc.text")
                            }
                            .disabled(model.isWorking)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                    .frame(width: 210)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let question = model.submittedQuestion {
                                Text(question)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            if model.isWorking {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text(
                                        model.activeCheck?.name.title
                                            ?? (useAI && generateExplanations
                                                ? t("Investigating current activity")
                                                : t("Preparing a current report")))
                                    Spacer()
                                    Button {
                                        model.stop()
                                    } label: {
                                        Image(systemName: "stop.fill")
                                    }
                                    .help("Stop")
                                    .accessibilityLabel("Stop")
                                }
                            }
                            if let message = model.message,
                                !showsLocalReadinessNotice || message != model.availabilityMessage
                            {
                                Label(message, systemImage: "info.circle")
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("ask.message")
                            }
                            if !model.investigationChecks.isEmpty {
                                DisclosureGroup("Checked evidence") {
                                    ForEach(
                                        Array(model.investigationChecks.enumerated()), id: \.offset
                                    ) { _, check in
                                        HStack(alignment: .top) {
                                            Image(systemName: "checkmark.circle").foregroundStyle(
                                                .secondary)
                                            Text(check.name.title + ": " + check.metric.title)
                                            Spacer(minLength: 4)
                                            Text(
                                                t(
                                                    "%@ to %@ minutes ago",
                                                    check.fromMinutesAgo.formatted(),
                                                    check.toMinutesAgo.formatted())
                                            )
                                            .foregroundStyle(.secondary)
                                        }
                                        .font(.caption)
                                        .padding(.vertical, 3)
                                    }
                                }
                                .accessibilityIdentifier("ask.checked-evidence")
                            }
                            if let report = model.report {
                                reportContent(report)
                            } else if !model.isWorking, model.message == nil {
                                Text("What feels slow?")
                                    .font(.headline)
                                Text(
                                    "Opening apps, switching windows, saving files, or loading websites?"
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .textSelection(.enabled)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if showsLocalReadinessNotice, let reason = model.availabilityMessage {
                        AskModelReadinessNotice(backend: model.selectedBackend, reason: reason) {
                            model.refreshAvailability()
                        }
                    }
                    if let answer = model.explanation {
                        Text(answer.followUpQuestion)
                            .font(.callout.weight(.medium))
                            .accessibilityIdentifier("ask.follow-up")
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField(
                            model.explanation == nil ? "Ask about this Mac" : "Your reply",
                            text: $model.question, axis: .vertical
                        )
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .focused($questionFocused)
                        .disabled(!useAI || model.isWorking)
                        .onSubmit { model.ask() }
                        .accessibilityIdentifier("ask.question")
                        Button {
                            model.ask()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .help("Ask")
                        .accessibilityLabel("Ask")
                        .disabled(
                            !useAI || model.isWorking
                                || model.question.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                        )
                    }
                    if !showsLocalReadinessNotice {
                        Text(
                            model.availabilityMessage
                                ?? (useAI && generateExplanations
                                    ? t(
                                        "Answers use the selected local model and cited measurements."
                                    )
                                    : useAI
                                        ? t(
                                            "On-device AI selects a report. Values and explanations come from measured evidence."
                                        )
                                        : t(
                                            "On-device AI is off. Current reports remain available."
                                        ))
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(AskWindowLifecycle(onClose: { model.clear() }))
        .onAppear { model.refreshAvailability() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            model.refreshAvailability()
        }
        .onChange(of: enabled) { _, value in
            if !value { model.clear() }
            showSettings = value
        }
        .onChange(of: useAI) { _, value in
            if !value { model.clear() }
        }
        .onChange(of: generateExplanations) { _, _ in
            model.clear()
            model.refreshAvailability()
        }
        .onChange(of: backend) { _, _ in
            model.clear()
            model.refreshAvailability()
        }
        .onChange(of: showSettings) { _, _ in model.refreshAvailability() }
        .onChange(of: model.submittedQuestion) { _, _ in showMeasurements = false }
        .onChange(of: model.explanation) { _, answer in
            if answer != nil { questionFocused = true }
        }
    }

    private var showsLocalReadinessNotice: Bool {
        useAI && generateExplanations && model.selectedBackend.isLocal
            && model.availabilityMessage != nil
    }

    private func reportContent(_ report: AskReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let answer = model.explanation {
                explanationContent(answer)
                DisclosureGroup("Current report", isExpanded: $showMeasurements) {
                    measuredReportContent(report).padding(.top, 12)
                }
            } else {
                measuredReportContent(report)
            }
        }
        .accessibilityIdentifier("ask.report")
    }

    private func measuredReportContent(_ report: AskReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(report.topic.title).font(.title3.weight(.semibold))
                Text(
                    model.explanation == nil && model.usedAI
                        ? "AI-selected report" : "Current report"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let sampledAt = report.sampledAt {
                    Text(sampledAt, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(report.summary)
            }
            ForEach(report.evidence) { evidence in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(evidence.title).fontWeight(.medium)
                        Spacer(minLength: 8)
                        Text(evidence.value).monospacedDigit()
                        Button {
                            openEvidence(evidence, report.topic)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Open evidence")
                        .accessibilityLabel(t("Open evidence for %@", evidence.title))
                    }
                    Text(evidence.detail).font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
            }
            if !report.limits.isEmpty {
                Text("Limits").font(.headline)
                ForEach(Array(report.limits.enumerated()), id: \.offset) { _, limit in
                    Text(limit).font(.callout).foregroundStyle(.secondary)
                }
            }
            Button {
                openEvidence(nil, report.topic)
            } label: {
                Label("Open evidence", systemImage: "arrow.up.forward.square")
            }
        }
        .accessibilityIdentifier("ask.measurements")
    }

    private func explanationContent(_ answer: AskExplanationDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Generated explanation").font(.headline)
                Spacer()
                Text((model.answerBackend ?? .apple).displayName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(answer.summary).font(.title3.weight(.medium))
            Text(answer.interpretation)
            ForEach(model.explanationFacts) { fact in
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.name).font(.caption)
                    Spacer(minLength: 8)
                    Text(fact.value).font(.caption.monospacedDigit())
                }
                .help(fact.meaning)
            }
            Text("What to check next").font(.subheadline.weight(.semibold))
            Text(answer.nextCheck)
                .accessibilityIdentifier("ask.next-check")
            Button {
                if answer.nextStep != .observe, let openNextStep {
                    openNextStep(answer.nextStep, model.suggestedProcess)
                    return
                }
                switch answer.nextStep {
                case .inspectProcesses: openEvidence(model.suggestedProcess, .memory)
                case .inspectDiskActivity: openEvidence(nil, .disk)
                case .openDiskMap: openEvidence(nil, .disk)
                case .openNetwork: openEvidence(nil, .network)
                case .observe:
                    model.question = model.submittedQuestion ?? AskTopic.overview.question
                    model.ask()
                }
            } label: {
                Label(answer.nextStep.title, systemImage: "arrow.up.forward.square")
            }
            Text("What remains uncertain").font(.subheadline.weight(.semibold))
            Text(answer.uncertainty).foregroundStyle(.secondary)
            Text("AI interpretation may be wrong. Check the measured evidence before acting.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
        }
        .accessibilityIdentifier("ask.explanation")
    }
}

struct AskPreviewSettingsSection: View {
    @AppStorage(AskPreviewPreferences.enabledKey) private var enabled = false
    @AppStorage(AskPreviewPreferences.onDeviceKey) private var useAI = false
    @AppStorage(AskPreviewPreferences.siriKey) private var shareWithSiri = false
    @AppStorage(AskPreviewPreferences.explanationsKey) private var generateExplanations = false
    @AppStorage(AskPreviewPreferences.backendKey) private var backend = AskInferenceBackend.apple
        .rawValue
    @ObservedObject private var localModels: AskLocalModelLibrary
    @State private var appleAvailabilityMessage = AskModelSupport.unavailabilityReason

    init(localModel: AskLocalModelStore? = nil, localModels: AskLocalModelLibrary? = nil) {
        self.localModels =
            localModels
            ?? localModel.map { AskLocalModelLibrary(stores: [$0.backend: $0]) }
            ?? .shared
    }

    var body: some View {
        Section {
            Toggle("Enable Ask preview", isOn: $enabled)
                .accessibilityIdentifier("ask.enable")
            if enabled {
                Toggle("Use on-device AI", isOn: $useAI)
                    .accessibilityIdentifier("ask.ai")
                Text("AI runs locally. Current reports remain available without a model download.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Generate explanations from evidence", isOn: $generateExplanations)
                    .disabled(!useAI)
                Text(
                    "The selected local model can request recorded performance data to investigate your question. Process names and query results stay on this Mac. Closing Ask clears the conversation."
                )
                .font(.caption).foregroundStyle(.secondary)
                if generateExplanations {
                    Picker("Explanation model", selection: $backend) {
                        Text("Apple on-device (default)").tag(AskInferenceBackend.apple.rawValue)
                        ForEach(AskInferenceBackend.allCases.filter(\.isLocal), id: \.self) {
                            choice in
                            Text(
                                choice.isExperimental
                                    ? t("%@ (experimental)", choice.displayName)
                                    : t("%@ (optional)", choice.displayName)
                            )
                            .tag(choice.rawValue)
                            .disabled(localModels.stores[choice]?.isEligible != true)
                        }
                    }
                    .accessibilityIdentifier("ask.model")
                    .disabled(!useAI || localModels.isInUse)
                    if let choice = AskInferenceBackend(rawValue: backend), choice.isLocal,
                        let store = localModels.stores[choice]
                    {
                        localControls(store)
                    } else {
                        Label(
                            appleAvailabilityMessage ?? t("Apple Intelligence is ready"),
                            systemImage: appleAvailabilityMessage == nil
                                ? "checkmark.circle" : "info.circle"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("ask.apple-availability")
                        Text(
                            "Apple's model is managed by macOS. No optional model download is needed."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Share current reports with Siri and Shortcuts", isOn: $shareWithSiri)
                    .accessibilityIdentifier("ask.siri")
                Text(
                    "Reports can include process names and resource use. Apple controls Siri processing. Shortcuts can pass results to other actions."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(
                    "Investigations are read-only. AI cannot run commands, delete files, or change settings."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Ask About This Mac (Preview)")
        }
        .onAppear {
            for store in localModels.stores.values { store.refresh() }
            appleAvailabilityMessage = AskModelSupport.unavailabilityReason
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            for store in localModels.stores.values { store.refresh() }
            appleAvailabilityMessage = AskModelSupport.unavailabilityReason
        }
        .onChange(of: enabled) { _, value in
            if !value {
                useAI = false
                shareWithSiri = false
                generateExplanations = false
                localModels.prepare(enabled: false, backend: .apple)
            } else {
                prepareModel()
            }
        }
        .onChange(of: useAI) { _, _ in prepareModel() }
        .onChange(of: generateExplanations) { _, _ in prepareModel() }
        .onChange(of: backend) { _, _ in prepareModel() }
    }

    @ViewBuilder
    private func localControls(_ localModel: AskLocalModelStore) -> some View {
        let choice = localModel.backend
        let size = ByteCountFormatter.string(
            fromByteCount: localModel.definition.downloadBytes, countStyle: .file)
        if localModel.isInstalled, let reason = localModel.unavailabilityReason {
            AskModelReadinessNotice(backend: choice, reason: reason) { localModel.refresh() }
        }
        if choice == .qwen {
            Text("When Qwen is selected, enabling explanations downloads its model (about 2.3 GB).")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Experimental. Not yet benchmarked for Mac diagnostics.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text(t("Download: %@. Requires at least 16 GB of RAM and normal memory pressure.", size))
            .font(.caption).foregroundStyle(.secondary)
        if choice == .deepAnalyze {
            Text("DeepAnalyze uses more memory than the 4B models.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !localModel.isEligible {
            Text(
                t(
                    "%@ is unavailable on this Mac. Apple on-device AI and current reports are unaffected.",
                    choice.displayName)
            )
            .font(.caption).foregroundStyle(.secondary)
        } else if localModel.isDownloading {
            ProgressView(value: localModel.progress)
            HStack {
                Text(
                    localModel.isVerifying
                        ? t("Verifying model files") : t("Downloading %@", choice.displayName)
                )
                .font(.caption)
                Spacer()
                Button {
                    localModel.cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Cancel model download")
                .accessibilityLabel("Cancel model download")
                .accessibilityIdentifier("ask.model.cancel")
            }
        } else if localModel.isInstalled {
            HStack {
                Label(t("%@ is downloaded", choice.displayName), systemImage: "checkmark.circle")
                Spacer()
                Button(role: .destructive) {
                    localModel.remove()
                } label: {
                    Label("Remove model", systemImage: "trash")
                }
                .disabled(localModel.isInUse)
                .accessibilityIdentifier("ask.model.remove")
            }
        } else {
            Button {
                localModel.download()
            } label: {
                Label(
                    t("Download %@ (%@)", choice.displayName, size),
                    systemImage: "arrow.down.circle")
            }
            .disabled(!useAI || localModels.isInUse)
            .accessibilityIdentifier("ask.model.download")
        }
        if let message = localModel.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func prepareModel() {
        appleAvailabilityMessage = AskModelSupport.unavailabilityReason
        localModels.prepare(
            enabled: enabled && useAI && generateExplanations,
            backend: AskInferenceBackend(rawValue: backend) ?? .apple)
    }
}

struct AskModelReadinessNotice: View {
    let backend: AskInferenceBackend
    let reason: String
    let recheck: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(t("%@ paused", backend.displayName)).font(.subheadline.weight(.semibold))
                Text(reason).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Current reports are still available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: recheck) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Check model readiness")
            .accessibilityLabel("Check model readiness")
            .accessibilityIdentifier("ask.readiness.recheck")
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .accessibilityIdentifier("ask.readiness.notice")
    }
}

private struct AskWindowLifecycle: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.onClose = onClose
        return host
    }

    func updateNSView(_ view: Host, context: Context) {
        view.onClose = onClose
    }

    final class Host: NSView {
        var onClose: (() -> Void)?
        private var subscription: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            subscription = nil
            guard let window else { return }
            subscription = NotificationCenter.default.publisher(
                for: NSWindow.willCloseNotification, object: window
            ).sink { [weak self] _ in self?.onClose?() }
        }
    }
}
