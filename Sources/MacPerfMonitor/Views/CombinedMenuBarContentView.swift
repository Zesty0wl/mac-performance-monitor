import AppKit
import MacPerfMonitorCore
import SwiftUI

@MainActor
final class CombinedMenuBarPanelSelection: ObservableObject {
    @Published var metric: MenuBarMetric

    init(metric: MenuBarMetric) {
        self.metric = metric
    }
}

struct CombinedMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var configuration: CombinedMenuBarConfiguration
    @EnvironmentObject private var updateController: UpdateController
    @EnvironmentObject private var menuClock: MenuClock
    @EnvironmentObject private var appMode: AppModeManager

    @ObservedObject var selection: CombinedMenuBarPanelSelection

    let selectionChanged: (MenuBarMetric) -> Void
    let dismiss: () -> Void

    init(
        selection: CombinedMenuBarPanelSelection,
        selectionChanged: @escaping (MenuBarMetric) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.selection = selection
        self.selectionChanged = selectionChanged
        self.dismiss = dismiss
    }

    var body: some View {
        _ = menuClock.tick
        return VStack(alignment: .leading, spacing: 10) {
            metricSelector
            if !model.activeAlertKinds.isEmpty {
                alarmSummary
            }
            Divider()
            metricContent
                .id(selection.metric)
            Divider()
            commandBar
            MenuVersionFooter()
        }
        .padding(12)
        .frame(width: 404)
        .onAppear {
            menuClock.open()
            selectionChanged(selection.metric)
        }
        .onDisappear { menuClock.close() }
        .onChange(of: selection.metric) { _, metric in selectionChanged(metric) }
    }

    private var metricSelector: some View {
        let readouts = Dictionary(
            uniqueKeysWithValues: CombinedMenuBarReadouts.current(
                for: MenuBarMetric.allCases, model: model
            ).map { ($0.metric, $0) })
        return HStack(spacing: 0) {
            ForEach(MenuBarMetric.allCases) { metric in
                let readout = readouts[metric]
                Button {
                    selection.metric = metric
                } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Text(metric.shortTitle)
                                .font(.caption2.weight(.semibold))
                            Circle()
                                .frame(width: 4, height: 4)
                                .opacity(configuration.isSelected(metric) ? 1 : 0)
                                .accessibilityHidden(true)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .frame(width: 10)
                                .opacity(readout?.isAlarm == true ? 1 : 0)
                                .accessibilityHidden(readout?.isAlarm != true)
                        }
                        if let secondary = readout?.secondaryValue {
                            VStack(spacing: -2) {
                                Text(readout?.value ?? "--")
                                Text(secondary)
                            }
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                        } else {
                            Text(readout?.value ?? "--")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        selection.metric == metric ? Color.accentColor.opacity(0.16) : .clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help(
                    configuration.isSelected(metric)
                        ? "\(metric.title), shown in the menu bar"
                        : metric.title
                )
                .accessibilityLabel(metric.title)
                .accessibilityValue(readout?.value ?? "Unavailable")
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.22)))
    }

    private var alarmSummary: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(alarmText)
                .lineLimit(2)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var alarmText: String {
        let kinds = model.activeAlertKinds
        var labels: [String] = []
        if kinds.contains(.criticalPressure) { labels.append("critical memory pressure") }
        if kinds.contains(.swap) { labels.append("heavy swap use") }
        if kinds.contains(.processCeiling) { labels.append("memory ceiling") }
        if kinds.contains(.leak) { labels.append("possible memory leak") }
        if kinds.contains(.highCPU) { labels.append("sustained high CPU") }
        return labels.joined(separator: " · ")
    }

    @ViewBuilder private var metricContent: some View {
        switch selection.metric {
        case .pressure:
            MenuBarContentView(embedded: true)
        case .cpu:
            CPUMenuBarContentView(dismiss: dismiss, embedded: true)
        case .gpu:
            GPUMenuBarContentView(dismiss: dismiss, embedded: true)
        case .energy:
            BatteryMenuBarContentView(dismiss: dismiss, embedded: true)
        case .network:
            NetworkMenuBarContentView(dismiss: dismiss, embedded: true)
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
                appState.requestedMainTab = openDestination
                NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(openTitle, systemImage: "macwindow")
            }

            Button {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .macperfmonitorShowSettings, object: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Spacer()

            Menu {
                Button(
                    appMode.mode == .full ? "Pause history logging" : "Resume history logging",
                    systemImage: appMode.mode == .full ? "pause.circle" : "record.circle"
                ) {
                    appMode.mode = appMode.mode == .full ? .menuBarOnly : .full
                }
                Divider()
                Button("About \(AppInfo.displayName)", systemImage: "info.circle") {
                    dismiss()
                    showStandardAboutPanel()
                }
                Button("Check for Updates...", systemImage: "arrow.down.circle") {
                    dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
                Divider()
                Button("Quit \(AppInfo.displayName)", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton)
            .help("More actions")
        }
        .buttonStyle(.borderless)
    }

    private var openDestination: MainWindowTab {
        switch selection.metric {
        case .cpu: return .processes
        case .energy: return .battery
        case .network: return .network
        case .pressure, .gpu: return .dashboard
        }
    }

    private var openTitle: String {
        switch openDestination {
        case .processes: return "Open Processes"
        case .battery: return "Open Energy"
        case .network: return "Open Network"
        case .dashboard: return "Open Dashboard"
        default: return "Open"
        }
    }
}
