import AppKit
import MacPerfMonitorCore
import SwiftUI

enum CombinedMenuBarPanel: Hashable {
    case metric(MenuBarMetric)
    case alerts
}

@MainActor
final class CombinedMenuBarPanelSelection: ObservableObject {
    @Published var panel: CombinedMenuBarPanel

    init(panel: CombinedMenuBarPanel) {
        self.panel = panel
    }
}

struct CombinedMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var configuration: CombinedMenuBarConfiguration
    @EnvironmentObject private var updateController: UpdateController
    @EnvironmentObject private var menuClock: MenuClock
    @EnvironmentObject private var components: AppComponentsManager
    @EnvironmentObject private var notchDisplay: NotchDisplayController

    @ObservedObject var selection: CombinedMenuBarPanelSelection

    let selectionChanged: (CombinedMenuBarPanel) -> Void
    let dismiss: () -> Void

    init(
        selection: CombinedMenuBarPanelSelection,
        selectionChanged: @escaping (CombinedMenuBarPanel) -> Void,
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
            alarmSummary
            Divider()
            metricContent
                .id(selection.panel)
            Divider()
            commandBar
            MenuVersionFooter()
        }
        .padding(12)
        .frame(width: 404)
        .onAppear {
            menuClock.open()
            selectionChanged(selection.panel)
        }
        .onDisappear { menuClock.close() }
        .onChange(of: selection.panel) { _, panel in selectionChanged(panel) }
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
                    selection.panel = .metric(metric)
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
                        selection.panel == .metric(metric)
                            ? Color.accentColor.opacity(0.16) : .clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                // Built with t() rather than interpolated: `metric.title` is a
                // String, so the ternary types as String and the interpolated
                // literal would never be looked up, leaving ", shown in the menu
                // bar" in English beside an already-translated title.
                .help(
                    configuration.isSelected(metric)
                        ? t("%@, shown in the menu bar", metric.title)
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
        Button {
            selection.panel = .alerts
        } label: {
            HStack(spacing: 7) {
                Image(
                    systemName: model.activeAlerts.isEmpty
                        ? (model.alertObservations.isEmpty ? "checkmark.circle" : "eye")
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.activeAlerts.isEmpty ? Color.secondary : .red)
                Text("Alerts")
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if !model.alertObservations.isEmpty {
                    Text(t("Observations: %@", String(model.alertObservations.count)))
                        .foregroundStyle(.secondary)
                }
                Text(model.activeAlerts.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selection.panel == .alerts
                ? Color.accentColor.opacity(0.12)
                : Color.red.opacity(model.activeAlerts.isEmpty ? 0 : 0.08),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .accessibilityIdentifier("menubar.alerts.open")
    }

    @ViewBuilder private var metricContent: some View {
        switch selection.panel {
        case .alerts:
            AlertsMenuBarContentView(
                alerts: model.activeAlerts, processes: model.displayProcesses,
                observations: model.alertObservations,
                inspectAlert: { alert in
                    guard let request = AlertInvestigation(alerts: [alert]) else { return }
                    dismiss()
                    appState.alertInvestigation = request
                    appState.requestedMainTab = .analytics
                    NotificationCenter.default.post(
                        name: .macperfmonitorShowMainWindow, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }, snooze: { id, seconds in model.snoozeAlert(id, seconds: seconds) }
            ) { identity in
                dismiss()
                appState.navigationTarget = identity
                appState.requestedMainTab = .processes
                NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        case .metric(.pressure):
            MenuBarContentView(embedded: true)
        case .metric(.cpu):
            CPUMenuBarContentView(dismiss: dismiss, embedded: true)
        case .metric(.gpu):
            GPUMenuBarContentView(dismiss: dismiss, embedded: true)
        case .metric(.energy):
            BatteryMenuBarContentView(dismiss: dismiss, embedded: true)
        case .metric(.network):
            NetworkMenuBarContentView(dismiss: dismiss, embedded: true)
        case .metric(.disk):
            DiskMenuBarContentView(dismiss: dismiss)
        case .metric(.temperature):
            TemperatureMenuBarContentView(embedded: true)
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
                Button("Ask About This Mac (Preview)", systemImage: "sparkles") {
                    dismiss()
                    WindowOpenBridge.shared.open(id: WindowID.ask)
                }
                Divider()
                Button(
                    LocalizedStringKey(
                        components.historyLogging
                            ? "Pause history logging" : "Resume history logging"),
                    systemImage: components.historyLogging ? "pause.circle" : "record.circle"
                ) {
                    components.historyLogging.toggle()
                }
                // Only on Macs that have a notch to hide. Status items are confined
                // to the menu bar right of it, so on a crowded bar this is what
                // makes room for them; see `NotchDisplayController`.
                if notchDisplay.isSupported {
                    Button(
                        LocalizedStringKey(
                            notchDisplay.isNotchHidden ? "Show Notch" : "Hide Notch"),
                        systemImage: "menubar.rectangle"
                    ) {
                        dismiss()
                        notchDisplay.setNotchHidden(!notchDisplay.isNotchHidden)
                    }
                    .help(
                        notchDisplay.isNotchHidden
                            ? "Use the full height of the display again, with the menu bar either side of the camera housing."
                            : "Drop the menu bar below the camera housing so it runs edge to edge and fits more items. Costs a little screen height, and applies to every app."
                    )
                }
                Divider()
                Button("About \(AppInfo.displayName)", systemImage: "info.circle") {
                    dismiss()
                    showStandardAboutPanel()
                }
                Button("Check for Updates\u{2026}", systemImage: "arrow.down.circle") {
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
        switch selection.panel {
        case .alerts: return .insights
        case .metric(.cpu): return .processes
        case .metric(.energy): return .battery
        case .metric(.network): return .network
        case .metric(.disk): return .diskUsage
        case .metric(.gpu): return .gpu
        case .metric(.pressure): return .dashboard
        // The Thermals section lives on the Energy tab.
        case .metric(.temperature): return .battery
        }
    }

    private var openTitle: LocalizedStringKey {
        switch openDestination {
        case .processes: return "Open Processes"
        case .battery: return "Open Energy"
        case .network: return "Open Network"
        case .diskUsage: return "Open Disk"
        case .gpu: return "Open GPU"
        case .dashboard: return "Open Dashboard"
        case .insights: return "Open Insights"
        default: return "Open"
        }
    }
}
