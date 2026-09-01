import CoreWLAN
import Darwin
import Foundation
import IOKit
import Metal

/// What the kernel and the frameworks know that `system_profiler` does not
/// report, or reports thinly: the device tree's product identity, the CPU's
/// performance levels and instruction-set features, the Metal device limits,
/// the raw battery gauge, the Wi-Fi card as CoreWLAN sees it, and the running
/// kernel. Each reader returns explorer nodes plus the typed facts the
/// overview draws from.
enum HardwareNativeReaders {
    struct Result {
        var nodes: [HardwareNode] = []
        var facts = HardwareFacts()
    }

    // MARK: - Device tree identity

    static func identity(parentID: String, systemImage: String) -> Result {
        var result = Result()
        var properties: [HardwareProperty] = []
        var productName: String?
        var socName: String?

        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if product != 0 {
            defer { IOObjectRelease(product) }
            productName = text(product, "product-name") ?? text(product, "product-description")
            socName = text(product, "product-soc-name")
            if let name = productName { properties.append(HardwareProperty("Product name", name)) }
            if let soc = socName { properties.append(HardwareProperty("System on a chip", soc)) }
            if let upgradeable = uint32(product, "upgradeable-memory") {
                properties.append(
                    HardwareProperty("Upgradeable memory", upgradeable == 0 ? t("No") : t("Yes")))
            }
            if let notch = uint32(product, "partially-occluded-display") {
                properties.append(
                    HardwareProperty(
                        "Display with camera housing", notch == 0 ? t("No") : t("Yes")))
            }
            if let mirroring = uint32(product, "display-mirroring") {
                properties.append(
                    HardwareProperty("Display mirroring", mirroring == 0 ? t("No") : t("Yes")))
            }
            if let chipset = text(product, "wifi-chipset") {
                properties.append(HardwareProperty("Wi-Fi chipset", chipset))
            }
            if let lea = uint32(product, "bluetooth-lea2") {
                properties.append(
                    HardwareProperty("Bluetooth LE Audio", lea == 0 ? t("No") : t("Yes")))
            }
        }

        let expert = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if expert != 0 {
            defer { IOObjectRelease(expert) }
            let model = text(expert, "model")
            let serial = IOKitProperty.string(expert, "IOPlatformSerialNumber")
            let uuid = IOKitProperty.string(expert, "IOPlatformUUID")
            if let model { properties.append(HardwareProperty("Model identifier", model)) }
            if let number = text(expert, "model-number") {
                properties.append(HardwareProperty("Model number", number))
            }
            if let target = text(expert, "target-type") {
                properties.append(HardwareProperty("Target type", target))
            }
            if let sub = text(expert, "target-sub-type") {
                properties.append(HardwareProperty("Target subtype", sub))
            }
            if let serial { properties.append(HardwareProperty("Serial number", serial)) }
            if let uuid { properties.append(HardwareProperty("Hardware UUID", uuid)) }
            if let regulatory = text(expert, "regulatory-model-number") {
                properties.append(HardwareProperty("Regulatory model number", regulatory))
            }
            if let region = text(expert, "region-info") {
                properties.append(HardwareProperty("Region", region))
            }
            if let origin = text(expert, "country-of-origin") {
                properties.append(HardwareProperty("Country of origin", origin))
            }
            if let maker = text(expert, "manufacturer") {
                properties.append(HardwareProperty("Manufacturer", maker))
            }
            if let tag = text(expert, "device-tree-tag") {
                properties.append(HardwareProperty("Device tree", tag))
            }
            if let stamp = text(expert, "time-stamp") {
                properties.append(HardwareProperty("Firmware built", stamp))
            }
            if let clock = uint32(expert, "clock-frequency") {
                properties.append(HardwareProperty("Reference clock", "\(clock / 1_000_000) MHz"))
            }
            result.facts.modelIdentifier = model
            result.facts.serialNumber = serial
        }
        result.facts.productName = productName
        result.facts.chipName = socName ?? Sysctl.string("machdep.cpu.brand_string")

        let title = productName ?? Sysctl.string("hw.model") ?? t("This Mac")
        result.nodes = [
            HardwareNode(
                id: "\(parentID)/native/identity", title: title,
                subtitle: socName ?? Sysctl.string("hw.model"), systemImage: systemImage,
                properties: properties)
        ]
        return result
    }

    // MARK: - Processor

