import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The energy menubar dropdown (window style). On a laptop: a charge header
/// that says how long the battery lasts, how long until it is charged, or why
/// it is not charging; a stacked chart of where the power comes from; the top
/// energy-using apps, a health snippet, and actions. On a desktop (no battery): a bolt header, the top
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
                let status = BatteryChargeStatus(battery)
                header(battery, status)
                if let note = statusNote(battery, status) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(statusHelp(status) ?? "")
                }
                powerFlow(battery, status)
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

    /// Where the power has come from over the recent window, as stacked bands:
    /// blue for what the adapter supplies to the Mac, green for what the
    /// battery supplies, and green on top for what goes into the battery while
    /// it charges. A legend underneath gives the current figures. Falls back
    /// to the charge line on a Mac that reports no power figures.
    @ViewBuilder private func powerFlow(
        _ battery: BatterySample, _ status: BatteryChargeStatus
    ) -> some View {
        let flow = model.batteryPowerFlow()
        if flow.isEmpty {
            chargeChart(battery)
            Divider()
            powerSummary(battery)
        } else {
            let upper = MenuChart.niceUpperBound(flow.peak)
            let legend = flowLegend(flow, battery, status)
            Button(action: openBattery) {
                VStack(alignment: .leading, spacing: 6) {
                    MenuBitmapChart(
                        model: .init(
                            series: [
                                .init(
                                    values: flow.adapterTop, color: BatteryStyle.charger,
                                    smooth: false, gradient: false),
                                .init(
                                    values: flow.batteryTop, color: BatteryStyle.battery,
                                    smooth: false, gradient: false, floor: flow.batteryFloor),
                                .init(
                                    values: flow.chargingTop, color: BatteryStyle.battery,
                                    smooth: false, gradient: false, floor: flow.chargingFloor),
                            ],
                            domain: 0...upper, capacity: model.systemHistory.capacity,
                            ticks: [0, upper], labels: ["0", "\(Int(upper.rounded())) W"],
                            gutter: MenuChart.gutter, accessibilityLabel: t("Power"),
                            accessibilityValue: legend.items.map(\.text).joined(separator: ", "))
                    )
                    .frame(height: MenuChart.height)
                    // The trailing figure gives way first when a translation
                    // runs long.
                    ViewThatFits(in: .horizontal) {
                        legendRow(legend.items, trailing: legend.trailing)
                        legendRow(legend.items, trailing: nil)
                    }
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Open the Energy tab")
        }
    }

    private func legendRow(_ items: [LegendItem], trailing: String?) -> some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.text) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 6, height: 6)
                    Text(item.text)
                }
            }
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).foregroundStyle(.secondary)
            }
        }
    }

    private struct LegendItem {
        var color: Color
        var text: String
    }

    /// The legend under the power chart: the current flows, in the chart's
    /// colours, and on the right when the battery runs out or the adapter size.
    private func flowLegend(
        _ flow: BatteryPowerFlow, _ battery: BatterySample, _ status: BatteryChargeStatus
    ) -> (items: [LegendItem], trailing: String?) {
        let now = flow.latest
        var items: [LegendItem] = []
        // While charging the adapter feeds both bands, so name where each
        // goes; otherwise the Mac is the only consumer, so name the sources.
        if now.fromAdapter > 0 {
            let watts = BatteryFormat.watts(now.fromAdapter)
            items.append(
                .init(
                    color: BatteryStyle.charger,
                    text: now.intoBattery > 0 ? t("%@ to Mac", watts) : t("%@ from adapter", watts))
            )
        }
        if now.fromBattery > 0 {
            items.append(
                .init(
                    color: BatteryStyle.battery,
                    text: t("%@ from battery", BatteryFormat.watts(now.fromBattery))))
        }
        if now.intoBattery > 0 {
            items.append(
                .init(
                    color: BatteryStyle.battery,
                    text: t("%@ into battery", BatteryFormat.watts(now.intoBattery))))
        }
        if items.isEmpty {
            items.append(.init(color: BatteryStyle.charger, text: t("On power adapter")))
        }
        var trailing: String?
        if case .onBattery(let minutes?) = status, minutes > 0 {
            let empty = Date().addingTimeInterval(minutes * 60)
            trailing = t("Until about %@", empty.formatted(date: .omitted, time: .shortened))
        } else if battery.isOnAC, let watts = battery.adapterWatts {
            trailing = t("%@ W adapter", String(watts))
        }
        return (items, trailing)
    }

    /// Charge over the recent window as a line on a fixed 0–100 scale — matching
    /// the CPU/memory/network header style. Absolute (not peak-relative) so a
    /// steady 80 % reads as a flat line near the top, sloping down while draining /
    /// up while charging.
    @ViewBuilder private func chargeChart(_ battery: BatterySample) -> some View {
        let level = BatteryLevel(percent: battery.chargePercent)
        MenuTrendChart(
            values: model.batteryChargeTrail(),
            sampleCapacity: model.systemHistory.capacity,
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
                values: watts, sampleCapacity: model.systemHistory.capacity,
                color: BatteryStyle.consumer,
                domain: 0...upper, ticks: [0, upper], label: { "\(Int($0.rounded())) W" }
            )
            .frame(height: MenuChart.height)
        }
    }

    // MARK: - Header

    private func header(_ battery: BatterySample, _ status: BatteryChargeStatus) -> some View {
        let level = BatteryLevel(percent: battery.chargePercent)
        let tint = stateColor(status, level: level)
        return Button(action: openBattery) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: stateSymbol(status, level: level))
                    .foregroundStyle(tint)
                    .imageScale(.small)
                Text(BatteryFormat.percent(battery.chargePercent))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 58, alignment: .leading)
                Text(stateWord(status))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tint)
                Spacer()
                Text(stateDetail(status))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Open the Energy tab")
    }

    private func stateWord(_ status: BatteryChargeStatus) -> String {
        switch status {
        case .onBattery: return t("On battery")
        case .charging: return t("Charging")
        case .onHold: return t("Charging on hold")
        case .charged: return t("Battery full")
        case .adapterShortfall: return t("Plugged in")
        case .notCharging: return t("Not charging")
        }
    }

    private func stateSymbol(_ status: BatteryChargeStatus, level: BatteryLevel) -> String {
        switch status {
        case .onBattery: return level.symbolName
        case .charging, .charged: return "battery.100.bolt"
        case .onHold, .adapterShortfall, .notCharging: return "powerplug.fill"
        }
    }

    private func stateColor(_ status: BatteryChargeStatus, level: BatteryLevel) -> Color {
        switch status {
        case .onBattery: return level.color
        case .charging, .charged: return BatteryStyle.battery
        case .onHold: return BatteryStyle.charger
        case .adapterShortfall, .notCharging: return BatteryStyle.consumer
        }
    }

    /// The figure on the right of the header: time left on battery, or time
    /// to full (or to the hold's limit) while charging.
    private func stateDetail(_ status: BatteryChargeStatus) -> String {
        switch status {
        case .onBattery(let minutes?) where minutes > 0:
            return t("%@ left", BatteryFormat.duration(minutes: Int(minutes.rounded())))
        case .charging(100, let minutes?) where minutes > 0:
            return t("%@ to full", BatteryFormat.duration(minutes: Int(minutes.rounded())))
        case .charging(let target, let minutes?) where minutes > 0:
            return t(
                "%1$@ in %2$@", BatteryFormat.percent(Double(target)),
                BatteryFormat.duration(minutes: Int(minutes.rounded())))
        default:
            return ""
        }
    }

    /// The tooltip on the note: how to get past an Optimised Battery Charging
    /// hold, which macOS offers only from its own battery menu.
    private func statusHelp(_ status: BatteryChargeStatus) -> String? {
        guard case .onHold(let hold) = status, hold.reason == .optimizedCharging else { return nil }
        return t(
            "To charge to 100% now, choose Charge to Full Now from the battery menu in the menu bar."
        )
    }

    /// A sentence under the header when the state needs explaining: why a
    /// plugged-in battery is not charging, or where charging will stop.
    private func statusNote(_ battery: BatterySample, _ status: BatteryChargeStatus) -> String? {
        switch status {
        case .onHold(let hold):
            let limit = BatteryFormat.percent(Double(hold.limitPercent))
            switch hold.reason {
            case .optimizedCharging:
                return t(
                    "Optimised Battery Charging is waiting at %@ and will finish charging before you usually unplug.",
                    limit)
            case .chargeLimit:
                return t("Charging stops at %@, the charge limit set in Battery settings.", limit)
            case .other:
                return t("macOS is holding the battery at %@.", limit)
            }
        case .charging(let target, _) where target < 100:
            let limit = BatteryFormat.percent(Double(target))
            switch battery.chargeHold?.reason {
            case .optimizedCharging:
                return t("Optimised Battery Charging will pause charging at %@.", limit)
            case .chargeLimit:
                return t("Charging stops at %@, the charge limit set in Battery settings.", limit)
            default:
                return t("macOS will pause charging at %@.", limit)
            }
        case .adapterShortfall(let watts):
            if let adapter = battery.adapterWatts {
                return t(
                    "The %1$@ W adapter can't supply everything, so the battery is adding %2$@.",
                    String(adapter), BatteryFormat.watts(watts))
            }
            return t(
                "The adapter can't supply everything, so the battery is adding %@.",
                BatteryFormat.watts(watts))
        case .notCharging:
            return t("macOS has paused charging without giving a reason.")
        default:
            return nil
        }
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
            let base = t("+%@ into battery", BatteryFormat.watts(battery.powerWatts))
            if let w = battery.adapterWatts {
                return [base, t("%@ W adapter", String(w))].joined(separator: " · ")
            }
            return base
        }
        if battery.isOnAC {
            if let w = battery.adapterWatts { return t("On %@ W adapter", String(w)) }
            return t("On power adapter")
        }
        return t("%@ drawing from battery", BatteryFormat.watts(battery.powerWatts))
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
            Image(nsImage: ProcessIconProvider.shared.rowIcon(forPath: process.executablePath))
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
                Text(t("%@%% health", String(Int(health.rounded()))))
                    .foregroundStyle(.secondary)
            }
            if let cycles = battery.cycleCount {
                Text(t("%@ cycles", String(cycles)))
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
            MenuActionButton(title: "Settings…", systemImage: "gearshape") {
                openSettings()
            }
            MenuActionButton(
                title: "About \(AppInfo.displayName)", systemImage: "info.circle"
            ) {
                dismiss()
                showStandardAboutPanel()
            }
            MenuActionButton(
                title: "Check for Updates…", systemImage: "arrow.down.circle"
            ) {
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
