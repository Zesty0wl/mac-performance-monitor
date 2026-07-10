import Darwin
import Foundation

/// Reads system-wide network throughput from the kernel's per-interface byte
/// counters (`getifaddrs` → `if_data`), summed across the physical Ethernet and
/// Wi-Fi interfaces (`en*`). Loopback, AWDL, VPN tunnels (`utun*`), and bridges
/// are deliberately excluded: tunnels and bridges carry traffic that *also*
/// crosses an `en*` interface, so counting them would double the figure.
///
/// Cheap enough (one `getifaddrs` walk) to run on the fast system tick, like
/// `CPUReader`/`BatteryReader`. Stateful, unlike those: throughput is a rate, so
/// the reader keeps each interface's previous cumulative counters and differences
/// them. `getifaddrs` exposes the classic 32-bit counters, which wrap every 4 GB;
/// unsigned wraparound subtraction (`&-`) recovers the correct per-tick delta as
/// long as less than a full wrap happened between reads (always true at a
/// sub-second cadence), and the session totals are accumulated into 64-bit sums
/// from those deltas so they never saturate.
///
/// Confined to the sampler's serial queue like the rest of the sampling path.
public final class NetworkReader {
    public init() {}

    /// Per-interface previous cumulative counters (the wrapping 32-bit figures),
    /// keyed by interface name, for the inter-read delta.
    private var lastCounters: [String: (inBytes: UInt32, outBytes: UInt32)] = [:]
    private var lastTime: Date?

    /// Session totals accumulated from per-tick deltas (64-bit, so they never
    /// wrap), counted from the first reading this session.
    private var sessionIn: UInt64 = 0
    private var sessionOut: UInt64 = 0

    /// Read the current throughput. Returns a sample with zero rates on the first
    /// call (no previous counters to difference yet) and whenever no time has
    /// elapsed. Returns nil only if the interface list cannot be read at all.
    public func read(now: Date = Date()) -> NetworkSample? {
        guard let snapshot = Self.interfaceSnapshot() else { return nil }
        let counters = snapshot.counters

        let dt = lastTime.map { now.timeIntervalSince($0) } ?? 0
        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        var busiest: (name: String, bytes: UInt64)?

        for (name, current) in counters {
            guard let previous = lastCounters[name] else { continue }
            // Unsigned wraparound subtraction recovers the delta across a 32-bit
            // counter wrap, as long as under one full wrap elapsed (a 4 GB tick
            // is impossible at this cadence).
            let inD = UInt64(current.inBytes &- previous.inBytes)
            let outD = UInt64(current.outBytes &- previous.outBytes)
            deltaIn &+= inD
            deltaOut &+= outD
            let total = inD &+ outD
            if total > (busiest?.bytes ?? 0) { busiest = (name, total) }
        }

        lastCounters = counters
        lastTime = now
        sessionIn &+= deltaIn
        sessionOut &+= deltaOut

        let inRate = dt > 0 ? Double(deltaIn) / dt : 0
        let outRate = dt > 0 ? Double(deltaOut) / dt : 0

        // The local IPv4 of the active interface, preferring the busiest one, then
        // en0, then any en*; for the network menu's "via Wi-Fi · 192.168.x.y" line.
        let ipv4 = snapshot.ipv4
        let localIP = busiest.flatMap { ipv4[$0.name] } ?? ipv4["en0"] ?? ipv4.values.sorted().first

        return NetworkSample(
            timestamp: now,
            inBytesPerSec: inRate,
            outBytesPerSec: outRate,
            sessionInBytes: sessionIn,
            sessionOutBytes: sessionOut,
            primaryInterface: busiest?.name,
            localIPv4: localIP
        )
    }

    /// Reset inter-read state (e.g. after a long pause) so the next read reports a
    /// zero rate rather than a since-boot spike. Mirrors `Sampler.reset()`.
    public func reset() {
        lastCounters.removeAll()
        lastTime = nil
    }

    private struct InterfaceSnapshot {
        var counters: [String: (inBytes: UInt32, outBytes: UInt32)]
        var ipv4: [String: String]
    }

    /// Read counters and addresses in one `getifaddrs` walk. The linked list has
    /// one entry per address family, so AF_LINK and AF_INET data for the same
    /// interface naturally land in the two dictionaries below.
    private static func interfaceSnapshot() -> InterfaceSnapshot? {
        var firstAddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddr) == 0, let firstAddr else { return nil }
        defer { freeifaddrs(firstAddr) }

        var counters: [String: (inBytes: UInt32, outBytes: UInt32)] = [:]
        var ipv4: [String: String] = [:]
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            // Physical Ethernet/Wi-Fi only. Counting tunnels/bridges/loopback
            // would double-count traffic that also crosses an en* interface.
            guard name.hasPrefix("en") else { continue }

            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                guard let raw = ifa.ifa_data else { continue }
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = (UInt32(data.ifi_ibytes), UInt32(data.ifi_obytes))
            case AF_INET where ipv4[name] == nil:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST) == 0
                {
                    ipv4[name] = String(cString: host)
                }
            default:
                continue
            }
        }
        return InterfaceSnapshot(counters: counters, ipv4: ipv4)
    }
}
