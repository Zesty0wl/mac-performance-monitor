import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The panel identity is shared by its header action and its detail sheet.
/// Headline metric cards keep their own, shared MetricCard detail path.
enum DashboardDetailKind: String {
    case pressure, processor, network, disk, cores, composition, swap, thermals, topCPU, topDisk

    var title: String {
        switch self {
        case .pressure: return t("Memory pressure")
        case .processor: return t("Processor")
        case .network: return t("Network")
        case .disk: return t("Physical disk")
        case .cores: return t("CPU cores")
        case .composition: return t("Memory composition")
        case .swap: return t("Swap")
        case .thermals: return t("Thermals")
        case .topCPU: return t("Top CPU processes")
        case .topDisk: return t("Top disk processes")
        }
    }

    var systemImage: String {
        switch self {
        case .pressure: return "gauge.with.dots.needle.50percent"
        case .processor, .cores: return "cpu"
        case .network: return "network"
        case .disk, .swap: return "internaldrive"
        case .composition: return "chart.bar.fill"
        case .thermals: return "thermometer.medium"
        case .topCPU, .topDisk: return "list.number"
        }
    }

    var isRanking: Bool { self == .topCPU || self == .topDisk }
    var isCurrentState: Bool { self == .cores || self == .composition }

    var meaning: LocalizedStringKey {
        switch self {
        case .pressure:
            return
                "The pressure index describes how hard macOS is working to meet memory demand. It is not the percentage of RAM in use. The kernel's normal, warning, and critical states anchor the scale."
        case .processor:
            return
                "Total CPU is the share of all logical cores in use, from 0 to 100%. High use can be healthy during demanding work. A narrow range means steady demand; a wide range means bursts."
        case .network:
            return
                "Download and upload show the bytes transferred each second across physical network interfaces. They measure traffic, not your connection's maximum speed. The two directions have separate averages and ranges."
        case .disk:
            return
                "Read and write show physical traffic across real internal and external disks. Throughput is not the same as disk capacity, latency, or busy time. A burst can be brief even when its peak is high."
        case .cores:
            return
                "Each bar shows the busy share of one logical core in the captured sample. Performance and efficiency cores serve different workloads. An uneven spread can reflect normal scheduling or work that uses only one thread."
        case .composition:
            return
                "This is how physical RAM was divided when the snapshot was taken. Cached files can be reclaimed, so occupied RAM is not automatically a problem. Swap lives on disk and is not part of this stack."
        case .swap:
            return
                "Swap is memory held on disk rather than in RAM. A nonzero balance alone does not mean the Mac is struggling. A sustained rise alongside memory pressure is more useful evidence."
        case .thermals:
            return
                "CPU and GPU temperatures come from separate sensors. A gap means a reading was unavailable, not zero degrees. A high temperature alone does not prove throttling; macOS reports its thermal state separately."
        case .topCPU:
            return
                "These processes had the highest recorded mean CPU use in the selected range. Values are percentages of one core, so a process using several cores can exceed 100%. They are not the whole-machine percentages shown in the Processor chart."
        case .topDisk:
            return
                "These processes had the highest mean kernel-attributed disk throughput in the selected range. Each value combines attributed reads and writes. These figures do not necessarily add up to the physical disk chart."
        }
    }

