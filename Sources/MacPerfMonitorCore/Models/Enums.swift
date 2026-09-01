import Foundation

/// CPU architecture a process is executing as.
public enum Architecture: String, Codable, Sendable, CaseIterable {
    case arm64
    // swift-format-ignore: AlwaysUseLowerCamelCase
    case x86_64
    case unknown

    /// Display label suitable for badges.
    ///
    /// NOT localised, and must never be: `TraceExport` serialises this exact
    /// string into the `architecture` field of an exported `.mpmtrace`, so
    /// translating it would write locale-dependent values into a portable file
    /// format and break traces shared between machines. These are also the
    /// architecture's real names, which read the same in every language.
    public var label: String {
        switch self {
        case .arm64: return "arm64"
        case .x86_64: return "x86_64"
        case .unknown: return "unknown"
        }
    }
}

/// macOS memory pressure level, mirroring `kern.memorystatus_vm_pressure_level`
/// (1 = normal, 2 = warning, 4 = critical).
public enum PressureLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Map the raw sysctl integer onto a level, defaulting unknown values to
    /// `.normal` so the UI never shows a phantom alert.
    public init(rawLevel: Int) {
        switch rawLevel {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }

    public var label: String {
        switch self {
        case .normal: return t("Normal")
        case .warning: return t("Warning")
        case .critical: return t("Critical")
        }
    }
}

/// Where a process sample's data came from, so the UI can be honest about
/// coverage gaps.
public enum SampleSource: String, Codable, Sendable {
    /// Read directly by the unprivileged app via libproc.
    case directUserRead
    /// Read by the privileged root helper on the app's behalf, for processes the
    /// unprivileged app cannot inspect (system and other-user processes).
    case privilegedHelper
}
