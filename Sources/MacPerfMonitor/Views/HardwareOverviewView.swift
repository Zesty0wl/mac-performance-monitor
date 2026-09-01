import MacPerfMonitorCore
import SwiftUI

/// The Hardware tab's first page: this Mac at a glance, drawn rather than
/// listed. A block diagram of the system on a chip (CPU clusters, GPU cores,
/// the Neural Engine, the unified memory they share), capacity bars for
/// memory and volumes, the displays to scale, the battery's health ring, the
/// radios and buses, and the running software. Every card opens its section.
struct HardwareOverviewView: View {
    @ObservedObject var model: HardwareExplorerModel
    @EnvironmentObject private var sampler: SamplerModel
    @EnvironmentObject private var appState: AppState
    @StateObject private var sensorLive = SensorLiveStore()
    @Environment(\.colorScheme) private var colorScheme
    /// The domain whose live per-sensor sheet is open, if any.
    @State private var detailGroup: SensorDetailSelection?

    private var facts: HardwareFacts { model.facts }

    var body: some View {
        ScrollView {
            // Two columns whose rows share a height (every card stretches to
            // its row) and sit top-aligned, so the page reads as a neat grid.
            // One column when the pane is too narrow for two.
            ViewThatFits(in: .horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        cell(macCard)
                        cell(socCard)
                    }
                    GridRow {
                        cell(memoryCard)
                        cell(storageCard)
                    }
                    GridRow {
                        cell(displaysCard)
                        cell(powerCard)
                    }
                    GridRow {
                        cell(connectivityCard)
                        cell(softwareCard)
                    }
                    GridRow {
                        cell(sensorsCard)
                            .gridCellColumns(2)
                    }
                }
                .frame(maxWidth: 1240, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    macCard
                    socCard
                    memoryCard
                    storageCard
                    displaysCard
                    powerCard
                    connectivityCard
                    softwareCard
                    sensorsCard
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A grid cell: at least a card's width, and as tall as its row.
    private func cell<Content: View>(_ content: Content) -> some View {
        content
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - This Mac

    private var macCard: some View {
        HardwarePanel("This Mac", systemImage: "macbook", action: { model.selectedID = "mac" }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(facts.productName ?? facts.modelIdentifier ?? t("Mac"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HardwareFactRows(rows: [
                    ("Model identifier", facts.modelIdentifier),
                    ("Chip", facts.chipName),
                    ("Memory", facts.memoryBytes.map { ByteFormat.string($0, fractionDigits: 0) }),
                    ("Serial number", facts.serialNumber),
                    ("Metal", facts.metalSupport),
                    ("macOS", facts.osVersion),
                ])
            }
        }
    }

    // MARK: - System on a chip

    private var socCard: some View {
        HardwarePanel(
            "System on a chip", systemImage: "cpu", action: { model.selectedID = "processor" }
        ) {
            SoCDiagram(facts: facts)
        }
    }

    // MARK: - Memory

    private var memoryCard: some View {
        HardwarePanel("Memory", systemImage: "memorychip", action: { model.selectedID = "memory" })
        {
            VStack(alignment: .leading, spacing: 10) {
                if let bytes = facts.memoryBytes {
                    Text(ByteFormat.string(bytes, fractionDigits: 0))
                        .font(.title2.weight(.semibold))
                    HardwareCapacityBar(fraction: 1, tint: .purple)
                        .frame(height: 10)
                    Text("Unified memory, shared by the CPU, GPU and Neural Engine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    pending
                }
                if let type = facts.memoryType {
                    HardwareFactRows(rows: [("Type", type)])
                }
            }
        }
    }

    // MARK: - Storage

    private var storageCard: some View {
        HardwarePanel(
            "Storage", systemImage: "internaldrive", action: { model.selectedID = "storage" }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                let volumes = overviewVolumes
                if volumes.isEmpty {
                    pending
                } else {
                    ForEach(Array(volumes.enumerated()), id: \.offset) { _, volume in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(volume.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(ByteFormat.string(volume.capacityBytes, fractionDigits: 0))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            let used = volume.freeBytes.map {
                                volume.capacityBytes - min($0, volume.capacityBytes)
                            }
                            HardwareCapacityBar(
                                fraction: used.map {
                                    Double($0) / Double(max(volume.capacityBytes, 1))
                                } ?? 0,
                                tint: .blue
                            )
                            .frame(height: 8)
                            if let free = volume.freeBytes {
                                Text(t("%@ free", ByteFormat.string(free, fractionDigits: 1)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Mounted user-facing volumes: the boot volume, the data volume that
    /// backs it, and anything under /Volumes. Duplicated APFS volumes in the
    /// same container report the same free space, so only the first of each
    /// free-space figure is shown.
    private var overviewVolumes: [HardwareFacts.Volume] {
        guard let all = facts.volumes else { return [] }
        func rank(_ mount: String) -> Int {
            if mount == "/" { return 0 }
            if mount.hasPrefix("/Volumes/") { return 1 }
            if mount == "/System/Volumes/Data" { return 2 }
            return 3
        }
        let visible = all.filter { rank($0.mountPoint ?? "") < 3 }
            .sorted { rank($0.mountPoint ?? "") < rank($1.mountPoint ?? "") }
        // Volumes in one APFS container report the same capacity and (to
        // within a few MB) the same free space; show each container once.
        var seen: [(UInt64, UInt64)] = []
        var picked: [HardwareFacts.Volume] = []
        for volume in visible {
            let key = (volume.capacityBytes, (volume.freeBytes ?? 0) / (256 << 20))
            if seen.contains(where: { $0 == key }) { continue }
            seen.append(key)
            picked.append(volume)
        }
        return Array(picked.prefix(6))
    }

    // MARK: - Displays

    private var displaysCard: some View {
        HardwarePanel("Displays", systemImage: "display", action: { model.selectedID = "displays" })
        {
            if let displays = facts.displays, !displays.isEmpty {
                HardwareFlowLayout(spacing: 14) {
                    ForEach(Array(displays.enumerated()), id: \.offset) { _, display in
                        DisplayGlyph(display: display)
                    }
                }
            } else {
                pending
            }
        }
    }

    // MARK: - Power

    private var powerCard: some View {
        HardwarePanel(
            "Battery", systemImage: "battery.100percent", action: { model.selectedID = "power" }
        ) {
            if let battery = facts.battery {
                HStack(alignment: .center, spacing: 16) {
                    HealthRing(fraction: (battery.healthPercent ?? 0) / 100)
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        if let health = battery.healthPercent {
                            Text(t("%@%% maximum capacity", "\(Int(health.rounded()))"))
                                .font(.callout.weight(.medium))
                        }
                        HardwareFactRows(rows: [
                            ("Condition", battery.condition),
                            ("Cycle count", battery.cycleCount.map { "\($0)" }),
                            ("Charge", battery.chargePercent.map { "\(Int($0.rounded()))%" }),
                            (
                                "Capacity",
                                battery.maxCapacitymAh.flatMap { full in
                                    battery.designCapacitymAh.map {
                                        t("%1$@ of %2$@ mAh", "\(full)", "\($0)")
                                    }
                                }
                            ),
                        ])
                    }
                }
            } else if model.section("power") != nil {
                Text("No battery: this Mac runs on mains power.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                pending
            }
        }
    }

    // MARK: - Connectivity

    private var connectivityCard: some View {
        HardwarePanel(
            "Connectivity", systemImage: "antenna.radiowaves.left.and.right",
            action: { model.selectedID = "network" }
        ) {
            HardwareFactRows(rows: [
                (
                    "Wi-Fi",
                    facts.wifiSummary
                        ?? (model.section("wifi") != nil ? t("No Wi-Fi interface") : nil)
                ),
                ("Bluetooth", facts.bluetoothSummary),
                ("USB devices", facts.usbDeviceCount.map { "\($0)" }),
                ("Thunderbolt ports", facts.thunderboltPortCount.map { "\($0)" }),
            ])
        }
    }

    // MARK: - Software

    private var softwareCard: some View {
        HardwarePanel(
            "Software", systemImage: "macwindow", action: { model.selectedID = "software" }
        ) {
            HardwareFactRows(rows: [
                ("System", facts.osVersion),
                ("Kernel", facts.kernelVersion),
                (
                    "Last boot",
                    facts.bootTime.map { $0.formatted(date: .abbreviated, time: .shortened) }
                ),
                ("Uptime", facts.bootTime.map { HardwareUptime.string(since: $0) }),
                ("Secure boot", facts.secureBoot),
            ])
        }
    }

    // MARK: - Sensors

    /// Every temperature domain as a quarter-width chart block in the same
    /// style as the Processes tab's detail rail: a titled `MetricChart` of
    /// the domain's hottest sensor over a fixed five-minute window, live at
    /// the app's refresh cycle while this page is visible. Clicking a block
    /// opens a live sheet listing every individual sensor behind the figure.
    private var sensorsCard: some View {
        let groups = sensorLive.groups.isEmpty ? (facts.sensorGroups ?? []) : sensorLive.groups
        let fans = sensorLive.groups.isEmpty ? (facts.fanRPMs ?? []) : sensorLive.fans
        return HardwarePanel(
            "Sensors", systemImage: "thermometer.medium", action: { model.selectedID = "sensors" }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if groups.isEmpty, facts.sensorGroups != nil {
                    Text("No readable temperature sensors on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if groups.isEmpty {
                    pending
                } else {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                            count: 4),
                        alignment: .leading, spacing: 14
                    ) {
                        ForEach(groups, id: \.name) { group in
                            // `group.name` stays the raw English domain name
                            // everywhere else (it is a dictionary key into
                            // `sensorLive.samples` and is matched against the
                            // literals in `sensorSymbol`); only the on-screen
                            // title is translated.
                            SensorChartBlock(
                                title: t(group.name),
                                systemImage: Self.sensorSymbol(group.name),
                                value: "\(Int((group.readings.first ?? 0).rounded()))\u{00B0}C",
                                tint: SensorHeat.color(group.readings.first ?? 0, in: colorScheme),
                                samples: sensorLive.samples[group.name] ?? [],
                                minTop: 60,
                                yFormat: { "\(Int(max($0, 0).rounded()))\u{00B0}" },
                                action: { detailGroup = SensorDetailSelection(name: group.name) }
                            )
                        }
                        if !fans.isEmpty {
                            SensorChartBlock(
                                title: t("Fans"),
                                systemImage: "fanblades",
                                value: (fans.max() ?? 0) == 0
                                    ? t("Off") : t("%@ rpm", "\(fans.max() ?? 0)"),
                                tint: (fans.max() ?? 0) == 0 ? .secondary : .teal,
                                samples: sensorLive.samples[SensorLiveStore.fansKey] ?? [],
                                minTop: 2000,
                                yFormat: { "\(Int(max($0, 0).rounded()))" },
                                action: {
                                    detailGroup = SensorDetailSelection(
                                        name: SensorLiveStore.fansKey)
                                }
                            )
                        }
                    }
                    Text(
                        LocalizedStringKey(
                            "Each chart is the hottest sensor of its domain over the last five "
                                + "minutes, live at the refresh cycle. Click a chart to watch "
                                + "every sensor behind it; Details lists the raw keys.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .onReceive(sampler.liveTick) {
            guard appState.mainWindowVisible else { return }
            sensorLive.sweepIfDue(floor: detailGroup == nil ? 5 : 2)
        }
        .onAppear {
            sensorLive.seedFromHistory(sampler)
            sensorLive.sweepIfDue()
        }
        .sheet(item: $detailGroup) { selection in
            SensorDetailSheet(store: sensorLive, groupName: selection.name)
        }
    }

    private static func sensorSymbol(_ group: String) -> String {
        switch group {
        case "CPU die (P cores)", "CPU die (E cores)": return "cpu"
        case "GPU clusters": return "square.grid.3x3.fill"
        case "SSD": return "internaldrive"
        case "Battery": return "minus.plus.batteryblock"
        case "Airflow": return "wind"
        case "Wireless": return "wifi"
        case "Voltage rails": return "bolt"
        default: return "thermometer.medium"
        }
    }

    private var pending: some View {
        HStack(spacing: 6) {
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.isRefreshing ? "Reading\u{2026}" : "Not reported")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The temperature-to-color ramp for the sensor card figures: cool blue at
/// room temperature through amber to red near the die limit. The ramp is
/// per-appearance: the bright ramp only reads against a dark backdrop, so
/// light mode gets a darker, more saturated variant that stays legible on
/// the grey panel.
private enum SensorHeat {
    static func color(_ celsius: Double, in scheme: ColorScheme) -> Color {
        let t = min(max((celsius - 20) / 80, 0), 1)
        let hue = 0.58 * (1 - t)
        return scheme == .dark
            ? Color(hue: hue, saturation: 0.72, brightness: 0.92)
            : Color(hue: hue, saturation: 0.9, brightness: 0.58)
    }
}

/// Identifies the open per-sensor sheet.
private struct SensorDetailSelection: Identifiable {
    var name: String
    var id: String { name }
}

/// Live channel behind the overview's sensor charts: one queue-confined
/// reader whose first sweep pays discovery and whose repeats re-read only the
/// known keys (tens of milliseconds), throttled so a fast dial cannot turn
/// the full sensor set into a hot loop. Each sweep appends the per-domain
/// hottest (and the fastest fan) to a trailing five-minute trend, and keeps
/// the individual named readings for the detail sheet.
private final class SensorLiveStore: ObservableObject {
    static let fansKey = "Fans"
    static let chartSpan: TimeInterval = 5 * 60

    @Published private(set) var groups: [HardwareFacts.SensorGroup] = []
    @Published private(set) var fans: [Int] = []
    /// Trailing five-minute trend per group name (plus `fansKey`), oldest
    /// first, appended once per sweep.
    @Published private(set) var samples: [String: [MetricSample]] = [:]
    /// Every named reading of the latest sweep, hottest first, per group.
    @Published private(set) var sensorsByGroup: [String: [SensorValue]] = [:]

    private let queue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.sensor-live", qos: .utility)
    /// Confined to `queue`.
    private let reader = SensorInventoryReader()
    private var lastSweep: Date?
    private var inFlight = false
    private var didSeed = false

    /// Seed every chart from the recorded history so a restart resumes the
    /// trend instead of starting blank. Groups with no persisted column, and a
    /// database that predates them, simply stay empty and fill from the live
    /// sweeps. Safe to call repeatedly; only the first call reads.
    func seedFromHistory(_ model: SamplerModel) {
        guard !didSeed else { return }
        didSeed = true
        model.loadRecentSystemHistory(seconds: Self.chartSpan) { [weak self] points in
            guard let self, !points.isEmpty else { return }
            var seeded: [String: [MetricSample]] = [:]
            for group in HardwareFacts.SensorGroup.displayOrder {
                let series = points.compactMap { point in
                    HardwareFacts.SensorGroup.recordedValue(group, in: point)
                        .map { MetricSample(date: point.date, value: $0) }
                }
                if !series.isEmpty { seeded[group] = series }
            }
            let fanSeries = points.compactMap { point in
                point.fanRPM.map { MetricSample(date: point.date, value: $0) }
            }
            if !fanSeries.isEmpty { seeded[Self.fansKey] = fanSeries }
            guard !seeded.isEmpty else { return }
            // Live sweeps may have landed while the read was in flight; keep
            // any samples newer than the seed rather than dropping them.
            for (key, series) in seeded {
                let seedEnd = series.last?.date ?? .distantPast
                let live = (self.samples[key] ?? []).filter { $0.date > seedEnd }
                self.samples[key] = series + live
            }
        }
    }

    /// `floor` is the minimum interval between SMC sweeps: the card row uses
    /// 5 s, and the open detail sheet tightens it so its rows track closer to
    /// real time.
    func sweepIfDue(now: Date = Date(), floor minInterval: TimeInterval = 5) {
        if let lastSweep, now.timeIntervalSince(lastSweep) < minInterval { return }
        guard !inFlight else { return }
        inFlight = true
        lastSweep = now
        queue.async { [weak self] in
            guard let self else { return }
            let (groups, fans, sensors) = self.reader.read()
            let byGroup = Dictionary(grouping: sensors, by: \.group)
                .mapValues { $0.sorted { $0.celsius > $1.celsius } }
            DispatchQueue.main.async {
                self.inFlight = false
                self.groups = groups
                self.fans = fans
                self.sensorsByGroup = byGroup
                var next = self.samples
                let cutoff = now.addingTimeInterval(-Self.chartSpan - 30)
                for group in groups {
                    guard let hottest = group.readings.first else { continue }
                    var series = next[group.name] ?? []
                    series.append(MetricSample(date: now, value: hottest))
                    series.removeAll { $0.date < cutoff }
                    next[group.name] = series
                }
                if !fans.isEmpty {
                    var series = next[Self.fansKey] ?? []
                    series.append(MetricSample(date: now, value: Double(fans.max() ?? 0)))
                    series.removeAll { $0.date < cutoff }
                    next[Self.fansKey] = series
                }
                self.samples = next
            }
        }
    }
}

/// One domain in the Sensors panel, drawn like the Processes tab's detail
/// rail: a titled `MetricChart` of the hottest sensor over a fixed
/// five-minute window, with the current figure trailing the title. The whole
/// block is a button opening the live per-sensor sheet.
private struct SensorChartBlock: View {
    let title: String
    let systemImage: String
    let value: String
    let tint: Color
    let samples: [MetricSample]
    let minTop: Double
    let yFormat: (Double) -> String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(title, systemImage: systemImage)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(value)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint)
                }
                MetricChart(
                    samples: samples, tint: tint, minTop: minTop,
                    windowSeconds: SensorLiveStore.chartSpan, accessibilityTitle: title,
                    yFormat: yFormat
                )
                .equatable()
                .frame(height: 96)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t("Watch every %@ sensor live", title))
    }
}

/// The deep-dive modal: every sensor behind one domain figure, re-sorted and
/// re-read live while the sheet is open (the host tightens the sweep floor).
private struct SensorDetailSheet: View {
    @ObservedObject var store: SensorLiveStore
    let groupName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(t(groupName), systemImage: "thermometer.medium")
                    .font(.headline)
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if groupName == SensorLiveStore.fansKey {
                fanRows
            } else {
                sensorRows
            }
        }
        .frame(width: 440, height: 520)
    }

    private var subtitle: String {
        if groupName == SensorLiveStore.fansKey {
            return store.fans.count == 1
                ? t("1 fan, live") : t("%@ fans, live", "\(store.fans.count)")
        }
        let count = store.sensorsByGroup[groupName]?.count ?? 0
        return count == 1 ? t("1 sensor, live") : t("%@ sensors, live", "\(count)")
    }

    private var sensorRows: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(store.sensorsByGroup[groupName] ?? []) { sensor in
                    GridRow {
                        Text(sensor.key)
                            .font(.callout.monospaced())
                            .gridColumnAlignment(.leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary.opacity(0.5))
                                Capsule()
                                    .fill(SensorHeat.color(sensor.celsius, in: colorScheme))
                                    .frame(
                                        width: proxy.size.width
                                            * min(max((sensor.celsius - 20) / 90, 0.02), 1))
                            }
                        }
                        .frame(height: 7)
                        .gridCellUnsizedAxes(.vertical)
                        Text(String(format: "%.1f\u{00B0}C", sensor.celsius))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(SensorHeat.color(sensor.celsius, in: colorScheme))
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .padding(16)
        }
    }

    private var fanRows: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(Array(store.fans.enumerated()), id: \.offset) { index, rpm in
                    GridRow {
                        Text(t("Fan %@", "\(index + 1)"))
                            .font(.callout)
                            .gridColumnAlignment(.leading)
                        Text(rpm == 0 ? t("Off") : t("%@ rpm", "\(rpm)"))
                            .font(.callout.monospacedDigit())
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .padding(16)
        }
    }
}

/// Label/value rows for a card, skipping facts that are not known yet.
private struct HardwareFactRows: View {
    // The label half of each row is always a literal at the call site (a
    // LocalizedStringKey), so it re-resolves against the translation table
    // itself; the value half is the device's own data (a String) and is
    // rendered verbatim.
    let rows: [(LocalizedStringKey, String?)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let value = row.1 {
                    GridRow {
                        Text(row.0)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(value)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .font(.callout)
    }
}

enum HardwareUptime {
    static func string(since boot: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(boot))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 || days > 0 { parts.append("\(hours)h") }
        parts.append("\(minutes)m")
        return parts.joined(separator: " ")
    }
}

// MARK: - Drawings

/// The system on a chip as blocks: CPU clusters with one square per core,
/// the GPU's cores, the Neural Engine, and the unified memory underneath.
private struct SoCDiagram: View {
    let facts: HardwareFacts

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HardwareFlowLayout(spacing: 8, equalHeights: true) {
                cpuBlock
                gpuBlock
                aneBlock
            }
            memoryBlock
            legend
        }
    }

    private var cpuBlock: some View {
        SoCBlock(title: "CPU", subtitle: cpuSubtitle) {
            VStack(alignment: .leading, spacing: 8) {
                if let p = facts.performanceCores {
                    CoreGrid(count: p, color: .orange, label: t("%@ performance", "\(p)"))
                }
                if let e = facts.efficiencyCores {
                    CoreGrid(count: e, color: .teal, label: t("%@ efficiency", "\(e)"))
                }
                if facts.performanceCores == nil, facts.efficiencyCores == nil {
                    Text("Reading\u{2026}").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cpuSubtitle: String {
        let total = (facts.performanceCores ?? 0) + (facts.efficiencyCores ?? 0)
        guard total > 0 else { return "" }
        return total == 1 ? t("1 core") : t("%@ cores", "\(total)")
    }

    private var gpuBlock: some View {
        SoCBlock(title: "GPU", subtitle: coreCountSubtitle(facts.gpuCores)) {
            if let cores = facts.gpuCores {
                // Seven across: 14-core and 28-core parts fill their rows.
                CoreGrid(
                    count: cores, color: .green, label: facts.metalSupport ?? "Metal", )
            } else {
                Text("Reading\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "1 core" / "%@ cores", or empty while the count is still unknown.
    private func coreCountSubtitle(_ count: Int?) -> String {
        guard let count else { return "" }
        return count == 1 ? t("1 core") : t("%@ cores", "\(count)")
    }

    private var aneBlock: some View {
        SoCBlock(
            title: "Neural Engine", subtitle: coreCountSubtitle(facts.neuralEngineCores)
        ) {
            VStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 22))
                    .foregroundStyle(.pink)
                if let cores = facts.neuralEngineCores {
                    CoreGrid(count: cores, color: .pink, label: nil, maxPerRow: 8, size: 7)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var memoryBlock: some View {
        HStack {
            Image(systemName: "memorychip")
                .foregroundStyle(.purple)
            Text("Unified memory")
                .font(.callout.weight(.medium))
            Spacer()
            Text(memoryText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.purple.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.35), lineWidth: 1))
    }

    private var memoryText: String {
        var parts: [String] = []
        if let bytes = facts.memoryBytes {
            parts.append(ByteFormat.string(bytes, fractionDigits: 0))
        }
        if let type = facts.memoryType { parts.append(type) }
        return parts.isEmpty ? "Reading\u{2026}" : parts.joined(separator: ", ")
    }

    private var legend: some View {
        HardwareFlowLayout(spacing: 12) {
            legendItem(.orange, "Performance core")
            legendItem(.teal, "Efficiency core")
            legendItem(.green, "GPU core")
            legendItem(.pink, "Neural Engine core")
            if let chip = facts.chipName {
                Text(chip)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
        }
    }
}

private struct SoCBlock<Content: View>: View {
    // Always a literal at the call site; subtitle stays String because it is
    // built at runtime (a translated "%@ cores" or similar).
    let title: LocalizedStringKey
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(8)
        .frame(minWidth: 100, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

/// One square per core, wrapped into rows.
private struct CoreGrid: View {
    let count: Int
    let color: Color
    let label: String?
    /// The widest a row gets; the grid then balances its rows, so 14 cores
    /// draw as 7 + 7, 24 as 8 + 8 + 8, and an 80-core GPU as 8 rows of 10.
    var maxPerRow: Int = 10
    var size: CGFloat = 12

    private var rows: Int { max(1, (count + maxPerRow - 1) / maxPerRow) }
    private var columns: Int { max(1, (count + rows - 1) / rows) }
    /// Smaller squares past 40 cores keep the biggest chips compact.
    private var side: CGFloat { count > 40 ? size * 0.8 : size }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < count {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(color.opacity(0.85))
                                .frame(width: side, height: side)
                        }
                    }
                }
            }
            if let label {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HardwareCapacityBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint.opacity(0.8))
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
    }
}

private struct HealthRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.callout.weight(.semibold).monospacedDigit())
        }
    }

    private var color: Color {
        if fraction >= 0.8 { return .green }
        if fraction >= 0.6 { return .orange }
        return .red
    }
}

/// A display drawn to its aspect ratio, labelled with its resolution.
private struct DisplayGlyph: View {
    let display: HardwareFacts.Display

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5)
                )
                .overlay(alignment: .topTrailing) {
                    if display.isMain {
                        Text("Main")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .padding(4)
                    }
                }
                .frame(width: 130, height: 130 * aspect)
            Text(display.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if display.pixelWidth > 0 {
                Text("\(display.pixelWidth) x \(display.pixelHeight) pixels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let resolution = display.resolution {
                Text(resolution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(display.isBuiltIn ? "Built-in" : "External")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 150, alignment: .leading)
    }

    private var aspect: CGFloat {
        guard display.pixelWidth > 0, display.pixelHeight > 0 else { return 0.625 }
        return CGFloat(display.pixelHeight) / CGFloat(display.pixelWidth)
    }
}
