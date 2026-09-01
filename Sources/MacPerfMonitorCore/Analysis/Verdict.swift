import Foundation

/// The dashboard's "what to do" verdict: a plain-language reading of the current
/// memory situation. M4 ships a basic rule set driven by the pressure level and
/// swap; the full insights engine (M7) replaces the internals while keeping this
/// shape.
public struct Verdict: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case good, caution, alert }

    public var tone: Tone
    public var headline: String
    public var detail: String?

    /// Whether this verdict should be surfaced as a prominent banner. Healthy
    /// ("good") states are shown as a compact one-line status instead, so a
    /// normal Mac is not dominated by an always-present banner.
    public var needsAttention: Bool { tone != .good }

    public init(tone: Tone, headline: String, detail: String? = nil) {
        self.tone = tone
        self.headline = headline
        self.detail = detail
    }
}

public enum DashboardVerdict {
    /// Swap above this fraction of total RAM counts as "heavy" swapping.
    static let heavySwapFraction = 0.05

    public static func compute(system: SystemSample, topProcess: ProcessSample?) -> Verdict {
        let topName = topProcess?.name
        let heavySwap =
            system.totalRAM > 0
            && Double(system.swapUsed) / Double(system.totalRAM) >= heavySwapFraction

        switch system.pressureLevel {
        case .critical:
            if heavySwap, let topName {
                return Verdict(
                    tone: .alert,
                    headline: t("Swapping heavily"),
                    detail: t(
                        "Your Mac is moving memory to disk to cope. Consider quitting %@, the largest consumer.",
                        topName)
                )
            }
            return Verdict(
                tone: .alert,
                headline: t("Under heavy pressure"),
                detail: topName.map {
                    t("Memory is critically tight. %@ is the largest consumer.", $0)
                }
                    ?? t("Memory is critically tight.")
            )

        case .warning:
            return Verdict(
                tone: .caution,
                headline: t("Under pressure"),
                detail: topName.map { t("%@ is the largest consumer right now.", $0) }
                    ?? t("Memory is getting tight.")
            )

        case .normal:
            // Swap being in use at normal pressure is expected on macOS and is
            // not actionable, so it is not flagged here. Swap is still shown in
            // the headline numbers and the swap trend for anyone who wants it.
            return Verdict(
                tone: .good,
                headline: t("All good"),
                detail: t(
                    "Memory is comfortable. Cached files are reclaimable and nothing to worry about."
                )
            )
        }
    }
}
