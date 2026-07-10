import SwiftUI

/// The first-run education flow (PRD 8.9). Three short, skippable screens that
/// teach the pressure-first mental model: free RAM is not the metric, cached
/// files are good, and sustained compression and swap are the real signals.
/// Re-openable any time from the menu, so it is a calm explainer rather than a
/// gate.
struct OnboardingView: View {
    @EnvironmentObject private var onboarding: OnboardingState
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0

    /// The ordered steps: the education screens (unless the user has already seen
    /// them — see `autoConfigOnly`) followed by the interactive setup steps.
    private var steps: [OnboardingStep] {
        var result: [OnboardingStep] = []
        if !onboarding.autoConfigOnly {
            result += OnboardingPage.all.map(OnboardingStep.info)
        }
        result += [.mode, .permissions, .menuBar]
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(page)
                .transition(pageTransition)

            footer
                .padding(20)
        }
        .frame(width: 520, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        // Reset the transient "config only" hint so a later manual replay from the
        // menu shows the full flow again.
        .onDisappear { onboarding.autoConfigOnly = false }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch steps[min(page, steps.count - 1)] {
        case .info(let pageModel):
            OnboardingPageView(page: pageModel)
        case .mode:
            OnboardingModeStep()
        case .permissions:
            OnboardingPermissionsStep()
        case .menuBar:
            OnboardingMenuBarStep()
        }
    }

    /// Slide-and-fade between screens, suppressed under Reduce Motion.
    private var pageTransition: AnyTransition {
        Motion.reduced
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity))
    }

    private var footer: some View {
        HStack {
            Button("Skip") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isLastPage ? 0 : 1)
                .disabled(isLastPage)
                .accessibilityHidden(isLastPage)

            Spacer()

            PageDots(count: steps.count, current: page)

            Spacer()

            Button(isLastPage ? "Get started" : "Next") {
                if isLastPage {
                    finish()
                } else {
                    withOptionalAnimation { page += 1 }
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var isLastPage: Bool { page >= steps.count - 1 }

    private func finish() {
        onboarding.complete()
        onboarding.autoConfigOnly = false
        dismiss()
    }

    /// Animate page changes unless the user has asked for reduced motion.
    private func withOptionalAnimation(_ body: () -> Void) {
        if Motion.reduced {
            body()
        } else {
            withAnimation(.easeInOut(duration: 0.25), body)
        }
    }
}

/// One step in the first-run flow: an education screen or an interactive setup
/// step.
private enum OnboardingStep {
    case info(OnboardingPage)
    case mode
    case permissions
    case menuBar
}

/// One educational screen: a symbol, a title, and a short explanation.
private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: page.symbol)
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(page.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(page.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(page.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(page.title). \(page.body)")
    }
}

/// The page indicator dots.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(
                        index == current ? Color.accentColor : Color(nsColor: .quaternaryLabelColor)
                    )
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The content of one onboarding screen.
struct OnboardingPage {
    let symbol: String
    let tint: Color
    let title: String
    let body: String

    static let all: [OnboardingPage] = [
        OnboardingPage(
            symbol: "gauge.with.dots.needle.50percent",
            tint: .green,
            title: "Watch pressure, not free RAM",
            body: """
                On Apple silicon, almost no RAM is ever “free”, and that is normal. \
                macOS keeps memory busy on purpose. What matters is memory pressure: \
                how hard the system is working to keep up. \(AppInfo.displayName) puts that front \
                and centre.
                """),
        OnboardingPage(
            symbol: "externaldrive.badge.checkmark",
            tint: .teal,
            title: "Cached files are a good thing",
            body: """
                Much of your “used” memory is cached files: recently used data kept \
                around to make things fast. macOS hands it back the instant something \
                needs it. \(AppInfo.displayName) shows cached files in a calm colour so you know \
                it is working for you, not against you.
                """),
        OnboardingPage(
            symbol: "arrow.down.circle",
            tint: .orange,
            title: "Compression and swap are the real signals",
            body: """
                When pressure stays high, macOS compresses memory and then writes to \
                swap. A little is fine; a lot, sustained, is the sign that something \
                is asking for too much. \(AppInfo.displayName) watches these trends and points to \
                the process responsible.
                """),
    ]
}

// MARK: - Setup steps

/// Shared scaffold for an interactive setup step: a symbol, a title, a short
/// subtitle, and the step's controls, laid out to match the education screens.
private struct OnboardingStepScaffold<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            Spacer(minLength: 8)
        }
    }
}

/// One labelled switch row used by the setup steps.
private struct OnboardingToggleRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
        }
        .toggleStyle(.switch)
    }
}

/// Step 1: choose the function mode (full history vs menu-bar-only).
private struct OnboardingModeStep: View {
    @EnvironmentObject private var appMode: AppModeManager

