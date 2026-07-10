import Darwin
import Foundation

public struct NetworkScanConfiguration: Sendable, Equatable {
    public static let maximumHostCount = 4096

    public var interfaceName: String
    public var localIPv4Address: String
    public var localMACAddress: String?
    public var fromIPv4Address: String
    public var toIPv4Address: String

    public init(
        interfaceName: String,
        localIPv4Address: String,
        localMACAddress: String? = nil,
        fromIPv4Address: String,
        toIPv4Address: String
    ) {
        self.interfaceName = interfaceName
        self.localIPv4Address = localIPv4Address
        self.localMACAddress = localMACAddress
        self.fromIPv4Address = fromIPv4Address
        self.toIPv4Address = toIPv4Address
    }

    public func addresses() throws -> [String] {
        guard !interfaceName.isEmpty else { throw NetworkScanError.missingInterface }
        guard NetworkIPv4Address.value(localIPv4Address) != nil else {
            throw NetworkScanError.invalidAddress(localIPv4Address)
        }
        guard let first = NetworkIPv4Address.value(fromIPv4Address) else {
            throw NetworkScanError.invalidAddress(fromIPv4Address)
        }
        guard let last = NetworkIPv4Address.value(toIPv4Address) else {
            throw NetworkScanError.invalidAddress(toIPv4Address)
        }
        guard first <= last else { throw NetworkScanError.reversedRange }
        let count = UInt64(last) - UInt64(first) + 1
        guard count <= UInt64(Self.maximumHostCount) else {
            throw NetworkScanError.rangeTooLarge(Int(count), maximum: Self.maximumHostCount)
        }
        return (first...last).map(NetworkIPv4Address.string)
    }
}

public enum NetworkScanError: LocalizedError, Sendable, Equatable {
    case missingInterface
    case invalidAddress(String)
    case reversedRange
    case rangeTooLarge(Int, maximum: Int)
    case socketUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingInterface:
            return "Choose a network interface."
        case .invalidAddress(let address):
            return "\(address) is not a valid IPv4 address."
        case .reversedRange:
            return "The first address must not come after the last address."
        case .rangeTooLarge(let count, let maximum):
            return "The range contains \(count) addresses. Choose \(maximum) or fewer."
        case .socketUnavailable:
            return "The discovery socket could not be opened."
        }
    }
}

public enum NetworkIPv4Address {
    public static func value(_ string: String) -> UInt32? {
        var address = in_addr()
        guard string.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    public static func string(_ value: UInt32) -> String {
        var address = in_addr(s_addr: value.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return ""
        }
        return String(cString: buffer)
    }

    public static func suggestedRange(
        address: String, prefixLength: Int?,
        maximumHostCount: Int = NetworkScanConfiguration.maximumHostCount
    ) -> (from: String, to: String)? {
        guard let addressValue = value(address) else { return nil }
        let requestedPrefix = min(max(prefixLength ?? 24, 0), 32)
        let requestedCount = requestedPrefix == 32 ? 1 : UInt64(1) << (32 - requestedPrefix)
        let minimumPrefix = 32 - Int(floor(log2(Double(max(maximumHostCount, 1)))))
        let prefix = requestedCount > UInt64(maximumHostCount) ? minimumPrefix : requestedPrefix
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefix)
        let network = addressValue & mask
        let broadcast = network | ~mask

        let first: UInt32
        let last: UInt32
        if prefix <= 30 {
            first = network &+ 1
            last = broadcast &- 1
        } else {
            first = network
            last = broadcast
        }
        return (string(first), string(last))
    }
}

public struct NetworkScanHost: Sendable, Equatable, Identifiable {
    public var ipv4Address: String
    public var ipv6LocalAddresses: [String]
    public var ipv6GlobalAddresses: [String]
    public var macAddress: String?
    public var hostName: String?
    public var vendor: String?
    public var identification: String?
    public var dnsName: String?
    public var mdnsName: String?
    public var smbName: String?
    public var smbDomain: String?
    public var isReachable: Bool

    public var id: String { ipv4Address }