    static func processor(parentID: String, systemImage: String) -> Result {
        var result = Result()
        let brand = Sysctl.string("machdep.cpu.brand_string") ?? t("Processor")
        let logical = Sysctl.integer("hw.logicalcpu", as: Int32.self).map(Int.init) ?? 0
        let physical = Sysctl.integer("hw.physicalcpu", as: Int32.self).map(Int.init) ?? 0
        let levels = Sysctl.integer("hw.nperflevels", as: Int32.self).map(Int.init) ?? 0

        var properties: [HardwareProperty] = [
            HardwareProperty("Chip", brand),
            HardwareProperty("Architecture", Sysctl.string("hw.machine") ?? "arm64"),
            HardwareProperty("Physical cores", "\(physical)"),
            HardwareProperty("Logical cores", "\(logical)"),
        ]
        var levelNodes: [HardwareNode] = []
        var summary: [String] = []
        for level in 0..<max(levels, 0) {
            let prefix = "hw.perflevel\(level)."
            let name = Sysctl.string(prefix + "name") ?? t("Level %@", "\(level)")
            let cores = Sysctl.integer(prefix + "physicalcpu", as: Int32.self).map(Int.init) ?? 0
            let maxCores =
                Sysctl.integer(prefix + "physicalcpu_max", as: Int32.self).map(Int.init) ?? cores
            let l1i = Sysctl.integer(prefix + "l1icachesize", as: Int64.self)
            let l1d = Sysctl.integer(prefix + "l1dcachesize", as: Int64.self)
            let l2 = Sysctl.integer(prefix + "l2cachesize", as: Int64.self)
            let perL2 = Sysctl.integer(prefix + "cpusperl2", as: Int32.self)
            let isPerformance = name.lowercased().hasPrefix("perf")
            let isEfficiency = name.lowercased().hasPrefix("eff")
            // "%@ performance" / "%@ efficiency" are Hardware-page-specific
            // (the summary reads "4 performance, 6 efficiency"); the level
            // node's own title and subtitle below reuse the same
            // "Performance cores" / "Efficiency cores" / "%@ cores" keys the
            // Dashboard and GPU tabs already use for the same concept.
            summary.append(
                isPerformance
                    ? t("%@ performance", "\(cores)")
                    : isEfficiency
                        ? t("%@ efficiency", "\(cores)") : "\(cores) \(name.lowercased())")
            if isPerformance { result.facts.performanceCores = cores }
            if isEfficiency { result.facts.efficiencyCores = cores }
            var levelProperties: [HardwareProperty] = [
                HardwareProperty("Cores", "\(cores)"),
                HardwareProperty("Cores available", "\(maxCores)"),
            ]
            if let l1i {
                levelProperties.append(HardwareProperty("L1 instruction cache", bytes(l1i)))
            }
            if let l1d { levelProperties.append(HardwareProperty("L1 data cache", bytes(l1d))) }
            if let l2 { levelProperties.append(HardwareProperty("L2 cache", bytes(l2))) }
            if let perL2 { levelProperties.append(HardwareProperty("Cores per L2", "\(perL2)")) }
            let levelTitle =
                isPerformance
                ? t("Performance cores") : isEfficiency ? t("Efficiency cores") : "\(name) cores"
            levelNodes.append(
                HardwareNode(
                    id: "\(parentID)/native/perflevel\(level)", title: levelTitle,
                    subtitle: cores == 1 ? t("1 core") : t("%@ cores", "\(cores)"),
                    systemImage: systemImage,
                    properties: levelProperties))
        }
        if let line = Sysctl.integer("hw.cachelinesize", as: Int64.self) {
            properties.append(HardwareProperty("Cache line", "\(line) bytes"))
        }
        if let page = Sysctl.integer("hw.pagesize", as: Int64.self) {
            properties.append(HardwareProperty("Page size", bytes(page)))
        }
        if let tb = Sysctl.integer("hw.tbfrequency", as: Int64.self) {
            properties.append(HardwareProperty("Timebase frequency", "\(tb / 1_000_000) MHz"))
        }
        if let family = Sysctl.integer("hw.cpufamily", as: UInt32.self) {
            properties.append(HardwareProperty("CPU family", String(format: "0x%08x", family)))
        }
        if let sub = Sysctl.integer("hw.cpusubfamily", as: UInt32.self) {
            properties.append(HardwareProperty("CPU subfamily", "\(sub)"))
        }
        if let target = Sysctl.string("hw.targettype") {
            properties.append(HardwareProperty("Target type", target))
        }
        if let cpu64 = Sysctl.integer("hw.cpu64bit_capable", as: Int32.self) {
            properties.append(HardwareProperty("64-bit capable", cpu64 == 1 ? t("Yes") : t("No")))
        }
        if let hv = Sysctl.integer("kern.hv_support", as: Int32.self) {
            properties.append(
                HardwareProperty("Hypervisor support", hv == 1 ? t("Yes") : t("No")))
        }

        let features = isaFeatures()
        let supported = features.filter(\.supported)
        result.facts.isaFeatureCount = supported.count
        let featureNode = HardwareNode(
            id: "\(parentID)/native/features", title: t("Instruction set features"),
            subtitle: t("%@ supported", "\(supported.count)"), systemImage: systemImage,
            properties: features.map {
                HardwareProperty($0.name, $0.supported ? t("Supported") : t("Not supported"))
            })

        result.nodes = [
            HardwareNode(
                id: "\(parentID)/native/cpu", title: brand,
                subtitle: summary.isEmpty
                    ? (physical == 1 ? t("1 core") : t("%@ cores", "\(physical)"))
                    : summary.joined(separator: ", "),
                systemImage: systemImage, properties: properties,
                children: levelNodes + [featureNode])
        ]
        return result
    }

    struct ISAFeature: Equatable {
        var name: String
        var supported: Bool
    }

