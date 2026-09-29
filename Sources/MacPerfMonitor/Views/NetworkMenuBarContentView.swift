import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The network menubar dropdown (window style): a download/upload header with a
/// live throughput sparkline and the session totals, then the top network apps
/// (when per-app tracking is on) or a prompt to turn it on, then the actions.
/// Tapping the header or the app list opens the main window's Network tab. The
/// CPU/memory/energy twins live in their own content views; the four share the
/// row affordances and action buttons.
struct NetworkMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updateController: UpdateController
    @EnvironmentObject private var menuClock: MenuClock

    /// Shared with `SamplerModel`/Settings: whether per-app attribution is on.
    @AppStorage(SamplerModel.perAppNetworkDefaultsKey) private var trackPerApp = true

    /// Active ping-based latency/jitter, run ONLY while this dropdown is open.
    @StateObject private var latency = LatencyMonitor()

    /// Called after an action so the host (the AppKit popover) can dismiss.
    var dismiss: () -> Void = {}
    var embedded = false

    var body: some View {
        // Re-render once a second while the popover is open (independently of the
        // main window's refresh rate). Depend on the clock's tick and drive its
        // open/close from this view's lifecycle — the status-item popover delegate
        // callbacks do not fire reliably (which left the dropdowns at the global
        // rate).
        _ = menuClock.tick
        return
            panel
            .onAppear {
                if !embedded { menuClock.open() }
                latency.start()
            }
            .onDisappear {
                if !embedded { menuClock.close() }
                latency.stop()
            }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            topApps
            if !embedded {
                Divider()
                actions
                MenuVersionFooter()
            }
        }
        .padding(embedded ? 0 : 12)
        .frame(width: embedded ? nil : 360)
    }

    // MARK: - Header

    private var header: some View {
        let rates = model.smoothedNetworkRates
        return Button(action: openNetwork) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    rateColumn(
                        symbol: NetworkStyle.downSymbol, label: "Download",
                        bytesPerSec: rates?.inBytesPerSec, tint: NetworkStyle.download)
                    rateColumn(
                        symbol: NetworkStyle.upSymbol, label: "Upload",
                        bytesPerSec: rates?.outBytesPerSec, tint: NetworkStyle.upload)
                }

                NetworkUpDownChart(
                    download: model.networkInTrail(), upload: model.networkOutTrail(),
                    sampleCapacity: model.systemHistory.capacity
                )
                .frame(height: MenuChart.networkHeight)

                NetworkMenuSummary(
                    network: model.latestNetwork, latencyMs: latency.latencyMs,
                    jitterMs: latency.jitterMs,
                    packetLoss: latency.latencyMs != nil || latency.packetLoss > 0
                        ? latency.packetLoss : nil)
            }
        }
        .buttonStyle(.plain)
        .help("Open the Network tab")
    }

    private func rateColumn(
        symbol: String, label: LocalizedStringKey, bytesPerSec: Double?, tint: Color
    )
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.small)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(NetworkMenuSummary.rateText(bytesPerSec))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .frame(height: 22)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 14)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: 36)
    }

    // MARK: - Top apps

    @ViewBuilder private var topApps: some View {
        if !trackPerApp {
            perAppPrompt
        } else {
            Button(action: openNetwork) {
                NetworkMenuAppList(processes: menuLists.topNetwork)
            }
            .buttonStyle(.plain)
            .help("Open the Network tab")
        }
    }

    /// Shown when per-app tracking is off: explains the opt-in and offers a path
    /// to Settings, since the system-wide rates above work without it.
    private var perAppPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-app network usage")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                "Turn on per-app network tracking to see which apps are using the network. It is off by default because it runs an extra system tool."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings\u{2026}") { openSettings() }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 2) {
            MenuActionButton(title: "Open Network", systemImage: "network") {
                openNetwork()
            }
            MenuActionButton(title: "Settings\u{2026}", systemImage: "gearshape") {
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

    private func openNetwork() {
        dismiss()
        appState.showNetworkTab = true
        NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .macperfmonitorShowSettings, object: nil)
    }

    private func checkForUpdates() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        updateController.checkForUpdates()
    }
}

struct NetworkMenuSummary: View {
    static let height: CGFloat = 124

    let network: NetworkSample?
    let latencyMs: Double?
    let jitterMs: Double?
    let packetLoss: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                metadata("Interface", value: network?.primaryInterface)
                metadata("IPv4", value: network?.localIPv4)
            }
            .frame(height: 40)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Color.clear.frame(height: 14)
                    Text("This session").frame(height: 14)
                }
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
                transferred("Download", bytes: network?.sessionInBytes, tint: NetworkStyle.download)
                transferred("Upload", bytes: network?.sessionOutBytes, tint: NetworkStyle.upload)
            }
            .font(.caption.monospacedDigit())
            .frame(height: 32)

            HStack(alignment: .top, spacing: 12) {
                measurement("Latency", value: Self.millisecondsText(latencyMs))
                measurement("Jitter", value: Self.millisecondsText(jitterMs))
                measurement(
                    "Packet loss", value: Self.lossText(packetLoss),
                    tint: (packetLoss ?? 0) > 0.01 ? .orange : .secondary)
            }
            .frame(height: 36)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height, alignment: .top)
        .transaction { $0.animation = nil }
    }

    private func metadata(_ title: LocalizedStringKey, value: String?) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value ?? "--")
                .font(.caption.monospaced())
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .help(value ?? t("Unavailable"))
        }
        .font(.caption)
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }

    private func transferred(_ title: LocalizedStringKey, bytes: UInt64?, tint: Color) -> some View
    {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title).foregroundStyle(tint).frame(height: 14)
            Text(bytes.map { ByteFormat.string($0) } ?? "--").frame(height: 14)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private func measurement(
        _ title: LocalizedStringKey, value: String, tint: Color = .secondary
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(height: 14)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(tint).frame(height: 18)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    static func millisecondsText(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "--" }
        return String(format: "%.1f ms", milliseconds)
    }

    static func lossText(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return "--" }
        return String(format: "%.0f%%", fraction * 100)
    }

    static func rateText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "--" }
        return ByteFormat.rate(bytesPerSecond)
    }
}

struct NetworkMenuAppList: View {
    static let rowCount = 6
    static let rowHeight: CGFloat = 22
    static let height: CGFloat = 16 + rowHeight * CGFloat(rowCount)

    let processes: [ProcessSample]

    var body: some View {
        let top = Array(processes.prefix(Self.rowCount))
        let maxRate = max(top.map(\.networkBytesPerSec).filter(\.isFinite).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 0) {
            Text("Top network apps")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 14)
                .padding(.bottom, 2)
            ZStack(alignment: .topLeading) {
                if top.isEmpty {
                    Text("No app network activity right now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(top) { process in
                        appRow(process, maxRate: maxRate)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Self.rowHeight * CGFloat(Self.rowCount), alignment: .topLeading)
        }
        .frame(height: Self.height, alignment: .top)
        .transaction { $0.animation = nil }
    }

    private func appRow(_ process: ProcessSample, maxRate: Double) -> some View {
        let rate = process.networkBytesPerSec
        let fraction = rate.isFinite ? min(max(rate / maxRate, 0), 1) : 0
        return HStack(spacing: 8) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            Text(process.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .help(process.displayName)
            Capsule()
                .fill(NetworkStyle.download.opacity(0.7))
                .frame(width: max(3, 50 * fraction), height: 5)
                .frame(width: 50, alignment: .leading)
            Text(NetworkMenuSummary.rateText(rate))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 74, alignment: .trailing)
        }
        .frame(height: Self.rowHeight)
    }
}
