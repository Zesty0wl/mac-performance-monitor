import Foundation
import IOKit

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
    private var didReadStatics = false

    func read() -> GPUSample? {
        if !didReadStatics {
            cachedName = Self.chipName()
            didReadStatics = true
        }

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
                sample.recoveryCount = stats["recoveryCount"] as? Int
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
