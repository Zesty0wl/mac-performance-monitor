import Foundation
import IOKit

/// One fan's telemetry from the SMC.
struct FanSample: Sendable, Equatable {
    var rpm: Int
    var maxRPM: Int?
}

/// Apple silicon temperatures and fan speeds read from the SMC, grouped by
/// domain. Sensor keys are discovered once by name prefix and then sampled on
/// an internal throttle (temperatures move slowly, so the SMC is touched at
/// most every few seconds however often this is called).
struct ThermalSample: Sendable, Equatable {
    /// Hottest CPU die sensor (P or E cluster), degrees Celsius. Max, not
    /// average: "CPU temperature" means the hottest core to a user.
    var cpuDieMaxC: Double?

    /// Average across the CPU die sensors, the secondary trend figure.
    var cpuDieAvgC: Double?

    /// Hottest GPU cluster sensor. Nil on chips with no GPU-specific keys.
    var gpuDieMaxC: Double?

    /// Hottest SSD sensor.
    var ssdMaxC: Double?

    /// Every fan the SMC reports, in index order. Empty on fanless Macs.
    var fans: [FanSample] = []

    /// The fastest-spinning fan, for single-readout displays.
    var primaryFanRPM: Int? { fans.map(\.rpm).max() }

    /// The highest rated maximum across the fans.
    var primaryFanMaxRPM: Int? { fans.compactMap(\.maxRPM).max() }
}

/// Reads die, SSD, and fan telemetry from the AppleSMC user client.
///
/// Discovery is pattern based (prefix plus plausibility), never a per-chip key
/// table: key names drift between M1/M2/M3/M4 generations but the prefixes
/// have held. See docs/temperature-design.md for the probed key inventory.
final class SMCReader {
    /// The temperature domain a discovered key's readings belong to.
    enum SensorDomain: Sendable, Equatable {
        case cpuDie
        case gpuDie
        case ssd
    }

    private var connection: io_connect_t = 0
    private var didOpen = false
    private var didDiscover = false
    private var cpuKeys: [UInt32] = []
    private var gpuKeys: [UInt32] = []
    private var ssdKeys: [UInt32] = []
    private var fanCount = 0
    private var cached = ThermalSample()
    private var lastRead: Date?
    private let minInterval: TimeInterval = 5.0
    /// Full-inventory discovery cache (`sensorInventory`), separate from the
    /// sampling key sets above: every readable temperature key, not just the
    /// headline domains.
    private var inventoryKeys: [(key: UInt32, name: String)]?
    private var inventoryFanCount = 0

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func read(now: Date) -> ThermalSample? {
        if let lastRead, now.timeIntervalSince(lastRead) < minInterval { return cached }
        guard open() else { return nil }
        if !didDiscover { discoverKeys() }

        var sample = ThermalSample()
        let cpu = temperatures(of: cpuKeys)
        sample.cpuDieMaxC = cpu.max()
        if !cpu.isEmpty { sample.cpuDieAvgC = cpu.reduce(0, +) / Double(cpu.count) }
        sample.gpuDieMaxC = temperatures(of: gpuKeys).max()
        sample.ssdMaxC = temperatures(of: ssdKeys).max()
        sample.fans = (0..<fanCount).compactMap(readFan)
        cached = sample
        lastRead = now
        return sample
    }

    // MARK: - Classification policy

    /// Which domain an SMC key's readings belong to, or nil for keys that must
    /// never feed a die figure. `TV*` keys are voltage-rail sensors, not die:
    /// the SMC enumerates keys sorted with uppercase before lowercase, so a
    /// `TV`-accepting discovery with a small cap used to fill every slot with
    /// voltage rails on chips with many `TV*` keys (M3 Pro has 12+ plausible
    /// ones) and never reach a single `Te*`/`Tp*` die sensor. Case matters
    /// throughout: `Tg*` is the GPU, while `TG0*` keys are battery-adjacent.
    static func domain(forKeyName name: String) -> SensorDomain? {
        if name.hasPrefix("Tp") || name.hasPrefix("Te") { return .cpuDie }
        if name.hasPrefix("Tg") { return .gpuDie }
        if name.hasPrefix("TH0") { return .ssd }
        return nil
    }

