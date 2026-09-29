import MacPerfMonitorCore
import SwiftUI

/// A shared badge for sustained footprint growth, not a memory-leak diagnosis.
struct LeakIndicator: View {
    /// Kept for existing callers; the badge does not present a leak probability.
    var confidence: Double? = nil
    /// The symbol point size, so the badge can match the type around it.
    var size: Font = .caption

    var body: some View {
        Image(systemName: "arrow.up.right.circle")
            .font(size)
            .foregroundStyle(.orange)
            .symbolRenderingMode(.hierarchical)
            .help(helpText)
            .accessibilityLabel(accessibilityText)
    }

    private var helpText: String {
        t("Memory has been growing steadily. Growth alone does not prove a memory leak.")
    }

    private var accessibilityText: String {
        t("Sustained memory growth")
    }
}