    var investigation: LocalizedStringKey {
        switch self {
        case .pressure:
            return
                "Compare sustained pressure with compressed memory and swap. Use the Processes tab to find large or growing footprints. A short spike is different from pressure that stays high."
        case .processor:
            return
                "Compare the mean with the observed range, then inspect CPU cores and Top CPU processes. Load averages describe queued or running work, not a percentage. Compare them with the machine's core count."
        case .network:
            return
                "Hover an interval to compare download and upload. Check for downloads, backups, or sync activity at the same time. Enable per-app network tracking in Settings when you need attribution."
        case .disk:
            return
                "Compare read and write bursts with Top disk processes. Use the Disk tab to inspect device busy time and latency. Caching and delayed writes can shift physical traffic away from the process activity that caused it."
        case .cores:
            return
                "Compare busy, user, and system time for each core. Use Top CPU processes to identify the workload. Reopen this sheet for a fresh sample; no historical per-core series is recorded for this view."
        case .composition:
            return
                "Compare this breakdown with pressure and swap before judging free memory. Check the Processes tab for growing app footprints. Cached files usually need no action because macOS can release that space."
        case .swap:
            return
                "Look for sustained growth, then compare pressure, compression, and app memory. Disk activity may increase while memory moves between RAM and swap. A flat swap balance can remain after the workload ends."
        case .thermals:
            return
                "Compare temperatures with CPU activity and macOS thermal state. Check the Energy tab for fans and thermal events. If one sensor is unavailable, do not infer its temperature from the other."
        case .topCPU:
            return
                "Use the full process name, PID, and executable path to identify the workload in the Processes tab. Check the sample count before comparing short-lived processes. Close and reopen this snapshot after the Dashboard ranking refreshes to compare activity."
        case .topDisk:
            return
                "Compare the process names with recent copies, builds, downloads, or backups. Use the Disk tab for physical device measurements. Check sample counts; a short observation can be less representative than a long one."
        }
    }

    var measurement: LocalizedStringKey {
        switch self {
        case .pressure:
            return
                "macOS memory pressure selects the band: normal 0-33, warning 34-66, or critical 67-100. Compression, swap, and their growth place the index within that band. The chart summarizes recorded samples, not a percentage of allocated bytes."
        case .processor:
            return
                "CPU use comes from changes in the kernel's per-core time counters. Busy time includes user and system work. The timeline uses recorded samples; the Dashboard's current numeric readouts are smoothed and are not selected-range means."
        case .network:
            return
                "The sampler divides changes in received and sent byte counters by elapsed time, then sums physical interfaces. Units are bytes per second, not bits per second. Current readouts are smoothed; the chart summarizes recorded rates."
        case .disk:
            return
                "The sampler differences physical block-device counters and divides by elapsed time. Virtual disk images are excluded. IOPS counts read and write operations per second, not bytes. Current throughput readouts are smoothed."
        case .cores:
            return
                "Each percentage is the change in that core's kernel time counters between two samples. User time includes nice-priority work. Idle is the remaining share. The enlarged grid and table use one captured sample, not an average over the selected history range."
        case .composition:
            return
                "Wired, app memory, compressed memory, and cached files come from macOS virtual-memory counters. Free and available is the remainder of total RAM. If counters overlap, the measured categories are scaled to total RAM so the stack still reconciles."
        case .swap:
            return
                "Swap used comes from macOS virtual-memory swap counters and is recorded in bytes. It is a balance, not a transfer rate. Minima and maxima describe observed usage within each interval; missing legacy bounds are not invented."
        case .thermals:
            return
                "The SMC supplies the hottest available CPU die sensor and the hottest available GPU die sensor. macOS supplies thermal state independently. Missing sensor readings remain missing, including explicit gaps within the selected range. The caption identifies the available statistics for older records."
        case .topCPU:
            return
                "Raw CPU rows are weighted by the time each recorded value held. Stored aggregate rows are weighted by their source sample counts. Only recorded, readable process rows contribute. The ranking is limited to 20 processes and refreshes about once a minute; it is not a complete attribution of all system CPU time."
        case .topDisk:
            return
                "The mean uses changes in cumulative attributed read and write bytes across each process's observed portion of the selected range. At least two distinct observation times are needed for a rate. Coverage, caching, and attribution differ from physical device counters. The ranking includes up to 20 recorded processes and refreshes about once a minute."
        }
    }
}

struct DashboardDetailFact: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// These feeds are seeded once at the open action and never connected to the
/// sampler. Reusing the native surfaces preserves their hover and accessibility.
struct DashboardCoreSnapshot {
    let cores: [CoreUsage]
    let feed: CoreGridFeed

    init(cores: [CoreUsage]) {
        self.cores = cores
        let feed = CoreGridFeed()
        feed.publish(cores)
        self.feed = feed
    }
}

struct DashboardCompositionSnapshot {
    let slices: [TaxonomySlice]
    let total: UInt64
    let feed: TaxonomyFeed

