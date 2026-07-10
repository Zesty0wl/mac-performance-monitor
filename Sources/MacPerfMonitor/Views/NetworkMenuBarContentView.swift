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
                    Spacer(minLength: 0)
                }

                NetworkUpDownChart(
                    download: model.networkInTrail(), upload: model.networkOutTrail()
                )
                .frame(height: MenuChart.networkHeight)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                latencyLine
            }
        }
        .buttonStyle(.plain)
        .help("Open the Network tab")
    }

    /// Latency · jitter · packet-loss line, from the active ping (populates a
    /// second or two after the dropdown opens).
    @ViewBuilder private var latencyLine: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .imageScale(.small)
            if let ms = latency.latencyMs {
                Text("\(Int(ms.rounded())) ms")
                if let jitter = latency.jitterMs {
                    Text("± \(Int(jitter.rounded())) ms")
                        .foregroundStyle(.tertiary)
                }
                if latency.packetLoss > 0.01 {
                    Text("\(Int((latency.packetLoss * 100).rounded()))% loss")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("measuring latency\u{2026}")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func rateColumn(
        symbol: String, label: String, bytesPerSec: Double?, tint: Color
    )
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text(bytesPerSec.map { ByteFormat.rate($0) } ?? "—")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The interface, local IP, and session totals
    /// ("via Wi-Fi · 192.168.1.5 · 1.2 GB ↓ · 300 MB ↑ this session").
    private var subtitle: String {
        guard let net = model.latestNetwork else { return "Reading network\u{2026}" }
        var parts: [String] = []
        if let iface = net.primaryInterface { parts.append("via \(Self.interfaceName(iface))") }
        if let ip = net.localIPv4 { parts.append(ip) }
        parts.append(
            "\(ByteFormat.string(net.sessionInBytes)) \u{2193} · "
                + "\(ByteFormat.string(net.sessionOutBytes)) \u{2191} this session")
        return parts.joined(separator: " · ")
    }

    /// A friendlier label for the common interfaces; otherwise the raw BSD name.
    private static func interfaceName(_ bsd: String) -> String {
        switch bsd {
        case "en0": return "Wi-Fi"
        default: return bsd
        }
    }

    // MARK: - Top apps

    @ViewBuilder private var topApps: some View {
        if !trackPerApp {
            perAppPrompt
        } else {
            let top = Array(menuLists.topNetwork.prefix(6))
            let maxRate = max(top.first?.networkBytesPerSec ?? 1, 1)
            Button(action: openNetwork) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Top network apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    if top.isEmpty {
                        Text("No app network activity right now.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(top) { process in
                            appRow(process, maxRate: maxRate)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Open the Network tab")
        }
    }

    private func appRow(_ process: ProcessSample, maxRate: Double) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            Text(process.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule()
                .fill(NetworkStyle.download.opacity(0.7))
                .frame(width: max(3, 50 * process.networkBytesPerSec / maxRate), height: 5)
                .frame(width: 50, alignment: .leading)
            Text(ByteFormat.rate(process.networkBytesPerSec))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 3)
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
