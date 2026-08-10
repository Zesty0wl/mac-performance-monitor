import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Builds the rich per-adapter `NetworkInfo` for the Network page: each
/// interface's addresses, MAC, link state, and live throughput, plus the
/// machine-wide config (primary service, router, DNS, host name).
///
/// Three sources are merged:
///   1. `getifaddrs` — per-interface byte counters (for the rates), IPv4/IPv6
///      addresses, the hardware MAC, and the up/running flags.
///   2. `SCNetworkInterfaceCopyAll` — the friendly display name and type
///      (Wi-Fi vs Ethernet vs Thunderbolt …) for each configured service.
///   3. `SCDynamicStore` — the global primary interface, default router, and DNS
///      servers / search domains.
///
/// Stateful, like `NetworkReader`: throughput is a rate, so it keeps each
/// interface's previous cumulative counters and differences them across reads
/// (wrap-safe via unsigned subtraction; 64-bit session totals accumulated from
/// the deltas). The Network page owns one of these and polls it while visible.
public final class NetworkInfoReader {
    public init() {}

    private var lastCounters: [String: (inBytes: UInt32, outBytes: UInt32)] = [:]
    private var lastTime: Date?
    private var sessionIn: [String: UInt64] = [:]
    private var sessionOut: [String: UInt64] = [:]

    /// Read a full snapshot. The rates are zero on the first call (nothing to
    /// difference yet).
    public func read(now: Date = Date()) -> NetworkInfo {
        let dt = lastTime.map { now.timeIntervalSince($0) } ?? 0
        let scNames = Self.serviceNamesAndTypes()
        var raw = Self.rawInterfaces()  // [bsd: (flags, counters, ipv4, ipv6, mac)]

        var interfaces: [NetworkInterfaceInfo] = []
        var newCounters: [String: (inBytes: UInt32, outBytes: UInt32)] = [:]
        for (bsd, info) in raw {
            newCounters[bsd] = info.counters
            var inRate = 0.0
            var outRate = 0.0
            if let prev = lastCounters[bsd], dt > 0 {
                let inD = UInt64(info.counters.inBytes &- prev.inBytes)
                let outD = UInt64(info.counters.outBytes &- prev.outBytes)
                inRate = Double(inD) / dt
                outRate = Double(outD) / dt
                sessionIn[bsd, default: 0] &+= inD
                sessionOut[bsd, default: 0] &+= outD
            }
            let sc = scNames[bsd]
            let (displayName, kind) = Self.classify(bsd: bsd, sc: sc, flags: info.flags)
            let isRunning = (info.flags & UInt32(IFF_RUNNING)) != 0
            // Wi-Fi radio detail only for the associated 802.11 interface.
            let wifi = (kind == .wifi && isRunning) ? Self.wifiInfo(bsd: bsd) : nil
            interfaces.append(
                NetworkInterfaceInfo(
                    bsdName: bsd,
                    displayName: displayName,
                    kind: kind,
                    hasServiceName: sc?.name != nil,
                    isUp: (info.flags & UInt32(IFF_UP)) != 0,
                    isRunning: isRunning,
                    ipv4: info.ipv4.sorted(),
                    ipv6: info.ipv6.sorted(),
                    addresses: info.addresses,
                    macAddress: info.mac,
                    inBytesPerSec: inRate,
                    outBytesPerSec: outRate,
                    sessionInBytes: sessionIn[bsd] ?? 0,
                    sessionOutBytes: sessionOut[bsd] ?? 0,
                    mtu: info.mtu,
                    linkSpeedBitsPerSec: info.linkSpeed,
                    packetsIn: info.packetsIn,
                    packetsOut: info.packetsOut,
                    errorsIn: info.errorsIn,
                    errorsOut: info.errorsOut,
                    collisions: info.collisions,
                    drops: info.drops,
                    wifi: wifi))
        }

        lastCounters = newCounters
        lastTime = now
        raw.removeAll()

        let global = Self.globalConfig()
        return NetworkInfo(
            interfaces: interfaces.sorted { $0.bsdName < $1.bsdName },
            primaryInterface: global.primary,
            router: global.router,
            dnsServers: global.dns,
            searchDomains: global.searchDomains,
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            wifiSSID: nil)
    }

    /// Reset inter-read state so the next read reports zero rates.
    public func reset() {
        lastCounters.removeAll()
        lastTime = nil
        sessionIn.removeAll()
        sessionOut.removeAll()
    }

    // MARK: - getifaddrs

