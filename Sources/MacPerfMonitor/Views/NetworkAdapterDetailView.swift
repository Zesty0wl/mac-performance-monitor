import Charts
import MacPerfMonitorCore
import SwiftUI

/// The per-adapter detail sheet, opened by clicking an adapter on the Network
/// page. Shows everything macOS exposes for the interface without elevated
/// privileges: identity, link, every address with its mask/broadcast, the Wi-Fi
/// radio (for 802.11), and live + cumulative traffic counters.
///
/// It is handed the live `NetworkInfo` (re-passed each poll by the parent) and
/// looks its adapter up by BSD name, so the figures keep ticking while open.
struct NetworkAdapterDetailView: View {
    let bsdName: String
    let info: NetworkInfo
    /// Recent throughput for this adapter, for the per-adapter chart.
    var trail: [SystemHistoryPoint] = []
    var xDomain: ClosedRange<Date>? = nil
    var dismiss: () -> Void = {}

    private var adapter: NetworkInterfaceInfo? {
        info.interfaces.first { $0.bsdName == bsdName }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let adapter {
                header(adapter)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        throughputSection(adapter)
                        generalSection(adapter)
                        addressSection(adapter)
                        if let wifi = adapter.wifi { wifiSection(wifi) }
                        trafficSection(adapter)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "Adapter unavailable", systemImage: "network.slash",
                    description: Text(t("%@ is no longer present.", bsdName)))
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
    }

    // MARK: - Header

