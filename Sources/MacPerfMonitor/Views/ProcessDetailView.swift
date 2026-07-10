import AppKit
import Charts
import MacPerfMonitorCore
import SwiftUI

/// The per-process detail (PRD section 8.4): footprint, CPU, file-descriptor,
/// and disk-I/O timelines drawn from logged history, process metadata, and a
/// leak indicator when the analysis engine flags steady growth.
///
/// Shown in the Processes tab's inspector for the selected row. History is read
/// from the database for the chosen range and the current live sample is
/// appended on the right edge so the charts track the latest tick.
struct ProcessDetailView: View {
    @EnvironmentObject private var model: SamplerModel
    let identity: ProcessIdentity

    @ObservedObject private var glossaryStore = ProcessGlossaryStore.shared

    @State private var range: HistoryWindow = .oneHour
    @State private var history: [ProcessHistoryPoint] = []

    /// True while a range-change (or first) history read is in flight, so the
    /// charts show a spinner over dimmed data instead of silently displaying the
    /// previous range until the new window arrives. Set only on a range switch and
    /// the initial load — never on the per-tick append refresh, which would make
    /// the spinner flicker every sample.
    @State private var isLoading = false

    /// Charts are built one beat after the inspector mounts, so opening the pane
    /// for a process slides in smoothly instead of stuttering while four Swift
    /// Charts lay out on the first frame. A same-height placeholder holds the
    /// layout so nothing jumps when the real charts take over. Reset per process
    /// because the parent recreates this view (`.id(selection)`) on each open.
    @State private var chartsReady = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                descriptionCard
                rangePicker

