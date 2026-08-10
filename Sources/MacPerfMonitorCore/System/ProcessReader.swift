import CMacPerfMonitor
import Darwin
import Foundation

/// File-descriptor breakdown for a process.
public struct FDBreakdown: Codable, Sendable {
    public var total: Int32 = 0
    public var vnode: Int32 = 0
    public var socket: Int32 = 0
    public var pipe: Int32 = 0
    public var other: Int32 = 0

    public init(
        total: Int32 = 0, vnode: Int32 = 0, socket: Int32 = 0, pipe: Int32 = 0, other: Int32 = 0
    ) {
        self.total = total
        self.vnode = vnode
        self.socket = socket
        self.pipe = pipe
        self.other = other
    }
}

/// Reusable scratch storage for `ProcessReader.fdCount`, so counting
/// descriptors across the ~500-process per-tick scan does not allocate a
/// buffer per process. Grows to the largest FD table seen and is retained.
/// Not thread-safe: confine each instance to one queue, as the Sampler is.
public final class FDCountScratch {
    fileprivate var buffer: [proc_fdinfo] = []
    public init() {}
}

/// rusage-derived figures for a process.
public struct RUsage: Codable, Sendable {
    public var physFootprint: UInt64
    public var lifetimeMaxFootprint: UInt64
    public var diskBytesRead: UInt64
    public var diskBytesWritten: UInt64
    /// Kernel per-process energy accounting (nanojoules, cumulative). Best-effort
    /// — often 0 on hardware or for processes the energy ledger does not track,
    /// so the sampler falls back to a CPU/wakeups estimate when this is zero.
    public var energyNanojoules: UInt64
    /// Cumulative idle + interrupt wakeups, the classic battery-drain signal.
    public var idleWakeups: UInt64

    public init(
        physFootprint: UInt64, lifetimeMaxFootprint: UInt64, diskBytesRead: UInt64,
        diskBytesWritten: UInt64, energyNanojoules: UInt64 = 0, idleWakeups: UInt64 = 0
    ) {
        self.physFootprint = physFootprint
        self.lifetimeMaxFootprint = lifetimeMaxFootprint
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.energyNanojoules = energyNanojoules
        self.idleWakeups = idleWakeups
    }
}

/// One open file descriptor of a process, with its kind and a resolved detail:
/// the file path for a vnode, a formatted endpoint description for a socket, or
/// a short type word otherwise. Surfaced in the process detail inspector so a
/// rising descriptor count can be inspected entry by entry.
///
/// Codable so the root helper can ship a process's descriptor list back to the
/// app over XPC as JSON, the same way `RawProcessRead` is transported.
public struct OpenFileDescriptor: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        case file
        case socket
        case pipe
        case kqueue
        case other

        /// Map the C shim's small stable type code to a kind.
        init(code: Int32) {
            switch code {
            case 1: self = .file
            case 2: self = .socket
            case 3: self = .pipe
            case 4: self = .kqueue
            default: self = .other
            }
        }
    }

    public let fd: Int32
    public let kind: Kind
    public let detail: String

    public var id: Int32 { fd }

    public init(fd: Int32, kind: Kind, detail: String) {
        self.fd = fd
        self.kind = kind
        self.detail = detail
    }
}

/// Basic per-process task info pulled from `PROC_PIDTASKALLINFO`.
public struct TaskAllInfo: Codable, Sendable {
    public var name: String
    public var ppid: Int32
    public var uid: uid_t
    public var startTime: Date
    public var residentSize: UInt64
    public var virtualSize: UInt64
    public var cpuTimeUser: UInt64  // nanoseconds
    public var cpuTimeSystem: UInt64  // nanoseconds
    public var threadCount: Int32

    public init(
        name: String, ppid: Int32, uid: uid_t, startTime: Date, residentSize: UInt64,
        virtualSize: UInt64, cpuTimeUser: UInt64, cpuTimeSystem: UInt64, threadCount: Int32
    ) {
        self.name = name
        self.ppid = ppid
        self.uid = uid
        self.startTime = startTime
        self.residentSize = residentSize
        self.virtualSize = virtualSize
        self.cpuTimeUser = cpuTimeUser
        self.cpuTimeSystem = cpuTimeSystem
        self.threadCount = threadCount
    }
}

/// Unprivileged per-process reads via libproc. Each accessor returns nil when
/// the read is not permitted or the process has gone, so callers can record
/// coverage honestly.
public struct ProcessReader: Sendable {
    public init() {}

    /// Whether the host itself is Apple Silicon, used to label native processes.
    public static let hostIsAppleSilicon: Bool = {
        // `hw.optional.arm64` is 1 on Apple Silicon.
        (Sysctl.integer("hw.optional.arm64", as: Int32.self) ?? 0) == 1
    }()

