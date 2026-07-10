import AppKit
import Charts
import MacPerfMonitorCore
import SwiftUI

/// The GPU menubar dropdown. Headline utilization and a usage-history sparkline,
/// device / renderer / tiler / Neural-Engine activity bars, and a details block
/// with GPU + ANE + CPU power (IOReport), in-use / allocated memory, die
/// temperature and fan (SMC). Apple-silicon only. Re-renders at 1 Hz while open
/// via the shared `MenuClock`; there is no per-process GPU attribution, so the
/// panel adds no scanning cost.
struct GPUMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
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
                Text(gpu.name ?? "Graphics").font(.headline).lineLimit(1)
                if let cores = gpu.coreCount {
                    Text("\(cores)-core").font(.caption2).foregroundStyle(.secondary)
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
        let maxX = Double(max(points.count - 1, 1))
        return Chart(points, id: \.offset) { point in
            AreaMark(x: .value("t", point.offset), y: .value("u", point.element))
                .foregroundStyle(Color.accentColor.opacity(0.18))
            LineMark(x: .value("t", point.offset), y: .value("u", point.element))
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: 0...maxX)
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

    private func bar(_ label: String, _ percent: Double, trailing: String? = nil) -> some View {
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

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value).font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
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
