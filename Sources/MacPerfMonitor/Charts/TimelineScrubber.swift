import Charts
import MacPerfMonitorCore
import SwiftUI

/// A draggable time-range scrubber shown under the Analytics charts. It draws
/// the whole loaded span as a horizontal track with a date axis, and a
/// highlighted "brush" marking the currently visible window. Dragging the brush
/// body pans; dragging either edge (or scroll / pinch over the track) zooms;
/// dragging empty track rubber-bands a new window. Every interaction reports the
/// requested window back to the parent, which owns the clamping and drives the
/// shared visible domain, so in the grid all charts pan and zoom together.
struct TimelineScrubber: View {
    /// The whole loaded span: the outer bounds the brush can cover.
    let fullDomain: ClosedRange<Date>
    /// The currently visible sub-window (equal to `fullDomain` when not zoomed).
    let visibleDomain: ClosedRange<Date>
    /// Tightest allowed window, matched to the charts' minimum zoom span.
    var minSpan: TimeInterval = 20
    /// Request a new visible window. The parent clamps it into `fullDomain`,
    /// enforces `minSpan`, and snaps back to "no zoom" when it covers the span.
    var onScrub: (ClosedRange<Date>) -> Void
    /// Zoom about a date on the track; `factor` > 1 zooms in.
    var onZoom: (_ anchor: Date, _ factor: Double) -> Void
    /// Shift the visible window; positive moves it later in time.
    var onPan: (_ deltaSeconds: TimeInterval) -> Void

    private static let trackHeight: CGFloat = 46
    /// Visual width of each edge grip (also the resize cursor's hit area).
    private static let handleWidth: CGFloat = 16
    /// The brush must be at least this wide before edge-resize is offered, so a
    /// narrow (zoomed-in) brush always pans as a whole instead of resizing.
    private static let minResizeBrushWidth: CGFloat = 48

    @State private var drag: DragState?
    /// Previous pinch magnification, so each change reports an incremental factor.
    @State private var magnifyLast: CGFloat = 1

    private struct DragState {
        enum Kind { case pan, resizeLeft, resizeRight }
        let kind: Kind
        let startWindow: ClosedRange<Date>
        /// The date under the cursor when the drag began, so a pan keeps that
        /// point pinned under the pointer and never jumps on first touch.
        let startCursor: Date
    }

    var body: some View {
        chart
            .frame(height: Self.trackHeight)
            .accessibilityLabel("Timeline")
            .accessibilityHint("Drag to pan and zoom every chart at once.")
    }

    // MARK: - Chart track

