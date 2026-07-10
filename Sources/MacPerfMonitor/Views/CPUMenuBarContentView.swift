import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The CPU menubar dropdown (window style): a total-CPU summary with a live
/// sparkline and load averages, the per-core grid (badged P/E on Apple Silicon),
/// and the top processes by CPU. The memory/pressure twin lives in
/// `MenuBarContentView`; the two share the row affordances and action buttons.
struct CPUMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var updateController: UpdateController
    @EnvironmentObject private var menuClock: MenuClock

    /// Called after an action so the host (the AppKit popover) can dismiss.
    var dismiss: () -> Void = {}
    var embedded = false

    private let topology = CPUTopology.current

    var body: some View {
        // Re-render once a second while the popover is open, so the live CPU %,
        // load averages, sparkline, and core grid tick at 1 Hz (independently of
        // the main window's refresh rate). Depend on the clock's tick explicitly,
        // and drive its open/close from THIS view's lifecycle — the status-item
        // popover's own `popoverDidShow`/`DidClose` delegate callbacks do not fire
        // reliably, which is why the dropdowns were stuck at the global rate.
        _ = menuClock.tick
        return
            panel
            .onAppear { if !embedded { menuClock.open() } }
            .onDisappear { if !embedded { menuClock.close() } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            coreSection
            Divider()
            topProcesses
            if !embedded {
                Divider()
                actions
                MenuVersionFooter()
            }
        }
        .padding(embedded ? 0 : 12)
        .frame(width: embedded ? nil : 380)
    }

    // MARK: - Header

    private var header: some View {
        let cpu = model.smoothedCPU
        let usage = cpu?.totalUsage ?? 0
        let level = CPULevel(fraction: usage)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: level.symbolName)
                    .foregroundStyle(level.color)
                    .imageScale(.small)
                Text(cpu == nil ? "—" : "\(Int((usage * 100).rounded()))%")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    // Reserve room for the widest value ("100%") so the level
                    // label beside it does not shift as the digit count changes.
                    .frame(minWidth: 58, alignment: .leading)
                Text(level.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(level.color)
                Spacer()
                if let cpu {
                    Text(
                        "load \(loadString(cpu.loadAverage1)) · \(loadString(cpu.loadAverage5)) · \(loadString(cpu.loadAverage15))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("1, 5 and 15-minute load averages (run-queue length).")
                }
            }

            MenuTrendChart(
                values: model.cpuLoadTrail(), color: level.color,
                domain: 0...100, ticks: [0, 50, 100], label: { "\(Int($0))" }
            )
            .frame(height: MenuChart.height)

            Text(coreSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A static one-liner naming the chip and core layout, independent of the
    /// live sample so it reads even before the first delta lands.
    private var coreSummary: String {
        let total = topology.logicalCores
        if topology.efficiencyCoreCount > 0 && topology.performanceCoreCount > 0 {
            return
                "\(topology.brand) · \(total) cores (\(topology.performanceCoreCount)P + \(topology.efficiencyCoreCount)E)"
        }
        return "\(topology.brand) · \(total) core\(total == 1 ? "" : "s")"
    }

    private func loadString(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Core grid

    private var coreSection: some View {
        CoreGridView(cores: model.smoothedCPU?.cores ?? [], barHeight: 38)
    }

    // MARK: - Top processes

    private var topProcesses: some View {
        let top = Array(menuLists.topCPU.prefix(8))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Top CPU")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if top.isEmpty {
                Text("Sampling…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(top) { process in
                    CPUMenuProcessRow(
                        process: process,
                        trail: model.cpuTrail(for: process.id))
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 2) {
            MenuActionButton(title: "Open \(AppInfo.displayName)", systemImage: "macwindow") {
                showMainWindow()
            }
            MenuActionButton(title: "Settings…", systemImage: "gearshape") {
                openSettings()
            }
            MenuActionButton(title: "About \(AppInfo.displayName)", systemImage: "info.circle") {
                dismiss()
                showStandardAboutPanel()
            }
            MenuActionButton(title: "Check for Updates\u{2026}", systemImage: "arrow.down.circle") {
                checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
            MenuActionButton(title: "Quit \(AppInfo.displayName)", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - AppKit-hosted actions

    /// This panel is shown from an AppKit `NSPopover`, not a `MenuBarExtra`
    /// scene, so the SwiftUI `openWindow` / `openSettings` environment actions are
    /// not available here. Drive the equivalents through notifications the
    /// always-present pressure menubar label (which IS in a SwiftUI scene) handles
    /// with the real environment actions.

    private func showMainWindow() {
        dismiss()
        NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        // Routed to MenuBarWindowRouter's `openSettings` action — reliable, unlike
        // `NSApp.sendAction("showSettingsWindow:")` from a popover with no key
        // window, which silently did nothing.
        NotificationCenter.default.post(name: .macperfmonitorShowSettings, object: nil)
    }

    /// Sparkle presents its own update window, so this needs no SwiftUI scene —
    /// just dismiss the popover and bring the app forward so that window is key.
    private func checkForUpdates() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        updateController.checkForUpdates()
    }
}

/// One row in the top-CPU list: icon, name, a CPU-trend sparkline, the current
/// CPU percentage, and the shared per-row actions menu. Mirrors `MenuProcessRow`
/// but keyed on CPU rather than footprint. A single click opens the process in
/// the main window.
struct CPUMenuProcessRow: View {
    let process: ProcessSample
    let trail: [Double]
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            Text(process.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Sparkline(values: trail)
                .tint(.secondary)
                .frame(width: 34, height: 14)
            Text(CPUFormat.percent(process.cpuPercent))
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
        .accessibilityLabel("\(process.displayName), \(CPUFormat.percent(process.cpuPercent)) CPU")
        .accessibilityHint("Opens this process in the main window")
        .processRowActions(identity: process.id, bringWindowForward: true, openOnSingleTap: true)
    }
}

/// Shared CPU-percentage formatting (percent of one core, Activity-Monitor
/// convention): one decimal under 10% so small movers are legible, whole numbers
/// above.
enum CPUFormat {
    static func percent(_ value: Double) -> String {
        if value < 10 {
            return String(format: "%.1f%%", max(0, value))
        }
        return String(format: "%.0f%%", value)
    }
}
