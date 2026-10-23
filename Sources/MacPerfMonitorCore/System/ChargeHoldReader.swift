import Foundation

/// A cap macOS has put on charging while the Mac is on the adapter: Optimised
/// Battery Charging waiting at 80 % until you usually unplug, a charge limit
/// set in Battery settings, or another powerd policy.
public struct ChargeHold: Sendable, Codable, Equatable {
    public enum Reason: String, Sendable, Codable {
        case optimizedCharging, chargeLimit, other
    }

    public var reason: Reason
    /// powerd's own name for the policy, e.g. "optimizedChargeLimit".
    public var policyName: String
    /// The charge the battery is held at, in percent (below 100).
    public var limitPercent: Int

    public init(reason: Reason, policyName: String, limitPercent: Int) {
        self.reason = reason
        self.policyName = policyName
        self.limitPercent = limitPercent
    }

    static func reason(forPolicy name: String) -> Reason {
        let lowered = name.lowercased()
        if lowered.contains("optimized") || lowered.contains("obc") { return .optimizedCharging }
        if lowered.contains("limit") { return .chargeLimit }
        return .other
    }
}

/// Reads the charge-control policies powerd publishes in a world-readable
/// preference file, which is the only unprivileged place that says *why* a
/// plugged-in battery is not charging. The file holds the boot session it was
/// written in plus a keyed archive of `ChargeCtrlPolicy` objects
/// (`reason`, `soclimit`, `terminated`, ...); a policy from an earlier boot is
/// stale and ignored. Parsed only when the file changes.
public enum ChargeHoldReader {
    static let path = "/Library/Preferences/com.apple.powerd.charging.plist"

    private static let lock = NSLock()
    private static var cache: (stamp: FileStamp, hold: ChargeHold?)?
    private static let bootSession = Sysctl.string("kern.bootsessionuuid")

    struct FileStamp: Equatable {
        var modified: timespec
        var size: off_t

        static func == (a: Self, b: Self) -> Bool {
            a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
                && a.size == b.size
        }
    }

    /// The hold in force now, or nil when charging is not capped (or the
    /// file is missing, unreadable or from an earlier boot).
    public static func read() -> ChargeHold? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let stamp = FileStamp(modified: info.st_mtimespec, size: info.st_size)
        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.stamp == stamp { return cache.hold }
        let hold = FileManager.default.contents(atPath: path).flatMap {
            parse($0, bootSession: bootSession)
        }
        cache = (stamp, hold)
        return hold
    }

    /// The lowest active limit in the file's policies. `bootSession` nil
    /// skips the staleness check (for tests and Macs without the sysctl).
    static func parse(_ data: Data, bootSession: String?) -> ChargeHold? {
        guard
            let outer = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let archive = outer["policies"] as? Data
        else { return nil }
        if let bootSession, let written = outer["bootSessionUUID"] as? String,
            written.caseInsensitiveCompare(bootSession) != .orderedSame
        {
            return nil
        }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(ChargePolicyRecord.self, forClassName: "ChargeCtrlPolicy")
        let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        let policies = (root as? [Any])?.compactMap { $0 as? ChargePolicyRecord } ?? []
        return
            policies
            .filter { !$0.terminated && (1..<100).contains($0.limit) }
            .min { $0.limit < $1.limit }
            .map {
                ChargeHold(
                    reason: ChargeHold.reason(forPolicy: $0.reason), policyName: $0.reason,
                    limitPercent: $0.limit)
            }
    }
}

/// Stands in for powerd's `ChargeCtrlPolicy` class while unarchiving; only the
/// fields that say what the policy does are kept.
@objc(MPMChargePolicyRecord)
private final class ChargePolicyRecord: NSObject, NSCoding {
    let reason: String
    let limit: Int
    let terminated: Bool

    init?(coder: NSCoder) {
        reason = (coder.decodeObject(forKey: "reason") as? String) ?? ""
        limit = coder.decodeInteger(forKey: "soclimit")
        terminated = coder.decodeBool(forKey: "terminated")
    }

    func encode(with coder: NSCoder) {}
}
