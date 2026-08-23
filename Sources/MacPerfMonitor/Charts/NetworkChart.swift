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
            download: LiveColumn(points) { $0.networkInBytesPerSec },
            upload: LiveColumn(points) { $0.networkOutBytesPerSec },
            xDomain: xDomain, yDomain: yDomain, showsTimeAxis: showsTimeAxis)
    }

    /// The live Dashboard path: zero-copy columns of the window.
    init(
        window: SystemHistoryWindow, xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil, showsTimeAxis: Bool = false
    ) {
        self.init(
            download: LiveColumn(window, .networkInBytesPerSec),
            upload: LiveColumn(window, .networkOutBytesPerSec),
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
            return "No data yet."
        }
        let peak = max(download.range?.max ?? 0, upload.range?.max ?? 0)
        if peak < 1 { return "No network traffic over the shown window." }
        return
            "Currently \(ByteFormat.rate(latestIn)) down, \(ByteFormat.rate(latestOut)) up. "
            + "Peak \(ByteFormat.rate(peak)) over the shown window."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: LiveTrend.points(download, xDomain: xDomain),
                    color: NetworkStyle.download, filled: true),
                TrendSeries(
                    points: LiveTrend.points(upload, xDomain: xDomain),
                    color: NetworkStyle.upload, filled: false, lineWidth: 1.8),
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