    public init(
        ipv4Address: String,
        ipv6LocalAddresses: [String] = [],
        ipv6GlobalAddresses: [String] = [],
        macAddress: String? = nil,
        hostName: String? = nil,
        vendor: String? = nil,
        identification: String? = nil,
        dnsName: String? = nil,
        mdnsName: String? = nil,
        smbName: String? = nil,
        smbDomain: String? = nil,
        isReachable: Bool = true
    ) {
        self.ipv4Address = ipv4Address
        self.ipv6LocalAddresses = ipv6LocalAddresses
        self.ipv6GlobalAddresses = ipv6GlobalAddresses
        self.macAddress = macAddress
        self.hostName = hostName
        self.vendor = vendor
        self.identification = identification
        self.dnsName = dnsName
        self.mdnsName = mdnsName
        self.smbName = smbName
        self.smbDomain = smbDomain
        self.isReachable = isReachable
    }
}

public enum NetworkMACAddressKind: Sendable, Equatable {
    case universallyAdministered
    case locallyAdministered
    case multicast
}

public enum NetworkMACAddress {
    public static func kind(_ value: String?) -> NetworkMACAddressKind? {
        guard let normalized = NetworkScanner.normalizedMAC(value),
            let firstOctet = UInt8(normalized.prefix(2), radix: 16)
        else { return nil }
        if firstOctet & 0x01 != 0 { return .multicast }
        if firstOctet & 0x02 != 0 { return .locallyAdministered }
        return .universallyAdministered
    }
}

public enum NetworkScanPhase: Sendable, Equatable {
    case discovering
    case identifying
    case finished
}

public struct NetworkScanProgress: Sendable, Equatable {
    public var phase: NetworkScanPhase
    public var completedAddressCount: Int
    public var totalAddressCount: Int
    public var deviceCount: Int

    public init(
        phase: NetworkScanPhase,
        completedAddressCount: Int,
        totalAddressCount: Int,
        deviceCount: Int
    ) {
        self.phase = phase
        self.completedAddressCount = completedAddressCount
        self.totalAddressCount = totalAddressCount
        self.deviceCount = deviceCount
    }
}

public enum NetworkScanEvent: Sendable, Equatable {
    case host(NetworkScanHost)
    case progress(NetworkScanProgress)
    case vendorLookupStarted
    case vendors([String: String])
    case vendorLookupFinished
    case failed(String)
}

public struct NetworkOpenPort: Sendable, Equatable, Identifiable {
    public var port: UInt16
    public var serviceName: String
    public var id: UInt16 { port }

    public init(port: UInt16, serviceName: String) {
        self.port = port
        self.serviceName = serviceName
    }
}

public final class NetworkScanner: @unchecked Sendable {
    public init() {}

