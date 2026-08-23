import MacPerfMonitorCore
import SwiftUI

/// Average device service time per operation. The latency fields are optional
/// (nil marks an interval with no IO), so each series carries only the points
/// that have a value: `TrendChart`'s gap splitting then leaves quiet stretches
/// blank instead of bridging them or drawing a misleading 0 ms floor.
struct DiskLatencyChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false

    private var readPoints: [TrendPoint] {
        points.compactMap { point in
            point.diskReadLatencyMs.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var writePoints: [TrendPoint] {
        points.compactMap { point in
            point.diskWriteLatencyMs.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var accessibilitySummary: String {
        let reads = readPoints
        let writes = writePoints
        guard !reads.isEmpty || !writes.isEmpty else {
            return "No disk activity with measurable latency in the shown window."
        }
        var parts: [String] = []
        if let read = reads.last {
            parts.append(String(format: "read %.2f milliseconds per operation", read.value))
        }
        if let write = writes.last {
            parts.append(String(format: "write %.2f milliseconds per operation", write.value))
        }
        return "Latest " + parts.joined(separator: ", ") + "."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: readPoints, color: DiskStyle.read, filled: false),
                TrendSeries(
                    points: writePoints, color: DiskStyle.write, filled: false, lineWidth: 1.8),
            ],
            xDomain: xDomain,
            yFormat: { String(format: "%.1f ms", max($0, 0)) },
            showsTimeAxis: showsTimeAxis
        )
        .accessibilityLabel("Disk service time trend")
        .accessibilityValue(accessibilitySummary)
    }
}
