import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The energy menubar dropdown (window style). On a laptop: a charge + power
/// header, a one-line power-flow summary, the top energy-using apps, a health
/// snippet, and actions. On a desktop (no battery): a bolt header, the top
/// energy users, and actions. Tapping the header, the power summary, or the
/// energy list opens the main window's Energy tab. The CPU/memory twins live in
/// `CPUMenuBarContentView` / `MenuBarContentView`; the three share the row
/// affordances and action buttons.
struct BatteryMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updateController: UpdateController
    @EnvironmentObject private var menuClock: MenuClock

    /// Called after an action so the host (the AppKit popover) can dismiss.
    var dismiss: () -> Void = {}
    var embedded = false

    var body: some View {
        // Re-render once a second while the popover is open (independently of the
        // main window's refresh rate). Depend on the clock's tick and drive its
        // open/close from this view's lifecycle — the status-item popover delegate
        // callbacks do not fire reliably (which left the dropdowns at the global
        // rate).
        _ = menuClock.tick
        return
            panel
            .onAppear { if !embedded { menuClock.open() } }
            .onDisappear { if !embedded { menuClock.close() } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let battery = model.latestBattery, battery.isPresent {
                header(battery)
                chargeChart(battery)
                Divider()
                powerSummary(battery)
                Divider()
                topEnergy
                Divider()
                healthRow(battery)
                if !embedded {
                    Divider()
                    actions
                }
            } else if model.liveSystem == nil {
                Text("Reading energy\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                // Desktop: no battery, but the energy leaderboard still matters.
                desktopHeader
                powerChart
                Divider()
                topEnergy
                if !embedded {
                    Divider()
                    actions
                }
            }
            if !embedded { MenuVersionFooter() }
        }
        .padding(embedded ? 0 : 12)
        .frame(width: embedded ? nil : 360)
    }

    /// The header for a Mac with no battery: the measured system power (or just a
    /// bolt before the first reading), with an "on power adapter" note. Tapping it
    /// opens the Energy tab.
    private var desktopHeader: some View {
        let watts = model.latestBattery?.systemPowerWatts ?? 0
        return Button(action: openBattery) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(BatteryStyle.consumer)
                    .imageScale(.small)
                if watts > 0 {
                    Text(BatteryFormat.watts(watts))
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text("system power")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Energy").font(.headline)
                }
                Spacer()
                Text("On power adapter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Open the Energy tab")
    }

    // MARK: - Trend charts

    /// Charge over the recent window as a line on a fixed 0–100 scale — matching
    /// the CPU/memory/network header style. Absolute (not peak-relative) so a
    /// steady 80 % reads as a flat line near the top, sloping down while draining /
    /// up while charging.
    @ViewBuilder private func chargeChart(_ battery: BatterySample) -> some View {
        let level = BatteryLevel(percent: battery.chargePercent)
        MenuTrendChart(
            values: model.batteryChargeTrail(),
            color: battery.isCharging ? BatteryStyle.battery : level.color,
            domain: 0...100, ticks: [0, 50, 100], label: { "\(Int($0))" }
        )
        .frame(height: MenuChart.height)
    }

    /// Whole-machine power draw as a line on a rounded auto-peak scale, matching
    /// the CPU/memory/network header style. Shown on the desktop (no-battery)
    /// header, where the charge line has nothing to plot; hidden when the SMC
    /// exposes no telemetry.
    @ViewBuilder private var powerChart: some View {
        let watts = model.systemPowerTrail()
        if let peak = watts.max(), peak > 0 {
            let upper = MenuChart.niceUpperBound(peak)
            MenuTrendChart(
                values: watts, color: BatteryStyle.consumer,
                domain: 0...upper, ticks: [0, upper], label: { "\(Int($0.rounded())) W" }
            )
            .frame(height: MenuChart.height)
        }
    }

    // MARK: - Header

    private func header(_ battery: BatterySample) -> some View {
        let level = BatteryLevel(percent: battery.chargePercent)
        return Button(action: openBattery) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: battery.isCharging ? "battery.100.bolt" : level.symbolName)
                        .foregroundStyle(battery.isCharging ? BatteryStyle.battery : level.color)
                        .imageScale(.small)
                    Text(BatteryFormat.percent(battery.chargePercent))
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 58, alignment: .leading)
                    Text(stateWord(battery))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(battery.isCharging ? BatteryStyle.battery : level.color)
                    Spacer()
                    Text(timeRemaining(battery))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Open the Energy tab")
    }

    private func stateWord(_ battery: BatterySample) -> String {
        if battery.isCharging { return "Charging" }
        if battery.isOnAC { return battery.chargePercent >= 99 ? "Full" : "Plugged in" }
        return "On battery"
    }

    private func timeRemaining(_ battery: BatterySample) -> String {
        if battery.isCharging, let m = battery.timeToFullMinutes, m > 0 {
            return BatteryFormat.duration(minutes: m) + " to full"
        }
        if !battery.isOnAC, let m = battery.timeToEmptyMinutes, m > 0 {
            return BatteryFormat.duration(minutes: m) + " left"
        }
        return ""
    }

    // MARK: - Power summary

    private func powerSummary(_ battery: BatterySample) -> some View {
        Button(action: openBattery) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(powerLine(battery))
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .help("Open the Energy tab")
    }

    private func powerLine(_ battery: BatterySample) -> String {
        if battery.isCharging {
            var s = "+" + BatteryFormat.watts(battery.powerWatts) + " into battery"
            if let w = battery.adapterWatts { s += " · \(w) W adapter" }
            return s
        }
        if battery.isOnAC {
            if let w = battery.adapterWatts { return "On \(w) W adapter" }
            return "On power adapter"
        }
        return BatteryFormat.watts(battery.powerWatts) + " drawing from battery"
    }

    // MARK: - Top energy

    private var topEnergy: some View {
        let top = Array(menuLists.topEnergy.prefix(6))
        let maxEnergy = max(top.first?.energyImpact ?? 1, 0.001)
        return Button(action: openBattery) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Top energy users")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                if top.isEmpty {
                    Text("Sampling\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(top) { process in
                        energyRow(process, maxEnergy: maxEnergy)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .help("Open the Energy tab")
    }

    private func energyRow(_ process: ProcessSample, maxEnergy: Double) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            Text(process.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule()
                .fill(BatteryStyle.consumer.opacity(0.7))
                .frame(width: max(3, 60 * process.energyImpact / maxEnergy), height: 5)
                .frame(width: 60, alignment: .leading)
            Text(String(format: "%.0f", process.energyImpact))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Health

    private func healthRow(_ battery: BatterySample) -> some View {
        HStack(spacing: 10) {
            if let health = battery.healthPercent {
                Text("\(Int(health.rounded()))% health")
                    .foregroundStyle(.secondary)
            }
            if let cycles = battery.cycleCount {
                Text("\(cycles) cycles")
                    .foregroundStyle(.secondary)
            }
            if let temp = battery.temperatureCelsius {
                Text(BatteryFormat.celsius(temp))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption.monospacedDigit())
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 2) {
            MenuActionButton(title: "Open Energy", systemImage: "bolt.fill") {
                openBattery()
            }
            MenuActionButton(title: "Settings\u{2026}", systemImage: "gearshape") {
                openSettings()
            }
            MenuActionButton(title: "About \(AppInfo.displayName)", systemImage: "info.circle") {
                dismiss()
                showStandardAboutPanel()
            }
            MenuActionButton(title: "Check for Updates\u{2026}", systemImage: "arrow.down.circle") {
                checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
            MenuActionButton(title: "Quit \(AppInfo.displayName)", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - AppKit-hosted actions

    /// Open the main window on the Battery tab: set the navigation signal the
    /// main window observes, then surface the window. Posting through the same
    /// notification the CPU panel uses keeps the open path in one place.
    private func openBattery() {
        dismiss()
        appState.showBatteryTab = true
        NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .macperfmonitorShowSettings, object: nil)
    }

    /// Sparkle presents its own update window, so this needs no SwiftUI scene —
    /// just dismiss the popover and bring the app forward so that window is key.
    private func checkForUpdates() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        updateController.checkForUpdates()
    }
}
