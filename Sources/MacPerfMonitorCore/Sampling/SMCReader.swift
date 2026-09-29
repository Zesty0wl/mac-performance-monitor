import Foundation
import IOKit

/// One fan's telemetry from the SMC.
struct FanSample: Sendable, Equatable {
    var rpm: Int
    var maxRPM: Int?
}

/// Apple silicon temperatures and fan speeds read from the SMC, grouped by
/// domain. Sensor candidates are discovered by name and type, then validated
/// on each throttled read. Incomplete discovery is retried infrequently.
struct ThermalSample: Sendable, Equatable {
    /// Hottest CPU die sensor (P or E cluster), degrees Celsius. Max, not
    /// average: "CPU temperature" means the hottest core to a user.
    var cpuDieMaxC: Double?

    /// Per-display-group hottest readings, recorded so the Hardware tab's
    /// sensor charts have history to read back after a restart.
    var cpuPCoreMaxC: Double?
    var cpuECoreMaxC: Double?
    var batteryMaxC: Double?
    var airflowMaxC: Double?
    var skinMaxC: Double?
    var wirelessMaxC: Double?
    var voltageRailMaxC: Double?
    var otherMaxC: Double?

    /// Average across the CPU die sensors, the secondary trend figure.
    var cpuDieAvgC: Double?

    /// Hottest GPU cluster sensor. Nil if no GPU-specific key has a valid reading.
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
/// Discovery is pattern based, never a per-chip key table. Recognized die
/// candidates need decodable metadata, not a plausible first value: a zero or
/// unavailable first read must not exclude a sensor for the reader's lifetime.
/// Other groups still require a plausible discovery value.
final class SMCReader {

    /// Tests supply the user-client transport without opening hardware. Both
    /// transports use the same response validation, discovery and sampling path.
    typealias Transport = (inout SMCParamStruct, inout SMCParamStruct, inout Int) -> kern_return_t
    private let transport: Transport?
    private var connection: io_connect_t = 0
    private var didOpen = false
    private var fanCount = 0
    private var cached = ThermalSample()
    private var lastRead: Date?
    private let minInterval: TimeInterval = 5.0
    /// Temperature candidates shared by sampling and the full inventory. A
    /// retained key is not itself evidence of an available temperature.
    private var groupedKeys: [(key: UInt32, name: String, group: String)]?
    private var lastDiscovery: Date?
    private var discoveryIncomplete = false
    /// Retry absent domains or failed enumeration/metadata reads at most once
    /// per five minutes, not every sampling pass. Retained keys need no rescan
    /// when their values temporarily become unavailable.
    static let discoveryRetryInterval: TimeInterval = 300
    /// The slow-moving domains' last readings, refreshed on their own longer
    /// cadence (see `slowInterval`) and carried between sweeps.
    private var slowMaxima: [String: Double] = [:]
    private var lastSlowRead: Date?
    /// Airflow, skin, wireless, rails and the unidentified tail move over
    /// minutes, not seconds, and there are ~190 of them against ~75 die keys:
    /// sweeping the lot every read cost 37 ms a time (measured on an M3 Pro),
    /// which would have pushed the app's time-averaged CPU from 1.3% toward
    /// the 2% budget. They get a 30 s cadence; the figures a user watches move
    /// at the full read rate.
    private let slowInterval: TimeInterval = 30

