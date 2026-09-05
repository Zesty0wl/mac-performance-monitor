import MacPerfMonitorCore
import SwiftUI

/// A compact network-throughput trend: download as a filled teal band, upload as
/// an orange line over it. Bytes-per-second on the Y axis, in human rate units.
/// Drawn with the lightweight Canvas `TrendChart`.
struct NetworkChart: View {
    let download: LiveColumn
    let upload: LiveColumn
    var xDomain: ClosedRange<Date>? = nil
    var yDomain: ClosedRange<Double>? = nil
    var showsTimeAxis: Bool = false

    init(
        points: [SystemHistoryPoint], xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil, showsTimeAxis: Bool = false
    ) {
        self.init(
            download: LiveColumn(
                points, value: { $0.networkInBytesPerSec },
                high: { $0.effectivePeaks.networkInBytesPerSec }),
            upload: LiveColumn(
                points, value: { $0.networkOutBytesPerSec },
                high: { $0.effectivePeaks.networkOutBytesPerSec }),
            xDomain: xDomain, yDomain: yDomain, showsTimeAxis: showsTimeAxis)
    }

    /// The live Dashboard path: zero-copy columns of the window.
    init(
        window: SystemHistoryWindow, xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil, showsTimeAxis: Bool = false
    ) {
        self.init(
            download: LiveColumn(window, .networkInBytesPerSec, peak: .networkInPeak),
            upload: LiveColumn(window, .networkOutBytesPerSec, peak: .networkOutPeak),
            xDomain: xDomain, yDomain: yDomain, showsTimeAxis: showsTimeAxis)
    }

    private init(
        download: LiveColumn, upload: LiveColumn, xDomain: ClosedRange<Date>?,
        yDomain: ClosedRange<Double>?, showsTimeAxis: Bool
    ) {
        self.download = download
        self.upload = upload
        self.xDomain = xDomain
        self.yDomain = yDomain
        self.showsTimeAxis = showsTimeAxis
    }

    private var accessibilitySummary: String {
        guard let latestIn = download.lastValue, let latestOut = upload.lastValue else {
            return t("No data yet.")
        }
        let peak = max(download.range?.max ?? 0, upload.range?.max ?? 0)
        if peak < 1 { return t("No network traffic over the shown window.") }
        return t(
            "Currently %1$@ down, %2$@ up. Peak %3$@ over the shown window.",
            ByteFormat.rate(latestIn), ByteFormat.rate(latestOut), ByteFormat.rate(peak))
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: LiveTrend.allPoints(download), color: NetworkStyle.download),
                TrendSeries(
                    points: LiveTrend.allPoints(upload), color: NetworkStyle.upload,
                    lineWidth: 1.8),
            ],
            xDomain: xDomain,
            yDomain: yDomain,
            yFormat: { ByteFormat.rate(max($0, 0)) },
            showsTimeAxis: showsTimeAxis,
            leftGutter: 56
        )
        .accessibilityLabel("Network throughput trend")
        .accessibilityValue(accessibilitySummary)
    }
}
