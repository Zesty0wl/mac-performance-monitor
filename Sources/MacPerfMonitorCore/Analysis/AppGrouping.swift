import Foundation

/// One app and every process working for it, for the Processes tab's Apps
/// view: the processes sharing a resource coalition, named after the app that
/// is responsible for them, with their figures added up.
public struct AppGroup: Sendable, Equatable {
    public var coalitionID: UInt64
    /// The member the group is named after (the app itself, usually).
    public var leader: ProcessSample
    /// Every member, the leader included.
    public var members: [ProcessSample]
    /// The leader's sample carrying the app's name and the members' totals,
    /// so a row can draw and sort it like any process.
    public var total: ProcessSample

    /// The row identity, distinct from every real process's.
    public var identity: ProcessIdentity { .appGroup(coalitionID: coalitionID) }
}

extension ProcessIdentity {
    /// The identity of the Apps-view row for a coalition. A negative pid, which
    /// no real process has, so it never collides with a member's row, and
    /// stable across rebuilds so the row keeps its expansion and selection.
    public static func appGroup(coalitionID: UInt64) -> ProcessIdentity {
        ProcessIdentity(
            pid: -1 - Int32(truncatingIfNeeded: coalitionID & 0x7FFF_FFFF),
            startTime: .distantPast)
    }

    /// Whether this identity is an Apps-view row rather than a process.
    public var isAppGroup: Bool { pid < 0 && startTime == .distantPast }
}

/// Groups processes into the apps they work for (issue #162). A parent-PID
/// tree misses most helpers: XPC services, WebKit's content processes among
/// them, are launchd's children, so Safari's tree is Safari alone while its
/// coalition holds every tab. Coalitions are what macOS itself accounts apps
/// by. Pure, so it is unit-tested and shared by the table and the inspector.
public enum AppGrouping {
    /// The coalitions with more than one member, as groups, and every other
    /// process (alone in its coalition, or with none readable) left loose.
    public static func group(
        _ samples: [ProcessSample]
    ) -> (groups: [AppGroup], loose: [ProcessSample]) {
        var byCoalition: [UInt64: [ProcessSample]] = [:]
        var loose: [ProcessSample] = []
        for sample in samples {
            if let coalition = sample.coalitionID {
                byCoalition[coalition, default: []].append(sample)
            } else {
                loose.append(sample)
            }
        }
        var groups: [AppGroup] = []
        for (coalition, members) in byCoalition {
            guard members.count > 1 else {
                loose.append(contentsOf: members)
                continue
            }
            groups.append(makeGroup(coalitionID: coalition, members: members))
        }
        return (groups, loose)
    }

    /// Build a group from its members.
    public static func makeGroup(coalitionID: UInt64, members: [ProcessSample]) -> AppGroup {
        let leader = leader(of: members)
        return AppGroup(
            coalitionID: coalitionID, leader: leader, members: members,
            total: total(leader: leader, members: members))
    }

    /// The member to name the group after: the process most members name as
    /// responsible for them, when it is a member; otherwise an app's main
    /// executable; otherwise the oldest member. Ties go to the oldest.
    static func leader(of members: [ProcessSample]) -> ProcessSample {
        let byOldest = members.sorted {
            ($0.startTime, $0.pid) < ($1.startTime, $1.pid)
        }
        var votes: [Int32: Int] = [:]
        for member in members {
            if let responsible = member.responsiblePID { votes[responsible, default: 0] += 1 }
        }
        if let top = byOldest.compactMap({ votes[$0.pid] }).max(),
            let chosen = byOldest.first(where: { votes[$0.pid] == top })
        {
            return chosen
        }
        return byOldest.first { appBundleName(forExecutablePath: $0.executablePath) != nil }
            ?? byOldest[0]
    }