    init(transport: Transport? = nil) {
        self.transport = transport
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// The per-domain hottest readings for one tick. Every display group is
    /// carried, not just the die figures: the recorded history behind the
    /// Hardware tab's sensor charts is built from these, so the trends survive
    /// a restart.
    func read(now: Date) -> ThermalSample? {
        if let lastRead, now.timeIntervalSince(lastRead) < minInterval { return cached }
        guard open() else { return nil }
        discover(now: now)

        let slowDue = lastSlowRead.map { now.timeIntervalSince($0) >= slowInterval } ?? true
        var maxima: [String: Double] = [:]
        var slow: [String: Double] = [:]
        var cpuValues: [Double] = []
        for entry in groupedKeys ?? [] {
            let isFast = Self.isFastGroup(entry.group)
            guard isFast || slowDue else { continue }
            guard let value = readFloat(entry.key), Self.isPlausibleReading(value) else { continue }
            if isFast {
                maxima[entry.group] = Swift.max(maxima[entry.group] ?? value, value)
                if entry.group == Self.groupCPUPCores || entry.group == Self.groupCPUECores {
                    cpuValues.append(value)
                }
            } else {
                slow[entry.group] = Swift.max(slow[entry.group] ?? value, value)
            }
        }
        if slowDue {
            slowMaxima = slow
            lastSlowRead = now
        }
        maxima.merge(slowMaxima) { current, _ in current }

        var sample = ThermalSample()
        sample.cpuPCoreMaxC = maxima[Self.groupCPUPCores]
        sample.cpuECoreMaxC = maxima[Self.groupCPUECores]
        sample.cpuDieMaxC = [sample.cpuPCoreMaxC, sample.cpuECoreMaxC].compactMap { $0 }.max()
        if !cpuValues.isEmpty {
            sample.cpuDieAvgC = cpuValues.reduce(0, +) / Double(cpuValues.count)
        }
        sample.gpuDieMaxC = maxima[Self.groupGPU]
        sample.ssdMaxC = maxima[Self.groupSSD]
        sample.batteryMaxC = maxima[Self.groupBattery]
        sample.airflowMaxC = maxima[Self.groupAirflow]
        sample.skinMaxC = maxima[Self.groupSkin]
        sample.wirelessMaxC = maxima[Self.groupWireless]
        sample.voltageRailMaxC = maxima[Self.groupVoltageRails]
        sample.otherMaxC = maxima[Self.groupOther]
        sample.fans = (0..<fanCount).compactMap(readFan)
        cached = sample
        lastRead = now
        return sample
    }

    // MARK: - Classification policy

    /// True for the groups that may feed a die temperature figure. `TV*` keys
    /// are voltage-rail sensors, not die: the SMC enumerates keys sorted with
    /// uppercase before lowercase, so a `TV`-accepting discovery with a small
    /// cap used to fill every slot with voltage rails on chips with many `TV*`
    /// keys (M3 Pro has 12+ plausible ones) and never reach a single
    /// `Te*`/`Tp*` die sensor. Case matters throughout: `Tg*` is the GPU,
    /// while `TG0*` keys are battery-adjacent.
    static func isDieGroup(_ group: String) -> Bool {
        group == groupCPUPCores || group == groupCPUECores || group == groupGPU
    }

    /// The domains read on every sampling pass: the ones a user watches move
    /// second to second, and few enough keys to be cheap. The rest ride
    /// `slowInterval`.
    static func isFastGroup(_ group: String) -> Bool {
        isDieGroup(group) || group == groupSSD || group == groupBattery
    }

    enum TemperatureKeyPolicy: Equatable {
        case ignore
        case retainCandidate
        case requirePlausibleValue
    }

    /// Metadata establishes whether a recognized die key should be retried,
    /// independently of its current value. Case is significant, so neither
    /// voltage rails nor uppercase TG keys can become die candidates. Ta0*
    /// keys are the documented calibration-offset family, not temperatures.
    static func discoveryPolicy(
        name: String, type: String, dataSize: Int
    ) -> TemperatureKeyPolicy {
        guard name.utf8.count == 4, name.hasPrefix("T"), !name.hasPrefix("Ta0"),
            let expectedSize = scalarByteCount(forType: type), dataSize == expectedSize
        else { return .ignore }
        return isDieGroup(sensorGroup(forKeyName: name))
            ? .retainCandidate : .requirePlausibleValue
    }

    /// Discovery gate for the non-die groups: zero offsets, dead zones and
    /// sub-ambient junk must not become sampled keys just because they decode.
    static func isPlausibleDiscoveryTemperature(_ celsius: Double) -> Bool {
        celsius > 10 && celsius < 110
    }

    /// Read-time gate for every temperature candidate. A zero or invalid value
    /// stays missing even when the key was retained during discovery.
    static func isPlausibleReading(_ celsius: Double) -> Bool {
        celsius > 1 && celsius < 130
    }

    /// Decodes an exact-size SMC scalar by type code. `ioft` is a 64-bit
    /// little-endian fixed point with 16 fraction bits.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        guard let byteCount = scalarByteCount(forType: type), bytes.count == byteCount else {
            return nil
        }
        switch type {
        case "flt ":
            let bits =
                UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "ioft":
            var value: UInt64 = 0
            for index in (0..<8).reversed() { value = value << 8 | UInt64(bytes[index]) }
            return Double(value) / 65536.0
        case "ui16":
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui8 ":
            return Double(bytes[0])
        default:
            return nil
        }
    }

