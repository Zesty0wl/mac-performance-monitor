import Darwin
import Foundation

/// Opt-in cadence and cost counters for the sampler, so "are we really ticking
/// at 4 Hz and what does each tick cost" can be answered on any Mac from the
/// unified log instead of a profiler:
///
///     defaults write uk.co.bzwrd.macperfmonitor diagnostics.tickStats -bool YES
///     log stream --predicate 'subsystem == "uk.co.bzwrd.macperfmonitor"' --info
///
/// Every `reportInterval` seconds it logs the achieved tick rate against the
/// target, the mean and worst cost of the system tick, the process scan and
/// the main-thread publish, and how much CPU the process and its main thread
/// used over the period. Off (and free) unless the default is set.
final class TickDiagnostics {
    static let defaultsKey = "diagnostics.tickStats"

    let enabled: Bool
    private let reportInterval: TimeInterval = 30
    private let lock = NSLock()

    private var periodStart: TimeInterval
    private var ticks = 0
    private var systemTotal: TimeInterval = 0
    private var systemMax: TimeInterval = 0
    private var scans = 0
    private var scanTotal: TimeInterval = 0
    private var scanMax: TimeInterval = 0
    private var publishes = 0
    private var publishTotal: TimeInterval = 0
    private var publishMax: TimeInterval = 0
    private var lastProcessCPU: TimeInterval
    private var lastMainCPU: TimeInterval
    /// The main thread's Mach port, captured at creation (the sampler model is
    /// built on the main thread at launch).
    private let mainThread: thread_t

    init(enabled: Bool = UserDefaults.standard.bool(forKey: TickDiagnostics.defaultsKey)) {
        self.enabled = enabled
        mainThread =
            Thread.isMainThread ? mach_thread_self() : pthread_mach_thread_np(pthread_self())
        periodStart = Self.now()
        lastProcessCPU = Self.processCPUSeconds()
        lastMainCPU = Self.threadCPUSeconds(mainThread)
    }

    /// Monotonic seconds.
    static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
    }

    func recordSystemTick(duration: TimeInterval) {
        guard enabled else { return }
        lock.lock()
        ticks += 1
        systemTotal += duration
        systemMax = max(systemMax, duration)
        lock.unlock()
    }

    func recordScan(duration: TimeInterval) {
        guard enabled else { return }
        lock.lock()
        scans += 1
        scanTotal += duration
        scanMax = max(scanMax, duration)
        lock.unlock()
    }

    func recordPublish(duration: TimeInterval) {
        guard enabled else { return }
        lock.lock()
        publishes += 1
        publishTotal += duration
        publishMax = max(publishMax, duration)
        lock.unlock()
    }

    /// Log a period summary once `reportInterval` has elapsed. Call from the
    /// sampler queue each tick; it returns immediately otherwise.
    func reportIfDue(targetInterval: TimeInterval) {
        guard enabled else { return }
        let now = Self.now()
        let elapsed = now - periodStart
        guard elapsed >= reportInterval else { return }
        let processCPU = Self.processCPUSeconds()
        let mainCPU = Self.threadCPUSeconds(mainThread)
        lock.lock()
        let line = String(
            format:
                "tick stats: %d ticks in %.1fs = %.2f Hz (target %.2f) | system tick mean %.2f ms max %.2f "
                + "| %d scans mean %.1f ms max %.1f | publish mean %.2f ms max %.2f "
                + "| CPU process %.1f%% main thread %.1f%%",
            ticks, elapsed, Double(ticks) / elapsed, 1 / targetInterval,
            ticks > 0 ? systemTotal / Double(ticks) * 1000 : 0, systemMax * 1000,
            scans, scans > 0 ? scanTotal / Double(scans) * 1000 : 0, scanMax * 1000,
            publishes > 0 ? publishTotal / Double(publishes) * 1000 : 0, publishMax * 1000,
            (processCPU - lastProcessCPU) / elapsed * 100, (mainCPU - lastMainCPU) / elapsed * 100)
        ticks = 0
        systemTotal = 0
        systemMax = 0
        scans = 0
        scanTotal = 0
        scanMax = 0
        publishes = 0
        publishTotal = 0
        publishMax = 0
        lock.unlock()
        periodStart = now
        lastProcessCPU = processCPU
        lastMainCPU = mainCPU
        AppLog.sampler.notice("\(line, privacy: .public)")
    }

    /// User + system CPU seconds consumed by this process so far.
    private static func processCPUSeconds() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1e6
            + TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1e6
    }

    /// User + system CPU seconds consumed by one thread so far.
    private static func threadCPUSeconds(_ thread: thread_t) -> TimeInterval {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds)
            / 1e6
            + TimeInterval(info.system_time.seconds)
            + TimeInterval(info.system_time.microseconds) / 1e6
    }
}