    private var chart: some View {
        Chart {
            // Invisible anchors so the x-scale and its axis lay out even though
            // the track carries no data marks of its own.
            RuleMark(x: .value("Start", fullDomain.lowerBound))
                .foregroundStyle(.clear)
            RuleMark(x: .value("End", fullDomain.upperBound))
                .foregroundStyle(.clear)
        }
        .chartXScale(domain: fullDomain)
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.14))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: xLabelFormat)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.border(Color.secondary.opacity(0.22), width: 0.5)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                overlay(proxy: proxy, geo: geo)
            }
        }
    }

    // MARK: - Brush overlay

    private func overlay(proxy: ChartProxy, geo: GeometryProxy) -> some View {
        let plot = proxy.plotFrame.map { geo[$0] } ?? geo.frame(in: .local)
        let x0 = xPosition(visibleDomain.lowerBound, proxy: proxy, plot: plot)
        let x1 = xPosition(visibleDomain.upperBound, proxy: proxy, plot: plot)
        let handle = Self.handleWidth
        // Only show edge grips when the brush is wide enough to still leave a
        // central pan zone; a narrow brush pans as a whole.
        let canResize = (x1 - x0) >= Self.minResizeBrushWidth
        return ZStack(alignment: .topLeading) {
            // Full-size transparent base so the stack fills the whole track and its
            // coordinate space matches the gesture's. Without it the stack shrinks to
            // its content and centres, drawing the brush and grips offset from where
            // the drag hit-test looks for them, so edge-drags miss the grips and fall
            // through to panning (the resize cursor still shows over the drawn grip).
            Rectangle().fill(.clear)

            // Dim the out-of-view regions on either side of the brush.
            scrim(width: x0 - plot.minX, x: plot.minX, plot: plot)
            scrim(width: plot.maxX - x1, x: x1, plot: plot)

            // The visible window.
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                )
                .frame(width: max(x1 - x0, 2), height: plot.height)
                .offset(x: x0, y: plot.minY)

            // Grabbable edge handles (only when there is room to resize).
            if canResize {
                edgeHandle.frame(width: handle, height: plot.height)
                    .offset(x: x0 - handle / 2, y: plot.minY)
                edgeHandle.frame(width: handle, height: plot.height)
                    .offset(x: x1 - handle / 2, y: plot.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture(proxy: proxy, plot: plot, x0: x0, x1: x1))
        .background(
            ScrollWheelCatcher { location, dx, dy in
                handleScroll(location: location, dx: dx, dy: dy, proxy: proxy, plot: plot)
            }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let factor = value.magnification / max(magnifyLast, 0.0001)
                    magnifyLast = value.magnification
                    let anchor =
                        date(atX: value.startLocation.x, proxy: proxy, plot: plot) ?? mid
                    onZoom(anchor, Double(factor))
                }
                .onEnded { _ in magnifyLast = 1 }
        )
    }

    private func scrim(width: CGFloat, x: CGFloat, plot: CGRect) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(width: max(width, 0), height: plot.height)
            .offset(x: x, y: plot.minY)
    }

    private var edgeHandle: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 4)
                .padding(.vertical, 5)
        }
        .contentShape(Rectangle())
        .pointerStyle(.columnResize)
    }

    // MARK: - Drag

    private func dragGesture(
        proxy: ChartProxy, plot: CGRect, x0: CGFloat, x1: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    drag = beginDrag(
                        startX: value.startLocation.x, proxy: proxy, plot: plot,
                        x0: x0, x1: x1)
                }
                guard let drag else { return }
                let cursor =
                    date(atX: value.location.x, proxy: proxy, plot: plot)
                    ?? drag.startCursor
                switch drag.kind {
                case .pan:
                    // Move the window by the drag delta, keeping its width exactly.
                    // The delta is 0 at the first event, so the charts never jump
                    // on touch; they simply follow the drag.
                    onScrub(
                        shift(drag.startWindow, by: cursor.timeIntervalSince(drag.startCursor)))
                case .resizeLeft:
                    let lo = min(
                        cursor, drag.startWindow.upperBound.addingTimeInterval(-minSpan))
                    onScrub(lo...drag.startWindow.upperBound)
                case .resizeRight:
                    let hi = max(
                        cursor, drag.startWindow.lowerBound.addingTimeInterval(minSpan))
                    onScrub(drag.startWindow.lowerBound...hi)
                }
            }
            .onEnded { _ in drag = nil }
    }

    private func beginDrag(
        startX: CGFloat, proxy: ChartProxy, plot: CGRect, x0: CGFloat, x1: CGFloat
    ) -> DragState {
        let startCursor = date(atX: startX, proxy: proxy, plot: plot) ?? visibleDomain.lowerBound
        // Resize when the drag starts near an edge; pan everywhere else. The edge
        // zone is a capped share of the brush width, so grabbing a grip reliably
        // resizes — a fixed few-px zone was near-impossible to hit, especially in
        // live mode where the edge drifts a few px between ticks — while the
        // center stays a clear pan zone. A narrow brush has no resize zone.
        let brushWidth = x1 - x0
        let edge = min(brushWidth * 0.3, 20)
        let canResize = brushWidth >= Self.minResizeBrushWidth
        let kind: DragState.Kind
        if canResize && abs(startX - x0) <= edge {
            kind = .resizeLeft
        } else if canResize && abs(startX - x1) <= edge {
            kind = .resizeRight
        } else {
            kind = .pan
        }
        return DragState(kind: kind, startWindow: visibleDomain, startCursor: startCursor)
    }

    // MARK: - Scroll wheel / trackpad

    private func handleScroll(
        location: CGPoint, dx: CGFloat, dy: CGFloat, proxy: ChartProxy, plot: CGRect
    ) {
        if abs(dx) > abs(dy) {
            // Horizontal two-finger swipe pans the window along the full track.
            guard plot.width > 0 else { return }
            onPan(-Double(dx / plot.width) * fullSpan)
        } else if dy != 0 {
            let anchor = date(atX: location.x, proxy: proxy, plot: plot) ?? mid
            onZoom(anchor, exp(Double(dy) * 0.006))
        }
    }

    // MARK: - Geometry helpers

    private var fullSpan: TimeInterval {
        max(fullDomain.upperBound.timeIntervalSince(fullDomain.lowerBound), 1)
    }

    private var mid: Date {
        fullDomain.lowerBound.addingTimeInterval(fullSpan / 2)
    }

    private var xLabelFormat: Date.FormatStyle {
        if fullSpan <= 600 { return .dateTime.minute().second() }
        if fullSpan <= 26 * 3600 { return .dateTime.hour().minute() }
        return .dateTime.month(.abbreviated).day()
    }

    private func xPosition(_ date: Date, proxy: ChartProxy, plot: CGRect) -> CGFloat {
        let x = (proxy.position(forX: date) ?? 0) + plot.minX
        return min(max(x, plot.minX), plot.maxX)
    }

    private func date(atX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> Date? {
        let clamped = min(max(x, plot.minX), plot.maxX)
        return proxy.value(atX: clamped - plot.minX)
    }

    private func shift(_ window: ClosedRange<Date>, by delta: TimeInterval) -> ClosedRange<Date> {
        window.lowerBound.addingTimeInterval(delta)...window.upperBound.addingTimeInterval(delta)
    }
}