    /// Discovery gate: strict, so calibration offsets (0.00 / -3.10 pairs),
    /// dead zones, and sub-ambient junk never become sampled keys.
    static func isPlausibleDiscoveryTemperature(_ celsius: Double) -> Bool {
        celsius > 10 && celsius < 110
    }

    /// Read-time gate: lenient, so a known-good key still reports from a Mac
    /// in a cold room while a failed read (0) stays excluded.
    static func isPlausibleReading(_ celsius: Double) -> Bool {
        celsius > 1 && celsius < 130
    }

    /// Decodes an SMC value by type code. `ioft` is a 64-bit little-endian
    /// fixed point with 16 fraction bits.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits =
                UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ioft":
            guard bytes.count >= 8 else { return nil }
            var value: UInt64 = 0
            for index in (0..<8).reversed() { value = value << 8 | UInt64(bytes[index]) }
            return Double(value) / 65536.0
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui8 ":
            return bytes.first.map(Double.init)
        default:
            return nil
        }
    }

    // MARK: - Reading

    private func temperatures(of keys: [UInt32]) -> [Double] {
        keys.compactMap { key in
            guard let value = readFloat(key), Self.isPlausibleReading(value) else { return nil }
            return value
        }
    }

    private func readFan(_ index: Int) -> FanSample? {
        guard let rpm = readFloat(Self.fourCC("F\(index)Ac")) else { return nil }
        let maxRPM = readFloat(Self.fourCC("F\(index)Mx")).map { Int($0.rounded()) }
        return FanSample(rpm: Int(rpm.rounded()), maxRPM: maxRPM)
    }

    // MARK: - Full inventory (Hardware explorer)

    /// One named temperature reading from the full SMC enumeration.
    struct SensorReading: Sendable, Equatable {
        var key: String
        var celsius: Double
        var group: String
    }

    /// Every readable temperature key with a plausible value, grouped by
    /// domain, plus the fans. The first call pays the full enumeration (a few
    /// hundred milliseconds, so never on the sampling tick); repeat calls on
    /// the same reader re-read just the discovered keys (tens of
    /// milliseconds), which is what lets a visible sensor surface stay live.
    /// Callers keep one reader confined to their own queue.
    func sensorInventory() -> (sensors: [SensorReading], fans: [FanSample]) {
        guard open() else { return ([], []) }
        if inventoryKeys == nil {
            var discovered: [(key: UInt32, name: String)] = []
            if let total = readUInt32(Self.fourCC("#KEY")), total > 0 {
                for index in 0..<total {
                    guard let key = keyAtIndex(index) else { continue }
                    let name = Self.toString(key)
                    guard name.hasPrefix("T") else { continue }
                    guard let value = readFloat(key), Self.isPlausibleReading(value) else {
                        continue
                    }
                    discovered.append((key, name))
                }
            }
            inventoryKeys = discovered
            var fans = readFloat(Self.fourCC("FNum")).map { Int($0) } ?? 0
            if fans == 0, (readFloat(Self.fourCC("F0Mx")) ?? 0) > 0 { fans = 1 }
            inventoryFanCount = fans
        }
        let sensors = (inventoryKeys ?? []).compactMap { entry -> SensorReading? in
            guard let value = readFloat(entry.key), Self.isPlausibleReading(value) else {
                return nil
            }
            return SensorReading(
                key: entry.name, celsius: value, group: Self.sensorGroup(forKeyName: entry.name))
        }
        return (sensors, (0..<inventoryFanCount).compactMap(readFan))
    }

    /// Human grouping for the full key set. Broader than `domain(forKeyName:)`,
    /// which only admits keys safe to fold into headline die figures; here
    /// everything readable is shown, honestly labelled. Ordering for display
    /// lives in `sensorGroupOrder`.
    static func sensorGroup(forKeyName name: String) -> String {
        if name.hasPrefix("Tp") { return "CPU die (P cores)" }
        if name.hasPrefix("Te") { return "CPU die (E cores)" }
        if name.hasPrefix("Tg") { return "GPU clusters" }
        if name.hasPrefix("TH0") { return "SSD" }
        if name.hasPrefix("TB") { return "Battery" }
        if name.hasPrefix("Ta") { return "Airflow" }
        if name.hasPrefix("Ts") { return "Skin and board" }
        if name.hasPrefix("Th") { return "Skin and board" }
        if name.hasPrefix("TW") { return "Wireless" }
        if name.hasPrefix("TV") { return "Voltage rails" }
        return "Other"
    }

    static let sensorGroupOrder = [
        "CPU die (P cores)", "CPU die (E cores)", "GPU clusters", "SSD", "Battery",
        "Airflow", "Skin and board", "Wireless", "Voltage rails", "Other",
    ]

    // MARK: - Connection

    private func open() -> Bool {
        if didOpen { return connection != 0 }
        didOpen = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    /// One-time discovery: a single enumeration classifying every plausible
    /// temperature key into its domain (uncapped: the full die-sensor sweep
    /// costs single-digit milliseconds at the read throttle), plus the fan
    /// count from `FNum` with a probe of fan 0 as the fallback.
    private func discoverKeys() {
        didDiscover = true
        fanCount = readFloat(Self.fourCC("FNum")).map { Int($0) } ?? 0
        if fanCount == 0, (readFloat(Self.fourCC("F0Mx")) ?? 0) > 0 { fanCount = 1 }
        guard let total = readUInt32(Self.fourCC("#KEY")), total > 0 else { return }
        for index in 0..<total {
            guard let key = keyAtIndex(index) else { continue }
            guard let domain = Self.domain(forKeyName: Self.toString(key)) else { continue }
            guard let value = readFloat(key), Self.isPlausibleDiscoveryTemperature(value) else {
                continue
            }
            switch domain {
            case .cpuDie: cpuKeys.append(key)
            case .gpuDie: gpuKeys.append(key)
            case .ssd: ssdKeys.append(key)
            }
        }
    }

    // MARK: - SMC protocol

    func keyAtIndex(_ index: UInt32) -> UInt32? {
        var input = SMCParamStruct()
        input.data8 = 8  // kSMCGetKeyFromIndex
        input.data32 = index
        let out = call(&input)
        return out.result == 0 ? out.key : nil
    }

    func readFloat(_ key: UInt32) -> Double? {
        guard let (type, bytes) = readKey(key) else { return nil }
        return Self.decode(type: type, bytes: bytes)
    }

    private func readUInt32(_ key: UInt32) -> UInt32? {
        guard let (_, bytes) = readKey(key), bytes.count >= 4 else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    private func readKey(_ key: UInt32) -> (type: String, bytes: [UInt8])? {
        var info = SMCParamStruct()
        info.key = key
        info.data8 = 9  // kSMCGetKeyInfo
        let infoOut = call(&info)
        guard infoOut.result == 0, infoOut.keyInfo.dataSize > 0 else { return nil }

        var read = SMCParamStruct()
        read.key = key
        read.keyInfo = infoOut.keyInfo
        read.data8 = 5  // kSMCReadKey
        let readOut = call(&read)
        guard readOut.result == 0 else { return nil }

        let size = Int(infoOut.keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: readOut.bytes) { Array($0.prefix(size)) }
        return (Self.toString(infoOut.keyInfo.dataType), bytes)
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        _ = IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outputSize)
        return output
    }

    static func fourCC(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in s.utf8 { result = (result << 8) | UInt32(byte) }
        return result
    }

    static func toString(_ value: UInt32) -> String {
        let bytes = [
            UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

// MARK: - SMC struct layout (must match the kernel's SMCParamStruct, 80 bytes)

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8,
    UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// `padding` after `keyInfo` is load-bearing: Swift packs the nested `keyInfo`
/// struct tighter than C, and without it the struct is 76 bytes and the kernel
/// rejects the call (kIOReturnBadArgument). With it the layout is the kernel's 80.
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}
