import MacPerfMonitorCore
import SwiftUI

/// A small, consistent "possible memory leak" badge shown beside a process
/// wherever it appears — the process table, the menubar list, the insights
/// consumers, the dashboard — so a suspected leak is obvious at a glance and
/// reads the same on every surface (PRD section 8.5).
struct LeakIndicator: View {
    /// Optional detector confidence (0\u{2026}1) folded into the tooltip; nil
    /// keeps the help text generic.
    var confidence: Double? = nil
    /// The symbol point size, so the badge can match the type around it.
    var size: Font = .caption

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(size)
            .foregroundStyle(.orange)
            .symbolRenderingMode(.hierarchical)
            .help(helpText)
            .accessibilityLabel(accessibilityText)
    }

    private var helpText: String {
        guard let confidence else {
            return t("Possible memory leak \u{00B7} its memory has been climbing steadily.")
        }
        let percent = Int((confidence * 100).rounded())
        return t(
            "Possible memory leak \u{00B7} %@%% confidence. Its memory has been climbing steadily.",
            String(percent))
    }

    private var accessibilityText: String {
        guard let confidence else { return t("Possible memory leak") }
        return t(
            "Possible memory leak, %@ percent confidence",
            String(Int((confidence * 100).rounded())))
    }
}
