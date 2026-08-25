import Foundation

/// macOS's own thermal pressure verdict, mirrored from
/// `ProcessInfo.thermalState`. This is the honest "is the system actually
/// throttling" signal that raw temperatures cannot give: color and alerts key
/// off this, never off an arbitrary degree threshold. Raw values are stable
/// and persisted (higher is worse).
public enum ThermalPressureState: Int, Sendable, Codable, Comparable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    public var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }

    /// True once macOS is visibly slowing work down (fair is only light
    /// fan-and-scheduling adjustment; serious and critical throttle).
    public var isThrottling: Bool { self >= .serious }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