    /// The leader's sample renamed to the app and carrying the members'
    /// summed figures. Memory is the sum of footprints: each process's
    /// footprint charges shared memory to its owner, so the sum is close to
    /// what quitting the app would free.
    public static func total(leader: ProcessSample, members: [ProcessSample]) -> ProcessSample {
        var total = leader
        total.name = displayName(for: leader)
        total.physFootprint = 0
        total.residentSize = 0
        total.lifetimeMaxFootprint = 0
        total.cpuPercent = 0
        total.cpuTimeUser = 0
        total.cpuTimeSystem = 0
        total.threadCount = 0
        total.fdTotal = 0
        total.fdVnode = 0
        total.fdSocket = 0
        total.fdPipe = 0
        total.fdOther = 0
        total.diskReadBytesPerSec = 0
        total.diskWriteBytesPerSec = 0
        total.energyImpact = 0
        total.networkBytesPerSec = 0
        total.footprintReadable = false
        var gpuPercent: Double?
        var gpuTime: UInt64?
        var gpuLast: Date?
        for m in members {
            total.physFootprint &+= m.physFootprint
            total.residentSize &+= m.residentSize
            total.lifetimeMaxFootprint &+= m.lifetimeMaxFootprint
            total.cpuPercent += m.cpuPercent
            total.cpuTimeUser &+= m.cpuTimeUser
            total.cpuTimeSystem &+= m.cpuTimeSystem
            total.threadCount = total.threadCount.addingClamped(m.threadCount)
            total.fdTotal = total.fdTotal.addingClamped(m.fdTotal)
            total.fdVnode = total.fdVnode.addingClamped(m.fdVnode)
            total.fdSocket = total.fdSocket.addingClamped(m.fdSocket)
            total.fdPipe = total.fdPipe.addingClamped(m.fdPipe)
            total.fdOther = total.fdOther.addingClamped(m.fdOther)
            total.diskReadBytesPerSec += m.diskReadBytesPerSec
            total.diskWriteBytesPerSec += m.diskWriteBytesPerSec
            total.energyImpact += m.energyImpact
            total.networkBytesPerSec += m.networkBytesPerSec
            // Readable when any member is: an unreadable helper adds nothing,
            // which undercounts a little rather than blanking the whole app.
            total.footprintReadable = total.footprintReadable || m.footprintReadable
            if let p = m.gpuPercent { gpuPercent = (gpuPercent ?? 0) + p }
            if let n = m.gpuTimeNanos { gpuTime = (gpuTime ?? 0) &+ n }
            if let last = m.gpuLastActive { gpuLast = max(gpuLast ?? last, last) }
        }
        total.gpuPercent = gpuPercent
        total.gpuTimeNanos = gpuTime
        total.gpuLastActive = gpuLast
        return total
    }

    /// The name an app row shows: the bundle whose main executable the leader
    /// is ("Microsoft Teams", not its binary "MSTeams"), else the process name.
    public static func displayName(for leader: ProcessSample) -> String {
        appBundleName(forExecutablePath: leader.executablePath) ?? leader.displayName
    }

    /// "Name" for a path ending `Name.app/Contents/MacOS/<executable>`; nil for
    /// anything else (daemons, helpers inside frameworks, command-line tools).
    static func appBundleName(forExecutablePath path: String?) -> String? {
        guard let bundle = appBundlePath(forExecutablePath: path) else { return nil }
        return String((bundle as NSString).lastPathComponent.dropLast(4))
    }

    /// The `.app` bundle whose main executable `path` is, for revealing the
    /// app rather than its binary.
    public static func appBundlePath(forExecutablePath path: String?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4,
            parts[parts.count - 2] == "MacOS",
            parts[parts.count - 3] == "Contents"
        else { return nil }
        let bundle = parts[parts.count - 4]
        guard bundle.hasSuffix(".app"), bundle.count > 4 else { return nil }
        return "/" + parts.dropLast(3).joined(separator: "/")
    }
}

extension Int32 {
    fileprivate func addingClamped(_ other: Int32) -> Int32 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