    private func header(_ a: NetworkInterfaceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(a.kind))
                .font(.title)
                .foregroundStyle(a.isActive ? Color.accentColor : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.displayName).font(.title3.weight(.semibold))
                Text("\(kindLabel(a.kind)) · \(a.bsdName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge(a)
        }
        .padding(16)
    }

    @ViewBuilder private func statusBadge(_ a: NetworkInterfaceInfo) -> some View {
        if a.isActive {
            badge("Connected", .green)
        } else if a.isRunning {
            badge("Link up, no address", .orange)
        } else {
            badge("Inactive", .secondary)
        }
    }

    // MARK: - Sections

    private func throughputSection(_ a: NetworkInterfaceInfo) -> some View {
        section("Throughput") {
            HStack(spacing: 22) {
                rateStat(
                    "Download", a.inBytesPerSec, NetworkStyle.download, NetworkStyle.downSymbol)
                rateStat("Upload", a.outBytesPerSec, NetworkStyle.upload, NetworkStyle.upSymbol)
                Spacer(minLength: 0)
            }
            ZStack {
                NetworkChart(points: trail, xDomain: xDomain)
                if trail.count < 2 {
                    Text("Collecting…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)
        }
    }

    private func rateStat(
        _ label: LocalizedStringKey, _ value: Double, _ tint: Color, _ symbol: String
    )
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text(ByteFormat.rate(value)).font(.headline.monospacedDigit())
                Text(label)
                    .textCase(.uppercase)
                    .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
            }
        }
    }

    private func generalSection(_ a: NetworkInterfaceInfo) -> some View {
        section("General") {
            row("Type", kindLabel(a.kind))
            if a.bsdName == info.primaryInterface { row("Role", t("Primary service")) }
            row("Hardware (MAC)", a.macAddress ?? "—")
            if a.linkSpeedBitsPerSec > 0 {
                row("Link speed", Self.linkSpeed(a.linkSpeedBitsPerSec))
            }
            if a.mtu > 0 { row("MTU", t("%d bytes", a.mtu)) }
            row(
                "Status",
                a.isUp
                    ? (a.isRunning ? t("Up, active") : t("Up, no link"))
                    : t("Down"))
        }
    }

    @ViewBuilder private func addressSection(_ a: NetworkInterfaceInfo) -> some View {
        let v4 = a.addresses.filter { $0.family == .ipv4 }
        let v6 = a.addresses.filter { $0.family == .ipv6 }
        section("Addresses") {
            if v4.isEmpty && v6.isEmpty {
                row("IP address", t("None assigned"))
            }
            ForEach(v4) { addr in
                row("IPv4", addr.cidr)
                if let b = addr.broadcast { row("Broadcast", b, secondary: true) }
            }
            ForEach(v6) { addr in
                row(addr.isLinkLocal ? "IPv6 (link-local)" : "IPv6", addr.cidr)
            }
            if let router = info.router, a.bsdName == info.primaryInterface {
                row("Router", router)
            }
            if !info.dnsServers.isEmpty, a.bsdName == info.primaryInterface {
                row("DNS", info.dnsServers.joined(separator: ", "))
            }
        }
    }

    private func wifiSection(_ w: WiFiInfo) -> some View {
        section("Wi-Fi") {
            row("Network (SSID)", w.ssid ?? t("Not available"))
            if let bssid = w.bssid { row("BSSID", bssid) }
            if let ch = w.channel {
                row("Channel", w.band.map { "\(ch) (\($0))" } ?? "\(ch)")
            }
            if let phy = w.phyMode { row("Mode", phy) }
            if let tx = w.txRateMbps { row("Tx rate", String(format: "%.0f Mbps", tx)) }
            if let rssi = w.rssiDBm { row("Signal", "\(rssi) dBm · \(Self.signalQuality(rssi))") }
            if let noise = w.noiseDBm { row("Noise", "\(noise) dBm") }
            if let sec = w.security { row("Security", sec) }
            if w.ssid == nil {
                Text(
                    t(
                        "macOS hides the Wi-Fi name and BSSID unless Location Services is enabled for %@.",
                        AppInfo.displayName)
                )
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func trafficSection(_ a: NetworkInterfaceInfo) -> some View {
        section("Traffic") {
            row("Download now", ByteFormat.rate(a.inBytesPerSec))
            row("Upload now", ByteFormat.rate(a.outBytesPerSec))
            row(
                "This session",
                "\(ByteFormat.string(a.sessionInBytes)) ↓ · \(ByteFormat.string(a.sessionOutBytes)) ↑"
            )
            row(
                "Packets", t("%1$@ in · %2$@ out", fmt(a.packetsIn), fmt(a.packetsOut)),
                secondary: true)
            if a.errorsIn > 0 || a.errorsOut > 0 {
                row(
                    "Errors", t("%1$@ in · %2$@ out", fmt(a.errorsIn), fmt(a.errorsOut)),
                    secondary: true)
            }
            if a.collisions > 0 { row("Collisions", fmt(a.collisions), secondary: true) }
            if a.drops > 0 { row("Dropped", fmt(a.drops), secondary: true) }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder private func section(
        _ title: LocalizedStringKey, @ViewBuilder _ content: () -> some View
    )
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .textCase(.uppercase)
                .font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) { content() }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String, secondary: Bool = false)
        -> some View
    {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(secondary ? .tertiary : .secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(secondary ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func badge(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Formatting

    private func fmt(_ n: UInt64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    private func icon(_ kind: NetworkInterfaceInfo.Kind) -> String {
        switch kind {
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

    private func kindLabel(_ kind: NetworkInterfaceInfo.Kind) -> String {
        switch kind {
        case .wifi: return t("Wi-Fi")
        case .ethernet: return t("Ethernet")
        case .thunderbolt: return t("Thunderbolt")
        case .bridge: return t("Bridge")
        case .vpn: return t("VPN")
        case .cellular: return t("Cellular")
        case .loopback: return t("Loopback")
        case .other: return t("Other")
        }
    }

    static func linkSpeed(_ bps: UInt64) -> String {
        let mbps = Double(bps) / 1_000_000
        if mbps >= 1000 {
            return String(format: "%.1f Gbps", mbps / 1000).replacingOccurrences(of: ".0", with: "")
        }
        return String(format: "%.0f Mbps", mbps)
    }

    /// A plain-language band for a Wi-Fi RSSI in dBm.
    static func signalQuality(_ rssi: Int) -> String {
        switch rssi {
        case (-60)...: return t("Excellent")
        case (-70)...(-61): return t("Good")
        // "Fair" is already spoken for by ThermalPressureState (a positive "nominal" reading,
        // translated "良好"), which would misleadingly read as "Good" here, one tier up from
        // where this mid-strength Wi-Fi signal actually sits. Disambiguated key; en.lproj should
        // map it back to "Fair" so the English interface is unaffected.
        case (-80)...(-71): return t("Wi-Fi signal fair")
        default: return t("Weak")
        }
    }
}
