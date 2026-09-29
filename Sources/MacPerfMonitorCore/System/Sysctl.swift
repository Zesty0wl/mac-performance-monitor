import Darwin
import Foundation

/// Minimal, safe wrappers around `sysctlbyname` for the handful of values
/// MacPerfMonitor reads.
enum Sysctl {
    /// Read a fixed-width integer value (e.g. `hw.memsize`).
    static func integer<T: FixedWidthInteger>(_ name: String, as type: T.Type = T.self) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        let result = sysctlbyname(name, &value, &size, nil, 0)
        guard result == 0 else { return nil }
        return value
    }

    /// Read an arbitrary POD struct value (e.g. `vm.swapusage` -> `xsw_usage`).
    static func raw<T>(_ name: String, into value: inout T) -> Bool {
        var size = MemoryLayout<T>.size
        let result = withUnsafeMutablePointer(to: &value) { ptr -> Int32 in
            ptr.withMemoryRebound(to: CChar.self, capacity: size) { raw in
                sysctlbyname(name, raw, &size, nil, 0)
            }
        }
        return result == 0
    }

    /// Read a string value (e.g. `hw.machine`).
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

public enum SystemBootTime {
    public static func read() -> Date? {
        var boot = timeval()
        guard Sysctl.raw("kern.boottime", into: &boot), boot.tv_sec > 0,
            (0..<1_000_000).contains(boot.tv_usec)
        else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec)
                / 1_000_000)
    }
}