    private static func scalarByteCount(forType type: String) -> Int? {
        switch type {
        case "flt ": return 4
        case "ioft": return 8
        case "ui16": return 2
        case "ui8 ": return 1
        default: return nil
        }
    }

    // MARK: - Reading

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
    /// hundred milliseconds); repeat calls on the same reader re-read just the
    /// discovered keys (tens of milliseconds), which is what lets a visible
    /// sensor surface stay live. Callers keep one reader confined to their own
    /// queue.
    func sensorInventory() -> (sensors: [SensorReading], fans: [FanSample]) {
        guard open() else { return ([], []) }
        discover(now: Date())
        let sensors = (groupedKeys ?? []).compactMap { entry -> SensorReading? in
            guard let value = readFloat(entry.key), Self.isPlausibleReading(value) else {
                return nil
            }
            return SensorReading(key: entry.name, celsius: value, group: entry.group)
        }
        return (sensors, (0..<fanCount).compactMap(readFan))
    }

    static let groupCPUPCores = "CPU die (P cores)"
    static let groupCPUECores = "CPU die (E cores)"
    static let groupGPU = "GPU clusters"
    static let groupSSD = "SSD"
    static let groupBattery = "Battery"
    static let groupAirflow = "Airflow"
    static let groupSkin = "Skin and board"
    static let groupWireless = "Wireless"
    static let groupVoltageRails = "Voltage rails"
    static let groupOther = "Other"

    /// Human grouping for the full key set: every readable sensor is placed,
    /// honestly labelled, including the rails and the unidentified tail that
    /// must never reach a die figure. Ordering for display lives in
    /// `sensorGroupOrder`.
    static func sensorGroup(forKeyName name: String) -> String {
        if name.hasPrefix("Tp") { return groupCPUPCores }
        if name.hasPrefix("Te") { return groupCPUECores }
        if name.hasPrefix("Tg") { return groupGPU }
        if name.hasPrefix("TH0") { return groupSSD }
        if name.hasPrefix("TB") { return groupBattery }
        if name.hasPrefix("Ta") { return groupAirflow }
        if name.hasPrefix("Ts") { return groupSkin }
        if name.hasPrefix("Th") { return groupSkin }
        if name.hasPrefix("TW") { return groupWireless }
        if name.hasPrefix("TV") { return groupVoltageRails }
        return groupOther
    }

    static let sensorGroupOrder = [
        groupCPUPCores, groupCPUECores, groupGPU, groupSSD, groupBattery,
        groupAirflow, groupSkin, groupWireless, groupVoltageRails, groupOther,
    ]

    // MARK: - Connection