    private struct RawInterface {
        var flags: UInt32 = 0
        var counters: (inBytes: UInt32, outBytes: UInt32) = (0, 0)
        var ipv4: [String] = []
        var ipv6: [String] = []
        var addresses: [NetworkAddress] = []
        var mac: String?
        var mtu: Int = 0
        var linkSpeed: UInt64 = 0
        var packetsIn: UInt64 = 0
        var packetsOut: UInt64 = 0
        var errorsIn: UInt64 = 0
        var errorsOut: UInt64 = 0
        var collisions: UInt64 = 0
        var drops: UInt64 = 0
    }

    private static func rawInterfaces() -> [String: RawInterface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [:] }
        defer { freeifaddrs(first) }

        var result: [String: RawInterface] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            let family = Int32(addr.pointee.sa_family)
            var entry = result[name] ?? RawInterface()
            entry.flags = ifa.ifa_flags

            switch family {
            case AF_LINK:
                if let data = ifa.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    entry.counters = (UInt32(d.ifi_ibytes), UInt32(d.ifi_obytes))
                    entry.mtu = Int(d.ifi_mtu)
                    entry.linkSpeed = UInt64(d.ifi_baudrate)
                    entry.packetsIn = UInt64(d.ifi_ipackets)
                    entry.packetsOut = UInt64(d.ifi_opackets)
                    entry.errorsIn = UInt64(d.ifi_ierrors)
                    entry.errorsOut = UInt64(d.ifi_oerrors)
                    entry.collisions = UInt64(d.ifi_collisions)
                    entry.drops = UInt64(d.ifi_iqdrops)
                }
                if let mac = Self.macAddress(addr) { entry.mac = mac }
            case AF_INET:
                if let s = Self.addressString(addr, family: AF_INET) {
                    entry.ipv4.append(s)
                    let prefix = ifa.ifa_netmask.flatMap { Self.prefixLength($0, family: AF_INET) }
                    var broadcast: String?
                    if (ifa.ifa_flags & UInt32(IFF_BROADCAST)) != 0, let b = ifa.ifa_dstaddr {
                        broadcast = Self.addressString(b, family: AF_INET)
                    }
                    entry.addresses.append(
                        NetworkAddress(
                            family: .ipv4, address: s, prefixLength: prefix, broadcast: broadcast))
                }
            case AF_INET6:
                if let s = Self.addressString(addr, family: AF_INET6) {
                    let linkLocal = NetworkScanner.isIPv6LinkLocal(s)
                    if !linkLocal { entry.ipv6.append(s) }
                    let prefix = ifa.ifa_netmask.flatMap { Self.prefixLength($0, family: AF_INET6) }
                    entry.addresses.append(
                        NetworkAddress(
                            family: .ipv6, address: s, prefixLength: prefix, isLinkLocal: linkLocal)
                    )
                }
            default:
                break
            }
            result[name] = entry
        }
        return result
    }

    /// Numeric address string for an AF_INET/AF_INET6 sockaddr, scope id stripped.
    private static func addressString(
        _ sa: UnsafeMutablePointer<sockaddr>, family: Int32
    ) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len =
            family == AF_INET
            ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        guard
            getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        var s = String(cString: host)
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        return s.isEmpty ? nil : s
    }

    /// CIDR prefix length (set-bit count) from a netmask sockaddr.
    private static func prefixLength(_ sa: UnsafeMutablePointer<sockaddr>, family: Int32) -> Int? {
        if family == AF_INET {
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                Int($0.pointee.sin_addr.s_addr.nonzeroBitCount)
            }
        }
        if family == AF_INET6 {
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
                withUnsafeBytes(of: ptr.pointee.sin6_addr) { raw in
                    raw.reduce(0) { $0 + $1.nonzeroBitCount }
                }
            }
        }
        return nil
    }

    /// Hardware MAC from an AF_LINK sockaddr_dl, or nil when not a 6-byte address.
    private static func macAddress(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dlPtr -> String? in
            let dl = dlPtr.pointee
            let nlen = Int(dl.sdl_nlen)
            let alen = Int(dl.sdl_alen)
            guard alen == 6, nlen + alen <= MemoryLayout.size(ofValue: dl.sdl_data) else {
                return nil
            }
            let bytes = withUnsafeBytes(of: dl.sdl_data) { raw -> [UInt8] in
                (0..<alen).map { raw.load(fromByteOffset: nlen + $0, as: UInt8.self) }
            }
            // All-zero MACs (some virtual interfaces) are not worth showing.
            guard bytes.contains(where: { $0 != 0 }) else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }

    // MARK: - CoreWLAN

    /// Wi-Fi radio detail for the given interface, or nil if it is not a usable
    /// Wi-Fi interface or the radio is off / not associated. RSSI, noise,
    /// channel, PHY mode, Tx rate, and security read without special permission;
    /// SSID and BSSID return nil unless Location Services has authorised them.
    private static func wifiInfo(bsd: String) -> WiFiInfo? {
        guard let iface = CWWiFiClient.shared().interface(withName: bsd) else { return nil }
        var w = WiFiInfo()
        w.ssid = iface.ssid()
        w.bssid = iface.bssid()
        let rssi = iface.rssiValue()
        w.rssiDBm = rssi != 0 ? rssi : nil
        let noise = iface.noiseMeasurement()
        w.noiseDBm = noise != 0 ? noise : nil
        if let ch = iface.wlanChannel() {
            w.channel = ch.channelNumber
            switch ch.channelBand {
            case .band2GHz: w.band = "2.4 GHz"
            case .band5GHz: w.band = "5 GHz"
            case .band6GHz: w.band = "6 GHz"
            default: w.band = nil
            }
        }
        switch iface.activePHYMode() {
        case .mode11a: w.phyMode = "802.11a"
        case .mode11b: w.phyMode = "802.11b"
        case .mode11g: w.phyMode = "802.11g"
        case .mode11n: w.phyMode = "Wi-Fi 4 (802.11n)"
        case .mode11ac: w.phyMode = "Wi-Fi 5 (802.11ac)"
        case .mode11ax: w.phyMode = "Wi-Fi 6 (802.11ax)"
        default: w.phyMode = nil
        }
        let tx = iface.transmitRate()
        w.txRateMbps = tx > 0 ? tx : nil
        w.security = Self.securityString(iface.security())
        return w.hasData ? w : nil
    }

    private static func securityString(_ s: CWSecurity) -> String? {
        switch s {
        case .none: return "None"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Transition: return "WPA3 Transition"
        case .personal: return "Personal"
        case .enterprise, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise:
            return "Enterprise"
        default: return nil
        }
    }

    // MARK: - SystemConfiguration

    /// BSD name → (friendly display name, SC interface type string).
    private static func serviceNamesAndTypes() -> [String: (name: String?, type: String?)] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var map: [String: (name: String?, type: String?)] = [:]
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            map[bsd] = (
                SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?,
                SCNetworkInterfaceGetInterfaceType(iface) as String?
            )
        }
        return map
    }

    /// The global primary interface, router, and DNS, from the dynamic store.
    private static func globalConfig() -> (
        primary: String?, router: String?, dns: [String], searchDomains: [String]
    ) {
        guard
            let store = SCDynamicStoreCreate(
                nil, "uk.co.bzwrd.macperfmonitor" as CFString, nil, nil)
        else { return (nil, nil, [], []) }
        let ipv4 =
            SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
            as? [String: Any]
        let dns =
            SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString)
            as? [String: Any]
        return (
            primary: ipv4?["PrimaryInterface"] as? String,
            router: ipv4?["Router"] as? String,
            dns: (dns?["ServerAddresses"] as? [String]) ?? [],
            searchDomains: (dns?["SearchDomains"] as? [String]) ?? []
        )
    }

    /// Derive a friendly name and kind, preferring SystemConfiguration's service
    /// info and falling back to BSD-name heuristics for interfaces SC does not
    /// list (tunnels, AWDL, bridges created on the fly).
    private static func classify(
        bsd: String, sc: (name: String?, type: String?)?, flags: UInt32
    ) -> (String, NetworkInterfaceInfo.Kind) {
        // Only the Wi-Fi and Ethernet SC type constants are reliably exposed to
        // Swift; everything else falls back to the BSD-name heuristic below.
        let kindFromType: NetworkInterfaceInfo.Kind? = sc?.type.flatMap { type in
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return .wifi }
            if type == (kSCNetworkInterfaceTypeEthernet as String) { return .ethernet }
            return nil
        }
        let kindFromName: NetworkInterfaceInfo.Kind
        switch true {
        case bsd == "lo0": kindFromName = .loopback
        case bsd.hasPrefix("utun"), bsd.hasPrefix("ipsec"), bsd.hasPrefix("ppp"),
            bsd.hasPrefix("tap"), bsd.hasPrefix("tun"):
            kindFromName = .vpn
        case bsd.hasPrefix("bridge"): kindFromName = .bridge
        case bsd.hasPrefix("en"): kindFromName = .ethernet
        default: kindFromName = .other
        }
        let kind = kindFromType ?? kindFromName
        let display = sc?.name ?? Self.fallbackName(bsd: bsd, kind: kind)
        return (display, kind)
    }

    private static func fallbackName(bsd: String, kind: NetworkInterfaceInfo.Kind) -> String {
        switch kind {
        case .loopback: return "Loopback"
        case .vpn: return "VPN (\(bsd))"
        case .bridge: return "Bridge (\(bsd))"
        default: return bsd
        }
    }
}
