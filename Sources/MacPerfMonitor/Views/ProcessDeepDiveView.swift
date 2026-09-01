import MacPerfMonitorCore
import SwiftUI

/// Self-contained target for the deep-dive window. Carries the live headline stats
/// and recent trails snapshotted at request time, so the window can run the full
/// diagnostic battery without subscribing to the sampler.
struct DeepDiveTarget: Codable, Hashable, Identifiable {
    var pid: Int32
    var startTime: Date
    var name: String
    var uid: UInt32

    var arch: String
    var isTranslated: Bool

    var cpuPercent: Double
    var footprintBytes: UInt64
    var peakFootprintBytes: UInt64
    var threadCount: Int
    var systemRAMBytes: UInt64
    var uptimeMinutes: Double

    var cpuTrail: [Double]
    var memoryTrail: [Double]
    var diskReadTrail: [Double]
    var diskWriteTrail: [Double]
    var fdTrail: [Double]
    var spanMinutes: Int

    var id: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }

    var profileStats: ProcessProfileStats {
        ProcessProfileStats(
            cpuPercent: cpuPercent, footprintBytes: footprintBytes,
            peakFootprintBytes: peakFootprintBytes, threadCount: threadCount)
    }
}

/// The deep-dive window: profiles one process and runs a battery of diagnostic
/// checks (CPU/loop, responsiveness, memory, leak, disk I/O, descriptors, network,
/// threads), each a clear pass/warn/fail with a specific finding. Deterministic —
/// no language model. Gets the helper (privileged capture); never the sampler.
struct ProcessDeepDiveView: View {
    let target: DeepDiveTarget

    @EnvironmentObject private var helper: HelperManager
    @StateObject private var model = ProcessDeepDiveModel()
    @ObservedObject private var catalog = CheckCatalogStore.shared
    @State private var revealed = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            catalogBar
            Divider()
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 540, minHeight: 580)
        .navigationTitle(t("Deep Dive — %@", target.name))
        .onAppear(perform: start)
    }

    /// Always-visible strip showing which catalog the checks come from — how many,
    /// what version, and whether it's the signed server copy or the built-in fallback.
    private var catalogBar: some View {
        HStack(spacing: 6) {
            Image(systemName: catalog.source == .server ? "checkmark.seal.fill" : "shippingbox")
                .foregroundStyle(catalog.source == .server ? Color.green : Color.secondary)
            Text(t("%@ checks", String(catalog.checkCount)))
            Text("·").foregroundStyle(.tertiary)
            Text(t("catalog v%@", String(catalog.version)))
            Text("·").foregroundStyle(.tertiary)
            Text(catalog.source == .server ? "latest, from server" : "built-in")
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("PID \(target.pid) · \(target.arch)\(target.isTranslated ? " · Rosetta" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case .done = model.state {
                Button(action: start) { Label("Re-run", systemImage: "arrow.clockwise") }
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .working:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(workingMessage).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: start)
            }
        case .done(let report):
            results(report)
        }
    }

    private var workingMessage: String {
        if case .working(let message) = model.state { return message }
        return t("Starting…")
    }

    private func start() {
        model.analyze(target: target, helper: helper)
    }

    // MARK: - Results

    @ViewBuilder private func results(_ r: ProcessProfileReport) -> some View {
        let checks = sortedChecks(r.checks)
        VStack(alignment: .leading, spacing: 14) {
            verdict(r)

            HStack(alignment: .top, spacing: 12) {
                metricCard(
                    "CPU", value: String(format: "%.0f%%", r.cpuPercent),
                    trend: r.cpuTrend, trail: r.cpuTrail, tint: .blue)
                metricCard(
                    "Memory", value: ByteFormat.string(r.memoryBytes),
                    trend: r.memoryTrend, trail: r.memoryTrail, tint: .purple)
            }

            HStack {
                Text("Diagnostics").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(min(revealed, checks.count)) / \(checks.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            ForEach(Array(checks.prefix(revealed))) { check in
                CheckRow(check: check).transition(.opacity)
            }
        }
        // Reveal the checks one at a time so you can see the battery run through.
        .task(id: r) {
            revealed = 0
            for i in checks.indices {
                withAnimation(.easeOut(duration: 0.18)) { revealed = i + 1 }
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
        }
    }

    /// Most severe first, then by their natural order.
    private func sortedChecks(_ checks: [DiagnosticCheck]) -> [DiagnosticCheck] {
        checks.enumerated().sorted {
            $0.element.status.severity != $1.element.status.severity
                ? $0.element.status.severity > $1.element.status.severity
                : $0.offset < $1.offset
        }.map(\.element)
    }

    private func verdict(_ r: ProcessProfileReport) -> some View {
        let (tint, icon) = CheckRow.style(r.overallStatus)
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            Text(r.headline).font(.headline).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                tint.opacity(0.25), lineWidth: 0.5))
    }

    private func metricCard(
        _ title: LocalizedStringKey, value: String, trend: String, trail: [Double], tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            if trail.count >= 2 {
                Sparkline(values: trail).tint(tint).frame(height: 22)
            }
            Text(trend).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

/// One diagnostic check, with its evidence collapsible (open by default when it
/// found something).
private struct CheckRow: View {
    let check: DiagnosticCheck
    @State private var expanded: Bool

    init(check: DiagnosticCheck) {
        self.check = check
        _expanded = State(initialValue: check.status == .critical || check.status == .warning)
    }

    var body: some View {
        let (tint, icon) = Self.style(check.status)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title).font(.callout.weight(.semibold))
                    Text(check.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !check.details.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if expanded, !check.details.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(check.details.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(line)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.08)))
    }

    static func style(_ status: DiagnosticCheck.Status) -> (Color, String) {
        switch status {
        case .ok: return (.green, "checkmark.circle.fill")
        case .info: return (.blue, "info.circle.fill")
        case .warning: return (.orange, "exclamationmark.triangle.fill")
        case .critical: return (.red, "exclamationmark.octagon.fill")
        case .skipped: return (.secondary, "minus.circle")
        }
    }
}