    init(slices: [TaxonomySlice], total: UInt64) {
        self.slices = slices
        self.total = total
        let feed = TaxonomyFeed()
        feed.publish(slices: slices, total: total)
        self.feed = feed
    }
}

/// Captured by the header action, not recomputed by the sheet's body. Trend
/// models retain their copy-on-write columns even while the Dashboard appends.
struct DashboardDetailSnapshot: Identifiable {
    enum Content {
        case trend(TrendModel)
        case cores(DashboardCoreSnapshot)
        case composition(DashboardCompositionSnapshot)
        case processes([ProcessConsumer])
    }

    let id = UUID()
    let kind: DashboardDetailKind
    let range: HistoryWindow
    let capturedAt: Date
    let dataTimestamp: Date?
    let content: Content
    let facts: [DashboardDetailFact]
}

struct DashboardDetailSheet: View {
    let snapshot: DashboardDetailSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    detailContent
                    if !snapshot.facts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(
                                snapshot.kind.isRanking ? "Ranking context" : "Readings at capture"
                            )
                            .font(.headline)
                            if !snapshot.kind.isRanking {
                                Text("Current values at capture, not selected-range means.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            factsGrid(snapshot.facts)
                        }
                    }
                    explanation("What it means", snapshot.kind.meaning)
                    explanation("How to investigate", snapshot.kind.investigation)
                    explanation("How it is measured", snapshot.kind.measurement)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Close and reopen for a new snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(
            width: 860,
            height: min(780, max(480, (NSScreen.main?.visibleFrame.height ?? 900) - 120)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(snapshot.kind.title, systemImage: snapshot.kind.systemImage)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("Snapshot, not live")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
            Text(
                t(
                    "Selected range: %1$@ · Captured %2$@", snapshot.range.label,
                    date(snapshot.capturedAt))
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if case .trend(let model) = snapshot.content, let domain = model.xDomain {
                Text(
                    t(
                        "Chart window: %1$@ to %2$@", date(domain.lowerBound),
                        date(domain.upperBound))
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if let timestamp = snapshot.dataTimestamp {
                Text(
                    t(
                        snapshot.kind.isRanking ? "Rankings last loaded: %@" : "Latest sample: %@",
                        date(timestamp))
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if snapshot.kind.isCurrentState {
                Text(
                    "Current-state snapshot. The selected history range does not change these readings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch snapshot.content {
        case .trend(let model):
            TrendSnapshotChart(model: model)
                .frame(height: 300)
            TrendStatisticsCaption(model: model)
            VStack(alignment: .leading, spacing: 10) {
                Text("Selected-range statistics")
                    .font(.headline)
                TrendStatisticsSummary(model: model)
            }
        case .cores(let captured):
            coreDetail(captured)
        case .composition(let captured):
            compositionDetail(captured)
        case .processes(let rows):
            processDetail(rows)
        }
    }

    private func coreDetail(_ captured: DashboardCoreSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            CoreGridSurface(feed: captured.feed, barHeight: 140)
            if captured.cores.isEmpty {
                Text("No per-core sample is available.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Per-core percentages in the captured sample")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        Text("Core")
                        Text("Kind")
                        Text("Busy")
                        Text("User")
                        Text("System")
                        Text("Idle")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(captured.cores) { core in
                        GridRow {
                            Text(String(core.index))
                            Text(core.kind == .unknown ? t("Unknown") : core.kind.label)
                                .foregroundStyle(core.kind.accent)
                            Text(percentage(core.usage))
                            Text(percentage(core.user))
                            Text(percentage(core.system))
                            Text(percentage(core.usage.isFinite ? max(0, 1 - core.usage) : .nan))
                        }
                        .font(.callout.monospacedDigit())
                        .accessibilityElement(children: .combine)
                    }
                }
                .textSelection(.enabled)
                Text("No historical per-core data is recorded for this view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func compositionDetail(_ captured: DashboardCompositionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            TaxonomySurface(feed: captured.feed, barHeight: 72)
            if captured.slices.isEmpty {
                Text("No memory composition sample is available.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Total physical RAM").font(.headline)
                    Spacer()
                    Text(ByteFormat.string(captured.total))
                        .font(.headline.monospacedDigit())
                    Text(t("%@ bytes", captured.total.formatted()))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(captured.slices) { slice in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Circle().fill(slice.category.color).frame(width: 8, height: 8)
                            Text(slice.name).font(.headline)
                            Spacer()
                            Text(ByteFormat.string(slice.bytes))
                                .font(.body.monospacedDigit())
                            Text(
                                captured.total > 0
                                    ? percentage(Double(slice.bytes) / Double(captured.total))
                                    : t("Share unavailable")
                            )
                            .font(.body.monospacedDigit())
                            .frame(minWidth: 65, alignment: .trailing)
                        }
                        Text(t("%@ bytes", slice.bytes.formatted()))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(slice.explanation)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func processDetail(_ rows: [ProcessConsumer]) -> some View {
        let ceiling = max(rows.map { rankValue($0) }.filter(\.isFinite).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 16) {
            Text(
                snapshot.kind == .topCPU
                    ? "Mean CPU, percent of one core"
                    : "Mean attributed disk throughput, read + write"
            )
            .font(.headline)
            Text(
                "Comparison bars share a zero baseline. All available rows in this ranking are shown, up to 20 processes."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No recorded processes are available for this range.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, process in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(index + 1))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Image(
                            nsImage: ProcessIconProvider.shared.icon(
                                forPath: process.executablePath)
                        )
                        .resizable()
                        .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(process.displayName).font(.headline)
                            Text(t("PID %@", String(process.identity.pid)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let path = process.executablePath {
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 12)
                        Text(rankText(process))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .fixedSize()
                    }
                    .textSelection(.enabled)
                    comparisonBar(process, ceiling: ceiling)
                    factsGrid([
                        DashboardDetailFact(
                            label: t("Mean CPU (one core)"), value: cpuText(process.averageCPU)),
                        DashboardDetailFact(
                            label: t("Mean attributed disk"), value: rateText(process.averageDisk)),
                        DashboardDetailFact(
                            label: t("Mean footprint"),
                            value: ByteFormat.string(process.averageFootprint)),
                        DashboardDetailFact(
                            label: t("Peak footprint"),
                            value: ByteFormat.string(process.peakFootprint)),
                        DashboardDetailFact(
                            label: t("Samples"), value: process.sampleCount.formatted()),
                    ])
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func comparisonBar(_ process: ProcessConsumer, ceiling: Double) -> some View {
        let value = rankValue(process)
        let fraction = value.isFinite ? min(max(value / ceiling, 0), 1) : 0
        let unit =
            snapshot.kind == .topCPU
            ? t("mean CPU, percent of one core")
            : t("mean attributed read + write, bytes per second")
        let exact =
            value.isFinite
            ? (snapshot.kind == .topCPU ? "\(value)%" : "\(value) B/s") : t("Unavailable")
        let readout = t("%1$@: %2$@ (%3$@)", process.displayName, exact, unit)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 3)
                    .fill(snapshot.kind == .topCPU ? Color.green : DiskStyle.read)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 14)
        .help(readout)
        .accessibilityLabel(readout)
    }

    private func factsGrid(_ facts: [DashboardDetailFact]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading,
            spacing: 12
        ) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .font(.callout.monospacedDigit())
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func explanation(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .standard)
    }

    private func percentage(_ fraction: Double) -> String {
        fraction.isFinite ? String(format: "%.1f%%", fraction * 100) : t("Unavailable")
    }

    private func cpuText(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f%%", value) : t("Unavailable")
    }

    private func rateText(_ value: Double) -> String {
        value.isFinite ? ByteFormat.rate(max(0, value)) : t("Unavailable")
    }

    private func rankValue(_ process: ProcessConsumer) -> Double {
        snapshot.kind == .topCPU ? process.averageCPU : process.averageDisk
    }

    private func rankText(_ process: ProcessConsumer) -> String {
        snapshot.kind == .topCPU ? cpuText(process.averageCPU) : rateText(process.averageDisk)
    }
}
