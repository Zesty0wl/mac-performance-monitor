import MacPerfMonitorCore
import SwiftUI

/// The Settings window.
///
/// Organised into focused tabs rather than one long scrolling column: General
/// (startup, mode, about), Menu Bar & Dock (where the app shows itself), Alerts
/// (every alert, each in its own headed section), and Advanced (the
/// privileged-helper coverage and the on-disk storage cap). Each tab is a short
/// `Form`; they all read the environment objects injected by the Settings scene
/// in `MacPerfMonitorApp`.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarDockSettingsView()
                .tabItem { Label("Menu Bar & Dock", systemImage: "menubar.rectangle") }
            AlertsSettingsView()
                .tabItem { Label("Alerts", systemImage: "bell") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        // A fixed window size across tabs (rather than resizing per tab) keeps the
        // window from jumping as the user clicks between tabs; the tallest tab
        // (Alerts, with its steppers expanded) scrolls within the Form if needed.
        .frame(width: 480, height: 560)
    }
}

// MARK: - General

/// Launch-at-login, function mode, and the privacy/about footnotes.
private struct GeneralSettingsView: View {
    @EnvironmentObject private var loginItem: LoginItemManager
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appMode: AppModeManager
    /// The process-table scan interval. The live charts/menu bar are always 1 Hz.
    @AppStorage(SamplerModel.tableIntervalKey) private var tableInterval =
        SamplerModel.defaultTableInterval

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: loginItemBinding)
                caption(
                    "Start \(AppInfo.displayName) automatically when you sign in, so it is in the menu bar and recording from the moment you log in."
                )
                if let error = loginItem.lastError {
                    caption("Last error: \(error)")
                }
            } header: {
                Text("Startup")
            }

            Section {
                Picker("Mode", selection: $appMode.mode) {
                    ForEach(AppMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                caption(appMode.mode.summary)
            } header: {
                Text("Mode")
            }

            Section {
                Picker("Refresh interval", selection: $tableInterval) {
                    ForEach(SamplerModel.tableIntervalChoices, id: \.self) { seconds in
                        Text(SamplerModel.tableIntervalLabel(seconds)).tag(seconds)
                    }
                }
                caption(
                    "How often the in-window charts, cards, and process list refresh and re-scan — the same control is in the window toolbar. Slower is lighter on CPU (the default 10 s is deliberately light); the menu-bar read-outs stay live regardless."
                )
            } header: {
                Text("Performance")
            }

            Section {
                LabeledContent("Data", value: "Stored locally, no telemetry")
                if let usage = model.selfUsage {
                    LabeledContent(
                        "\(AppInfo.displayName) itself",
                        value:
                            "\(ByteFormat.string(usage.footprint)) · \(String(format: "%.1f%%", usage.cpuPercent)) CPU"
                    )
                }
            } header: {
                Text("About")
            } footer: {
                Text(
                    "\(AppInfo.displayName) watches its own memory too. It should stay well under 60 MB while only the menubar is active."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Reflects whether the app opens at login; toggling registers or
    /// unregisters the app as a login item.
    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { wantsOn in
                if wantsOn {
                    loginItem.enable()
                } else {
                    loginItem.disable()
                }
            })
    }
}

// MARK: - Menu Bar & Dock

/// Configures the single combined menu bar item and the optional Dock icon.
private struct MenuBarDockSettingsView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var menuBar: CombinedMenuBarConfiguration
    /// Shared with `DockIconController`, so toggling shows or hides the Dock icon
    /// live. Off by default — the app is menubar-first.
    @AppStorage(DockIconController.defaultsKey) private var showDockIcon = false

    var body: some View {
        Form {
            Section {
                Picker("Presentation", selection: presentationBinding) {
                    ForEach(MenuBarPresentation.allCases) { presentation in
                        Text(presentation.title).tag(presentation)
                    }
                }
                .pickerStyle(.segmented)
                caption(
                    menuBar.presentation == .focus
                        ? "Focus shows one chosen read-out in the smallest practical space."
                        : "Strip shows every selected read-out together in one compact item."
                )

                if menuBar.presentation == .focus {
                    Picker("Focused read-out", selection: focusBinding) {
                        ForEach(menuBar.selectedMetrics) { metric in
                            Label(metric.title, systemImage: metric.symbolName).tag(metric)
                        }
                    }
                }

                HStack {
                    Text("Preview")
                    Spacer()
                    Image(nsImage: previewImage)
                        .accessibilityLabel("Menu bar preview")
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(
                            Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
            } header: {
                Text("Combined Item")
            } footer: {
                Text(
                    "Read-outs follow the menu bar appearance. Active alarms add a red warning marker."
                )
            }

            Section {
                ForEach(menuBar.selectedMetrics) { metric in
                    metricRow(metric, isSelected: true)
                }
                ForEach(unselectedMetrics) { metric in
                    metricRow(metric, isSelected: false)
                }
            } header: {
                Text("Read-outs")
            } footer: {
                Text(
                    "Choose any combination and order. At least one read-out must remain selected.")
            }

            Section {
                Toggle("Show icon in the Dock", isOn: $showDockIcon)
                caption(
                    "Also show \(AppInfo.displayName) in the Dock while it's running, as a second way to open it — handy if your menu bar is too crowded to see the menu bar items. It still runs from the menu bar either way."
                )
            } header: {
                Text("Dock")
            }
        }
        .formStyle(.grouped)
    }

    private var unselectedMetrics: [MenuBarMetric] {
        MenuBarMetric.allCases.filter { !menuBar.isSelected($0) }
    }

    private var presentationBinding: Binding<MenuBarPresentation> {
        Binding(get: { menuBar.presentation }, set: { menuBar.presentation = $0 })
    }

    private var focusBinding: Binding<MenuBarMetric> {
        Binding(get: { menuBar.focusedMetric }, set: { menuBar.focusedMetric = $0 })
    }

    private func selectionBinding(_ metric: MenuBarMetric) -> Binding<Bool> {
        Binding(
            get: { menuBar.isSelected(metric) },
            set: { menuBar.setSelected(metric, isSelected: $0) })
    }

    private func metricRow(_ metric: MenuBarMetric, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: selectionBinding(metric)) {
                Label(metric.title, systemImage: metric.symbolName)
            }
            .disabled(isSelected && menuBar.selectedMetrics.count == 1)

            if isSelected, let index = menuBar.selectedMetrics.firstIndex(of: metric) {
                Button {
                    menuBar.move(metric, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Move \(metric.title) earlier")

                Button {
                    menuBar.move(metric, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == menuBar.selectedMetrics.count - 1)
                .help("Move \(metric.title) later")
            }
        }
    }

    private var previewImage: NSImage {
        let metrics =
            menuBar.presentation == .focus
            ? [menuBar.focusedMetric] : menuBar.selectedMetrics
        let readouts = CombinedMenuBarReadouts.current(for: metrics, model: model)
        return CombinedMenuBarImage.image(
            readouts: readouts, presentation: menuBar.presentation)
    }
}

// MARK: - Alerts

/// Every alert, each in its own headed section so the group reads as one set of
/// related controls (the old layout left four of them headerless). Thresholded
/// alerts reveal their stepper only when enabled.
private struct AlertsSettingsView: View {
    @EnvironmentObject private var alertSettings: AlertSettings

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Critical memory pressure", isOn: $alertSettings.config.criticalPressureEnabled)
                caption(
                    "Notify when the system reaches critical pressure and apps may be forced to quit."
                )
            } header: {
                Text("Critical Memory Pressure")
            } footer: {
                Text(
                    "All alerts are off by default except critical pressure and runaway processes. \(AppInfo.displayName) never sends anything off your Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Runaway process", isOn: $alertSettings.config.leakEnabled)
                caption(
                    "Notify when a process keeps growing in a way that looks like a memory leak.")
            } header: {
                Text("Runaway Process")
            }

            Section {
                Toggle("Heavy swap use", isOn: $alertSettings.config.swapEnabled)
                if alertSettings.config.swapEnabled {
                    gigabyteStepper(
                        "Swap above", bytes: $alertSettings.config.swapThresholdBytes, range: 1...32
                    )
                }
                caption("Notify when the system writes more than the chosen amount to swap.")
            } header: {
                Text("Heavy Swap Use")
            }

            Section {
                Toggle("Process over ceiling", isOn: $alertSettings.config.processCeilingEnabled)
                if alertSettings.config.processCeilingEnabled {
                    gigabyteStepper(
                        "Footprint above", bytes: $alertSettings.config.processCeilingBytes,
                        range: 1...64)
                }
                caption("Notify when any single process exceeds the chosen memory footprint.")
            } header: {
                Text("Process Over Ceiling")
            }

            Section {
                Toggle("Sustained high CPU", isOn: $alertSettings.config.highCPUEnabled)
                if alertSettings.config.highCPUEnabled {
                    percentStepper(
                        "Total CPU above",
                        percent: $alertSettings.config.highCPUThresholdPercent,
                        range: 50...100)
                }
                caption(
                    "Notify when total CPU stays above the chosen level for a sustained period. Off by default — high CPU is normal during real work."
                )
            } header: {
                Text("Sustained High CPU")
            }
        }
        .formStyle(.grouped)
    }

    /// Presents a byte threshold as a whole number of gigabytes with a stepper,
    /// converting to and from the stored `UInt64` byte value.
    private func gigabyteStepper(
        _ label: String, bytes: Binding<UInt64>, range: ClosedRange<Double>
    ) -> some View {
        let bytesPerGB = 1024.0 * 1024.0 * 1024.0
        let value = Binding<Double>(
            get: { (Double(bytes.wrappedValue) / bytesPerGB).rounded() },
            set: { bytes.wrappedValue = UInt64($0 * bytesPerGB) })
        return Stepper(value: value, in: range, step: 1) {
            LabeledContent(label, value: "\(Int(value.wrappedValue)) GB")
        }
    }

    /// A whole-percent threshold with a stepper, in steps of 5.
    private func percentStepper(
        _ label: String, percent: Binding<Int>, range: ClosedRange<Int>
    ) -> some View {
        Stepper(value: percent, in: range, step: 5) {
            LabeledContent(label, value: "\(percent.wrappedValue)%")
        }
    }
}

