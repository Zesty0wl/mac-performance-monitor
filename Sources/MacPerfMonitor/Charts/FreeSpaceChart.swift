import MacPerfMonitorCore
import SwiftUI

/// Boot volume free space over the selected range: the "is the disk filling
/// up" chart. Draws a dashed warning rule at 10 percent of the volume's
/// capacity when the total is known.
struct FreeSpaceChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false

    private var freePoints: [TrendPoint] {
        points.compactMap { point in
            point.bootFreeBytes.map { TrendPoint(date: point.date, value: Double($0)) }
        }
    }

    private var totalBytes: UInt64? {
        points.reversed().compactMap(\.bootTotalBytes).first
    }

    private var accessibilitySummary: String {
        guard let latest = freePoints.last else { return t("No free space history yet.") }
        let free = ByteFormat.string(UInt64(max(0, latest.value)))
        let down: String? = {
            guard let first = freePoints.first, first.value > latest.value else { return nil }
            return ByteFormat.string(UInt64(first.value - latest.value))
        }()
        switch (totalBytes, down) {
        case (nil, nil):
            return t("Currently %@ free.", free)
        case (let total?, nil):
            return t("Currently %1$@ free of %2$@.", free, ByteFormat.string(total))
        case (nil, let down?):
            return t("Currently %1$@ free, down %2$@ over the window.", free, down)
        case (let total?, let down?):
            return t(
                "Currently %1$@ free of %2$@, down %3$@ over the window.", free,
                ByteFormat.string(total), down)
        }
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: freePoints, color: DiskStyle.read, filled: true)
            ],
            xDomain: xDomain,
            // Anchor the domain at zero up to the disk's capacity so the line's
            // height reads as "how much of the disk is left", not an auto-zoomed
            // wiggle that makes a stable disk look like a cliff.
            yDomain: totalBytes.map { 0...Double($0) },
            yFormat: { ByteFormat.string(UInt64(max($0, 0))) },
            rules: totalBytes.map {
                [
                    TrendRule(
                        value: Double($0) * 0.10, label: "Low", color: .orange)
                ]
            } ?? [],
            showsTimeAxis: showsTimeAxis,
            leftGutter: 56
        )
        .accessibilityLabel("Boot volume free space trend")
        .accessibilityValue(accessibilitySummary)
    }
}
