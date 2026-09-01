import Charts
import MacPerfMonitorCore
import SwiftUI

/// The live memory-taxonomy breakdown: a single horizontal stacked bar whose
/// slices sum to total RAM, with a plain-language legend. Hovering a legend row
/// explains the category (the educational copy from `TaxonomyCategory`). The
/// section header is supplied by the enclosing dashboard panel.
struct TaxonomySection: View {
    let slices: [TaxonomySlice]
    let total: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if slices.isEmpty {
                Text("Collecting the first sample…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                stackedBar
                legend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stackedBar: some View {
        Chart(slices) { slice in
            BarMark(
                x: .value("Bytes", Double(slice.bytes)),
                y: .value("RAM", "RAM")
            )
            .foregroundStyle(by: .value("Category", slice.name))
        }
        .chartForegroundStyleScale(
            domain: slices.map(\.name),
            range: slices.map { $0.category.color }
        )
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(
            t(
                "Memory taxonomy: %@",
                slices.map { "\($0.name) \(percent($0.bytes))" }.joined(separator: ", ")))
    }

    private var legend: some View {
        // Adaptive columns so the legend reads cleanly both at full dashboard
        // width and in the narrower stats rail (where it folds to two columns).
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(slices) { slice in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(slice.category.color)
                        .frame(width: 11, height: 11)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slice.name)
                            .font(.caption)
                        Text("\(ByteFormat.string(slice.bytes)) · \(percent(slice.bytes))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .help(slice.explanation)
            }
        }
    }

    private func percent(_ bytes: UInt64) -> String {
        guard total > 0 else { return "0%" }
        let p = Double(bytes) / Double(total) * 100
        return String(format: "%.0f%%", p)
    }
}