    /// Every `hw.optional.*` flag the kernel publishes, ARM `FEAT_*` names
    /// first, read by walking the sysctl tree so a feature this code has never
    /// heard of still appears.
    static func isaFeatures() -> [ISAFeature] {
        var names = sysctlNames(under: "hw.optional")
        if names.isEmpty { names = fallbackFeatureNames }
        var features: [ISAFeature] = []
        for name in names {
            // Flags only: `hw.optional.arm.sme_max_svl_b` is a size, not a feature.
            guard let value = Sysctl.integer(name, as: Int32.self), value == 0 || value == 1,
                !name.contains("_max_")
            else { continue }
            var short = name
            if short.hasPrefix("hw.optional.arm.") {
                short.removeFirst("hw.optional.arm.".count)
            } else if short.hasPrefix("hw.optional.") {
                short.removeFirst("hw.optional.".count)
            }
            features.append(ISAFeature(name: short, supported: value != 0))
        }
        return features.sorted { lhs, rhs in
            let lf = lhs.name.hasPrefix("FEAT_")
            let rf = rhs.name.hasPrefix("FEAT_")
            if lf != rf { return lf }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The names under a sysctl node, via the kernel's own next-oid walk (the
    /// same `{0, 2}` / `{0, 1}` queries `sysctl -a` uses).
    static func sysctlNames(under prefix: String) -> [String] {
        var mib = [Int32](repeating: 0, count: 32)
        var mibLength = mib.count
        guard sysctlnametomib(prefix, &mib, &mibLength) == 0, mibLength > 0 else { return [] }
        let root = Array(mib[0..<mibLength])
        var names: [String] = []
        var current = root
        while names.count < 4096 {
            var query = [Int32(0), Int32(2)] + current
            var next = [Int32](repeating: 0, count: 32)
            var nextSize = next.count * MemoryLayout<Int32>.size
            let status = query.withUnsafeMutableBufferPointer { q in
                sysctl(q.baseAddress, UInt32(q.count), &next, &nextSize, nil, 0)
            }
            guard status == 0 else { break }
            let oid = Array(next[0..<(nextSize / MemoryLayout<Int32>.size)])
            guard oid.count > root.count, Array(oid[0..<root.count]) == root else { break }
            var nameQuery = [Int32(0), Int32(1)] + oid
            var buffer = [CChar](repeating: 0, count: 256)
            var bufferSize = buffer.count
            let named = nameQuery.withUnsafeMutableBufferPointer { q in
                sysctl(q.baseAddress, UInt32(q.count), &buffer, &bufferSize, nil, 0)
            }
            if named == 0 { names.append(String(cString: buffer)) }
            current = oid
        }
        return names
    }

    static let fallbackFeatureNames: [String] = [
        "FEAT_AES", "FEAT_BF16", "FEAT_BTI", "FEAT_CRC32", "FEAT_CSSC", "FEAT_DIT", "FEAT_DotProd",
        "FEAT_DPB", "FEAT_DPB2", "FEAT_ECV", "FEAT_FCMA", "FEAT_FHM", "FEAT_FlagM", "FEAT_FlagM2",
        "FEAT_FP16", "FEAT_FPAC", "FEAT_FRINTTS", "FEAT_I8MM", "FEAT_JSCVT", "FEAT_LRCPC",
        "FEAT_LRCPC2", "FEAT_LSE", "FEAT_LSE2", "FEAT_PAuth", "FEAT_PAuth2", "FEAT_PMULL",
        "FEAT_RDM", "FEAT_SB", "FEAT_SHA1", "FEAT_SHA256", "FEAT_SHA3", "FEAT_SHA512", "FEAT_SME",
        "FEAT_SME2", "FEAT_SPECRES", "FEAT_SSBS", "FEAT_WFxT", "AdvSIMD", "AdvSIMD_HPFPCvt",
    ].map { "hw.optional.arm.\($0)" }

    // MARK: - Memory

    static func memory(parentID: String, systemImage: String) -> Result {
        var result = Result()
        var properties: [HardwareProperty] = []
        let installed = Sysctl.integer("hw.memsize", as: UInt64.self)
        if let installed {
            properties.append(HardwareProperty("Installed", bytes(Int64(installed))))
            result.facts.memoryBytes = installed
        }
        if let usable = Sysctl.integer("hw.memsize_usable", as: UInt64.self) {
            properties.append(HardwareProperty("Usable by the system", bytes(Int64(usable))))
        }
        if let page = Sysctl.integer("hw.pagesize", as: Int64.self) {
            properties.append(HardwareProperty("Page size", bytes(page)))
        }
        if let ecc = Sysctl.integer("hw.optional.ecc", as: Int32.self) {
            properties.append(HardwareProperty("ECC", ecc == 1 ? t("Yes") : t("No")))
        }
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if product != 0 {
            defer { IOObjectRelease(product) }
            if let upgradeable = uint32(product, "upgradeable-memory") {
                properties.append(
                    HardwareProperty(
                        "Upgradeable",
                        upgradeable == 0 ? t("No (unified, on package)") : t("Yes")))
            }
        }
        let title = installed.map { t("%@ unified memory", bytes(Int64($0))) } ?? t("Memory")
        result.nodes = [
            HardwareNode(
                id: "\(parentID)/native/memory", title: title,
                subtitle: t("Shared by CPU, GPU and Neural Engine"),
                systemImage: systemImage, properties: properties)
        ]
        return result
    }

    // MARK: - Graphics (Metal) and Neural Engine

    static func graphics(parentID: String, systemImage: String) -> Result {
        var result = Result()
        var nodes: [HardwareNode] = []
        let agx = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        var coreCount: Int?
        var pluginName: String?
        var driverBundle: String?
        if agx != 0 {
            defer { IOObjectRelease(agx) }
            coreCount = IOKitProperty.number(agx, "gpu-core-count").map(Int.init)
            pluginName = IOKitProperty.string(agx, "MetalPluginName")
            driverBundle = IOKitProperty.string(agx, "IOGLBundleName")
        }
        result.facts.gpuCores = coreCount

        if let device = MTLCreateSystemDefaultDevice() {
            var properties: [HardwareProperty] = []
            if let coreCount { properties.append(HardwareProperty("Cores", "\(coreCount)")) }
            properties.append(HardwareProperty("Architecture", device.architecture.name))
            let (family, metal) = metalSupport(device)
            properties.append(HardwareProperty("Metal support", metal))
            properties.append(HardwareProperty("GPU family", family))
            result.facts.metalSupport = metal
            properties.append(
                HardwareProperty("Unified memory", device.hasUnifiedMemory ? t("Yes") : t("No")))
            properties.append(
                HardwareProperty(
                    "Recommended working set", bytes(Int64(device.recommendedMaxWorkingSetSize))))
            properties.append(
                HardwareProperty("Maximum buffer length", bytes(Int64(device.maxBufferLength))))
            let threads = device.maxThreadsPerThreadgroup
            properties.append(
                HardwareProperty(
                    "Maximum threads per threadgroup",
                    "\(threads.width) x \(threads.height) x \(threads.depth)"))
            properties.append(
                HardwareProperty(
                    "Threadgroup memory", bytes(Int64(device.maxThreadgroupMemoryLength))))
            properties.append(
                HardwareProperty("Ray tracing", device.supportsRaytracing ? t("Yes") : t("No")))
            properties.append(
                HardwareProperty(
                    "Ray tracing from render", device.supportsRaytracingFromRender ? t("Yes") : t("No")))
            properties.append(
                HardwareProperty("32-bit MSAA", device.supports32BitMSAA ? t("Yes") : t("No")))
            properties.append(
                HardwareProperty(
                    "32-bit float filtering", device.supports32BitFloatFiltering ? t("Yes") : t("No")))
            properties.append(
                HardwareProperty(
                    "BC texture compression", device.supportsBCTextureCompression ? t("Yes") : t("No")))
            properties.append(
                HardwareProperty(
                    "Dynamic libraries", device.supportsDynamicLibraries ? t("Yes") : t("No")))
            properties.append(
                HardwareProperty(
                    "Function pointers", device.supportsFunctionPointers ? t("Yes") : t("No")))
            properties.append(
                HardwareProperty("Query texture LOD", device.supportsQueryTextureLOD ? t("Yes") : t("No"))
            )
            properties.append(
                HardwareProperty(
                    "Argument buffers", argumentBuffersTier(device.argumentBuffersSupport)))
            properties.append(
                HardwareProperty(
                    "Read-write textures", readWriteTier(device.readWriteTextureSupport)))
            properties.append(
                HardwareProperty("Sparse tile size", bytes(Int64(device.sparseTileSizeInBytes))))
            properties.append(HardwareProperty("Registry ID", "\(device.registryID)"))
            properties.append(HardwareProperty("Location", location(device)))
            properties.append(HardwareProperty("Low power", device.isLowPower ? t("Yes") : t("No")))
            properties.append(HardwareProperty("Removable", device.isRemovable ? t("Yes") : t("No")))
            properties.append(HardwareProperty("Headless", device.isHeadless ? t("Yes") : t("No")))
            if let pluginName { properties.append(HardwareProperty("Metal plug-in", pluginName)) }
            if let driverBundle { properties.append(HardwareProperty("Driver", driverBundle)) }
            nodes.append(
                HardwareNode(
                    id: "\(parentID)/native/gpu", title: device.name,
                    subtitle: coreCount.map { t("%@-core GPU", "\($0)") } ?? "GPU",
                    systemImage: systemImage,
                    properties: properties))
        }

        // The Neural Engine has no public device API; the device tree names
        // it and the core count follows the chip family.
        var aneProperties: [HardwareProperty] = []
        let chip = Sysctl.string("machdep.cpu.brand_string") ?? ""
        let aneCores = chip.localizedCaseInsensitiveContains("ultra") ? 32 : 16
        aneProperties.append(HardwareProperty("Cores", t("%@ (by chip family)", "\(aneCores)")))
        result.facts.neuralEngineCores = aneCores
        let ane = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/ane")
        if ane != 0 {
            defer { IOObjectRelease(ane) }
            if let type = uint32(ane, "ane-type") {
                aneProperties.append(HardwareProperty("ANE type", "\(type)"))
            }
            if let compatible = text(ane, "compatible") {
                aneProperties.append(HardwareProperty("Compatible", compatible))
            }
            if let role = text(ane, "role") { aneProperties.append(HardwareProperty("Role", role)) }
            if let version = uint32(ane, "iop-version") {
                aneProperties.append(HardwareProperty("IOP version", "\(version)"))
            }
        }
        nodes.append(
            HardwareNode(
                id: "\(parentID)/native/ane", title: t("Neural Engine"),
                subtitle: t("%@-core", "\(aneCores)"), systemImage: "brain",
                properties: aneProperties))
        result.nodes = nodes
        return result
    }

    private static func metalSupport(_ device: MTLDevice) -> (family: String, metal: String) {
        var family = t("Unknown")
        for n in stride(from: 9, through: 1, by: -1) {
            if let candidate = MTLGPUFamily(rawValue: 1000 + n), device.supportsFamily(candidate) {
                family = "Apple \(n)"
                break
            }
        }
        var metal = "Metal"
        if device.supportsFamily(.metal3) { metal = "Metal 3" }
        // MTLGPUFamily.metal4 only exists in the macOS 26 SDK (Xcode 26, Swift 6.2);
        // the #available check alone cannot keep an older SDK compiling.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), device.supportsFamily(.metal4) {
            metal = "Metal 4"
        }
        #endif
        return (family, metal)
    }

    private static func argumentBuffersTier(_ tier: MTLArgumentBuffersTier) -> String {
        switch tier {
        case .tier1: return "Tier 1"
        case .tier2: return "Tier 2"
        @unknown default: return "Tier \(tier.rawValue)"
        }
    }

    private static func readWriteTier(_ tier: MTLReadWriteTextureTier) -> String {
        switch tier {
        case .tierNone: return t("Not supported")
        case .tier1: return "Tier 1"
        case .tier2: return "Tier 2"
        @unknown default: return "Tier \(tier.rawValue)"
        }
    }

    private static func location(_ device: MTLDevice) -> String {
        switch device.location {
        case .builtIn: return t("Built-in")
        case .slot: return t("Slot %@", "\(device.locationNumber)")
        case .external: return t("External %@", "\(device.locationNumber)")
        case .unspecified: return t("Unspecified")
        @unknown default: return t("Unknown")
        }
    }

    // MARK: - Wi-Fi

    static func wifi(parentID: String, systemImage: String) -> Result {
        var result = Result()
        let client = CWWiFiClient.shared()
        guard let interfaces = client.interfaces(), !interfaces.isEmpty else { return result }
        var nodes: [HardwareNode] = []
        for (index, interface) in interfaces.enumerated() {
            var properties: [HardwareProperty] = []
            let name = interface.interfaceName ?? "en?"
            properties.append(HardwareProperty("Interface", name))
            properties.append(
                HardwareProperty("Power", interface.powerOn() ? t("On") : t("Off (setting)")))
            properties.append(
                HardwareProperty("Service active", interface.serviceActive() ? t("Yes") : t("No")))
            properties.append(HardwareProperty("Mode", mode(interface.interfaceMode())))
            let phy = phyMode(interface.activePHYMode())
            properties.append(HardwareProperty("PHY mode", phy))
            if let mac = interface.hardwareAddress() {
                properties.append(HardwareProperty("MAC address", mac))
            }
            if let ssid = interface.ssid() {
                properties.append(HardwareProperty("Network", ssid))
            } else if interface.powerOn() {
                properties.append(
                    HardwareProperty("Network", t("Hidden without Location Services access")))
            }
            if let bssid = interface.bssid() {
                properties.append(HardwareProperty("BSSID", bssid))
            }
            var channelSummary: String?
            if let channel = interface.wlanChannel() {
                let band = self.band(channel.channelBand)
                let width = self.width(channel.channelWidth)
                channelSummary = t("%1$@ channel %2$@", band, "\(channel.channelNumber)")
                properties.append(HardwareProperty("Channel", "\(channel.channelNumber)"))
                properties.append(HardwareProperty("Band", band))
                properties.append(HardwareProperty("Channel width", width))
            }
            let rssi = interface.rssiValue()
            let noise = interface.noiseMeasurement()
            if rssi != 0 {
                properties.append(HardwareProperty("Signal (RSSI)", "\(rssi) dBm"))
                properties.append(HardwareProperty("Noise", "\(noise) dBm"))
                properties.append(HardwareProperty("Signal to noise", "\(rssi - noise) dB"))
            }
            let rate = interface.transmitRate()
            if rate > 0 {
                properties.append(HardwareProperty("Transmit rate", "\(Int(rate)) Mb/s"))
            }
            let power = interface.transmitPower()
            if power > 0 { properties.append(HardwareProperty("Transmit power", "\(power) mW")) }
            properties.append(HardwareProperty("Security", security(interface.security())))
            if let country = interface.countryCode() {
                properties.append(HardwareProperty("Country code", country))
            }
            if let channels = interface.supportedWLANChannels() {
                var byBand: [String: Int] = [:]
                for channel in channels { byBand[band(channel.channelBand), default: 0] += 1 }
                let summary = byBand.keys.sorted().map {
                    t("%1$@ on %2$@", "\(byBand[$0] ?? 0)", $0)
                }
                properties.append(
                    HardwareProperty(
                        "Supported channels",
                        t("%1$@ (%2$@)", "\(channels.count)", summary.joined(separator: ", "))))
            }
            if index == 0 {
                var parts = [phy]
                if let channelSummary { parts.append(channelSummary) }
                if rssi != 0 { parts.append("\(rssi) dBm") }
                result.facts.wifiSummary = parts.joined(separator: ", ")
            }
            nodes.append(
                HardwareNode(
                    id: "\(parentID)/native/wifi/\(index)", title: t("Wi-Fi (%@)", name),
                    subtitle: interface.powerOn() ? phy : t("Off (setting)"),
                    systemImage: systemImage,
                    properties: properties))
        }
        result.nodes = nodes
        return result
    }

    private static func phyMode(_ mode: CWPHYMode) -> String {
        switch mode {
        case .modeNone: return t("None")
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n (Wi-Fi 4)"
        case .mode11ac: return "802.11ac (Wi-Fi 5)"
        case .mode11ax: return "802.11ax (Wi-Fi 6)"
        // CWPHYMode.mode11be only exists in the macOS 26 SDK; on older SDKs the
        // @unknown default below still renders Wi-Fi 7 as "802.11 (mode 7)".
        #if compiler(>=6.2)
        case .mode11be: return "802.11be (Wi-Fi 7)"
        #endif
        @unknown default: return "802.11 (mode \(mode.rawValue))"
        }
    }

    private static func mode(_ mode: CWInterfaceMode) -> String {
        switch mode {
        case .none: return t("Not associated")
        case .station: return t("Station")
        case .IBSS: return t("Ad hoc (IBSS)")
        case .hostAP: return t("Access point")
        @unknown default: return t("Unknown")
        }
    }

    private static func band(_ band: CWChannelBand) -> String {
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        case .bandUnknown: return t("Unknown band")
        @unknown default: return t("Unknown band")
        }
    }

