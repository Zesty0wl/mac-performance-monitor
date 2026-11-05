import Foundation
import IOKit
import Metal

/// Reads GPU utilization from the `IOAccelerator` registry — one cheap property
/// fetch, no subprocess and no per-process enumeration, so it is safe to call at
/// the menubar's 1 Hz cadence. Apple silicon publishes "Device Utilization %"
/// (plus render/tiler and in-use memory) in the accelerator's
/// `PerformanceStatistics`, exactly as `IOAccelerators`/Stats read it. Only run
/// when something actually shows GPU (the menubar item gates it), so a Mac with
/// the GPU item off pays nothing.
final class GPUReader {
    private var cachedName: String?
    private var cachedCoreCount: Int?
    private var cachedClusters: [Int]?
    private var didReadStatics = false
    /// The GPU's clock table, read once (it is fixed for the chip).
    private(set) var frequencyTable: GPUFrequencyTable?
    private var recommendedWorkingSet: UInt64?

    func read() -> GPUSample? {
        if !didReadStatics {
            cachedName = Self.chipName()
            frequencyTable = Self.readFrequencyTable()
            // One Metal device for one property, once. The app already renders
            // through Metal, so this adds no new framework or GPU context cost
            // worth measuring.
            recommendedWorkingSet = MTLCreateSystemDefaultDevice().map {
                $0.recommendedMaxWorkingSetSize
            }
            didReadStatics = true
        }
        let memoryLimit = GPUMemoryLimit.resolve(
            wiredLimitMB: Self.integerSysctl("iogpu.wired_limit_mb"),
            recommendedBytes: recommendedWorkingSet,
            physicalMemory: ProcessInfo.processInfo.physicalMemory)

        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: GPUSample?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
                let dict = properties?.takeRetainedValue() as? [String: Any],
                let stats = dict["PerformanceStatistics"] as? [String: Any],
                let util = (stats["Device Utilization %"] as? Int)
                    ?? (stats["GPU Activity(%)"] as? Int)
            {
                if cachedCoreCount == nil {
                    cachedCoreCount = Self.coreCount(of: service)
                    cachedClusters = Self.clusters(
                        from: dict["GPUConfigurationVariable"] as? [String: Any],
                        coreCount: cachedCoreCount)
                }
                var sample = GPUSample(
                    utilization: Double(util),
                    renderUtilization: (stats["Renderer Utilization %"] as? Int).map(Double.init),
                    tilerUtilization: (stats["Tiler Utilization %"] as? Int).map(Double.init),
                    inUseMemoryBytes: (stats["In use system memory"] as? Int).flatMap {
                        $0 >= 0 ? UInt64($0) : nil
                    },
                    name: cachedName)
                sample.allocatedMemoryBytes = (stats["Alloc system memory"] as? Int).flatMap {
                    $0 >= 0 ? UInt64($0) : nil
                }
                sample.coreCount = cachedCoreCount
                sample.coreClusters = cachedClusters
                sample.recoveryCount = stats["recoveryCount"] as? Int
                sample.maximumClockMHz = frequencyTable?.maximumMHz
                sample.memoryLimit = memoryLimit
                // More than one accelerator is rare on the Macs we run on; keep the
                // busiest so a discrete GPU under load wins over an idle integrated one.
                if best == nil || sample.utilization > best!.utilization { best = sample }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }

    /// The GPU core count (e.g. 16) from `gpu-core-count`, which sits on a parent of
    /// the accelerator in the IORegistry — search up the tree for it.
    private static func coreCount(of service: io_object_t) -> Int? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard
            let value = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "gpu-core-count" as CFString, kCFAllocatorDefault, options
            )
        else { return nil }
        return value as? Int
    }

    /// The SoC / chip brand string ("Apple M2 Pro"), which on Apple silicon is the
    /// GPU's friendly name too. A cheap sysctl — no Metal device creation.
    /// Enabled cores per GPU cluster, from the binning mask in
    /// `GPUConfigurationVariable.core_mask_list` (one bit per core slot, one
    /// mask per cluster). Only trusted when the bits add up to the published
    /// core count.
    static func clusters(from configuration: [String: Any]?, coreCount: Int?) -> [Int]? {
        guard let masks = configuration?["core_mask_list"] as? [Int], !masks.isEmpty,
            masks.count <= 16, masks.allSatisfy({ $0 > 0 })
        else { return nil }
        let counts = masks.map { $0.nonzeroBitCount }
        guard let coreCount, counts.reduce(0, +) == coreCount else { return nil }
        return counts
    }

    /// The power manager's GPU frequency table (`voltage-states9` on the
    /// `pmgr` node). nil on chips that do not publish it.
    static func readFrequencyTable() -> GPUFrequencyTable? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard
            let value = IORegistryEntryCreateCFProperty(
                service, "voltage-states9" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
            let data = value as? Data
        else { return nil }
        return GPUFrequencyTable(voltageStates: data)
    }

    private static func integerSysctl(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0, size == 8 { return Int(value) }
        var small: Int32 = 0
        size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &small, &size, nil, 0) == 0, size == 4 else { return nil }
        return Int(small)
    }

    private static func chipName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0
        else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
