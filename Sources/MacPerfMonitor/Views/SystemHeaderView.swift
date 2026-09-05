import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The processor summary shown above the process list — the CPU context the
/// table itself lacks. A total-CPU card (with a two-hour trend), the live
/// per-core utilisation grid, and the load average, plus a slim coverage line
/// specific to this tab. (Memory has its own full breakdown on the Dashboard.)
struct SystemHeaderView: View {
    let snapshot: Sampler.Snapshot?
    @EnvironmentObject private var helper: HelperManager
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState

    /// The two-hour CPU window and the feeds behind the live parts of the
    /// header (usage value and sparkline, core grid, load figure). Appended on
    /// every tick; this view's body re-renders only with the model's publish.
    @StateObject private var live = ProcessHeaderStore()

    var body: some View {
        // Prefer the smoothed live CPU (matches the Dashboard's Processor panel),
        // falling back to the snapshot's raw sample before the first smooth lands.
        let cpu = model.smoothedCPU ?? snapshot?.cpu
        var cards = CPUMetrics.cards(cpu: cpu, history: [], span: ProcessHeaderStore.headerSpan)
        if !cards.isEmpty { cards[0].live = live.usageFeed }
        if cards.count > 1 { cards[1].live = live.loadFeed }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("PROCESSOR")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let count = cpu?.cores.count, count > 0 {
                    Text("\(count) cores")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // Total CPU · live per-core grid · load average. The grid is the
            // dynamic centrepiece, updating each tick with the rest of the header.
            HStack(alignment: .top, spacing: 12) {
                if let usage = cards.first {
                    MetricCard(data: usage).frame(maxWidth: .infinity)
                }
                CPUCoreCard(feed: live.coreFeed).frame(maxWidth: .infinity)
                if cards.count > 1 {
                    MetricCard(data: cards[1]).frame(maxWidth: .infinity)
                }
                if live.hasTemperature {
                    MetricCard(data: temperatureCard).frame(maxWidth: .infinity)
                }
            }
            // Cap the row at the tallest card's natural height (the core grid) so it
            // sizes to content instead of grabbing a share of the window.
            .fixedSize(horizontal: false, vertical: true)
            coverageLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear(perform: reload)
        .onChange(of: appState.mainWindowVisible) { _, visible in if visible { reload() } }
        // The window grows in place at the dial rate; nothing here re-renders
        // for it (the feeds repaint their AppKit surfaces).
        .onReceive(model.liveTick) {
            // Collect while covered, draw only when visible: see the same
            // change in DashboardView. A hidden window must not punch a hole in
            // the history it shows when it comes back.
            live.append(
                model.liveSystem, cpu: model.smoothedCPU, liveCPU: model.liveCPU,
                publish: appState.mainWindowVisible)
        }
    }

    private func reload() {
        model.loadRecentSystemHistory(seconds: ProcessHeaderStore.headerSpan) { points in
            live.replace(
                points, live: model.liveSystem, cpu: model.smoothedCPU,
                liveCPU: model.liveCPU)
        }
    }

    /// The die-temperature card, live-fed like the total-CPU card. Only added
    /// to the row once a temperature has actually been seen.
    private var temperatureCard: MetricCardData {
        MetricCardData(
            label: "CPU die",
            unit: .celsius,
            yDomain: 0...110,
            help:
                "The hottest CPU die sensor. The colour follows macOS's thermal pressure: "
                + "green means hot but working as designed. Click for details.",
            explanation: MetricExplanation(
                meaning:
                    "The hottest of the CPU die's temperature sensors, the figure people mean by \u{201C}CPU temperature\u{201D}. High numbers under load are normal on Apple silicon; the colour turns orange or red only when macOS itself reports thermal pressure, the signal that it is slowing work down.",
                calculation:
                    "Every P-core and E-core cluster sensor the SMC exposes is read on a short throttle, and the card shows the maximum. The trend behind it is the same two-hour window as the other header cards."
            ),
            live: live.temperatureFeed)
    }

    // MARK: - Coverage

    /// A slim line beneath the cards: process count, plus an honest note and a
    /// one-tap fix when some processes are not fully readable.
    @ViewBuilder
    private var coverageLine: some View {
        if let snapshot {
            HStack(spacing: 8) {
                Text(String(format: String(localized: "%d processes"), snapshot.processes.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshot.unreadableProcessCount > 0 {
                    Text("\u{2022}")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(
                        String(
                            format: String(localized: "%d not readable"),
                            snapshot.unreadableProcessCount)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(
                        "Some processes are owned by other users or the system, so macOS does not allow \(AppInfo.displayName) to read their full memory figures."
                    )
                    coverageAction
                }
                Spacer()
            }
        }
    }

    /// A one-tap shortcut to close the coverage gap, shown only when the helper
    /// can actually help (it is available but not yet active).
    @ViewBuilder
    private var coverageAction: some View {
        switch helper.coverage {
        case .disabled:
            Button("Enable full coverage\u{2026}") { helper.enable() }
                .buttonStyle(.link)
                .font(.caption2)
        case .requiresApproval:
            Button("Approve in Settings\u{2026}") { helper.openApprovalSettings() }
                .buttonStyle(.link)
                .font(.caption2)
        case .enabled, .unavailable:
            EmptyView()
        }
    }
}

/// The live per-core utilisation grid presented as a header card, matching the
/// metric cards' chrome so it sits in the row beside them. Unlike a metric card
/// it has no detail modal — the live bars and the cluster-average legend (carried
/// by `CoreGridView`) are the content. Redraws each tick with the header, so the
/// bars move in real time.
private struct CPUCoreCard: View {
    let feed: CoreGridFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(CoreKind.performance.accent)
                    .frame(width: 6, height: 6)
                Text("CORES")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            CoreGridSurface(feed: feed, barHeight: 50)
        }
        // Match the metric cards' fill so all three header cards are one height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// The Processes header's live channel: a two-hour window of system samples
/// (seeded from the database, grown in place on every tick) and the feeds the
/// header's AppKit surfaces repaint from. The table's full publish runs every
/// 5 s; this keeps the CPU figure, its sparkline and the core grid at the
/// dial rate without re-rendering any SwiftUI view. Main thread only.
@MainActor
final class ProcessHeaderStore: ObservableObject {
    /// Ten minutes, not two hours. The strip is about 350 points wide, so a two
    /// hour window at the sampler's cadence put roughly twenty samples in every
    /// pixel column and painted the spike from each one: the result read as a
    /// band of noise whose height was worst case, not typical. Ten minutes is
    /// close to one sample per column, which is what makes the charts on the
    /// right legible.
    private var window = SystemHistoryWindow(span: ProcessHeaderStore.headerSpan)

    /// Shared by the window and the history load so they cannot drift apart.
    static let headerSpan: TimeInterval = 10 * 60

    let usageFeed = MetricCardFeed()
    let loadFeed = MetricCardFeed()
    let coreFeed = CoreGridFeed()
    let temperatureFeed = MetricCardFeed()
    /// True once any die-temperature sample has been seen, so the header only
    /// grows the fourth card on machines that actually report one.
    @Published private(set) var hasTemperature = false

    func replace(
        _ points: [SystemHistoryPoint], live: SystemSample?, cpu: CPUSample?,
        liveCPU: CPUSample?
    ) {
        window.replace(points)
        if let live { window.append(Self.point(from: live)) }
        publish(cpu, system: live, liveCPU: liveCPU)
    }

    func append(
        _ system: SystemSample?, cpu: CPUSample?, liveCPU: CPUSample?, publish shouldPublish: Bool
    ) {
        if let system { window.append(Self.point(from: system)) }
        guard shouldPublish else { return }
        publish(cpu, system: system, liveCPU: liveCPU)
    }

    private func publish(_ cpu: CPUSample?, system: SystemSample?, liveCPU: CPUSample?) {
        let level = CPULevel(fraction: cpu?.totalUsage ?? 0)
        usageFeed.publish(
            value: cpu.map { "\(Int(($0.totalUsage * 100).rounded()))%" },
            tint: NSColor(level.color), column: LiveColumn(window, .cpuLoad), scale: 100,
            xDomain: window.xDomain, yDomain: 0...100,
            peak: window.peak(.cpuLoad).map { t("peak %@%%", String(Int(($0 * 100).rounded()))) })
        // The load averages come from the window like every other metric, so
        // the card shows history the moment the tab opens and the detail sheet
        // has the same series. All three are drawn: the 1 minute figure as the
        // line, the 5 and 15 minute figures as fainter lines behind it, the way
        // beszel draws load, so a spike and the trend it sits on read together.
        let (loadTimes, load1, load5, load15) = Self.recordedLoad(window)
        let loadColumn = LiveColumn(
            times: loadTimes, values: load1.values, highs: load1.highs)
        let load5Column = LiveColumn(times: loadTimes, values: load5)
        let load15Column = LiveColumn(times: loadTimes, values: load15)
        // Full height is one process per core, so the chart reads as "how close
        // to fully subscribed", and it stretches when load goes past that.
        let loadTop = max(
            Double(cpu?.cores.count ?? 0), loadColumn.range?.max ?? 0,
            load5Column.range?.max ?? 0, load15Column.range?.max ?? 0, 1)
        loadFeed.publish(
            value: cpu.map { String(format: "%.2f", $0.loadAverage1) },
            tint: NSColor(CPUMetrics.loadColor(cpu)), column: loadColumn, scale: 1,
            xDomain: window.xDomain, yDomain: 0...loadTop,
            peak: loadColumn.range.map { t("peak %@", String(format: "%.2f", $0.max)) },
            // The card's second line labels these two, so the fainter lines
            // read without a legend the strip has no room for; the detail
            // sheet draws the legend.
            companions: [
                MetricCardCompanion(
                    label: "5 min", column: load5Column, alpha: 0.6, lineWidth: 1.2),
                MetricCardCompanion(
                    label: "15 min", column: load15Column, alpha: 0.35, lineWidth: 1),
            ])
        // The bars show the sample as measured. The cards above them stay
        // smoothed: a jittering percentage is unreadable, a still core grid is
        // uninformative.
        coreFeed.publish((liveCPU ?? cpu)?.cores ?? [])
        // The temperature card: hottest die sensor, tinted by macOS's own
        // thermal pressure verdict (green means "hot but working as designed").
        let die = system?.cpuDieC ?? window.peakLatestCPUDie
        if die != nil, !hasTemperature { hasTemperature = true }
        let pressure = system?.thermalPressure ?? .nominal
        // Zoom to the readings rather than 0 to 110: a die that lives between 60
        // and 75 degrees drew a flat line across the bottom sixth of the strip.
        // A minimum span keeps a steady temperature from being magnified into
        // noise, and the padding stops the line touching the edges.
        let dieColumn = LiveColumn(window, .cpuDieC)
        let dieRange = dieColumn.range
        let dieDomain =
            dieRange.map {
                ChartDomain.fitted(
                    min: $0.min, max: $0.max, minimumSpan: 10, padding: 2, floor: 0)
            } ?? 20...90
        temperatureFeed.publish(
            value: die.map { "\(Int($0.rounded()))°C" },
            tint: NSColor(pressure.color), column: dieColumn, scale: 1,
            xDomain: window.xDomain, yDomain: dieDomain,
            peak: window.peak(.cpuDieC).flatMap {
                $0 > 0 ? t("peak %@°C", String(Int($0.rounded()))) : nil
            },
            // Rule 2: a thermal spike is the event, so the line follows the
            // bucket maximum rather than its mean.
            reduction: .maximum)
    }

    private static func point(from s: SystemSample) -> SystemHistoryPoint {
        SystemHistoryPoint(
            date: s.timestamp,
            pressurePercent: s.pressurePercent,
            appMemory: s.appMemory,
            wired: s.wired,
            compressed: s.compressed,
            cachedFiles: s.cachedFiles,
            swapUsed: s.swapUsed,
            cpuLoad: s.cpuLoad,
            loadAverage1: s.loadAverage1,
            loadAverage5: s.loadAverage5,
            loadAverage15: s.loadAverage15,
            cpuDieC: s.cpuDieC
        )
    }

    /// The window's load averages, without the rows that have none. Rows
    /// written before the load averages were recorded read as zero, and a load
    /// average is never zero on a running Mac, so zero means "not recorded"
    /// rather than "idle"; drawing it would put a false floor under the chart
    /// for the first ten minutes after the upgrade.
    private static func recordedLoad(
        _ window: SystemHistoryWindow
    ) -> (
        times: ArraySlice<Double>, load1: (values: ArraySlice<Double>, highs: ArraySlice<Double>),
        load5: ArraySlice<Double>, load15: ArraySlice<Double>
    ) {
        let times = window.timestamps
        let load1 = window.values(.loadAverage1)
        let peak1 = window.values(.loadAverage1Peak)
        let load5 = window.values(.loadAverage5)
        let load15 = window.values(.loadAverage15)
        if !load1.contains(0) {
            return (times, (load1, peak1), load5, load15)
        }
        var t: [Double] = []
        var v1: [Double] = []
        var h1: [Double] = []
        var v5: [Double] = []
        var v15: [Double] = []
        for (offset, value) in load1.enumerated() where value > 0 {
            t.append(times[times.startIndex + offset])
            v1.append(value)
            h1.append(peak1[peak1.startIndex + offset])
            v5.append(load5[load5.startIndex + offset])
            v15.append(load15[load15.startIndex + offset])
        }
        return (t[...], (v1[...], h1[...]), v5[...], v15[...])
    }
}

extension SystemHistoryWindow {
    /// The newest non-zero die temperature, so the header card still shows a
    /// figure between SMC reads (live ticks carry thermal only on GPU-read
    /// ticks) and right after a DB seed.
    fileprivate var peakLatestCPUDie: Double? {
        values(.cpuDieC).reversed().first { $0 > 1 }
    }
}
