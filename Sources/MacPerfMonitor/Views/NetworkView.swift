import Charts
import Combine
import MacPerfMonitorCore
import SwiftUI

/// The Network tab: a full system-wide network page that works whether or not
/// per-app tracking is on. It shows the live total download/upload with a
/// throughput timeline, every adapter (type, status, addresses, MAC, live
/// up/down + session totals), the machine's network configuration (primary
/// service, router, DNS, host name), and an opt-in for per-app attribution that
/// reveals the top network apps inline.
///
/// The aggregate rates and the throughput chart come from the always-on sampler
/// (`SamplerModel`); the per-adapter detail and the config come from a
/// `NetworkInfoReader` this view owns and polls while it is on screen.
struct NetworkView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var appState: AppState
    @AppStorage(SamplerModel.perAppNetworkDefaultsKey) private var trackPerApp = true
    /// The global refresh interval; the interface poll below follows it so this tab
    /// honours the toolbar/Settings control rather than its own fixed cadence.
    @AppStorage(SamplerModel.tableIntervalKey) private var refreshInterval =
        SamplerModel.defaultTableInterval

    /// Held in @State so its inter-read counters survive re-renders. Reset each
    /// time the tab is mounted, which is fine — the first read just reports zero
    /// rates and the next (1.5 s later) has real ones.
    @State private var reader = NetworkInfoReader()
    @State private var info = NetworkInfo()
    /// The adapter whose detail sheet is open, keyed by BSD name so the sheet
    /// reads live data from `info` each poll rather than a frozen snapshot.
    @State private var selected: AdapterSelection?
    /// Recent per-adapter throughput, keyed by BSD name, for the detail sheet's
    /// per-adapter chart. Accrued from the same single reader so the figures
    /// stay consistent with the rest of the page.
    @State private var trails: [String: [SystemHistoryPoint]] = [:]
    /// The dedicated network discovery workspace replaces the summary page while open.
    @State private var showsNetworkScanner = false

    /// The interface/config poll, driven at the global refresh interval and
    /// recreated when it changes.
    @State private var pollCancellable: AnyCancellable?

    /// Cap on retained per-adapter trail points, whatever the poll cadence.
    private static let maxTrailPoints = 120

    /// The throughput chart's points, snapshotted from the model's ring once per
    /// poll rather than re-mapped (O(900)) on every body evaluation.
    @State private var throughputPoints: [SystemHistoryPoint] = []

    /// Serial queue for the interface read: `getifaddrs` + SCDynamicStore + the
    /// Wi-Fi SSID lookup can take tens of milliseconds, which used to run
    /// synchronously on the main thread each poll. Static and serial so
    /// overlapping polls (tab remount, visibility flip) never race the reader's
    /// inter-read counters.
    private static let pollQueue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.networkpoll", qos: .userInitiated)

    /// Identifiable wrapper so `.sheet(item:)` can key on a plain BSD name.
    private struct AdapterSelection: Identifiable { let id: String }

    var body: some View {
        Group {
            if showsNetworkScanner {
                NetworkScanView(networkInfo: info, dismiss: { showsNetworkScanner = false })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        throughputPanel
                        adaptersPanel
                        configPanel
                        perAppPanel
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            poll()
            startPolling()
            if appState.showNetworkScanner { openNetworkScanner() }
        }
        .onDisappear { pollCancellable?.cancel() }
        // Re-arm the poll whenever the global interval changes.
        .onChange(of: refreshInterval) { _, _ in startPolling() }
        // Poll once immediately when the window comes back into view.
        .onChange(of: appState.mainWindowVisible) { _, visible in if visible { poll() } }
        .onChange(of: appState.showNetworkScanner) { _, requested in
            if requested { openNetworkScanner() }
        }
        .sheet(item: $selected) { sel in
            NetworkAdapterDetailView(
                bsdName: sel.id, info: info, trail: trails[sel.id] ?? [],
                dismiss: { selected = nil })
        }
    }

    /// (Re)start the interface poll at the current global refresh interval, so a
    /// slower interval lightens this tab too; the menu-bar read-outs stay live.
    private func startPolling() {
        pollCancellable?.cancel()
        pollCancellable =
            Timer.publish(every: max(1, refreshInterval), on: .main, in: .common)
            .autoconnect()
            .sink { _ in if appState.mainWindowVisible { poll() } }
    }

    /// Read a fresh snapshot off the main thread, then apply it and append each
    /// adapter's current rate to its trail back on main.
    private func poll() {
        let reader = self.reader
        Self.pollQueue.async {
            // Stamp at read time, not schedule time: two queued polls (tab
            // appear + visibility flip) execute back-to-back on the serial
            // queue, and a schedule-time stamp would divide the second read's
            // real counter delta by a near-zero dt — phantom rate spikes that
            // linger in the trails.
            let now = Date()
            let fresh = reader.read(now: now)
            DispatchQueue.main.async { apply(fresh, at: now) }
        }
    }

    private func apply(_ fresh: NetworkInfo, at now: Date) {
        info = fresh
        let present = Set(fresh.interfaces.map(\.bsdName))
        trails = trails.filter { present.contains($0.key) }
        for adapter in fresh.interfaces {
            var points = trails[adapter.bsdName] ?? []
            points.append(
                SystemHistoryPoint(
                    date: now, pressurePercent: 0, appMemory: 0, wired: 0, compressed: 0,
                    cachedFiles: 0, swapUsed: 0,
                    networkInBytesPerSec: adapter.inBytesPerSec,
                    networkOutBytesPerSec: adapter.outBytesPerSec))
            if points.count > Self.maxTrailPoints {
                points.removeFirst(points.count - Self.maxTrailPoints)
            }
            trails[adapter.bsdName] = points
        }
        throughputPoints = chartPoints
    }

    // MARK: - Header

    private var header: some View {
        let rates = model.smoothedNetworkRates
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(info.hostName ?? "This Mac")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 22) {
                rateStat(
                    "Download", rates?.inBytesPerSec, NetworkStyle.download, NetworkStyle.downSymbol
                )
                rateStat(
                    "Upload", rates?.outBytesPerSec, NetworkStyle.upload, NetworkStyle.upSymbol)
            }
            Button {
                openNetworkScanner()
            } label: {
                Label("Network Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .help("Discover devices on your local network")
        }
    }

    private func openNetworkScanner() {
        appState.showNetworkScanner = false
        guard !showsNetworkScanner else { return }
        showsNetworkScanner = true
        AppLog.ui.notice("Network Scan workspace opened")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let primary = info.primaryAdapter {
            parts.append("Primary: \(primary.displayName)")
        } else if let p = info.primaryInterface {
            parts.append("Primary: \(p)")
        }
        if let router = info.router { parts.append("Router \(router)") }
        return parts.isEmpty ? "Network" : parts.joined(separator: " · ")
    }

    private func rateStat(
        _ label: String, _ value: Double?, _ tint: Color, _ symbol: String
    )
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.map { ByteFormat.rate($0) } ?? "—")
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold)).tracking(0.5)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Throughput chart

    private var throughputPanel: some View {
        NetworkPanel("Throughput", systemImage: "chart.xyaxis.line") {
            NetworkChart(points: throughputPoints)
                .frame(height: 150)
            if let net = model.latestNetwork {
                Text(
                    "This session: \(ByteFormat.string(net.sessionInBytes)) downloaded · "
                        + "\(ByteFormat.string(net.sessionOutBytes)) uploaded"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The live in-memory throughput history, mapped to chart points. Live only
    /// (the Dashboard carries the long historical ranges).
    private var chartPoints: [SystemHistoryPoint] {
        model.systemHistory.elements().map { s in
            SystemHistoryPoint(
                date: s.timestamp, pressurePercent: 0, appMemory: 0, wired: 0, compressed: 0,
                cachedFiles: 0, swapUsed: 0,
                networkInBytesPerSec: s.networkInBytesPerSec,
                networkOutBytesPerSec: s.networkOutBytesPerSec)
        }
    }

    // MARK: - Adapters

    private var adaptersPanel: some View {
        NetworkPanel("Adapters", systemImage: "app.connected.to.app.below.fill") {
            let adapters = info.listedInterfaces
            if adapters.isEmpty {
                Text("Reading adapters…").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(adapters.enumerated()), id: \.element.id) { index, adapter in
                        if index > 0 { Divider() }
                        AdapterRow(
                            adapter: adapter,
                            isPrimary: adapter.bsdName == info.primaryInterface,
                            onTap: { selected = AdapterSelection(id: adapter.bsdName) })
                    }
                }
                Text("Click an adapter for full detail.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Configuration

    private var configPanel: some View {
        NetworkPanel("Configuration", systemImage: "gearshape.2") {
            configRow("Computer name", info.hostName)
            configRow("Primary service", info.primaryAdapter?.displayName ?? info.primaryInterface)
            configRow("Router", info.router)
            configRow(
                "DNS servers",
                info.dnsServers.isEmpty ? nil : info.dnsServers.joined(separator: ", "))
            configRow(
                "Search domains",
                info.searchDomains.isEmpty ? nil : info.searchDomains.joined(separator: ", "))
            if let ssid = info.wifiSSID { configRow("Wi-Fi network", ssid) }
        }
    }

    @ViewBuilder private func configRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? "—")
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    // MARK: - Per-app

    private var perAppPanel: some View {
        NetworkPanel("Per-app usage", systemImage: "list.bullet") {
            Toggle("Track per-app network usage", isOn: $trackPerApp)
            Text(
                "Attribute traffic to individual apps. Off by default because it runs the system's "
                    + "“nettop” tool in the background, so it uses a little more CPU. The totals above "
                    + "work without it."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if trackPerApp {
                Divider()
                let top = Array(menuLists.topNetwork.prefix(8))
                if top.isEmpty {
                    Text("No app network activity right now.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
                } else {
                    let maxRate = max(top.first?.networkBytesPerSec ?? 1, 1)
                    ForEach(top) { process in
                        appRow(process, maxRate: maxRate)
                    }
                }
            }
        }
    }

    private func appRow(_ process: ProcessSample, maxRate: Double) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable().frame(width: 18, height: 18)
            Text(process.displayName)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule()
                .fill(NetworkStyle.download.opacity(0.7))
                .frame(width: max(3, 70 * process.networkBytesPerSec / maxRate), height: 5)
                .frame(width: 70, alignment: .leading)
            Text(ByteFormat.rate(process.networkBytesPerSec))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .processRowActions(identity: process.id)
    }
}

// MARK: - Adapter row

private struct AdapterRow: View {
    let adapter: NetworkInterfaceInfo
    let isPrimary: Bool
    var onTap: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(adapter.isActive ? Color.accentColor : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(adapter.displayName).font(.callout.weight(.semibold))
                    Text(adapter.bsdName).font(.caption2.monospacedDigit()).foregroundStyle(
                        .secondary)
                    if isPrimary { badge("Primary", .blue) }
                    statusBadge
                }
                if !adapter.ipv4.isEmpty {
                    detail("IPv4", adapter.ipv4.joined(separator: ", "))
                }
                if !adapter.ipv6.isEmpty {
                    detail("IPv6", adapter.ipv6.prefix(2).joined(separator: ", "))
                }
                if let mac = adapter.macAddress {
                    detail("MAC", mac)
                }
            }

            Spacer(minLength: 8)

            // Live up/down for this adapter, with session totals beneath.
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: NetworkStyle.downSymbol).foregroundStyle(
                        NetworkStyle.download
                    )
                    .imageScale(.small)
                    Text(ByteFormat.rate(adapter.inBytesPerSec))
                        .font(.callout.monospacedDigit())
                }
                HStack(spacing: 4) {
                    Image(systemName: NetworkStyle.upSymbol).foregroundStyle(NetworkStyle.upload)
                        .imageScale(.small)
                    Text(ByteFormat.rate(adapter.outBytesPerSec))
                        .font(.callout.monospacedDigit())
                }
                if adapter.sessionInBytes > 0 || adapter.sessionOutBytes > 0 {
                    Text(
                        "\(ByteFormat.string(adapter.sessionInBytes)) / \(ByteFormat.string(adapter.sessionOutBytes))"
                    )
                    .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .opacity(adapter.isActive ? 1 : 0.6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.accentColor.opacity(0.10) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            "\(adapter.displayName) adapter, \(adapter.isActive ? "connected" : "inactive")"
        )
        .accessibilityHint("Opens full adapter detail")
    }

    private var icon: String {
        switch adapter.kind {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .thunderbolt: return "bolt.horizontal.fill"
        case .bridge: return "square.stack.3d.up.fill"
        case .vpn: return "lock.shield.fill"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .other: return "network"
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if adapter.isActive {
            badge("Connected", .green)
        } else if adapter.isRunning {
            badge("No address", .secondary)
        } else {
            badge("Inactive", .secondary)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Panel

/// A titled, bordered card matching the Dashboard's panel chrome (which is
/// private to that file), so the Network page reads as part of the same app.
private struct NetworkPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: systemImage).font(.subheadline).foregroundStyle(.secondary)
                Text(title).font(.headline)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
