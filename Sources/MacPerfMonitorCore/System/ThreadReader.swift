import CMacPerfMonitor
import Darwin
import Foundation

/// One thread of a process at one moment.
///
/// Codable so the root helper can return a list as JSON, like
/// `OpenFileDescriptor`.
public struct ThreadSnapshot: Codable, Sendable, Identifiable, Equatable {
    /// What the scheduler is doing with the thread.
    public enum State: Int, Codable, Sendable {
        case running = 1
        case stopped = 2
        case waiting = 3
        case uninterruptible = 4
        case halted = 5
        case unknown = 0

        init(runState: Int32) {
            self = State(rawValue: Int(runState)) ?? .unknown
        }
    }

    /// The kernel's handle for the thread, as `PROC_PIDLISTTHREADS` reports it.
    /// Stable for the thread's life and unique within its process, which is
    /// all this is used for: matching a thread between two reads. It is not
    /// the thread ID that `sample` and Instruments print.
    public var id: UInt64
    /// The name the process gave the thread, empty when it gave none.
    public var name: String
    /// Accumulated time in user code, nanoseconds.
    public var userNanos: UInt64
    /// Accumulated time in the kernel on the thread's behalf, nanoseconds.
    public var systemNanos: UInt64
    public var state: State
    /// The priority the scheduler is using right now.
    public var currentPriority: Int32
    /// The thread's base priority, before any temporary boost or decay.
    public var basePriority: Int32
    /// Seconds since the thread last ran, as the kernel counts them.
    public var sleepSeconds: Int32

    public var cpuNanos: UInt64 { userNanos &+ systemNanos }

    public init(
        id: UInt64, name: String, userNanos: UInt64, systemNanos: UInt64, state: State,
        currentPriority: Int32, basePriority: Int32, sleepSeconds: Int32
    ) {
        self.id = id
        self.name = name
        self.userNanos = userNanos
        self.systemNanos = systemNanos
        self.state = state
        self.currentPriority = currentPriority
        self.basePriority = basePriority
        self.sleepSeconds = sleepSeconds
    }
}

/// Per-thread reads via libproc. Works as the user for the user's own
/// processes and as root (in the helper) for everything else; no task port is
/// needed either way.
public struct ThreadReader: Sendable {
    public init() {}

    /// Every thread of `pid`, in the kernel's order (the main thread first), or
    /// nil when the process is gone or not readable by this user.
    ///
    /// Two syscalls plus one per thread, so this is for inspecting one process
    /// on demand, never the per-tick sampling path.
    public func threads(_ pid: pid_t) -> [ThreadSnapshot]? {
        // Unlike the descriptor list, a nil buffer does not report the size
        // needed, so size from the task's thread count and leave room for
        // threads created between the two calls.
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let taskRead = withUnsafeMutablePointer(to: &task) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, taskSize)
        }
        guard taskRead == taskSize else { return nil }

        let stride = MemoryLayout<UInt64>.stride
        var handles = [UInt64](repeating: 0, count: Int(max(task.pti_threadnum, 1)) + 32)
        while true {
            let capacityBytes = Int32(handles.count * stride)
            let got = handles.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, $0.baseAddress, capacityBytes)
            }
            guard got > 0 else { return nil }
            // A reply that fills the buffer may have been cut short.
            if got >= capacityBytes, handles.count < 65_536 {
                handles = [UInt64](repeating: 0, count: handles.count * 2)
                continue
            }
            handles.removeSubrange(min(handles.count, Int(got) / stride)...)
            break
        }

        let infoSize = Int32(MemoryLayout<proc_threadinfo>.size)
        var result: [ThreadSnapshot] = []
        result.reserveCapacity(handles.count)
        var seen = Set<UInt64>()
        for handle in handles where seen.insert(handle).inserted {
            var info = proc_threadinfo()
            let read = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDTHREADINFO, handle, $0, infoSize)
            }
            // A thread that exited between the list and this read is skipped.
            guard read == infoSize else { continue }
            let name = withUnsafeBytes(of: info.pth_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            result.append(
                ThreadSnapshot(
                    id: handle, name: name,
                    // Unlike the task totals, per-thread times are already in
                    // nanoseconds: the kernel builds them from seconds and
                    // microseconds, not from Mach time units.
                    userNanos: info.pth_user_time, systemNanos: info.pth_system_time,
                    state: ThreadSnapshot.State(runState: info.pth_run_state),
                    currentPriority: info.pth_curpri, basePriority: info.pth_priority,
                    sleepSeconds: info.pth_sleep_time))
        }
        return result
    }
}

/// CPU use per thread between two reads of the same process.
public enum ThreadUsage {
    /// Percent of one core each thread in `current` used since `previous`,
    /// keyed by thread ID. A thread that was not in `previous` has no entry: it
    /// may have run for any part of the interval, so no honest rate exists yet.
    public static func cpuPercent(
        previous: [ThreadSnapshot], current: [ThreadSnapshot], elapsed: TimeInterval
    ) -> [UInt64: Double] {
        guard elapsed > 0 else { return [:] }
        let before = Dictionary(previous.map { ($0.id, $0.cpuNanos) }) { first, _ in first }
        var result: [UInt64: Double] = [:]
        for thread in current {
            guard let earlier = before[thread.id] else { continue }
            // A smaller total means the handle was reused by a new thread.
            guard thread.cpuNanos >= earlier else { continue }
            let used = Double(thread.cpuNanos - earlier) / 1_000_000_000
            result[thread.id] = used / elapsed * 100
        }
        return result
    }
}
