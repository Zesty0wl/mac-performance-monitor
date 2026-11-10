import CMacPerfMonitor
import Darwin
import Foundation

/// A file mapped into a process's memory: its executable, a library or
/// framework it loaded, a font, a database, a cache.
///
/// Codable so the root helper can return a list as JSON, like
/// `OpenFileDescriptor`.
public struct MappedFile: Codable, Sendable, Identifiable, Equatable {
    public var path: String
    /// Address space the file's mappings cover, in bytes. This is how much is
    /// mapped, not how much of it is in memory.
    public var mappedBytes: UInt64

    public var id: String { path }

    public var name: String { (path as NSString).lastPathComponent }

    /// Whether the file is code the process loaded, by where it lives and what
    /// it is called. A best guess for grouping the list, nothing more.
    public var isLibrary: Bool {
        path.hasSuffix(".dylib") || path.hasSuffix(".so") || path.hasSuffix(".bundle")
            || path.contains(".framework/") || path.contains("/dyld_shared_cache")
    }

    public init(path: String, mappedBytes: UInt64) {
        self.path = path
        self.mappedBytes = mappedBytes
    }
}

/// Lists the files mapped into a process, via libproc. Works as the user for
/// the user's own processes and as root (in the helper) for the rest; no task
/// port is needed.
public struct MappedFileReader: Sendable {
    public init() {}

    /// Hard stop for the walk, far above any real process, so a strange
    /// address space cannot spin forever.
    static let maximumRegions = 200_000

    /// Every distinct file mapped into `pid`, in address order of first
    /// appearance, or nil when the process is gone or not readable.
    ///
    /// Apple's own frameworks do not appear one by one: they live in the dyld
    /// shared cache, which shows up as the cache files themselves.
    ///
    /// One syscall per memory region (a few thousand for a large app), so this
    /// is for inspecting on demand, never the sampling path.
    public func mappedFiles(_ pid: pid_t) -> [MappedFile]? {
        var order: [String] = []
        var sizes: [String: UInt64] = [:]
        var address: UInt64 = 0
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var info = proc_regionwithpathinfo()
        var readAny = false

        for _ in 0..<Self.maximumRegions {
            let got = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, $0, size)
            }
            // Past the last region, or not permitted on the first call.
            guard got == size else { break }
            readAny = true
            let regionSize = info.prp_prinfo.pri_size
            let path = withUnsafeBytes(of: info.prp_vip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty {
                if sizes[path] == nil { order.append(path) }
                sizes[path, default: 0] &+= regionSize
            }
            let next = info.prp_prinfo.pri_address &+ regionSize
            guard next > address else { break }
            address = next
        }
        guard readAny else { return nil }
        return order.map { MappedFile(path: $0, mappedBytes: sizes[$0] ?? 0) }
    }
}
