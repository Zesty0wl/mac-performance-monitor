import AppKit
import Charts
import MacPerfMonitorCore
import SwiftUI

/// The GPU menubar dropdown. Headline utilization and a usage-history sparkline,
/// device / renderer / tiler / Neural-Engine activity bars, a details block
/// with GPU + ANE + CPU power (IOReport), in-use / allocated memory, die
/// temperature and fan (SMC), and the top GPU processes with the AI runtime
/// named where there is one. Apple-silicon only. Re-renders at the dial rate
/// while open via the shared `MenuClock`; the process list rides the popover
/// scan cadence its status item registers for.
struct GPUMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var menuClock: MenuClock

    /// Called after an action so the host (the AppKit popover) can dismiss.
    var dismiss: () -> Void = {}
    var embedded = false

    var body: some View {
        _ = menuClock.tick
        return
            panel
            .onAppear { if !embedded { menuClock.open() } }
            .onDisappear { if !embedded { menuClock.close() } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let gpu = model.latestGPU {
                header(gpu)
                sparkline
                Divider()
                bars(gpu)
                Divider()
                details(gpu)
                Divider()
                topProcesses
            } else {
                Text("Reading GPU\u{2026}")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
            }
            if !embedded { MenuVersionFooter() }
        }
        .padding(embedded ? 0 : 12)
        .frame(width: embedded ? nil : 300)
    }

    // MARK: - Header + sparkline

    private func header(_ gpu: GPUSample) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("GPU").font(.caption).foregroundStyle(.secondary)
                Text(gpu.name ?? t("Graphics")).font(.headline).lineLimit(1)
                if let cores = gpu.coreCount {
                    Text(t("%@-core", String(cores))).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(Int(gpu.utilization.rounded()))%")
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundStyle(CPULevel(fraction: gpu.utilization / 100).color)
                .monospacedDigit()
        }
    }

    private var sparkline: some View {
        let points = Array(model.gpuUtilizationHistory.enumerated())
        let capacity = SamplerModel.gpuHistoryCapacity
        return Chart(points, id: \.offset) { point in
            let x = LiveChartGeometry.normalizedSlot(
                index: point.offset, count: points.count, capacity: capacity)
            AreaMark(x: .value("t", x), y: .value("u", point.element))
                .foregroundStyle(Color.accentColor.opacity(0.18))
            LineMark(x: .value("t", x), y: .value("u", point.element))
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.linear)
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 38)
        .opacity(points.count > 1 ? 1 : 0)
    }

    // MARK: - Activity bars

    private func bars(_ gpu: GPUSample) -> some View {
        VStack(spacing: 8) {
            bar("Device", gpu.utilization)
            if let render = gpu.renderUtilization { bar("Renderer", render) }
            if let tiler = gpu.tilerUtilization { bar("Tiler", tiler) }
            if let ane = gpu.aneUtilization {
                bar("Neural Engine", ane, trailing: wattsString(gpu.anePowerWatts))
            }
        }
    }

    private func bar(
        _ label: LocalizedStringKey, _ percent: Double, trailing: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.caption2).foregroundStyle(.tertiary) }
                Text("\(Int(percent.rounded()))%").font(.caption.monospacedDigit())
            }
            ProgressView(value: min(max(percent / 100, 0), 1))
                .tint(CPULevel(fraction: percent / 100).color)
        }
    }

    // MARK: - Details

    private func details(_ gpu: GPUSample) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            if let watts = gpu.gpuPowerWatts {
                detail("GPU power", wattsString(watts) ?? "—")
            }
            if let watts = gpu.cpuPowerWatts {
                detail("CPU power", wattsString(watts) ?? "—")
            }
            if gpu.inUseMemoryBytes != nil || gpu.allocatedMemoryBytes != nil {
                detail("Memory", memoryString(gpu))
            }
            if let temp = gpu.dieTemperatureC {
                detail("Die temperature", "\(Int(temp.rounded()))\u{00B0}C")
            }
            if let rpm = gpu.fanRPM {
                detail("Fan", rpm == 0 ? "Off" : "\(rpm) rpm")
            }
        }
    }

    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value).font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Top processes

    private var topProcesses: some View {
        let top = Array(menuLists.topGPU.prefix(8))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Top GPU")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if top.isEmpty {
                Text(
                    menuLists.gpuListScanned ? t("Nothing is using the GPU") : t("Sampling\u{2026}")
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
                ForEach(top) { process in
                    GPUMenuProcessRow(
                        process: process,
                        workload: model.gpuWorkload(for: process.id))
                }
            }
        }
    }

    private func wattsString(_ watts: Double?) -> String? {
        guard let watts else { return nil }
        return String(format: "%.2f W", watts)
    }

    private func memoryString(_ gpu: GPUSample) -> String {
        func fmt(_ b: UInt64?) -> String? {
            guard let b else { return nil }
            return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
        }
        let inUse = fmt(gpu.inUseMemoryBytes)
        let alloc = fmt(gpu.allocatedMemoryBytes)
        switch (inUse, alloc) {
        case (.some(let u), .some(let a)): return "\(u) / \(a)"
        case (.some(let u), nil): return u
        case (nil, .some(let a)): return a
        default: return "—"
        }
    }
}

/// One row of the GPU dropdown's top list: icon, name, the AI runtime when the
/// process is one (the reason to watch the GPU at all), and its share of the
/// device over the last scan interval.
struct GPUMenuProcessRow: View {
    let process: ProcessSample
    let workload: GPUWorkloadInfo?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            HStack(spacing: 5) {
                Text(process.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let runtime = workload?.runtime {
                    Text(runtime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.15)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(CPUFormat.percent(process.gpuPercentValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            ProcessRowMenuButton(identity: process.id, bringWindowForward: true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.accentColor.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens this process in the main window")
        .processRowActions(identity: process.id, bringWindowForward: true, openOnSingleTap: true)
    }

    private var accessibilityLabel: String {
        let base = "\(process.displayName), \(CPUFormat.percent(process.gpuPercentValue)) GPU"
        guard let runtime = workload?.runtime else { return base }
        return "\(base), \(runtime)"
    }
}