                if chartPoints.count < 2 {
                    Text(
                        model.hasHistory
                            ? "Collecting history for this process…"
                            : "History store unavailable; showing live data only."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                charts
                MetadataSection(identity: identity, live: live)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { fullReload(spinner: true) }
        .task(id: identity) {
            // Let the inspector's slide-in animation start before building the
            // charts; ~300 ms covers the open so the first frames stay smooth.
            try? await Task.sleep(for: .milliseconds(300))
            chartsReady = true
        }
        .onChange(of: range) { fullReload(spinner: true) }
        // Each sampling tick re-publishes the live snapshot, which advances this
        // process's latest timestamp; that is the cue to pull just the rows
        // persisted since our last point and append them. The leak verdict is
        // refreshed on the same cue (once per tick, not per body evaluation).
        .onChange(of: live?.timestamp) {
            appendNewData()
        }
    }

    // MARK: - Live sample and derived series

    private var live: ProcessSample? { model.currentSample(for: identity) }

    private var displayName: String {
        live?.displayName ?? "PID \(identity.pid)"
    }

    /// When an aggregate (minute/hour) range last did a full window re-read;
    /// see `appendNewData`.
    @State private var lastAggregateReload = Date.distantPast

    /// The series every chart draws: this process's history as written to the
    /// database. Loaded in full when the inspector opens (and whenever the range
    /// changes), then extended in place each tick with only the rows persisted
    /// since the last point — no live synthesis or trail splicing, so the line
    /// stays continuous and simply grows on the right as new samples land.
    ///
    /// A process that has never been a top consumer has no stored rows yet, so
    /// until tracking starts persisting it the charts seed from the short
    /// in-memory trail the model keeps for every live process. The moment real
    /// stored history arrives it takes over.
    private var chartPoints: [ProcessHistoryPoint] {
        if history.count >= 2 { return history }
        let trail = model.trailSamples(for: identity)
        return trail.count >= 2 ? trail : history
    }

    /// Memoized leak verdict. `LeakDetector.analyze` sorts the whole series, and
    /// as a computed property it ran (twice) on every body evaluation — which at
    /// fast dials, or with a popover pumping 1 Hz publishes, meant re-sorting up
    /// to ~1,900 points many times a second. Refreshed once per data change
    /// instead (`refreshLeakFinding`).
    @State private var leakFinding: LeakDetector.Finding?

    private func refreshLeakFinding() {
        let series = chartPoints.map { ($0.date, $0.footprint) }
        leakFinding = LeakDetector.analyze(series: series)
    }

    /// The leak banner's old sentence, now surfaced as the Memory footprint
    /// card's caption when the analysis engine flags steady growth.
    private func leakDetailText(_ finding: LeakDetector.Finding) -> String {
        let growth = ByteFormat.string(finding.totalGrowth)
        let minutes = Int((finding.durationSeconds / 60).rounded())
        let rate = ByteFormat.string(UInt64(max(finding.slopeBytesPerSecond, 0)))
        let confidence = Int((finding.confidence * 100).rounded())
        return
            "\(displayName) grew \(growth) over \(minutes) min (~\(rate)/s, \(confidence)% confidence). "
            + "If it keeps climbing, consider restarting it."
    }

    /// Load the whole window from the database, replacing what we hold. Used
    /// when the inspector first appears and whenever the range changes.
    private func fullReload(spinner: Bool = false) {
        if spinner { isLoading = true }
        lastAggregateReload = Date()
        model.loadProcessHistory(identity, window: range) { points in
            self.history = points
            self.isLoading = false
            self.refreshLeakFinding()
        }
    }

    /// Pull only the rows persisted since our last point and append them, then
    /// trim to the visible window so the series stays bounded and slides
    /// forward. If nothing is loaded yet (a brand-new process with no stored
    /// rows), fall back to a full load and try again on the next tick.
    private func appendNewData() {
        // Only the 1-hour window is raw and can be extended point-by-point. The
        // longer windows read minute/hour aggregates, which gain a finalised
        // bucket once a minute at most — so cap the re-read cadence instead of
        // re-reading the whole window on every tick.
        guard range.granularity == .raw else {
            if Date().timeIntervalSince(lastAggregateReload) >= 60 {
                fullReload()
            }
            return
        }
        guard let after = history.last?.date else {
            fullReload()
            return
        }
        model.loadNewProcessHistory(identity, after: after) { newPoints in
            let fresh = newPoints.filter { $0.date > after }
            guard !fresh.isEmpty else { return }
            var merged = self.history
            merged.append(contentsOf: fresh)
            let cutoff = Date().addingTimeInterval(-self.range.seconds)
            self.history = merged.filter { $0.date >= cutoff }
            // Recompute AFTER the append lands (this closure runs later than
            // the onChange that scheduled it), so the leak badge describes the
            // series the chart is actually drawing, not last tick's.
            self.refreshLeakFinding()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: live?.executablePath))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if live?.isTranslated == true {
                        Text("Rosetta")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(live == nil ? "Exited · PID \(identity.pid)" : "PID \(identity.pid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Plain-language "what is this process?" from the (downloadable) glossary, with
    /// a derived fallback when we don't have a curated entry yet.
    private var descriptionCard: some View {
        let d = glossaryStore.describe(
            name: live?.name ?? displayName, bundleID: live?.bundleID, path: live?.executablePath)
        let tint = Self.categoryTint(d.category)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: Self.categoryIcon(d.category)).foregroundStyle(tint)
                Text(d.title).font(.callout.weight(.semibold))
                if let vendor = d.vendor {
                    Text(vendor)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !d.curated {
                    Text("not yet documented").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(d.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if d.expectedHigh {
                Label("High CPU/memory is normal for this process.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let urlString = d.url, let url = URL(string: urlString) {
                Link("Learn more", destination: url).font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.2)))
    }

    private static func categoryIcon(_ c: String) -> String {
        switch c {
        case "system": return "gearshape.2"
        case "app": return "app.badge"
        case "helper": return "puzzlepiece.extension"
        case "developer": return "hammer"
        case "security": return "lock.shield"
        default: return "questionmark.circle"
        }
    }

    private static func categoryTint(_ c: String) -> Color {
        switch c {
        case "system": return .blue
        case "app": return .indigo
        case "helper": return .teal
        case "developer": return .purple
        case "security": return .green
        default: return .secondary
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(HistoryWindow.allCases) { r in Text(r.label).tag(r) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .historyRangeGate()
    }

    // MARK: - Charts

    private var charts: some View {
        VStack(alignment: .leading, spacing: 16) {
            chartBlock(
                title: "Memory footprint",
                systemImage: "memorychip",
                caption: "phys_footprint, the headline \"Memory\" figure.",
                samples: chartPoints.map {
                    MetricSample(date: $0.date, value: Double($0.footprint))
                },
                tint: .blue,
                isLeaking: leakFinding != nil,
                leakDetail: leakFinding.map(leakDetailText),
                yFormat: { ByteFormat.string(UInt64(max($0, 0))) }
            )

            chartBlock(
                title: "CPU",
                systemImage: "cpu",
                caption: "Percent of one core, from the CPU-time delta between ticks.",
                samples: chartPoints.map { MetricSample(date: $0.date, value: $0.cpuPercent) },
                tint: .green,
                minTop: 5,
                yFormat: { String(format: "%.0f%%", max($0, 0)) }
            )

            chartBlock(
                title: "File descriptors",
                systemImage: "doc.on.doc",
                caption: "Open files, sockets, and pipes. A steady climb can signal a handle leak.",
                samples: chartPoints.map {
                    MetricSample(date: $0.date, value: Double($0.fdTotal))
                },
                tint: .purple,
                minTop: 10,
                yFormat: { String(format: "%.0f", max($0, 0)) }
            )

            VStack(alignment: .leading, spacing: 8) {
                Label("Disk I/O", systemImage: "internaldrive")
                    .font(.subheadline.weight(.semibold))
                chartBlock(
                    title: "Read",
                    systemImage: "arrow.down",
                    caption: "Kernel-attributed read throughput between samples.",
                    samples: diskRateSamples.read,
                    tint: DiskStyle.read,
                    yFormat: { ByteFormat.rate(max($0, 0)) })
                chartBlock(
                    title: "Write",
                    systemImage: "arrow.up",
                    caption: "Kernel-attributed write throughput between samples.",
                    samples: diskRateSamples.write,
                    tint: DiskStyle.write,
                    yFormat: { ByteFormat.rate(max($0, 0)) })
            }
        }
    }

    @ViewBuilder
    private func chartBlock(
        title: String,
        systemImage: String,
        caption: String,
        samples: [MetricSample],
        tint: Color,
        minTop: Double = 1,
        isLeaking: Bool = false,
        leakDetail: String? = nil,
        yFormat: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                if isLeaking {
                    LeakIndicator()
                    Text("Possible memory leak")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            Group {
                if chartsReady {
                    MetricChart(
                        samples: samples, tint: tint, minTop: minTop,
                        windowSeconds: range.seconds, accessibilityTitle: title,
                        yFormat: yFormat
                    )
                    .equatable()
                    .frame(height: 120)
                } else {
                    // Same-height stand-in so the pane opens at its final size and
                    // the real charts drop in without shifting anything.
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(height: 120)
                }
            }
            // Dim the previous range's line and spin while the new window loads,
            // so a range switch reads as "loading" rather than stale data.
            .opacity(isLoading ? 0.3 : 1)
            .overlay {
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            Text(leakDetail ?? caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Disk throughput (bytes/second) from the difference between consecutive
    /// cumulative counters. Counter resets (process replaced) clamp to zero.
    private var diskRateSamples: (read: [MetricSample], write: [MetricSample]) {
        let points = chartPoints
        guard points.count > 1 else { return ([], []) }
        var read: [MetricSample] = []
        var write: [MetricSample] = []
        read.reserveCapacity(points.count - 1)
        write.reserveCapacity(points.count - 1)
        for i in 1..<points.count {
            let dt = points[i].date.timeIntervalSince(points[i - 1].date)
            guard dt > 0 else { continue }
            let readDelta =
                points[i].diskRead >= points[i - 1].diskRead
                ? points[i].diskRead - points[i - 1].diskRead : 0
            let writeDelta =
                points[i].diskWritten >= points[i - 1].diskWritten
                ? points[i].diskWritten - points[i - 1].diskWritten : 0
            read.append(MetricSample(date: points[i].date, value: Double(readDelta) / dt))
            write.append(MetricSample(date: points[i].date, value: Double(writeDelta) / dt))
        }
        return (read, write)
    }
}

// MARK: - Metadata

private struct MetadataSection: View {
    let identity: ProcessIdentity
    let live: ProcessSample?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Details", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                if let live {
                    row("Path", live.executablePath ?? "—")
                    row("Bundle ID", live.bundleID ?? "—")
                    row("PID", "\(live.pid)")
                    if live.ppid > 0 { row("Parent PID", "\(live.ppid)") }
                    row(
                        "Architecture",
                        live.isTranslated
                            ? "\(live.architecture.label) (Rosetta)" : live.architecture.label)
                    row("Threads", "\(live.threadCount)")
                    row("CPU now", cpuNowDescription(live))
                    row("CPU split", cpuSplitDescription(live))
                    row("File descriptors", "\(live.fdTotal)")
                    row("Lifetime max", ByteFormat.string(live.lifetimeMaxFootprint))
                    row("Started", live.startTime.formatted(date: .abbreviated, time: .shortened))
                    row("Age", ageString(since: live.startTime))
                    row("User", userDescription(for: live.uid))
                    row(
                        "Coverage",
                        live.footprintReadable
                            ? "Direct user read"
                            : "Footprint not readable at user level")
                } else {
                    row("PID", "\(identity.pid)")
                    row(
                        "Started",
                        identity.startTime.formatted(date: .abbreviated, time: .shortened))
                    Text("This process has exited. Showing its last logged history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// CPU "now": percent of one core (Activity Monitor convention) plus the
    /// share of the whole machine's capacity, which puts a 100%+ single-core
    /// figure in context on a multi-core Mac.
    private func cpuNowDescription(_ live: ProcessSample) -> String {
        let cores = max(CPUTopology.current.logicalCores, 1)
        let share = live.cpuPercent / Double(cores)
        return
            "\(CPUFormat.percent(live.cpuPercent)) of one core · \(CPUFormat.percent(share)) of total"
    }

    /// Lifetime user-vs-system CPU split, from the cumulative CPU-time counters.
    /// A process heavy in system time is spending it in the kernel (syscalls,
    /// I/O); one heavy in user time is doing its own computation.
    private func cpuSplitDescription(_ live: ProcessSample) -> String {
        let total = live.cpuTimeUser &+ live.cpuTimeSystem
        guard total > 0 else { return "—" }
        let userPercent = Int((Double(live.cpuTimeUser) / Double(total) * 100).rounded())
        return "\(userPercent)% user / \(100 - userPercent)% system (lifetime)"
    }

    private func ageString(since start: Date) -> String {
        let seconds = max(Date().timeIntervalSince(start), 0)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "—"
    }

    /// Both the account name and the numeric uid, e.g. "alice (501)".
    /// Falls back to just the number for uids with no passwd entry (some
    /// system accounts), so the row is never blank.
    private func userDescription(for uid: uid_t) -> String {
        if let name = Self.username(for: uid) {
            return "\(name) (\(uid))"
        }
        return "\(uid)"
    }

    private static func username(for uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }
}
