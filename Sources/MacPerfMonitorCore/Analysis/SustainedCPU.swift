import Foundation

/// A program that keeps the processor busy for hours: a background part of
/// macOS stuck in a loop (contactsd syncing Contacts at 1.6 cores all night,
/// 2026-09-30), or an app spinning in the background. Neither the whole-Mac CPU
/// alert nor memory growth sees it, and after a few days it becomes part of
/// what looks normal for the Mac.
///
/// Programs are followed by executable, not by run: launchd restarts a stuck
/// daemon again and again, and each run alone looks short. Shared by the live
/// alert (`SustainedCPUMonitor`) and Ask (which replays recorded minutes), so
/// both flag the same thing.
public enum SustainedCPU {
    /// A reading counts as busy at a quarter of one core.
    public static let busyPercent = 25.0
    /// Flag when the spell averages this much of one core...
    public static let flagPercent = 80.0
    /// ...for at least this long...
    public static let minimumSpell: TimeInterval = 3600
    /// ...and was busy for most of it.
    public static let busyShare = 0.75
    /// This long below `busyPercent` ends a spell.
    public static let quietGap: TimeInterval = 600
    /// An app the person may be using is only worth a warning after this long.
    public static let appWarningSpell: TimeInterval = 3 * 3600
    /// Its CPU is macOS cooling the chip, not work.
    public static let exempt: Set<String> = ["kernel_task"]

    /// The trampoline launchd runs before exec. A run first seen at that
    /// moment keeps this path in the history under its real name (289
    /// programs in one week on a busy Mac), so the path says nothing.
    public static let launcherPath = "/usr/libexec/xpcproxy"

    /// How a program is followed across runs.
    public static func key(name: String, executablePath: String?) -> String {
        guard let executablePath, !executablePath.isEmpty, executablePath != launcherPath else {
            return name
        }
        return executablePath
    }

    /// `key` as SQL over the processes table aliased `p`.
    static let keySQL = """
        CASE WHEN p.executable_path IS NULL OR p.executable_path = '' \
        OR p.executable_path = '\(launcherPath)' THEN p.name ELSE p.executable_path END
        """
}

/// One continuous busy spell of one program.
public struct SustainedSpell: Sendable, Equatable {
    public private(set) var since: Date
    public private(set) var last: Date
    public private(set) var lastBusy: Date
    public private(set) var peak: Double
    private var cpuSeconds = 0.0
    private var seconds = 0.0
    private var busySeconds = 0.0

    /// Starts a spell, or nil when the reading is not busy.
    public init?(cpu: Double, at time: Date) {
        guard cpu.isFinite, cpu >= SustainedCPU.busyPercent else { return nil }
        since = time
        last = time
        lastBusy = time
        peak = cpu
    }

    /// Average CPU over the spell, percent of one core.
    public var average: Double { seconds > 0 ? cpuSeconds / seconds : peak }
    public var duration: TimeInterval { last.timeIntervalSince(since) }

    public var isSustained: Bool {
        duration >= SustainedCPU.minimumSpell && average >= SustainedCPU.flagPercent
            && busySeconds >= seconds * SustainedCPU.busyShare
    }

    /// Adds a reading covering the time since the previous one. Returns false
    /// when the spell has ended: a quiet stretch, or no readings for too long.
    public mutating func add(cpu: Double, at time: Date) -> Bool {
        let step = time.timeIntervalSince(last)
        guard step > 0 else { return true }
        guard step <= SustainedCPU.quietGap else { return false }
        let value = cpu.isFinite ? max(0, cpu) : 0
        cpuSeconds += value * step
        seconds += step
        if value >= SustainedCPU.busyPercent {
            busySeconds += step
            lastBusy = time
        }
        peak = max(peak, value)
        last = time
        return time.timeIntervalSince(lastBusy) <= SustainedCPU.quietGap
    }

    /// The spell running at the end of an evenly spaced series (oldest first,
    /// one value per step), or nil when none is.
    public static func current(in values: [(Date, Double)]) -> SustainedSpell? {
        var spell: SustainedSpell?
        for (time, cpu) in values {
            if spell != nil, spell?.add(cpu: cpu, at: time) == false { spell = nil }
            if spell == nil { spell = SustainedSpell(cpu: cpu, at: time) }
        }
        return spell
    }
}

/// Parts of macOS that are known to run hard for a long time, and what to say
/// about them. `job` work finishes by itself; the rest should not stay busy
/// for hours, so a long spell means something is stuck.
public enum KnownBackgroundWork {
    public struct Info: Sendable, Equatable {
        public var explanation: String?
        public var job: Bool
        /// Quitting it logs the person out or does nothing useful.
        public var neverQuit: Bool
    }

    public static func info(for name: String) -> Info? {
        switch name {
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd", "mdsync":
            return Info(
                explanation: t(
                    "It is Spotlight indexing files. That finishes on its own, often after an update or when many files changed."
                ), job: true, neverQuit: false)
        case "photoanalysisd", "mediaanalysisd", "photolibraryd":
            return Info(
                explanation: t(
                    "It is Photos analysing your library. It works while the Mac is otherwise idle and finishes on its own."
                ), job: true, neverQuit: false)
        case "backupd", "backupd-helper":
            return Info(
                explanation: t("It is Time Machine making a backup, which finishes on its own."),
                job: true, neverQuit: false)
        case "softwareupdated", "UpdateBrainService":
            return Info(
                explanation: t("It is preparing a macOS update, which finishes on its own."),
                job: true, neverQuit: false)
        case "contactsd", "AddressBookSourceSync", "contactsdonationagent":
            return Info(
                explanation: t(
                    "It keeps Contacts in step with your accounts. Busy for hours usually means a sync is stuck: in System Settings > Internet Accounts, turn Contacts off for one account at a time to find which."
                ), job: false, neverQuit: false)
        case "cloudd", "bird", "fileproviderd":
            return Info(
                explanation: t(
                    "It syncs iCloud. Large uploads take a while, but busy for many hours can mean a sync is stuck."
                ), job: false, neverQuit: false)
        case "WindowServer":
            return Info(
                explanation: t(
                    "It draws everything on screen. Busy for hours usually means an app keeps redrawing: quit apps with animations or many windows open."
                ), job: false, neverQuit: true)
        case "launchd", "loginwindow", "logd", "kernel_task":
            return Info(explanation: nil, job: false, neverQuit: true)
        default:
            return nil
        }
    }
}