// MARK: - Advanced

/// The heavier, less-often-touched settings: full-coverage (the privileged
/// helper) and the on-disk storage cap.
private struct AdvancedSettingsView: View {
    @EnvironmentObject private var helper: HelperManager
    @EnvironmentObject private var model: SamplerModel

    /// The database size cap in MB, read by the retention pass (same key).
    @AppStorage(SamplerModel.databaseMaxMBKey) private var databaseMaxMB =
        SamplerModel.defaultDatabaseMaxMB
    /// Per-app network attribution, shared with `SamplerModel`. On by default now
    /// that it uses a cheap one-shot `nettop` (it was opt-in when it ran a
    /// persistent one under a pty).
    @AppStorage(SamplerModel.perAppNetworkDefaultsKey) private var trackPerAppNetwork = true
    /// The host the network menu pings for its latency/jitter read-out.
    @AppStorage(LatencyMonitor.hostKey) private var latencyHost = LatencyMonitor.defaultHost
    /// The live on-disk size, refreshed when the tab appears.
    @State private var databaseSize: Int?

    // Logging-resolution tiers (see SamplerModel): high-res → raw tables,
    // standard-res → minute aggregates. The two ages are additive.
    @AppStorage(SamplerModel.highResIntervalKey) private var highResInterval =
        SamplerModel.defaultHighResInterval
    @AppStorage(SamplerModel.highResAgeKey) private var highResAge = SamplerModel.defaultHighResAge
    @AppStorage(SamplerModel.standardResIntervalKey) private var standardResInterval =
        SamplerModel.defaultStandardResInterval
    @AppStorage(SamplerModel.standardResAgeKey) private var standardResAge =
        SamplerModel.defaultStandardResAge
    /// Live inputs for the storage projection, loaded when the tab appears.
    @State private var projectionProcessCount = 600
    @State private var bytesPerRow: Double = 250