    public func scan(_ configuration: NetworkScanConfiguration) -> AsyncStream<NetworkScanEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.performScan(configuration, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func scanPorts(
        host: String,
        interfaceName: String,
        ports: [UInt16],
        timeout: TimeInterval = 0.25
    ) async -> [NetworkOpenPort] {
        let requested = Array(Set(ports)).sorted()
        var open: [NetworkOpenPort] = []
        for batchStart in stride(from: 0, to: requested.count, by: 64) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + 64, requested.count)
            let batch = Array(requested[batchStart..<batchEnd])
            let found = await withTaskGroup(of: NetworkOpenPort?.self) { group in
                for port in batch {
                    group.addTask {
                        guard
                            Self.isTCPPortOpen(
                                host: host, port: port, interfaceName: interfaceName,
                                timeout: timeout)
                        else { return nil }
                        return NetworkOpenPort(
                            port: port, serviceName: Self.serviceName(for: port))
                    }
                }
                var results: [NetworkOpenPort] = []
                for await result in group {
                    if let result { results.append(result) }
                }
                return results
            }
            open.append(contentsOf: found)
        }
        return open.sorted { $0.port < $1.port }
    }

    private static func performScan(
        _ configuration: NetworkScanConfiguration,
        continuation: AsyncStream<NetworkScanEvent>.Continuation
    ) async {
        let addresses: [String]
        do {
            addresses = try configuration.addresses()
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            continuation.finish()
            return
        }

        var hosts: [String: NetworkScanHost] = [:]
        let total = addresses.count
        continuation.yield(
            .progress(
                NetworkScanProgress(
                    phase: .discovering, completedAddressCount: 0,
                    totalAddressCount: total, deviceCount: 0)))

        mergeNeighborSnapshot(
            configuration: configuration, into: &hosts, continuation: continuation)

        do {
            try stimulateARP(
                addresses: addresses, configuration: configuration,
                progress: { completed in
                    continuation.yield(
                        .progress(
                            NetworkScanProgress(
                                phase: .discovering, completedAddressCount: completed,
                                totalAddressCount: total, deviceCount: hosts.count)))
                })
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            continuation.finish()
            return
        }

        guard !Task.isCancelled else {
            continuation.finish()
            return
        }
        try? await Task.sleep(nanoseconds: 220_000_000)
        mergeNeighborSnapshot(
            configuration: configuration, into: &hosts, continuation: continuation)

        let missing = addresses.filter { hosts[$0] == nil }
        if !missing.isEmpty, !Task.isCancelled {
            try? stimulateARP(addresses: missing, configuration: configuration, progress: nil)
            try? await Task.sleep(nanoseconds: 650_000_000)
            mergeNeighborSnapshot(
                configuration: configuration, into: &hosts, continuation: continuation)
        }

        guard !Task.isCancelled else {
            continuation.finish()
            return
        }
        continuation.yield(
            .progress(
                NetworkScanProgress(
                    phase: .finished, completedAddressCount: total,
                    totalAddressCount: total, deviceCount: hosts.count)))

        let macAddresses = hosts.values.compactMap(\.macAddress)
        continuation.yield(.vendorLookupStarted)
        if !macAddresses.isEmpty {
            let cachedVendors = await NetworkVendorDatabase.shared.cachedNames(
                for: macAddresses)
            applyVendors(cachedVendors, to: &hosts, continuation: continuation)
            let vendors = await NetworkVendorDatabase.shared.names(for: macAddresses)
            applyVendors(vendors, to: &hosts, continuation: continuation)
        }
        continuation.yield(.vendorLookupFinished)

        let hostAddresses = Array(hosts.keys)
        for batchStart in stride(from: 0, to: hostAddresses.count, by: 16) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + 16, hostAddresses.count)
            let batch = Array(hostAddresses[batchStart..<batchEnd])
            await withTaskGroup(of: (String, Bool).self) { group in
                for address in batch {
                    group.addTask { (address, respondsToPing(address)) }
                }
                for await (address, reachable) in group {
                    guard var host = hosts[address], host.isReachable != reachable else { continue }
                    host.isReachable = reachable
                    hosts[address] = host
                    continuation.yield(.host(host))
                }
            }
        }

        await withTaskGroup(of: (String, String?, SMBIdentity?).self) { group in
            for address in hosts.keys {
                group.addTask {
                    let reverseName = reverseDNSName(for: address)
                    var smb: SMBIdentity?
                    if isTCPPortOpen(
                        host: address, port: 445, interfaceName: configuration.interfaceName,
                        timeout: 0.18)
                    {
                        smb = smbIdentity(for: address)
                    }
                    return (address, reverseName, smb)
                }
            }
            for await (address, reverseName, smb) in group {
                guard var host = hosts[address] else { continue }
                if let reverseName {
                    if reverseName.lowercased().hasSuffix(".local") {
                        host.mdnsName = reverseName
                    } else {
                        host.dnsName = reverseName
                    }
                    host.hostName = reverseName
                }
                if let smb {
                    host.smbName = smb.name
                    host.smbDomain = smb.domain
                    host.hostName = host.hostName ?? smb.name
                    host.identification = host.identification ?? smb.name
                }
                hosts[address] = host
                continuation.yield(.host(host))
            }
        }

        continuation.finish()
    }

    private static func applyVendors(
        _ vendors: [String: String],
        to hosts: inout [String: NetworkScanHost],
        continuation: AsyncStream<NetworkScanEvent>.Continuation
    ) {
        var updates: [String: String] = [:]
        for (address, var host) in hosts {
            guard let mac = host.macAddress,
                let normalized = normalizedMAC(mac),
                let vendor = vendors[normalized],
                host.vendor != vendor
            else { continue }
            host.vendor = vendor
            hosts[address] = host
            updates[address] = vendor
        }
        if !updates.isEmpty { continuation.yield(.vendors(updates)) }
    }

    private static func mergeNeighborSnapshot(
        configuration: NetworkScanConfiguration,
        into hosts: inout [String: NetworkScanHost],
        continuation: AsyncStream<NetworkScanEvent>.Continuation
    ) {
        let first = NetworkIPv4Address.value(configuration.fromIPv4Address) ?? 0
        let last = NetworkIPv4Address.value(configuration.toIPv4Address) ?? 0
        let arpOutput = runTool(path: "/usr/sbin/arp", arguments: ["-an"], timeout: 2) ?? ""
        let ndpOutput = runTool(path: "/usr/sbin/ndp", arguments: ["-an"], timeout: 2) ?? ""
        let ipv6ByMAC = parseNDPTable(ndpOutput, interfaceName: configuration.interfaceName)
        var entries = parseARPTable(arpOutput, interfaceName: configuration.interfaceName)
            .filter { entry in
                guard let value = NetworkIPv4Address.value(entry.ipv4Address) else { return false }
                return value >= first && value <= last
            }
        if let localMAC = normalizedMAC(configuration.localMACAddress),
            let localValue = NetworkIPv4Address.value(configuration.localIPv4Address),
            localValue >= first, localValue <= last
        {
            entries.append(
                ARPEntry(
                    ipv4Address: configuration.localIPv4Address,
                    macAddress: localMAC,
                    interfaceName: configuration.interfaceName))
        }

        for entry in entries {
            var host =
                hosts[entry.ipv4Address]
                ?? NetworkScanHost(ipv4Address: entry.ipv4Address, macAddress: entry.macAddress)
            host.macAddress = entry.macAddress
            host.isReachable = true
            if let ipv6 = ipv6ByMAC[entry.macAddress] {
                host.ipv6LocalAddresses = ipv6.local.sorted()
                host.ipv6GlobalAddresses = ipv6.global.sorted()
            }
            if hosts[entry.ipv4Address] != host {
                hosts[entry.ipv4Address] = host
                continuation.yield(.host(host))
            }
        }
    }

    private static func stimulateARP(
        addresses: [String],
        configuration: NetworkScanConfiguration,
        progress: ((Int) -> Void)?
    ) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw NetworkScanError.socketUnavailable }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        guard
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0
        else { throw NetworkScanError.socketUnavailable }

        var interfaceIndex = if_nametoindex(configuration.interfaceName)
        guard interfaceIndex != 0 else { throw NetworkScanError.missingInterface }
        guard
            setsockopt(
                descriptor, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex,
                socklen_t(MemoryLayout.size(ofValue: interfaceIndex))) == 0
        else { throw NetworkScanError.socketUnavailable }

        if let localValue = NetworkIPv4Address.value(configuration.localIPv4Address) {
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = 0
            local.sin_addr = in_addr(s_addr: localValue.bigEndian)
            let bound = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw NetworkScanError.socketUnavailable }
        }

        var payload: UInt8 = 0
        for (index, address) in addresses.enumerated() {
            if Task.isCancelled { return }
            guard let value = NetworkIPv4Address.value(address) else { continue }
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = UInt16(9).bigEndian
            destination.sin_addr = in_addr(s_addr: value.bigEndian)
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(
                        descriptor, &payload, 1, MSG_DONTWAIT, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if index % 8 == 7 || index == addresses.count - 1 {
                progress?(index + 1)
            }
            usleep(750)
        }
    }

    struct ARPEntry: Equatable {
        var ipv4Address: String
        var macAddress: String
        var interfaceName: String
    }

    static func parseARPTable(_ output: String, interfaceName: String) -> [ARPEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let addressStart = line.firstIndex(of: "("),
                let addressEnd = line[addressStart...].firstIndex(of: ")")
            else { return nil }
            let address = String(line[line.index(after: addressStart)..<addressEnd])
            guard NetworkIPv4Address.value(address) != nil,
                let atRange = line.range(of: ") at "),
                let onRange = line.range(of: " on ", range: atRange.upperBound..<line.endIndex)
            else { return nil }
            let rawMAC = String(line[atRange.upperBound..<onRange.lowerBound])
            guard let mac = normalizedMAC(rawMAC) else { return nil }
            let interfaceStart = onRange.upperBound
            let interfaceEnd =
                line[interfaceStart...].firstIndex(where: \.isWhitespace) ?? line.endIndex
            let foundInterface = String(line[interfaceStart..<interfaceEnd])
            guard foundInterface == interfaceName else { return nil }
            return ARPEntry(
                ipv4Address: address, macAddress: mac, interfaceName: foundInterface)
        }
    }

    struct IPv6Addresses: Equatable {
        var local: Set<String> = []
        var global: Set<String> = []
    }

    static func parseNDPTable(
        _ output: String, interfaceName: String
    ) -> [String: IPv6Addresses] {
        var result: [String: IPv6Addresses] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields[2] == interfaceName,
                let mac = normalizedMAC(fields[1]), fields[0].contains(":")
            else { continue }
            let address =
                fields[0].split(separator: "%", maxSplits: 1).first.map(String.init) ?? fields[0]
            var addresses = result[mac] ?? IPv6Addresses()
            if address.lowercased().hasPrefix("fe80:") {
                addresses.local.insert(address)
            } else {
                addresses.global.insert(address)
            }
            result[mac] = addresses
        }
        return result
    }

    struct SMBIdentity: Equatable {
        var name: String?
        var domain: String?
    }

    static func parseSMBStatus(_ output: String) -> SMBIdentity? {
        var identity = SMBIdentity()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4 else { continue }
            let name = fields[0]
            let number = fields[1].lowercased()
            let type = fields[2].uppercased()
            let description = fields.dropFirst(3).joined(separator: " ")
            if identity.name == nil, number == "0x00", type == "UNIQUE",
                description.contains("Workstation Service")
            {
                identity.name = name
            }
            if identity.domain == nil, number == "0x00", type == "GROUP",
                description.contains("Domain Name")
            {
                identity.domain = name
            }
        }
        return identity.name == nil && identity.domain == nil ? nil : identity
    }

    private static func smbIdentity(for address: String) -> SMBIdentity? {
        guard
            let output = runTool(
                path: "/usr/bin/smbutil", arguments: ["status", "-ae", address], timeout: 2.5)
        else { return nil }
        return parseSMBStatus(output)
    }

    private static func reverseDNSName(for address: String) -> String? {
        guard let value = NetworkIPv4Address.value(address) else { return nil }
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_addr = in_addr(s_addr: value.bigEndian)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo(
                    $0, socklen_t(MemoryLayout<sockaddr_in>.size), &host,
                    socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        let name = String(cString: host).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty || name == address ? nil : name
    }

    private static func respondsToPing(_ address: String) -> Bool {
        runTool(
            path: "/sbin/ping", arguments: ["-c", "1", "-t", "1", "-n", address],
            timeout: 1.5) != nil
    }

    private static func isTCPPortOpen(
        host: String, port: UInt16, interfaceName: String, timeout: TimeInterval
    ) -> Bool {
        guard let value = NetworkIPv4Address.value(host) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var interfaceIndex = if_nametoindex(interfaceName)
        if interfaceIndex != 0 {
            _ = setsockopt(
                descriptor, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex,
                socklen_t(MemoryLayout.size(ofValue: interfaceIndex)))
        }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr = in_addr(s_addr: value.bigEndian)
        let connected = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(1, min(timeout * 1000, Double(Int32.max))))
        guard poll(&pollDescriptor, 1, milliseconds) > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: socketError))
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return false
        }
        return socketError == 0
    }

    private static func serviceName(for port: UInt16) -> String {
        let names: [UInt16: String] = [
            20: "FTP data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP",
            53: "DNS", 67: "DHCP", 80: "HTTP", 110: "POP3", 123: "NTP",
            135: "MS RPC", 139: "NetBIOS", 143: "IMAP", 443: "HTTPS",
            445: "SMB", 515: "LPD", 548: "AFP", 631: "IPP", 993: "IMAPS",
            995: "POP3S", 1883: "MQTT", 2049: "NFS", 3389: "RDP",
            5000: "UPnP", 5353: "mDNS", 5900: "VNC", 8008: "HTTP alt",
            8080: "HTTP alt", 8443: "HTTPS alt", 9100: "Printer",
        ]
        return names[port] ?? "TCP"
    }

    private static func runTool(
        path: String, arguments: [String], timeout: TimeInterval
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let box = NetworkScannerDataBox()
        let finishedReading = DispatchSemaphore(value: 0)
        do {
            try process.run()
        } catch {
            return nil
        }
        DispatchQueue.global(qos: .utility).async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            finishedReading.signal()
        }
        if finishedReading.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finishedReading.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finishedReading.wait(timeout: .now() + 0.2)
            }
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }

    fileprivate static func normalizedMAC(_ value: String?) -> String? {
        guard let value else { return nil }
        let octets = value.split(whereSeparator: { $0 == ":" || $0 == "-" })
        if octets.count == 6,
            octets.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) })
        {
            return octets.map { octet in
                String(repeating: "0", count: 2 - octet.count) + octet.uppercased()
            }.joined(separator: ":")
        }
        let hex = value.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return String(hex[start..<end])
        }.joined(separator: ":")
    }
}

