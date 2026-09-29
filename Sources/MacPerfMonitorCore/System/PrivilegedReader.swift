import Darwin
import Foundation

/// The privilege-gated reads for a single process, captured by the root helper
/// and shipped back to the app. Each field is optional so a process that has
/// gone, or a field even root cannot read, degrades to `nil` rather than a
/// fabricated zero.
///
/// Codable so it can cross the XPC boundary as JSON. It deliberately carries
/// only the reads that need root (task info, footprint, file descriptors); the
/// executable path and Rosetta flag read reliably at user level, so the app
/// fills those in itself.
public struct RawProcessRead: Codable, Sendable {
    public var pid: Int32
    public var task: TaskAllInfo?
    public var rusage: RUsage?
    public var fd: FDBreakdown?

    public init(
        pid: Int32, task: TaskAllInfo? = nil, rusage: RUsage? = nil, fd: FDBreakdown? = nil
    ) {
        self.pid = pid
        self.task = task
        self.rusage = rusage
        self.fd = fd
    }
}

public struct ANEPowerReading: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let interval: TimeInterval
    public let watts: Double

    public init(timestamp: Date, interval: TimeInterval, watts: Double) {
        self.timestamp = timestamp
        self.interval = interval
        self.watts = watts
    }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return timestamp.timeIntervalSince1970.isFinite && age >= -1 && age <= 5
            && interval.isFinite && interval > 0 && interval <= 30
            && watts.isFinite && watts >= 0
    }
}

/// Supplies privilege-gated process reads for the PIDs the unprivileged app
/// could not read on its own. The concrete implementation in the app talks to
/// the root helper over XPC; tests inject a fake. Kept in `MacPerfMonitorCore` (with
/// no XPC dependency) so the `Sampler` can call it without knowing how the data
/// is fetched.
public protocol PrivilegedReader: Sendable {
    /// Read whatever root can for the given PIDs. The result is keyed by PID;
    /// missing keys mean the helper could not read that process either.
    func readProcesses(pids: [Int32]) -> [Int32: RawProcessRead]
    func readANEPower(reply: @escaping @Sendable (ANEPowerReading?) -> Void)
    func stopANEPower()
}

extension PrivilegedReader {
    public func readANEPower(reply: @escaping @Sendable (ANEPowerReading?) -> Void) { reply(nil) }
    public func stopANEPower() {}
}
