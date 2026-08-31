import Charts
import MacPerfMonitorCore
import SwiftUI

/// The Energy tab: a page header with the time-range control, the headline
/// figures as metric cards, then consistent bordered panels for the energy-flow
/// diagram, the charge/power timeline, battery health, the top energy-using
/// processes, the live electrical detail, and the power adapter and Low Power
/// Mode. Mirrors `DashboardView` so the tabs read as one app. On a Mac with no
/// internal battery (a desktop) it drops the battery-only figures to dashes but
/// still shows the energy-flow diagram (fed from the wall outlet) and the
/// top energy users — which is the whole point on a desktop.
struct BatteryView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState

    @State private var range: HistoryWindow = .oneHour
    @State private var history: [SystemHistoryPoint] = []
    /// The downsampled timeline + live point, computed once whenever the source
    /// data changes (not on every layout pass). Recomputing this inside a chart's
    /// body re-ran `chartDownsampled` on every layout pass and handed Charts a
    /// fresh array each time, which fed a layout loop that pinned the CPU.
    @State private var points: [SystemHistoryPoint] = []
    /// The range the loaded `history` / `points` are for, so the charge chart and
    /// cards can show a spinner while a range change is still loading — but not
    /// during the silent 5-second refresh of the same range.
    @State private var loadedRange: HistoryWindow?
    @State private var topEnergy: [ProcessConsumer] = []
    /// Recent thermal throttling events (2 h raw window), shown under the
    /// Thermals charts. Reloaded with the rest of the tab.
    @State private var thermalEvents: [ThermalEvent] = []
    /// The flow diagram's app branches: top energy users averaged over a short
    /// (60s) window, so they track recent draw without reshuffling every tick.
    @State private var flowEnergy: [EnergyFlowProcess] = []

    /// True while the loaded data isn't for the selected range yet (first load or
    /// a range change still in flight). Drives the charge chart and card spinners.
    private var awaitingData: Bool { loadedRange != range }

    private var chartDomain: ClosedRange<Date>? {
        LiveChartGeometry.trailingDomain(latest: points.last?.date, span: range.seconds)
    }

    var body: some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            reload()
            // Keep the GPU/SMC read path live while the tab is visible so the
            // thermal panel tracks in real time even when recording is off.
            // Balanced by onDisappear; TabGate unmounts the tab when hidden.
            model.addGPUConsumer()
        }
        .onDisappear { model.removeGPUConsumer() }
        .onChange(of: range) { reload() }
        .onChange(of: model.displayProcessesVersion) {
            if appState.mainWindowVisible { reload() }
        }
        // Refresh only the live right-edge point as each new sample lands, so the
        // chart tracks the current tick without re-querying the whole window.
        .onReceive(model.liveTick) { _ in
            if appState.mainWindowVisible { rebuildPoints() }
        }
        .onChange(of: appState.mainWindowVisible) { _, visible in if visible { reload() } }
    }

    @ViewBuilder private var content: some View {
        if let battery = currentBattery, battery.isPresent {
            batteryContent(battery)
        } else if model.liveSystem == nil && model.latest == nil {
            // First sample has not landed yet.
            loadingState
        } else {
            // A desktop with no internal battery (Mac mini, Studio, iMac). The
            // energy story still holds — which apps are working the Mac hardest —
            // so show the flow diagram (fed from the wall outlet) and the leader
            // board, and dash the battery-only figures rather than hiding them.
            desktopEnergyContent
        }
    }

    /// The Energy tab on a Mac with no battery: the flow diagram from the AC
    /// outlet, the measured system power, the top energy users, and the
    /// battery-only metrics shown as dashes.
    private var desktopEnergyContent: some View {
        MainRailLayout {
            pageHeader(subtitle: "on power adapter")
            desktopEnergyFlowPanel
            thermalPanel
            topEnergyPanel
        } rail: {
            desktopPowerPanel
        }
    }

    /// The live battery-absent sample on a desktop — it carries the measured
    /// system power. Falls back to a synthetic AC sample before the first tick so
    /// the flow diagram can still render.
    private var desktopSample: BatterySample {
        currentBattery
            ?? BatterySample(
                timestamp: model.liveSystem?.timestamp ?? model.latest?.system.timestamp
                    ?? .distantPast,
                isPresent: false, isOnAC: true)
    }

    private var currentBattery: BatterySample? {
        model.latestBattery ?? model.latest?.battery
    }

    private var desktopEnergyFlowPanel: some View {
        BatteryPanel("Energy flow", systemImage: "bolt.horizontal") {
            EnergyFlowView(battery: desktopSample, processes: liveFlowEnergy)
                .frame(height: 240)
            Divider().opacity(0.5)
            Text(desktopFlowStatus)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
        }
    }

    /// A one-line summary under the desktop flow diagram, leading with the real
    /// measured draw when the SMC reports it.
    private var desktopFlowStatus: String {
        let watts = desktopSample.systemPowerWatts
        if watts > 0 {
            return
                "Drawing \(BatteryFormat.watts(watts)) from the wall · energy impact ranks which apps work the Mac hardest."
        }
        return "On power adapter (AC) · energy impact ranks which apps work the Mac hardest."
    }

    /// The desktop power panel: the real measured system power up top, then the
    /// battery-only metrics as dashes so it's clear they exist but don't apply.
    private var desktopPowerPanel: some View {
        let watts = desktopSample.systemPowerWatts
        return BatteryPanel("Power", systemImage: "bolt.fill") {
            detailRow(
                "System power", watts > 0 ? BatteryFormat.watts(watts) : "—", valueColor: .yellow)
            detailRow("Power source", "Power adapter (AC)")
            if desktopSample.isLowPowerMode {
                detailRow("Low Power Mode", "On", valueColor: .orange)
            }
            Divider().opacity(0.5)
            detailRow("Charge", "—")
            detailRow("Health", "—")
            detailRow("Cycle count", "—")
            footnote(
                "This Mac has no internal battery, so charge, health and runtime don't apply. System power is the whole machine's measured draw; the energy impact above ranks which apps are working it hardest.")
        }
    }

    private func batteryContent(_ battery: BatterySample) -> some View {
        // Charge/power timelines and the energy leaderboard run down the wide
        // main column; the compact hardware read-outs sit in the stats rail.
        MainRailLayout {
            pageHeader(subtitle: headerSubtitle(battery))
            headlineNumbers(battery)
            energyFlowPanel(battery)
            chargeTimelinePanel(battery)
            thermalPanel
            topEnergyPanel
        } rail: {
            healthPanel(battery)
            electricalPanel(battery)
            adapterPanel(battery)
        }
    }

    // MARK: - Page header

    private func pageHeader(subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Energy")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("HISTORY")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Picker("Range", selection: $range) {
                    ForEach(HistoryWindow.allCases) { r in Text(r.label).tag(r) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
                .historyRangeGate()
            }
        }
    }

    /// "523 cycles · 92% health · on battery", omitting parts that aren't known.
    private func headerSubtitle(_ battery: BatterySample) -> String {
        var parts: [String] = []
        if let cycles = battery.cycleCount { parts.append("\(cycles) cycles") }
        if let health = battery.healthPercent {
            parts.append("\(Int(health.rounded()))% health")
        }
        parts.append(battery.isOnAC ? "on power adapter" : "on battery")
        return parts.joined(separator: " · ")
    }

    // MARK: - Headline numbers

    private func headlineNumbers(_ battery: BatterySample) -> some View {
        MetricCardsRow(
            cards: batteryCards(battery), xDomain: chartDomain, loading: awaitingData)
    }

    private func batteryCards(_ battery: BatterySample) -> [MetricCardData] {
        let level = BatteryLevel(percent: battery.chargePercent)
        func samples(_ value: @escaping (SystemHistoryPoint) -> Double) -> [MetricSample] {
            MemoryMetrics.downsample(
                points.map { MetricSample(date: $0.date, value: value($0)) },
                span: range.seconds, to: 80)
        }
        var cards: [MetricCardData] = [
            MetricCardData(
                label: "Charge",
                value: BatteryFormat.percent(battery.chargePercent),
                tint: level.color,
                samples: samples { $0.batteryCharge },
                unit: .percent,
                detail: battery.isCharging ? "charging" : nil),
            MetricCardData(
                label: "Power",
                value: BatteryFormat.watts(battery.powerWatts),
                tint: .yellow,
                samples: samples { $0.batteryPowerWatts },
                detail: battery.isCharging ? "in" : "out"),
            MetricCardData(
                label: "Health",
                value: battery.healthPercent.map { BatteryFormat.percent($0) } ?? "—",
                tint: healthColor(battery.healthPercent),
                // Health is a slow wear metric, so show a capacity gauge (with the
                // 80% service threshold) rather than a near-flat sparkline.
                gauge: battery.healthPercent.map {
                    MetricGauge(fraction: $0 / 100, threshold: 0.8)
                },
                unit: .percent,
                help:
                    "Today's full-charge capacity vs the original design. Apple suggests service below 80% (the tick)."
            ),
            MetricCardData(
                label: "Time remaining",
                value: timeRemainingValue(battery),
                tint: .primary),
            MetricCardData(
                label: "Cycles",
                value: battery.cycleCount.map { "\($0)" } ?? "—",
                tint: cycleColor(battery.cycleCount),
                // Apple silicon batteries are rated for 1,000 cycles, so read the
                // count against that ceiling as a wear gauge, not a bare number.
                gauge: battery.cycleCount.map {
                    MetricGauge(fraction: Double($0) / Double(Self.ratedCycleCount))
                },
                detail: battery.cycleCount.map { _ in "of \(Self.ratedCycleCount.formatted())" },
                help:
                    "Charge cycles used of the \(Self.ratedCycleCount.formatted()) this battery is rated for."
            ),
        ]
        if let temp = battery.temperatureCelsius {
            cards.append(
                MetricCardData(
                    label: "Temperature",
                    value: BatteryFormat.celsius(temp),
                    tint: .teal,
                    samples: samples { $0.batteryTemperatureCelsius }))
        }
        return cards
    }

    private func timeRemainingValue(_ battery: BatterySample) -> String {
        if battery.isCharging {
            return BatteryFormat.duration(minutes: battery.timeToFullMinutes)
        }
        if battery.isOnAC { return "On adapter" }
        return BatteryFormat.duration(minutes: battery.timeToEmptyMinutes)
    }

    // MARK: - Panels

    /// The flow diagram's apps: the 60s-ranked list restricted to processes that
    /// are still running, so a quit app drops off within a tick instead of
    /// lingering for the rest of the averaging window. The ranking stays smoothed
    /// (60s) for the survivors; only the liveness gate is instantaneous.
    private var liveFlowEnergy: [EnergyFlowProcess] {
        guard let live = model.latest?.processes, !live.isEmpty else { return flowEnergy }
        let alivePids = Set(live.map(\.pid))
        return flowEnergy.filter { alivePids.contains($0.id.pid) }
    }

    private func energyFlowPanel(_ battery: BatterySample) -> some View {
        BatteryPanel("Energy flow", systemImage: "bolt.horizontal") {
            EnergyFlowView(battery: battery, processes: liveFlowEnergy)
                .frame(height: 240)
            Divider().opacity(0.5)
            Text(flowStatus(battery))
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Thermals

    /// Die temperature and fan history with the current readings, shared by
    /// the laptop and desktop layouts. Heat sits with power on purpose: this
    /// tab already answers "what is working the Mac hardest", and the thermal
    /// record answers "and what did that cost".
    private var thermalPanel: some View {
        BatteryPanel("Thermals", systemImage: "thermometer.medium") {
            TemperatureChart(points: points, xDomain: chartDomain, showsTimeAxis: true)
                .frame(height: 150)
                .chartReloading(awaitingData)
            if let status = thermalStatus {
                Text(status)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            if hasFanHistory {
                Divider().opacity(0.5)
                FanChart(points: points, xDomain: chartDomain)
                    .frame(height: 90)
                    .chartReloading(awaitingData)
            }
            if !thermalEvents.isEmpty {
                Divider().opacity(0.5)
                ForEach(thermalEvents.prefix(5)) { event in
                    ThermalEventRow(event: event)
                }
            }
            footnote(
                "Each line is the hottest sensor of its domain: CPU die in orange, GPU die in red. Longer ranges keep the peaks, not the average, so spikes stay visible. The status follows macOS's own thermal pressure verdict, the signal that the system is actually slowing work down.")
        }
    }

    /// "CPU 47°C · GPU 41°C · SSD 29°C · Fans off · Nominal", omitting parts
    /// that have no reading. Nil until the first thermal sample lands.
    private var thermalStatus: String? {
        guard let system = model.liveSystem else { return nil }
        var parts: [String] = []
        if let cpu = system.cpuDieC { parts.append("CPU \(Int(cpu.rounded()))°C") }
        if let gpu = system.gpuDieC { parts.append("GPU \(Int(gpu.rounded()))°C") }
        if let ssd = system.ssdTemperatureC { parts.append("SSD \(Int(ssd.rounded()))°C") }
        if let fan = system.fanRPM {
            parts.append(fan == 0 ? "Fans off" : "Fans \(Int(fan.rounded())) rpm")
        }
        guard !parts.isEmpty else { return nil }
        if let pressure = system.thermalPressure {
            parts.append(pressure.label)
        }
        return parts.joined(separator: " · ")
    }

    /// Hide the fan chart outright on fanless Macs (MacBook Air) rather than
    /// drawing an empty plot under a real temperature chart.
    private var hasFanHistory: Bool {
        points.contains { $0.fanRPM != nil } || model.liveSystem?.fanRPM != nil
    }

    /// A one-line plain-language summary of the current power state, shown under
    /// the diagram, e.g. "On battery · 22.8 W out · 2:41 remaining".
    private func flowStatus(_ battery: BatterySample) -> String {
        var parts: [String] = []
        if battery.isCharging {
            parts.append("Charging")
            parts.append("+" + BatteryFormat.watts(battery.powerWatts) + " into battery")
            if let m = battery.timeToFullMinutes, m > 0 {
                parts.append(BatteryFormat.duration(minutes: m) + " to full")
            }
        } else if battery.isOnAC {
            parts.append("On power adapter")
            parts.append(battery.chargePercent >= 99 ? "battery full" : "battery holding")
        } else {
            parts.append("On battery")
            parts.append(BatteryFormat.watts(battery.powerWatts) + " out")
            if let m = battery.timeToEmptyMinutes, m > 0 {
                parts.append(BatteryFormat.duration(minutes: m) + " remaining")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func chargeTimelinePanel(_ battery: BatterySample) -> some View {
        BatteryPanel("Charge over time", systemImage: "battery.100.bolt") {
            BatteryChart(
                points: points,
                currentLevel: BatteryLevel(percent: battery.chargePercent),
                xDomain: chartDomain
            )
            .frame(height: 160)
            .chartReloading(awaitingData)
            footnote(
                "The battery level over the selected window, 0-100%. The line's slope shows how fast it was charging or draining.")
        }
    }

    private func healthPanel(_ battery: BatterySample) -> some View {
        BatteryPanel("Battery health", systemImage: "cross.case") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(battery.healthPercent.map { BatteryFormat.percent($0) } ?? "—")
                    .font(.title.monospacedDigit().weight(.semibold))
                    .foregroundStyle(healthColor(battery.healthPercent))
                Text("max capacity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().opacity(0.5)
            detailRow("Cycle count", battery.cycleCount.map { "\($0)" } ?? "—")
            detailRow(
                "Condition", battery.isHealthyCondition ? "Normal" : "Service",
                valueColor: battery.isHealthyCondition ? .green : .orange)
            if let manufacturer = battery.manufacturer {
                detailRow("Manufacturer", manufacturer)
            }
            if let manufactured = battery.manufactureDate {
                detailRow("Manufactured", BatteryFormat.manufactured(manufactured))
            }
            if let current = battery.currentCapacitymAh {
                detailRow("Current charge", BatteryFormat.mAh(current))
            }
            if let maxCap = battery.maxCapacitymAh {
                detailRow("Full charge", BatteryFormat.mAh(maxCap))
            }
            if let design = battery.designCapacitymAh {
                detailRow("Design", BatteryFormat.mAh(design))
            }
            footnote(
                "Maximum capacity is today's full-charge capacity as a share of the original design capacity, the standard measure of wear. Below ~80% Apple suggests service.")
        }
    }

    private var topEnergyPanel: some View {
        BatteryPanel("Top energy users", systemImage: "bolt.fill") {
            if topEnergy.isEmpty {
                Text("Building history\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let maxEnergy = max(topEnergy.first?.averageEnergy ?? 1, 0.001)
                VStack(spacing: 8) {
                    ForEach(topEnergy.prefix(8)) { consumer in
                        energyRow(consumer, maxEnergy: maxEnergy)
                    }
                }
            }
            footnote(
                "Energy impact is a relative measure, like Activity Monitor's Energy tab: it combines each process's CPU use and how often it wakes the CPU. Higher means more battery drain."
            )
        }
    }

    private func energyRow(_ consumer: ProcessConsumer, maxEnergy: Double) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: consumer.executablePath))
                .resizable()
                .frame(width: 18, height: 18)
            Text(consumer.displayName)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Fixed-width track; the bar is a fraction of it. No GeometryReader —
            // a fixed 90pt track needs no measurement, and GeometryReaders in a
            // row list add avoidable layout cost.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 90, height: 6)
                Capsule()
                    .fill(Color.yellow.opacity(0.7))
                    .frame(width: max(2, 90 * consumer.averageEnergy / maxEnergy), height: 6)
            }
            .frame(width: 90)
            Text(String(format: "%.0f", consumer.averageEnergy))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func electricalPanel(_ battery: BatterySample) -> some View {
        BatteryPanel("Electrical", systemImage: "waveform.path.ecg") {
            detailRow("Power", BatteryFormat.watts(battery.powerWatts), valueColor: .yellow)
            detailRow("Voltage", BatteryFormat.volts(battery.voltage))
            detailRow("Current", BatteryFormat.milliAmps(battery.amperageMilliAmps))
            if let cells = battery.cellVoltagesMilliVolts, !cells.isEmpty {
                detailRow("Cell voltages", BatteryFormat.cellVoltages(cells))
            }
            if let temp = battery.temperatureCelsius {
                detailRow("Temperature", BatteryFormat.celsius(temp), valueColor: .teal)
            }
            if (battery.serialNumber?.isEmpty == false) || battery.gasGaugeChip != nil {
                Divider().opacity(0.5)
                if let serial = battery.serialNumber, !serial.isEmpty {
                    detailRow("Serial", serial)
                }
                if let chip = battery.gasGaugeChip {
                    detailRow("Gauge chip", chip)
                }
            }
        }
    }

    private func adapterPanel(_ battery: BatterySample) -> some View {
        BatteryPanel("Adapter & power mode", systemImage: "powerplug") {
            detailRow("Power source", battery.isOnAC ? "Power adapter (AC)" : "Battery")
            if let watts = battery.adapterWatts {
                let name = battery.adapterName.map { "\($0) · " } ?? ""
                detailRow("Adapter", "\(name)\(watts) W")
            } else {
                detailRow("Adapter", battery.isOnAC ? "Connected" : "Not connected")
            }
            if let v = battery.adapterVoltageMilliVolts, let a = battery.adapterAmperageMilliAmps {
                detailRow(
                    "Adapter output",
                    "\(BatteryFormat.volts(milliVolts: v)) · \(BatteryFormat.amps(milliAmps: a))")
            } else if let v = battery.adapterVoltageMilliVolts {
                detailRow("Adapter output", BatteryFormat.volts(milliVolts: v))
            }
            if battery.isCharging, let mA = battery.chargingCurrentMilliAmps, mA > 0 {
                detailRow("Charging at", BatteryFormat.amps(milliAmps: mA), valueColor: .green)
            }
            HStack {
                Text("Low Power Mode")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(battery.isLowPowerMode ? "On" : "Off")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(battery.isLowPowerMode ? .orange : .primary)
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        ContentUnavailableView {
            Label("Reading energy\u{2026}", systemImage: "bolt")
        } description: {
            Text("Waiting for the first sample.")
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    // MARK: - Shared bits

    private func detailRow(
        _ label: LocalizedStringKey, _ value: String, valueColor: Color = .primary
    )
        -> some View
    {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func healthColor(_ health: Double?) -> Color {
        guard let health else { return .secondary }
        switch health {
        case ..<80: return .red
        case ..<90: return .orange
        default: return .green
        }
    }

    /// Charge cycles an Apple silicon battery is rated for — it's designed to keep
    /// 80% of capacity through this many. The cycle gauge reads the count against it.
    static let ratedCycleCount = 1000

    /// Green well within the rating, amber in the last fifth, red at/over the rated
    /// 1,000 cycles — the same good/getting-there/replace read as health.
    private func cycleColor(_ cycles: Int?) -> Color {
        guard let cycles else { return .secondary }
        switch Double(cycles) / Double(Self.ratedCycleCount) {
        case ..<0.8: return .green
        case ..<1.0: return .orange
        default: return .red
        }
    }

    // MARK: - Derived

    private static let maxChartPoints = 360

    /// Recompute the memoized `points`: the pre-thinned loaded history plus the
    /// latest live sample on the right edge so the timelines track the current
    /// tick. The downsampling itself happens on the model's read queue
    /// (`downsampledTo:`), so this per-tick step is O(chart points). Called only
    /// when `history` reloads or a new sample lands — never during a layout pass.
    private func rebuildPoints() {
        var pts = history
        if let system = model.liveSystem, system.batteryPresent {
            let live = SystemHistoryPoint(
                date: system.timestamp,
                pressurePercent: system.pressurePercent,
                appMemory: system.appMemory,
                wired: system.wired,
                compressed: system.compressed,
                cachedFiles: system.cachedFiles,
                swapUsed: system.swapUsed,
                cpuLoad: system.cpuLoad,
                batteryCharge: system.batteryCharge,
                batteryPowerWatts: system.batteryPowerWatts,
                batteryHealthPercent: system.batteryHealthPercent,
                batteryTemperatureCelsius: system.batteryTemperatureCelsius,
                cpuDieC: system.cpuDieC,
                gpuDieC: system.gpuDieC,
                ssdTemperatureC: system.ssdTemperatureC,
                fanRPM: system.fanRPM,
                thermalPressure: system.thermalPressure
            )
            if let last = pts.last {
                if live.date > last.date { pts.append(live) }
            } else {
                pts.append(live)
            }
        }
        points = pts
    }

    /// The top-consumers window is just the selected range now that the whole
    /// app shares one `HistoryWindow`.
    private var consumerWindow: HistoryWindow { range }

    private func reload() {
        let requested = range
        model.loadSystemHistory(requested, downsampledTo: Self.maxChartPoints) { pts in
            self.history = pts
            self.loadedRange = requested
            self.rebuildPoints()
        }
        model.loadTopConsumers(window: consumerWindow, metric: .averageEnergy, limit: 8) { rows in
            self.topEnergy = rows
        }
        // The flow diagram's branches: top energy users over the last 60s, so the
        // ranking is live but smoothed rather than jumping every tick. Fetch a few
        // extra (8, shown 5) so the liveness filter still leaves a full set after a
        // recently-quit app is dropped.
        model.loadThermalEvents { events in
            self.thermalEvents = events
        }
        model.loadRecentEnergyConsumers(seconds: 60, limit: 8) { rows in
            withAnimation(.easeInOut(duration: 0.6)) {
                self.flowEnergy = rows.map {
                    EnergyFlowProcess(
                        id: $0.identity, name: $0.displayName,
                        executablePath: $0.executablePath, energy: max(0, $0.averageEnergy))
                }
            }
        }
    }
}

/// One thermal throttling event: when macOS stepped into a throttling state
/// and which process was working the CPU hardest at that moment.
private struct ThermalEventRow: View {
    let event: ThermalEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer.high")
                .foregroundStyle(event.state.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Throttling began (\(event.state.label.lowercased()))")
                    .font(.body.weight(.medium))
                Text(driverLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(event.date.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                Text(event.date.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var driverLine: String {
        if let name = event.dominantName {
            return "Top CPU: \(name) (\(Int(event.dominantCPUPercent.rounded()))%)"
        }
        return "No dominant process recorded"
    }
}

/// A titled, bordered content card — the Battery tab's structural unit, matching
/// the Dashboard's panels so the two tabs share the same weight and chrome.
private struct BatteryPanel<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
