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
        var cards = CPUMetrics.cards(cpu: cpu, history: [], span: 2 * 3600)
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
            guard appState.mainWindowVisible else { return }
            live.append(model.liveSystem, cpu: model.smoothedCPU)
        }
    }

    private func reload() {
        model.loadRecentSystemHistory(seconds: 2 * 3600) { points in
            live.replace(points, live: model.liveSystem, cpu: model.smoothedCPU)
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
                    "The hottest of the CPU die's temperature sensors, the figure people mean "
                    + "by \u{201C}CPU temperature\u{201D}. High numbers under load are normal on "
                    + "Apple silicon; the colour turns orange or red only when macOS itself "
                    + "reports thermal pressure, the signal that it is slowing work down.",
                calculation:
                    "Every P-core and E-core cluster sensor the SMC exposes is read on a short "
                    + "throttle, and the card shows the maximum. The trend behind it is the "
                    + "same two-hour window as the other header cards."),
            live: live.temperatureFeed)
    }

    // MARK: - Coverage

    /// A slim line beneath the cards: process count, plus an honest note and a
    /// one-tap fix when some processes are not fully readable.
    @ViewBuilder
    private var coverageLine: some View {
        if let snapshot {
            HStack(spacing: 8) {
                Text("\(snapshot.processes.count) processes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshot.unreadableProcessCount > 0 {
                    Text("\u{2022}")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("\(snapshot.unreadableProcessCount) not readable")
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
            CoreGridSurface(feed: feed, barHeight: 40)
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
    private var window = SystemHistoryWindow(span: 2 * 3600)
    let usageFeed = MetricCardFeed()
    let loadFeed = MetricCardFeed()
    let coreFeed = CoreGridFeed()
    let temperatureFeed = MetricCardFeed()
    /// True once any die-temperature sample has been seen, so the header only
    /// grows the fourth card on machines that actually report one.
    @Published private(set) var hasTemperature = false

    func replace(_ points: [SystemHistoryPoint], live: SystemSample?, cpu: CPUSample?) {
        window.replace(points)
        if let live { window.append(Self.point(from: live)) }
        publish(cpu, system: live)
    }

    func append(_ system: SystemSample?, cpu: CPUSample?) {
        if let system { window.append(Self.point(from: system)) }
        publish(cpu, system: system)
    }

    private func publish(_ cpu: CPUSample?, system: SystemSample?) {
        let level = CPULevel(fraction: cpu?.totalUsage ?? 0)
        usageFeed.publish(
            value: cpu.map { "\(Int(($0.totalUsage * 100).rounded()))%" },
            tint: NSColor(level.color), column: LiveColumn(window, .cpuLoad), scale: 100,
            xDomain: window.xDomain, yDomain: 0...100)
        loadFeed.publish(
            value: cpu.map { String(format: "%.2f", $0.loadAverage1) }, tint: .labelColor,
            column: nil, xDomain: nil, yDomain: nil)
        coreFeed.publish(cpu?.cores ?? [])
        // The temperature card: hottest die sensor, tinted by macOS's own
        // thermal pressure verdict (green means "hot but working as designed").
        let die = system?.cpuDieC ?? window.peakLatestCPUDie
        if die != nil, !hasTemperature { hasTemperature = true }
        let pressure = system?.thermalPressure ?? .nominal
        temperatureFeed.publish(
            value: die.map { "\(Int($0.rounded()))°C" },
            tint: NSColor(pressure.color), column: LiveColumn(window, .cpuDieC), scale: 1,
            xDomain: window.xDomain, yDomain: 0...110)
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
            cpuDieC: s.cpuDieC
        )
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