    /// The host's Mach timebase. `pti_total_user`/`pti_total_system` are
    /// reported in Mach absolute time units, NOT nanoseconds: on Apple Silicon
    /// the timebase is 125/3 (one unit ≈ 41.7 ns), so using them raw
    /// under-reports CPU by that factor. (Intel's timebase is 1/1, which is how
    /// this class of bug classically slips through.)
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Convert Mach absolute time units to nanoseconds. Split form so the
    /// multiply cannot overflow even for a process with years of CPU time.
    static func machToNanos(_ mach: UInt64) -> UInt64 {
        machToNanos(mach, numer: Self.timebase.numer, denom: Self.timebase.denom)
    }

    /// Testable core of the conversion with an explicit timebase.
    static func machToNanos(_ mach: UInt64, numer: UInt64, denom: UInt64) -> UInt64 {
        guard numer != denom else { return mach }
        return (mach / denom) &* numer &+ (mach % denom) &* numer / denom
    }

    /// Build the launch `Date` from the kernel's split seconds + microseconds.
    ///
    /// `proc_bsdinfo` records the start time as `pbi_start_tvsec` +
    /// `pbi_start_tvusec` (populated from `microuptime`), so the microsecond
    /// half must be carried into the `Date`. `ProcessIdentity` keys a reused
    /// PID apart by its start time, and the trace export encodes
    /// `startTime.timeIntervalSince1970.bitPattern`; both can only keep two
    /// same-second PID reuses distinct when the fractional part survives.
    static func startDate(seconds: UInt64, microseconds: UInt64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000)
    }

    /// Enumerate all process IDs visible to the caller.
    public func listPIDs() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // Over-allocate generously; process count is volatile between the two
        // calls and the return-value semantics are version-dependent.
        let capacity = Int(needed) + 512
        var pids = [pid_t](repeating: 0, count: capacity)
        let ret = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard ret > 0 else { return [] }
        let n = min(Int(ret), capacity)
        return pids[0..<n].filter { $0 > 0 }
    }

    /// Basic task info. Generally readable for other processes as the user.
    public func taskAllInfo(_ pid: pid_t) -> TaskAllInfo? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let ret = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        guard ret == size else { return nil }

        let name = withUnsafePointer(to: info.pbsd.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
        return TaskAllInfo(
            name: name,
            ppid: Int32(info.pbsd.pbi_ppid),
            uid: info.pbsd.pbi_uid,
            startTime: Self.startDate(
                seconds: info.pbsd.pbi_start_tvsec,
                microseconds: info.pbsd.pbi_start_tvusec),
            residentSize: info.ptinfo.pti_resident_size,
            virtualSize: info.ptinfo.pti_virtual_size,
            cpuTimeUser: Self.machToNanos(info.ptinfo.pti_total_user),
            cpuTimeSystem: Self.machToNanos(info.ptinfo.pti_total_system),
            threadCount: info.ptinfo.pti_threadnum
        )
    }

    /// Headline footprint via rusage. May fail for processes the user does not
    /// own, or for SIP-protected system processes.
    public func rusage(_ pid: pid_t) -> RUsage? {
        var fp: UInt64 = 0
        var lifetimeMax: UInt64 = 0
        var diskRead: UInt64 = 0
        var diskWritten: UInt64 = 0
        var energy: UInt64 = 0
        var wakeups: UInt64 = 0
        let rc = cmacperfmonitor_rusage(
            pid, &fp, &lifetimeMax, &diskRead, &diskWritten, &energy, &wakeups)
        guard rc == 0 else { return nil }
        return RUsage(
            physFootprint: fp,
            lifetimeMaxFootprint: lifetimeMax,
            diskBytesRead: diskRead,
            diskBytesWritten: diskWritten,
            energyNanojoules: energy,
            idleWakeups: wakeups
        )
    }

    /// Executable path.
    public func path(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not importable into Swift
        // ("structure not supported"); MAXPATHLEN is a stable 1024 on macOS.
        let maxSize = 4 * 1024
        var buffer = [CChar](repeating: 0, count: maxSize)
        let ret = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard ret > 0 else { return nil }
        return String(cString: buffer)
    }

    /// File-descriptor count and type breakdown.
    public func fdBreakdown(_ pid: pid_t) -> FDBreakdown? {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if bufferSize == 0 { return FDBreakdown() }
        guard bufferSize > 0 else { return nil }

        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let ret = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard ret > 0 else { return nil }

        let n = Int(ret) / MemoryLayout<proc_fdinfo>.stride
        var breakdown = FDBreakdown()
        for i in 0..<min(n, fds.count) {
            switch Int32(fds[i].proc_fdtype) {
            case PROX_FDTYPE_VNODE: breakdown.vnode += 1
            case PROX_FDTYPE_SOCKET: breakdown.socket += 1
            case PROX_FDTYPE_PIPE: breakdown.pipe += 1
            default: breakdown.other += 1
            }
            breakdown.total += 1
        }
        return breakdown
    }

    /// Just the open file-descriptor *count* — no per-descriptor
    /// type-classification loop. The per-tick sampler only ever displays the
    /// total; the vnode/socket/pipe/other split is read solely by the on-demand
    /// detail inspector (`openFileDescriptors`).
    ///
    /// Only the *fill* call's return value — bytes actually written — counts open
    /// descriptors. The separate *sizing* call
    /// (`proc_pidinfo(PROC_PIDLISTFDS, buffer: nil)`) is **not** a count: XNU
    /// sizes the reply as `(fd_nfiles + 20) * sizeof(proc_fdinfo)`, where
    /// `fd_nfiles` is the *allocated FD-table capacity* — a high-water mark that
    /// starts at 25, doubles on demand, and never shrinks. An earlier version
    /// returned the sizing result directly and displayed "1620" for a process
    /// with 27 real descriptors (docs/fd-count-1620-diagnosis.md).
    ///
    /// Because only the fill call is authoritative, the sizing call is pure
    /// overhead on the hot path — and it is not cheap: XNU walks the fd table to
    /// service it, ~0.5 ms across an ~800-process scan (measured, ≈63% of this
    /// function's cost). So skip it: fill straight into the retained `scratch`
    /// buffer (grown to the largest FD table seen and reused across the whole
    /// scan). Only if the reply exactly fills the buffer might it have been
    /// truncated, so grow and retry — rare, since almost every process has far
    /// fewer than the seeded 256 descriptors, and one big process bumps the
    /// buffer for the rest of the scan. Net: one syscall per process instead of
    /// two, with the count still taken solely from the fill return.
    public func fdCount(_ pid: pid_t, scratch: FDCountScratch) -> Int32? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Seed a starting buffer so the common case is a single fill call. Most
        // processes have well under 256 FDs; the buffer is retained and only grows.
        if scratch.buffer.count < 256 {
            scratch.buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        }
        while true {
            let capacityBytes = Int32(scratch.buffer.count * stride)
            let ret = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &scratch.buffer, capacityBytes)
            // <0: not permitted / process gone (errno set). 0: genuinely no FDs.
            guard ret >= 0 else { return nil }
            // A reply that fills the whole buffer may have been truncated; double
            // the buffer and retry so a process with many descriptors is never
            // undercounted. (The `>=` guards against a driver ever over-reporting.)
            if ret >= capacityBytes {
                scratch.buffer = [proc_fdinfo](
                    repeating: proc_fdinfo(), count: scratch.buffer.count * 2)
                continue
            }
            return Int32(Int(ret) / stride)
        }
    }

    /// The list of open file descriptors for a process, each resolved to its
    /// path (files) or endpoint (sockets). Returns nil only on a hard error; a
    /// process the user is not permitted to inspect reports an empty list rather
    /// than failing, matching `PROC_PIDLISTFDS`. The detail resolution makes a
    /// syscall per descriptor, so this is meant for on-demand inspection of one
    /// process, never the per-tick sampling path.
    public func openFileDescriptors(_ pid: pid_t) -> [OpenFileDescriptor]? {
        let count = cmacperfmonitor_list_fds(pid, nil, 0)
        if count < 0 { return nil }
        if count == 0 { return [] }

        let capacity = Int(count) + 16
        var buffer = [cmacperfmonitor_fd_t](repeating: cmacperfmonitor_fd_t(), count: capacity)
        let written = cmacperfmonitor_list_fds(pid, &buffer, Int32(capacity))
        if written < 0 { return nil }

        let n = min(Int(written), capacity)
        var result: [OpenFileDescriptor] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let entry = buffer[i]
            let detail = withUnsafePointer(to: entry.detail) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            result.append(
                OpenFileDescriptor(
                    fd: entry.fd, kind: OpenFileDescriptor.Kind(code: entry.type), detail: detail))
        }
        return result
    }

    /// Whether the process runs translated under Rosetta. nil on error.
    public func isTranslated(_ pid: pid_t) -> Bool? {
        let r = cmacperfmonitor_is_translated(pid)
        if r < 0 { return nil }
        return r == 1
    }

    /// Best-effort architecture: translated processes are x86_64; everything else
    /// is native arm64 (the app runs on Apple silicon only).
    public func architecture(translated: Bool?) -> Architecture {
        translated == true ? .x86_64 : .arm64
    }

    /// Bundle the privilege-gated reads (task info, footprint, file descriptors)
    /// for one process into a single transportable value. Run as root by the
    /// helper, this returns full data for processes the unprivileged app cannot
    /// read; the `nil` accessors degrade honestly when even root cannot read a
    /// field. Path and Rosetta state are deliberately omitted: both read
    /// reliably at user level, so the app computes them itself.
    public func rawRead(_ pid: pid_t) -> RawProcessRead {
        RawProcessRead(
            pid: pid,
            task: taskAllInfo(pid),
            rusage: rusage(pid),
            fd: fdBreakdown(pid)
        )
    }
}
