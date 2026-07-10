import Foundation

/// Stable identity for a process across time. A reused PID is a distinct
/// process, so identity is keyed on `pid` plus its start time.
public struct ProcessIdentity: Hashable, Sendable, Codable {
    public var pid: Int32
    public var startTime: Date

    public init(pid: Int32, startTime: Date) {
        self.pid = pid
        self.startTime = startTime
    }
}

/// A single per-process measurement captured on one sampling tick.
public struct ProcessSample: Sendable, Codable, Identifiable, Equatable {
    /// Timestamp of the sampling tick that produced this row.
    public var timestamp: Date

    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var executablePath: String?
    public var bundleID: String?

    /// The code-signing Team Identifier (e.g. "EQHXZ8M8AV"), resolved once per
    /// distinct executable and cached. Lets process groups match "everything
    /// signed by vendor X", including unbundled root daemons that have no bundle
    /// id. Nil when unsigned, ad-hoc signed, or not yet resolved.
    public var teamID: String?

    /// The headline "Memory" figure (bytes), matching Activity Monitor.
    public var physFootprint: UInt64
    public var residentSize: UInt64
    public var virtualSize: UInt64
    public var lifetimeMaxFootprint: UInt64

    /// CPU usage as a percentage of one core, computed from the CPU-time delta
    /// between consecutive ticks.
    public var cpuPercent: Double
    public var cpuTimeUser: UInt64
    public var cpuTimeSystem: UInt64

    public var threadCount: Int32

    public var fdTotal: Int32
    public var fdVnode: Int32
    public var fdSocket: Int32
    public var fdPipe: Int32
    public var fdOther: Int32

    public var diskBytesRead: UInt64
    public var diskBytesWritten: UInt64
    /// Instantaneous rates derived from the cumulative counters above over the
    /// real interval between process scans. First sightings and resets are zero.
    public var diskReadBytesPerSec: Double
    public var diskWriteBytesPerSec: Double

    /// Kernel per-process energy accounting (nanojoules, cumulative). Best-effort
    /// and often 0; `energyImpact` is the figure the UI ranks by.
    public var energyNanojoules: UInt64
    /// Relative "energy impact" for this tick, à la Activity Monitor's Energy
    /// tab: real power (watts) derived from the energy-counter delta when that
    /// counter is non-zero, otherwise a CPU-and-wakeups estimate. The sampler
    /// computes it inter-tick the same way it computes `cpuPercent`.
    public var energyImpact: Double

    /// This process's total network throughput for the tick, in bytes per second
    /// (download + upload). Populated only when per-app network tracking is
    /// enabled (it is sourced from `nettop`, which is opt-in because it is far
    /// heavier than the libproc reads); 0 otherwise. An instantaneous rate like
    /// `cpuPercent`, not a cumulative counter, so the sampler computes it
    /// inter-tick and the UI ranks by it directly.
    public var networkBytesPerSec: Double

    public var isTranslated: Bool
    public var architecture: Architecture

    public var startTime: Date
    public var uid: uid_t

    public var dataSource: SampleSource

    /// Whether the headline footprint could actually be read for this process.
    /// When false (and the helper is absent) the UI shows a coverage gap rather
    /// than a misleading zero.
    public var footprintReadable: Bool

    public var id: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }

    /// A fuller name for display. The kernel's `p_comm` (`name`) is capped at a
    /// short fixed length, so long names arrive pre-truncated (for example
    /// "com.apple.WebKit.WebContent" becomes "com.apple.WebK"). When the
    /// executable's filename extends that truncated name, prefer it so the UI
    /// can show the whole name; otherwise fall back to `name`.
    public var displayName: String {
        Self.resolvedDisplayName(name: name, executablePath: executablePath)
    }

    /// Recover a fuller display name from a kernel `p_comm` (which is capped at a
    /// short fixed length) by preferring the executable's filename when it
    /// extends the truncated name. Shared so the persisted leaderboards (top
    /// consumers, leak board) resolve names exactly as the live process list
    /// does, rather than showing the pre-truncated `p_comm`.
    public static func resolvedDisplayName(name: String, executablePath: String?) -> String {
        guard let path = executablePath, !path.isEmpty else { return name }
        let base = (path as NSString).lastPathComponent
        if !base.isEmpty, base.count > name.count, base.hasPrefix(name) {
            return base
        }
        return name
    }

    public init(
        timestamp: Date,
        pid: Int32,
        ppid: Int32,
        name: String,
        executablePath: String? = nil,
        bundleID: String? = nil,
        teamID: String? = nil,
        physFootprint: UInt64,
        residentSize: UInt64,
        virtualSize: UInt64,
        lifetimeMaxFootprint: UInt64,
        cpuPercent: Double,
        cpuTimeUser: UInt64,
        cpuTimeSystem: UInt64,
        threadCount: Int32,
        fdTotal: Int32,
        fdVnode: Int32,
        fdSocket: Int32,
        fdPipe: Int32,
        fdOther: Int32,
        diskBytesRead: UInt64,
        diskBytesWritten: UInt64,
        diskReadBytesPerSec: Double = 0,
        diskWriteBytesPerSec: Double = 0,
        energyNanojoules: UInt64 = 0,
        energyImpact: Double = 0,
        networkBytesPerSec: Double = 0,
        isTranslated: Bool,
        architecture: Architecture,
        startTime: Date,
        uid: uid_t,
        dataSource: SampleSource,
        footprintReadable: Bool
    ) {
        self.timestamp = timestamp
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.teamID = teamID
        self.physFootprint = physFootprint
        self.residentSize = residentSize
        self.virtualSize = virtualSize
        self.lifetimeMaxFootprint = lifetimeMaxFootprint
        self.cpuPercent = cpuPercent
        self.cpuTimeUser = cpuTimeUser
        self.cpuTimeSystem = cpuTimeSystem
        self.threadCount = threadCount
        self.fdTotal = fdTotal
        self.fdVnode = fdVnode
        self.fdSocket = fdSocket
        self.fdPipe = fdPipe
        self.fdOther = fdOther
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.energyNanojoules = energyNanojoules
        self.energyImpact = energyImpact
        self.networkBytesPerSec = networkBytesPerSec
        self.isTranslated = isTranslated
        self.architecture = architecture
        self.startTime = startTime
        self.uid = uid
        self.dataSource = dataSource
        self.footprintReadable = footprintReadable
    }
}