    private static func width(_ width: CWChannelWidth) -> String {
        switch width {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        case .widthUnknown: return t("Unknown")
        @unknown default: return t("Unknown")
        }
    }

    private static func security(_ security: CWSecurity) -> String {
        switch security {
        case .none: return t("None")
        case .WEP: return "WEP"
        case .wpaPersonal: return t("WPA Personal")
        case .wpaPersonalMixed: return t("WPA/WPA2 Personal")
        case .wpa2Personal: return t("WPA2 Personal")
        case .personal: return t("Personal")
        case .dynamicWEP: return t("Dynamic WEP")
        case .wpaEnterprise: return t("WPA Enterprise")
        case .wpaEnterpriseMixed: return t("WPA/WPA2 Enterprise")
        case .wpa2Enterprise: return t("WPA2 Enterprise")
        case .enterprise: return t("Enterprise")
        case .wpa3Personal: return t("WPA3 Personal")
        case .wpa3Enterprise: return t("WPA3 Enterprise")
        case .wpa3Transition: return t("WPA3 Transition")
        case .OWE: return "OWE"
        case .oweTransition: return t("OWE Transition")
        case .unknown: return t("Unknown")
        @unknown default: return t("Unknown")
        }
    }

    // MARK: - Battery gauge

    static func battery(parentID: String, systemImage: String) -> Result {
        var result = Result()
        guard let sample = BatteryReader().read(), sample.isPresent else { return result }
        var properties: [HardwareProperty] = []
        let condition = sample.isHealthyCondition ? t("Normal") : t("Service recommended")
        properties.append(HardwareProperty("Condition", condition))
        if let cycles = sample.cycleCount {
            properties.append(HardwareProperty("Cycle count", "\(cycles)"))
        }
        if let health = sample.healthPercent {
            properties.append(
                HardwareProperty(
                    "Maximum capacity", t("%@%% of design", "\(Int(health.rounded()))")))
        }
        if let design = sample.designCapacitymAh {
            properties.append(HardwareProperty("Design capacity", "\(design) mAh"))
        }
        if let full = sample.maxCapacitymAh {
            properties.append(HardwareProperty("Full charge capacity", "\(full) mAh"))
        }
        if let current = sample.currentCapacitymAh {
            properties.append(HardwareProperty("Current capacity", "\(current) mAh"))
        }
        properties.append(
            HardwareProperty("Charge", "\(Int(sample.chargePercent.rounded()))%"))
        properties.append(HardwareProperty("Charging", sample.isCharging ? t("Yes") : t("No")))
        properties.append(
            HardwareProperty(
                "Power source", sample.isOnAC ? t("Power adapter") : t("Battery")))
        properties.append(
            HardwareProperty(
                "Voltage", String(format: "%.3f V", Double(sample.voltageMilliVolts) / 1000)))
        properties.append(HardwareProperty("Amperage", "\(sample.amperageMilliAmps) mA"))
        if let temperature = sample.temperatureCelsius {
            properties.append(
                HardwareProperty("Temperature", String(format: "%.1f\u{00B0}C", temperature)))
        }
        if let serial = sample.serialNumber {
            properties.append(HardwareProperty("Serial number", serial))
        }
        if let maker = sample.manufacturer {
            properties.append(HardwareProperty("Manufacturer", maker))
        }
        if let made = sample.manufactureDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            properties.append(HardwareProperty("Manufacture date", formatter.string(from: made)))
        }
        if let gauge = sample.gasGaugeChip {
            properties.append(HardwareProperty("Gas gauge", gauge))
        }
        if let cells = sample.cellVoltagesMilliVolts, !cells.isEmpty {
            properties.append(
                HardwareProperty(
                    "Cell voltages",
                    cells.map { String(format: "%.3f V", Double($0) / 1000) }.joined(
                        separator: ", ")))
        }
        if let name = sample.adapterName {
            properties.append(HardwareProperty("Name", name, group: "Power adapter"))
        }
        if let watts = sample.adapterWatts {
            properties.append(HardwareProperty("Wattage", "\(watts) W", group: "Power adapter"))
        }
        if let volts = sample.adapterVoltageMilliVolts {
            properties.append(
                HardwareProperty(
                    "Voltage", String(format: "%.2f V", Double(volts) / 1000),
                    group: "Power adapter"))
        }
        if let amps = sample.adapterAmperageMilliAmps {
            properties.append(
                HardwareProperty("Amperage", "\(amps) mA", group: "Power adapter"))
        }
        if let charging = sample.chargingCurrentMilliAmps {
            properties.append(
                HardwareProperty("Charging current", "\(charging) mA", group: "Power adapter"))
        }
        result.facts.battery = HardwareFacts.Battery(
            cycleCount: sample.cycleCount, healthPercent: sample.healthPercent,
            designCapacitymAh: sample.designCapacitymAh, maxCapacitymAh: sample.maxCapacitymAh,
            condition: condition, chargePercent: sample.chargePercent)
        result.nodes = [
            HardwareNode(
                id: "\(parentID)/native/battery", title: t("Battery"),
                subtitle: sample.healthPercent.map {
                    t("%1$@%% capacity, %2$@", "\(Int($0.rounded()))", condition)
                }
                    ?? condition,
                systemImage: systemImage, properties: properties)
        ]
        return result
    }

    // MARK: - Sensors

    /// Shared shaping for the sensor facts: display-ordered groups with
    /// readings hottest first, plus the fan speeds.
    static func sensorFacts(
        _ inventory: (sensors: [SMCReader.SensorReading], fans: [FanSample])
    ) -> (groups: [HardwareFacts.SensorGroup], fans: [Int]) {
        let grouped = Dictionary(grouping: inventory.sensors, by: \.group)
        let groups = SMCReader.sensorGroupOrder.compactMap { group -> HardwareFacts.SensorGroup? in
            guard let readings = grouped[group], !readings.isEmpty else { return nil }
            return HardwareFacts.SensorGroup(
                name: group, readings: readings.map(\.celsius).sorted(by: >))
        }
        return (groups, inventory.fans.map(\.rpm))
    }

    /// Every readable temperature sensor the SMC exposes, grouped by domain,
    /// plus the fans. Values are one refresh-time snapshot, matching the rest
    /// of the explorer; the live thermal story lives on the Energy tab. This
    /// is the long tail's home: airflow, skin, wireless, voltage rails, and
    /// every individual die sensor behind the headline figures.
    static func sensors(parentID: String, systemImage: String) -> Result {
        var result = Result()
        let inventory = SMCReader().sensorInventory()
        let grouped = Dictionary(grouping: inventory.sensors, by: \.group)
        // Facts for the overview's heat strips: raw readings per group,
        // hottest first, in display order. Set even when empty so the
        // overview card can report "nothing readable" instead of loading
        // forever.
        let facts = sensorFacts(inventory)
        result.facts.sensorGroups = facts.groups
        result.facts.fanRPMs = facts.fans
        guard !inventory.sensors.isEmpty || !inventory.fans.isEmpty else { return result }

        for group in SMCReader.sensorGroupOrder {
            guard let readings = grouped[group], !readings.isEmpty else { continue }
            let hottest = readings.map(\.celsius).max() ?? 0
            let count = readings.count == 1 ? t("1 sensor") : t("%@ sensors", "\(readings.count)")
            let slug = group.lowercased().replacingOccurrences(of: " ", with: "-")
            result.nodes.append(
                HardwareNode(
                    id: "\(parentID)/\(slug)",
                    title: t(group),
                    subtitle: t(
                        "%1$@ \u{00B7} hottest %2$@\u{00B0}C", count,
                        "\(Int(hottest.rounded()))"),
                    systemImage: "thermometer.medium",
                    properties: readings.sorted { $0.key < $1.key }.map {
                        HardwareProperty($0.key, String(format: "%.1f\u{00B0}C", $0.celsius))
                    }))
        }

        if !inventory.fans.isEmpty {
            let spinning = inventory.fans.filter { $0.rpm > 0 }.count
            result.nodes.append(
                HardwareNode(
                    id: "\(parentID)/fans",
                    title: t("Fans"),
                    subtitle: spinning == 0
                        ? t("%@ \u{00B7} all off", "\(inventory.fans.count)")
                        : t("%1$@ of %2$@ spinning", "\(spinning)", "\(inventory.fans.count)"),
                    systemImage: "fanblades",
                    properties: inventory.fans.enumerated().map { index, fan in
                        var value = fan.rpm == 0 ? t("Off") : t("%@ rpm", "\(fan.rpm)")
                        if let maxRPM = fan.maxRPM {
                            value += " " + t("(maximum %@ rpm)", "\(maxRPM)")
                        }
                        return HardwareProperty(t("Fan %@", "\(index + 1)"), value)
                    }))
        }
        return result
    }

    // MARK: - Software

    static func software(parentID: String, systemImage: String) -> Result {
        var result = Result()
        var properties: [HardwareProperty] = []
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        let product =
            Sysctl.string("kern.osproductversion")
            ?? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let build = Sysctl.string("kern.osversion") ?? ""
        let osVersion = build.isEmpty ? "macOS \(product)" : "macOS \(product) (\(build))"
        properties.append(HardwareProperty("System version", osVersion))
        result.facts.osVersion = osVersion
        if let release = Sysctl.string("kern.osrelease") {
            properties.append(HardwareProperty("Darwin release", release))
        }
        if let kernel = Sysctl.string("kern.version") {
            let firstLine = kernel.split(separator: "\n").first.map(String.init) ?? kernel
            properties.append(HardwareProperty("Kernel", firstLine))
            result.facts.kernelVersion = firstLine
        }
        if let type = Sysctl.string("kern.ostype") {
            properties.append(HardwareProperty("Kernel type", type))
        }
        if let host = Sysctl.string("kern.hostname") {
            properties.append(HardwareProperty("Host name", host))
        }
        var boot = timeval()
        if Sysctl.raw("kern.boottime", into: &boot), boot.tv_sec > 0 {
            let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            properties.append(HardwareProperty("Last boot", formatter.string(from: bootDate)))
            properties.append(HardwareProperty("Uptime", uptime(since: bootDate)))
            result.facts.bootTime = bootDate
        }
        if let args = Sysctl.string("kern.bootargs") {
            properties.append(
                HardwareProperty("Boot arguments", args.isEmpty ? t("None") : args))
        }
        if let safe = Sysctl.integer("kern.safeboot", as: Int32.self) {
            properties.append(HardwareProperty("Safe mode", safe == 1 ? t("Yes") : t("No")))
        }
        if let secure = Sysctl.integer("kern.secure_kernel", as: Int32.self) {
            properties.append(HardwareProperty("Secure kernel", secure == 1 ? t("Yes") : t("No")))
        }
        if let maxProc = Sysctl.integer("kern.maxproc", as: Int32.self) {
            properties.append(HardwareProperty("Maximum processes", "\(maxProc)"))
        }
        if let maxFiles = Sysctl.integer("kern.maxfiles", as: Int32.self) {
            properties.append(HardwareProperty("Maximum open files", "\(maxFiles)"))
        }
        let rosetta = FileManager.default.fileExists(
            atPath: "/Library/Apple/usr/share/rosetta/rosetta")
        properties.append(
            HardwareProperty("Rosetta 2", rosetta ? t("Installed") : t("Not installed")))
        properties.append(
            HardwareProperty("Active processors", "\(info.activeProcessorCount)"))
        result.nodes = [
            HardwareNode(
                id: "\(parentID)/native/os", title: osVersion,
                subtitle: Sysctl.string("kern.osrelease").map { "Darwin \($0)" },
                systemImage: systemImage, properties: properties)
        ]
        return result
    }

    // MARK: - Helpers

    static func uptime(since boot: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(boot))
        guard seconds > 0 else { return t("0 minutes") }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        var parts: [String] = []
        // One key per grammatical number rather than an "s" suffix argument,
        // so a translation is never asked to splice a plural ending into an
        // otherwise fixed sentence.
        if days > 0 { parts.append(days == 1 ? t("1 day") : t("%@ days", "\(days)")) }
        if hours > 0 { parts.append(hours == 1 ? t("1 hour") : t("%@ hours", "\(hours)")) }
        if minutes > 0 || parts.isEmpty {
            parts.append(minutes == 1 ? t("1 minute") : t("%@ minutes", "\(minutes)"))
        }
        return parts.joined(separator: ", ")
    }

    static func bytes(_ value: Int64) -> String {
        guard value >= 0 else { return "\(value)" }
        let unsigned = UInt64(value)
        if unsigned < 1024 * 1024 { return "\(unsigned / 1024) KB" }
        return ByteFormat.string(unsigned, fractionDigits: unsigned % (1024 * 1024) == 0 ? 0 : 1)
    }

    /// A string property, whether stored as a CFString or as NUL-padded
    /// bytes the way the device tree keeps most of its strings.
    static func text(_ entry: io_registry_entry_t, _ key: String) -> String? {
        if let string = IOKitProperty.string(entry, key) { return string }
        guard let data = IOKitProperty.data(entry, key) else { return nil }
        let trimmed = data.prefix { $0 != 0 }
        guard !trimmed.isEmpty, let string = String(data: trimmed, encoding: .utf8) else {
            return nil
        }
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    static func uint32(_ entry: io_registry_entry_t, _ key: String) -> UInt32? {
        if let number = IOKitProperty.number(entry, key) {
            return UInt32(truncatingIfNeeded: number)
        }
        guard let data = IOKitProperty.data(entry, key), data.count >= 4 else { return nil }
        return data.prefix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