    private func open() -> Bool {
        if transport != nil { return true }
        if didOpen { return connection != 0 }
        didOpen = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    /// Enumerate once in the normal case. A missing die domain or a failed
    /// enumeration/metadata read warrants a bounded retry. Merge discoveries:
    /// a failed rescan must never discard candidates already known to exist.
    private func discover(now: Date) {
        let groups = Set((groupedKeys ?? []).map { $0.group })
        let missingDieDomain = [Self.groupCPUPCores, Self.groupCPUECores, Self.groupGPU]
            .contains { !groups.contains($0) }
        if let lastDiscovery {
            guard discoveryIncomplete || missingDieDomain,
                now.timeIntervalSince(lastDiscovery) >= Self.discoveryRetryInterval
            else { return }
        }
        lastDiscovery = now
        var found = groupedKeys ?? []
        var knownKeys = Set(found.map { $0.key })
        var incomplete = false
        if let total = readUInt32(Self.fourCC("#KEY")), total > 0 {
            for index in 0..<total {
                guard let key = keyAtIndex(index) else {
                    incomplete = true
                    continue
                }
                let name = Self.toString(key)
                guard name.hasPrefix("T"), !knownKeys.contains(key) else { continue }
                guard let info = readKeyInfo(key) else {
                    if Self.isDieGroup(Self.sensorGroup(forKeyName: name)) { incomplete = true }
                    continue
                }
                switch Self.discoveryPolicy(
                    name: name, type: Self.toString(info.dataType), dataSize: Int(info.dataSize))
                {
                case .ignore:
                    continue
                case .retainCandidate:
                    break
                case .requirePlausibleValue:
                    guard let raw = readKey(key, info: info),
                        let value = Self.decode(type: raw.type, bytes: raw.bytes),
                        Self.isPlausibleDiscoveryTemperature(value)
                    else { continue }
                }
                found.append((key, name, Self.sensorGroup(forKeyName: name)))
                knownKeys.insert(key)
            }
        } else {
            incomplete = true
        }
        groupedKeys = found
        discoveryIncomplete = incomplete
        fanCount = readFloat(Self.fourCC("FNum")).map { Int($0) } ?? 0
        if fanCount == 0, (readFloat(Self.fourCC("F0Mx")) ?? 0) > 0 { fanCount = 1 }
    }

    // MARK: - SMC protocol

    func keyAtIndex(_ index: UInt32) -> UInt32? {
        var input = SMCParamStruct()
        input.data8 = 8  // kSMCGetKeyFromIndex
        input.data32 = index
        return call(&input)?.key
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
        guard let info = readKeyInfo(key) else { return nil }
        return readKey(key, info: info)
    }

    private func readKeyInfo(_ key: UInt32) -> SMCKeyInfoData? {
        var info = SMCParamStruct()
        info.key = key
        info.data8 = 9  // kSMCGetKeyInfo
        guard let infoOut = call(&info), infoOut.keyInfo.dataSize > 0,
            infoOut.keyInfo.dataSize <= UInt32(MemoryLayout<SMCBytes>.size)
        else { return nil }
        return infoOut.keyInfo
    }

    private func readKey(_ key: UInt32, info: SMCKeyInfoData) -> (type: String, bytes: [UInt8])? {
        var read = SMCParamStruct()
        read.key = key
        read.keyInfo = info
        read.data8 = 5  // kSMCReadKey
        guard let readOut = call(&read) else { return nil }

        let size = Int(info.dataSize)
        let bytes = withUnsafeBytes(of: readOut.bytes) { Array($0.prefix(size)) }
        return (Self.toString(info.dataType), bytes)
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result: kern_return_t
        if let transport {
            result = transport(&input, &output, &outputSize)
        } else {
            result = IOConnectCallStructMethod(
                connection, 2, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outputSize)
        }
        // A transport failure can leave the zero-initialized result field at
        // zero. Neither that nor a truncated response is a successful SMC read.
        guard result == kIOReturnSuccess, outputSize == MemoryLayout<SMCParamStruct>.stride,
            output.result == 0
        else { return nil }
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

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8,
    UInt8, UInt8, UInt8, UInt8
)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// `padding` after `keyInfo` is load-bearing: Swift packs the nested `keyInfo`
/// struct tighter than C, and without it the struct is 76 bytes and the kernel
/// rejects the call (kIOReturnBadArgument). With it the layout is the kernel's 80.
struct SMCParamStruct {
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