enum NetworkVendorRegistry {
    static func parse(csv: String) -> [String: String] {
        var result: [String: String] = [:]
        csv.enumerateLines { line, _ in
            let fields = csvFields(line)
            guard fields.count >= 3 else { return }
            let assignment = fields[1].uppercased().filter(\.isHexDigit)
            guard assignment.count == 6, assignment != "ASSIGN" else { return }
            let organization = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            if !organization.isEmpty { result[assignment] = organization }
        }
        return result
    }

    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if quoted, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = line.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if character == ",", !quoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(field)
        return fields
    }
}

enum NetworkVendorCache {
    static func names(
        for macAddresses: [String], entries: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for mac in macAddresses {
            guard NetworkMACAddress.kind(mac) == .universallyAdministered,
                let normalized = NetworkScanner.normalizedMAC(mac)
            else { continue }
            let prefix = String(normalized.replacingOccurrences(of: ":", with: "").prefix(6))
            if let vendor = entries[prefix], !vendor.isEmpty {
                result[normalized] = vendor
            }
        }
        return result
    }
}

private actor NetworkVendorDatabase {
    static let shared = NetworkVendorDatabase()

    private static let registryURL = URL(string: "https://standards-oui.ieee.org/oui/oui.csv")!
    private var entries: [String: String]?
    private var resolvedEntries: [String: String]?

    func cachedNames(for macAddresses: [String]) -> [String: String] {
        names(for: macAddresses, using: loadResolvedEntries())
    }

    func names(for macAddresses: [String]) async -> [String: String] {
        let requests = normalizedRequests(for: macAddresses)
        var resolved = loadResolvedEntries()
        var result = names(for: macAddresses, using: resolved)
        let missing = requests.filter { resolved[$0.prefix] == nil }
        guard !missing.isEmpty else { return result }

        let database = await loadEntries()
        var changed = false
        for request in missing {
            let vendor = database[request.prefix] ?? ""
            if !vendor.isEmpty { result[request.macAddress] = vendor }
            if resolved[request.prefix] != vendor {
                resolved[request.prefix] = vendor
                changed = true
            }
        }
        if changed {
            resolvedEntries = resolved
            persistResolvedEntries(resolved)
        }
        return result
    }

    private func names(
        for macAddresses: [String], using database: [String: String]
    ) -> [String: String] {
        NetworkVendorCache.names(for: macAddresses, entries: database)
    }

    private func normalizedRequests(
        for macAddresses: [String]
    ) -> [(macAddress: String, prefix: String)] {
        macAddresses.compactMap { mac in
            guard NetworkMACAddress.kind(mac) == .universallyAdministered,
                let normalized = NetworkScanner.normalizedMAC(mac)
            else { return nil }
            let prefix = normalized.replacingOccurrences(of: ":", with: "").prefix(6)
            return (normalized, String(prefix))
        }
    }

    private func loadResolvedEntries() -> [String: String] {
        if let resolvedEntries { return resolvedEntries }
        guard let data = try? Data(contentsOf: resolvedCacheURL),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            resolvedEntries = [:]
            return [:]
        }
        let sanitized = decoded.filter { prefix, _ in
            NetworkMACAddress.kind(prefix + "000000") == .universallyAdministered
        }
        resolvedEntries = sanitized
        if sanitized.count != decoded.count { persistResolvedEntries(sanitized) }
        return sanitized
    }

    private func persistResolvedEntries(_ entries: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: resolvedCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: resolvedCacheURL, options: .atomic)
    }

    private func loadEntries() async -> [String: String] {
        if let entries { return entries }
        if let cached = try? String(contentsOf: cacheURL, encoding: .utf8) {
            let parsed = NetworkVendorRegistry.parse(csv: cached)
            if !parsed.isEmpty {
                entries = parsed
                return parsed
            }
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.registryURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                data.count < 12_000_000,
                let csv = String(data: data, encoding: .utf8)
            else { throw URLError(.badServerResponse) }
            let parsed = NetworkVendorRegistry.parse(csv: csv)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            entries = parsed
            return parsed
        } catch {
            entries = Self.fallbackEntries
            return Self.fallbackEntries
        }
    }

    private var cacheURL: URL {
        cacheDirectory
            .appendingPathComponent("ieee-oui.csv")
    }

    private var resolvedCacheURL: URL {
        cacheDirectory.appendingPathComponent("network-vendors.json")
    }

    private var cacheDirectory: URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("uk.co.bzwrd.macperfmonitor", isDirectory: true)
    }

    private static let fallbackEntries: [String: String] = [
        "001124": "Apple, Inc.",
        "0017F2": "Apple, Inc.",
        "001B63": "Apple, Inc.",
        "001E52": "Apple, Inc.",
        "001F5B": "Apple, Inc.",
        "0023DF": "Apple, Inc.",
        "002500": "Apple, Inc.",
        "00254B": "Apple, Inc.",
        "0026BB": "Apple, Inc.",
        "04D3CF": "Apple, Inc.",
        "08A6BC": "Amazon Technologies Inc.",
        "0C8BFD": "Intel Corporate",
        "145AFC": "Apple, Inc.",
        "186590": "Apple, Inc.",
        "18E7F4": "Apple, Inc.",
        "28CFDA": "Apple, Inc.",
        "3C22FB": "Apple, Inc.",
        "40B0FA": "Apple, Inc.",
        "48A195": "Apple, Inc.",
        "5C969D": "Apple, Inc.",
        "6C4008": "Apple, Inc.",
        "70CD60": "Apple, Inc.",
        "7CD1C3": "Apple, Inc.",
        "84FCFE": "Apple, Inc.",
        "8C8590": "Apple, Inc.",
        "A851AB": "Apple, Inc.",
        "B827EB": "Raspberry Pi Foundation",
        "B8E856": "Apple, Inc.",
        "C82A14": "Apple, Inc.",
        "D89E3F": "Apple, Inc.",
        "DC2B2A": "Apple, Inc.",
        "E0ACCB": "Apple, Inc.",
        "F0B479": "Apple, Inc.",
        "F4F15A": "Apple, Inc.",
    ]
}

private final class NetworkScannerDataBox: @unchecked Sendable {
    var data = Data()
}
