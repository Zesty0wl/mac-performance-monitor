import Darwin
import Foundation

/// The command line of a process, from `sysctl KERN_PROCARGS2`. Readable for
/// the user's own processes without privilege; other users' processes (and
/// some system daemons) return nothing. Used to tell what a bare `python` is
/// doing (the module and model it runs), so it is read only for processes
/// that turn out to be using the GPU, and cached per identity by the caller.
public enum ProcessArguments {
    /// `argv` for `pid`, or nil when unreadable.
    public static func read(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return parse(buffer[0..<size])
    }

    /// KERN_PROCARGS2 layout: a 32-bit argc, the executable path, NUL padding,
    /// then argc NUL-terminated arguments (the environment follows; ignored).
    static func parse(_ bytes: ArraySlice<UInt8>) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let base = bytes.startIndex
        let argc = Int(
            UInt32(bytes[base]) | UInt32(bytes[base + 1]) << 8 | UInt32(bytes[base + 2]) << 16
                | UInt32(bytes[base + 3]) << 24)
        guard argc > 0, argc < 10_000 else { return nil }
        var index = base + 4
        let end = bytes.endIndex
        // Skip the executable path and the padding after it.
        while index < end, bytes[index] != 0 { index += 1 }
        while index < end, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        arguments.reserveCapacity(argc)
        while arguments.count < argc, index < end {
            var stop = index
            while stop < end, bytes[stop] != 0 { stop += 1 }
            arguments.append(String(decoding: bytes[index..<stop], as: UTF8.self))
            index = stop + 1
        }
        return arguments.isEmpty ? nil : arguments
    }
}