    var body: some View {
        OnboardingStepScaffold(
            symbol: "switch.2", tint: .blue,
            title: "Choose how it runs",
            subtitle: "You can switch anytime — in Settings or from the menu bar."
        ) {
            VStack(spacing: 10) {
                ForEach(AppMode.allCases, id: \.self) { mode in
                    OnboardingModeCard(mode: mode, isSelected: appMode.mode == mode) {
                        appMode.mode = mode
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

/// A single selectable mode card.
private struct OnboardingModeCard: View {
    let mode: AppMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title).font(.headline)
                    Text(mode.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.title). \(mode.summary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Step 2: the two optional permissions — open at login and full coverage.
private struct OnboardingPermissionsStep: View {
    @EnvironmentObject private var loginItem: LoginItemManager
    @EnvironmentObject private var helper: HelperManager

    var body: some View {
        OnboardingStepScaffold(
            symbol: "checkmark.shield", tint: .teal,
            title: "Set up access",
            subtitle: "Both are optional and can be changed later in Settings."
        ) {
            VStack(spacing: 12) {
                OnboardingToggleRow(
                    symbol: "power",
                    title: "Open at login",
                    subtitle:
                        "Start in the menu bar and keep history unbroken from the moment you sign in.",
                    isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { $0 ? loginItem.enable() : loginItem.disable() }))

                if helper.coverage != .unavailable {
                    OnboardingToggleRow(
                        symbol: "lock.shield",
                        title: "Show every process",
                        subtitle: helperSubtitle,
                        isOn: Binding(
                            get: {
                                helper.coverage == .enabled || helper.coverage == .requiresApproval
                            },
                            set: { $0 ? helper.enable() : helper.disable() }))

                    if helper.coverage == .requiresApproval {
                        Button("Open System Settings…") { helper.openApprovalSettings() }
                            .controlSize(.small)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var helperSubtitle: String {
        switch helper.coverage {
        case .requiresApproval:
            return "Approve the helper in System Settings to finish enabling it."
        case .enabled:
            return "Full coverage is on — even system processes are visible."
        default:
            return
                "Install a small privileged helper so \(AppInfo.displayName) can read system and other-user processes."
        }
    }
}

/// Step 3: which combined menu-bar read-outs to show, the optional Dock icon, and the
/// refresh interval.
private struct OnboardingMenuBarStep: View {
    @EnvironmentObject private var menuBar: CombinedMenuBarConfiguration
    @AppStorage(DockIconController.defaultsKey) private var showDockIcon = false
    @AppStorage(SamplerModel.tableIntervalKey) private var tableInterval =
        SamplerModel.defaultTableInterval

    var body: some View {
        OnboardingStepScaffold(
            symbol: "menubar.rectangle", tint: .orange,
            title: "Menu bar & refresh",
            subtitle: "Choose what the single compact menu bar item shows."
        ) {
            VStack(spacing: 12) {
                Picker("Presentation", selection: presentationBinding) {
                    ForEach(MenuBarPresentation.allCases) { presentation in
                        Text(presentation.title).tag(presentation)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(MenuBarMetric.allCases) { metric in
                    OnboardingToggleRow(
                        symbol: metric.symbolName, title: metric.title,
                        subtitle: metricSubtitle(metric), isOn: selectionBinding(metric)
                    )
                    .disabled(menuBar.isSelected(metric) && menuBar.selectedMetrics.count == 1)
                }

                OnboardingToggleRow(
                    symbol: "dock.rectangle", title: "Dock icon",
                    subtitle: "Also show \(AppInfo.displayName) in the Dock.", isOn: $showDockIcon)

                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text("Refresh interval")
                    Spacer(minLength: 8)
                    Picker("Refresh interval", selection: $tableInterval) {
                        ForEach(SamplerModel.tableIntervalChoices, id: \.self) { seconds in
                            Text(SamplerModel.tableIntervalLabel(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.top, 4)
        }
    }

    private var presentationBinding: Binding<MenuBarPresentation> {
        Binding(get: { menuBar.presentation }, set: { menuBar.presentation = $0 })
    }

    private func selectionBinding(_ metric: MenuBarMetric) -> Binding<Bool> {
        Binding(
            get: { menuBar.isSelected(metric) },
            set: { menuBar.setSelected(metric, isSelected: $0) })
    }

    private func metricSubtitle(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .pressure: return "Memory pressure and the largest processes."
        case .cpu: return "Total CPU, every core, and top CPU processes."
        case .gpu: return "GPU activity, power, memory, and temperature."
        case .energy: return "Charge, power flow, and top energy users."
        case .network: return "Download, upload, latency, and top network apps."
        }
    }
}
