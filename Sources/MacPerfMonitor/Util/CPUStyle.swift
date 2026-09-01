import MacPerfMonitorCore
import SwiftUI

/// A glanceable band for total CPU load, mirroring `PressureLevel`'s role for
/// memory. The thresholds are deliberately calm — sustained high CPU is normal
/// during real work — so green covers everyday use and only a near-pinned
/// machine reads red.
enum CPULevel: Int, CaseIterable {
    case light
    case busy
    case heavy

    /// Classify a total-CPU fraction (0...1 of capacity).
    init(fraction: Double) {
        switch fraction {
        case ..<0.6: self = .light
        case ..<0.85: self = .busy
        default: self = .heavy
        }
    }

    var color: Color {
        switch self {
        case .light: return .green
        case .busy: return .orange
        case .heavy: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .light: return "cpu"
        case .busy: return "gauge.with.dots.needle.67percent"
        case .heavy: return "flame.fill"
        }
    }

    var label: String {
        switch self {
        case .light: return t("Light")
        case .busy: return t("Busy")
        case .heavy: return t("Heavy")
        }
    }
}

extension CoreKind {
    /// Single-letter badge for a per-core chip ("P" / "E").
    var badge: String {
        switch self {
        case .performance: return "P"
        case .efficiency: return "E"
        case .unknown: return "•"
        }
    }

    /// Cluster name for tooltips and legends.
    ///
    /// The keys say "cores" where the rendered English says only "Performance",
    /// because a bare "Performance" also titles a Settings section and the two
    /// need different Chinese words. `en.lproj` maps these keys back to the short
    /// English wording, so the English interface is unchanged.
    var label: String {
        switch self {
        case .performance: return t("Performance cores")
        case .efficiency: return t("Efficiency cores")
        case .unknown: return t("Core")
        }
    }

    /// Cluster accent, used for the P/E badges and cluster headers. Distinct from
    /// the per-core load colour, which always tracks utilisation.
    var accent: Color {
        switch self {
        case .performance: return .blue
        case .efficiency: return .teal
        case .unknown: return .gray
        }
    }
}