    var body: some View {
        Form {
            Section {
                Toggle("Track per-app network usage", isOn: $trackPerAppNetwork)
                caption(
                    "Attribute network traffic to individual apps, so the Analytics tab and the network menu can show which apps are using the network. It samples the system's \u{201C}nettop\u{201D} tool briefly each refresh; the overall download and upload rates are always shown regardless."
                )
                LabeledContent("Latency ping host") {
                    TextField(LatencyMonitor.defaultHost, text: $latencyHost)
                        .frame(width: 140)
                        .multilineTextAlignment(.trailing)
                }
                caption(
                    "The network menu measures latency and jitter by pinging this host while the menu is open."
                )
            } header: {
                Text("Network")
            }

            Section {
                Toggle("Show every process", isOn: coverageBinding)
                    .disabled(helper.coverage == .unavailable)
                caption(coverageStatus)
                if helper.coverage == .requiresApproval {
                    Button("Open System Settings\u{2026}") { helper.openApprovalSettings() }
                }
                if let error = helper.lastError {
                    caption("Last error: \(error)")
                }
            } header: {
                Text("Full Coverage")
            } footer: {
                Text(
                    "\(AppInfo.displayName) can install a small privileged helper so it can read the memory of system and other-user processes (such as WindowServer) that it otherwise cannot see. The helper runs only to read memory statistics and sends nothing off your Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Frequency", selection: $highResInterval) {
                    ForEach(
                        pickerOptions(highIntervalOptions, current: highResInterval), id: \.self
                    ) {
                        Text(SamplerModel.tableIntervalLabel($0)).tag($0)
                    }
                }
                Picker("Keep for", selection: $highResAge) {
                    ForEach(pickerOptions(highAgeOptions, current: highResAge), id: \.self) {
                        Text(durationLabel($0)).tag($0)
                    }
                }
                caption(
                    "Every process is logged at this resolution for the most recent window. Finer and longer means more detail — and a larger database."
                )
            } header: {
                Text("High-resolution logging")
            }

            Section {
                Picker("Frequency", selection: $standardResInterval) {
                    ForEach(
                        pickerOptions(standardIntervalOptions, current: standardResInterval),
                        id: \.self
                    ) {
                        Text(SamplerModel.tableIntervalLabel($0)).tag($0)
                    }
                }
                Picker("Keep for", selection: $standardResAge) {
                    ForEach(pickerOptions(standardAgeOptions, current: standardResAge), id: \.self)
                    {
                        Text(durationLabel($0)).tag($0)
                    }
                }
                caption(
                    "Older data is aggregated to this coarser resolution. Its age is additive: detailed history spans the high-resolution age plus this (e.g. 24h + 7d = 8 days), with about 90 days of hourly history kept beneath it."
                )
            } header: {
                Text("Standard-resolution logging")
            }

            Section {
                Slider(value: maxDatabaseBinding, in: 100...5000, step: 100) {
                    Text("Maximum size")
                } minimumValueLabel: {
                    Text("100 MB").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("5 GB").font(.caption2).foregroundStyle(.secondary)
                }
                LabeledContent("Limit", value: sizeLabel(megabytes: databaseMaxMB))
                LabeledContent(
                    "Detailed history", value: durationLabel(highResAge + standardResAge))
                LabeledContent(
                    "Projected size", value: ByteFormat.string(UInt64(max(0, projectedBytes))))
                LabeledContent("Projected samples", value: sampleCountLabel(projectedRows))
                if let databaseSize {
                    LabeledContent("Current size", value: ByteFormat.string(UInt64(databaseSize)))
                }
                if projectedBytes > byteCap {
                    WarningBanner(
                        text:
                            "These settings need about \(ByteFormat.string(UInt64(max(0, projectedBytes)))), more than your \(sizeLabel(megabytes: databaseMaxMB)) size limit. The oldest high-resolution samples will be dropped early to fit — raise the size limit or reduce resolution to keep it all."
                    )
                }
                if nearSampleCeiling {
                    WarningBanner(
                        text:
                            "You're near the \(sampleCountLabel(SamplerModel.maxTotalSamples))-sample limit above which the app slows down, so retention is capped at what fits. To keep more history, choose a coarser frequency."
                    )
                }
                caption(
                    "When the database reaches this size, the oldest high-resolution samples are dropped first, keeping the long low-resolution trend."
                )
            } header: {
                Text("Storage")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.loadDatabaseSize { databaseSize = $0 }
            model.loadBytesPerRow { bytesPerRow = $0 }
            projectionProcessCount = model.loggedProcessCount
            clampSelections()
        }
        .onChange(of: highResInterval) { _, _ in clampSelections() }
        .onChange(of: highResAge) { _, _ in clampSelections() }
        .onChange(of: standardResInterval) { _, _ in clampSelections() }
        .onChange(of: standardResAge) { _, _ in clampSelections() }
    }

    /// Reflects the daemon's registration state; toggling registers or
    /// unregisters the privileged daemon.
    private var coverageBinding: Binding<Bool> {
        Binding(
            get: { helper.coverage == .enabled || helper.coverage == .requiresApproval },
            set: { wantsOn in
                if wantsOn {
                    helper.enable()
                } else {
                    helper.disable()
                }
            })
    }

    /// A plain-language description of the current coverage state.
    private var coverageStatus: String {
        switch helper.coverage {
        case .unavailable:
            return "Not available in this build. Install the signed app to use full coverage."
        case .disabled:
            return "Off. \(AppInfo.displayName) shows only the processes it can read at user level."
        case .requiresApproval:
            return "Waiting for your approval in System Settings \u{203A} Login Items."
        case .enabled:
            return "On. \(AppInfo.displayName) can read every process, including system processes."
        }
    }

    /// Slider binding over the stored MB value.
    private var maxDatabaseBinding: Binding<Double> {
        Binding(get: { Double(databaseMaxMB) }, set: { databaseMaxMB = Int($0) })
    }

    /// Format a size given in whole megabytes, switching to GB past 1000.
    private func sizeLabel(megabytes: Int) -> String {
        megabytes >= 1000
            ? String(format: "%.1f GB", Double(megabytes) / 1000)
            : "\(megabytes) MB"
    }

    // MARK: - Storage projection + tier clamping

    private var byteCap: Int { databaseMaxMB * 1_000_000 }

    private var projectedRows: Int {
        SamplerModel.projectedSampleRows(
            highInterval: highResInterval, highAge: highResAge,
            standardInterval: standardResInterval, standardAge: standardResAge,
            processCount: projectionProcessCount)
    }
    private var projectedBytes: Int { Int(Double(projectedRows) * bytesPerRow) }
    /// True once options are being clamped away to stay under the performance
    /// ceiling — drives the warning banner.
    private var nearSampleCeiling: Bool {
        projectedRows > Int(Double(SamplerModel.maxTotalSamples) * 0.9)
    }

    private func rows(_ hi: Double, _ ha: Double, _ si: Double, _ sa: Double) -> Int {
        SamplerModel.projectedSampleRows(
            highInterval: hi, highAge: ha, standardInterval: si, standardAge: sa,
            processCount: projectionProcessCount)
    }
    /// Options that keep the projection within the sample ceiling (holding the
    /// other three tiers fixed), with high-freq < standard-freq enforced.
    private var highIntervalOptions: [Double] {
        // Frequency is always freely selectable (only high < standard). The sample
        // budget constrains the AGE dropdowns instead, so 1s/2s are never hidden —
        // choosing a finer rate just shortens how long it can be kept.
        SamplerModel.highResIntervalChoices.filter { $0 < standardResInterval }
    }
    private var highAgeOptions: [Double] {
        SamplerModel.highResAgeChoices.filter {
            rows(highResInterval, $0, standardResInterval, standardResAge)
                <= SamplerModel.maxTotalSamples
        }
    }
    private var standardIntervalOptions: [Double] {
        SamplerModel.standardResIntervalChoices.filter { $0 > highResInterval }
    }
    private var standardAgeOptions: [Double] {
        SamplerModel.standardResAgeChoices.filter {
            rows(highResInterval, highResAge, standardResInterval, $0)
                <= SamplerModel.maxTotalSamples
        }
    }
    /// Ensure the currently-stored value is always renderable in its Picker, even
    /// if another tier temporarily pushed it out of budget (clampSelections then
    /// snaps it back).
    private func pickerOptions(_ opts: [Double], current: Double) -> [Double] {
        opts.contains(current) ? opts : (opts + [current]).sorted()
    }

    /// Snap the four tier selections into a legal, in-budget combination: enforce
    /// high-freq < standard-freq, then coarsen/shorten (high freq → high age →
    /// standard age → standard freq) until the projection is under the ceiling.
    private func clampSelections() {
        if highResInterval >= standardResInterval {
            if let s = SamplerModel.standardResIntervalChoices.first(where: { $0 > highResInterval }
            ) {
                standardResInterval = s
            } else if let h = SamplerModel.highResIntervalChoices.last(where: {
                $0 < standardResInterval
            }) {
                highResInterval = h
            }
        }
        var guardCount = 0
        while projectedRows > SamplerModel.maxTotalSamples, guardCount < 50 {
            guardCount += 1
            // Preserve the chosen sample frequencies; shorten retention to fit
            // first, and only coarsen a frequency as a last resort.
            if let a = SamplerModel.highResAgeChoices.last(where: { $0 < highResAge }) {
                highResAge = a
            } else if let a = SamplerModel.standardResAgeChoices.last(where: { $0 < standardResAge }
            ) {
                standardResAge = a
            } else if let s = SamplerModel.standardResIntervalChoices.first(where: {
                $0 > standardResInterval
            }) {
                standardResInterval = s
            } else if let h = SamplerModel.highResIntervalChoices.first(where: {
                $0 > highResInterval && $0 < standardResInterval
            }) {
                highResInterval = h
            } else {
                break
            }
        }
    }

    /// Human-readable age, e.g. "30 min", "24 hours", "7 days".
    private func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 3600 { return "\(max(1, s / 60)) min" }
        if s < 86_400 {
            let h = s / 3600
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        let d = s / 86_400
        return d == 1 ? "1 day" : "\(d) days"
    }

    /// Compact sample count, e.g. "18.6M", "450K".
    private func sampleCountLabel(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

/// A highlighted advisory banner for Settings, in the app's warning language
/// (orange tint + triangle glyph), matching the `InsightCard` fill+border recipe.
private struct WarningBanner: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.28)))
    }
}

// MARK: - Shared

/// A muted explanatory caption shown beneath a Settings control.
private func caption(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}
