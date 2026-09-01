import MacPerfMonitorCore
import SwiftUI

/// A live per-core utilisation strip: every logical core as a vertical bar on a
/// single row, each filling to the core's current load. Colour distinguishes the
/// clusters — performance cores in blue, efficiency cores in teal — with a small
/// legend below carrying the cluster averages. On Intel (a single tier) the bars
/// share one colour under a "Cores" legend. Shared by the CPU menubar panel and
/// the dashboard Processor section.
///
/// Bars are ordered performance cluster first, then efficiency, to match the
/// legend — see `orderedCores`.
struct CoreGridView: View {
    let cores: [CoreUsage]
    /// Height of the bar track. Shorter in the compact menubar panel.
    var barHeight: CGFloat = 44

    /// Cores in display order: the performance cluster first, then efficiency, so
    /// the bars read left-to-right the same way as the legend below. The raw array
    /// is in `host_processor_info` index order, which puts the efficiency cluster
    /// first on Apple Silicon; presenting performance first keeps every CPU view
    /// consistent. Each bar still carries its true `core.index`.
    private var orderedCores: [CoreUsage] {
        cores.filter { $0.kind != .efficiency } + cores.filter { $0.kind == .efficiency }
    }

    var body: some View {
        if cores.isEmpty {
            Text("Measuring cores…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                // All cores on one row, sharing the width equally so any core
                // count fits without wrapping.
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(orderedCores) { core in
                        bar(core)
                    }
                }
                .frame(height: barHeight)

                legend
            }
        }
    }

    private func bar(_ core: CoreUsage) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.secondary.opacity(0.14))
            .frame(maxWidth: .infinity)
            .frame(height: barHeight)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(core.kind.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, barHeight * core.usage))
            }
            .help(
                t(
                    "Core %1$@ · %2$@ · %3$@%%", String(core.index), core.kind.label,
                    String(loadPercent(core.usage)))
            )
            .accessibilityLabel(
                t(
                    "Core %1$@, %2$@, %3$@ percent", String(core.index), core.kind.label,
                    String(loadPercent(core.usage))))
    }

    // MARK: - Legend

    @ViewBuilder private var legend: some View {
        let efficiency = cores.filter { $0.kind == .efficiency }
        let performance = cores.filter { $0.kind != .efficiency }
        HStack(spacing: 14) {
            if efficiency.isEmpty {
                // Single tier (Intel, or before the split is known).
                legendItem(CoreKind.performance.accent, "Cores · %1$@ · %2$@%%", performance)
            } else {
                legendItem(
                    CoreKind.performance.accent, "Performance · %1$@ · %2$@%%", performance)
                legendItem(CoreKind.efficiency.accent, "Efficiency · %1$@ · %2$@%%", efficiency)
            }
            Spacer(minLength: 0)
        }
    }

    /// `template` carries the cluster name and both figures in a single key, so a
    /// translation can reorder them or attach a measure word to the count. The
    /// same three keys back the AppKit legend in `CoreGridSurface`, which keeps
    /// the two surfaces reading identically.
    private func legendItem(_ color: Color, _ template: String, _ cores: [CoreUsage]) -> some View {
        let average = cores.isEmpty ? 0 : cores.reduce(0.0) { $0 + $1.usage } / Double(cores.count)
        return HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(t(template, String(cores.count), String(loadPercent(average))))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func loadPercent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }
}
