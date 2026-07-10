import CMacPerfMonitor
import Darwin
import Foundation

/// Raw system-wide virtual-memory statistics for one tick, in bytes (already
/// multiplied out by the page size), plus cumulative event counters.
public struct VMStatistics: Sendable {
    public var pageSize: UInt64

    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var speculative: UInt64
    public var compressed: UInt64
    public var purgeable: UInt64
    public var external: UInt64  // file-backed pages
    public var `internal`: UInt64  // anonymous pages

    public var pageIns: UInt64
    public var pageOuts: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64
    public var swapIns: UInt64
    public var swapOuts: UInt64
}

/// Reads system-wide memory, swap and pressure figures from Mach and sysctl.
public struct SystemMemoryReader: Sendable {
    public init() {}

    private static let cachedPageSize: UInt64 = {
        var size: vm_size_t = 0
        if host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 {
            return UInt64(size)
        }
        return UInt64(getpagesize())
    }()

    private static let cachedTotalRAM = Sysctl.integer("hw.memsize", as: UInt64.self) ?? 0

    /// Kernel page size in bytes (16384 on Apple Silicon). Never hardcoded.
    public var pageSize: UInt64 {
        Self.cachedPageSize
    }

    /// Total physical RAM in bytes.
    public var totalRAM: UInt64 {
        Self.cachedTotalRAM
    }

    /// Read `vm_statistics64` and convert page counts to bytes.
    public func sampleVM() -> VMStatistics? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, raw, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let ps = pageSize
        func bytes(_ pages: some FixedWidthInteger) -> UInt64 { UInt64(pages) * ps }

        return VMStatistics(
            pageSize: ps,
            free: bytes(stats.free_count),
            active: bytes(stats.active_count),
            inactive: bytes(stats.inactive_count),
            wired: bytes(stats.wire_count),
            speculative: bytes(stats.speculative_count),
            compressed: bytes(stats.compressor_page_count),
            purgeable: bytes(stats.purgeable_count),
            external: bytes(stats.external_page_count),
            internal: bytes(stats.internal_page_count),
            pageIns: UInt64(stats.pageins),
            pageOuts: UInt64(stats.pageouts),
            compressions: UInt64(stats.compressions),
            decompressions: UInt64(stats.decompressions),
            swapIns: UInt64(stats.swapins),
            swapOuts: UInt64(stats.swapouts)
        )
    }

    /// Swap usage in bytes.
    public func sampleSwap() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        guard Sysctl.raw("vm.swapusage", into: &usage) else { return nil }
        return (UInt64(usage.xsu_total), UInt64(usage.xsu_used))
    }

    /// Current discrete memory pressure level.
    public func pressureLevel() -> PressureLevel {
        if let raw = Sysctl.integer("kern.memorystatus_vm_pressure_level", as: Int32.self) {
            return PressureLevel(rawLevel: Int(raw))
        }
        return .normal
    }
}
