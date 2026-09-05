import AppKit
import MacPerfMonitorCore
import SwiftUI

/// One line (with optional area fill) on a live chart surface, as the raw
/// window column it is drawn from. The surface buckets the samples itself,
/// anchored to absolute time, so it can paint each column once and slide it
/// (see `TrendSurfaceView`). `scale` multiplies every value (CPU load 0...1
/// is shown as a percentage).
struct TrendSurfaceSeries {
    /// What the line through a bucket of samples should be. See rule 2 in
    /// docs/chart-rules.md: the reduction belongs to the metric, not the chart.
    enum Reduction {
        /// "How loaded was it": the mean, with the extremes drawn as a band.
        case mean
        /// "Did it spike": the maximum. Temperatures and fan speeds, where an
        /// average erases the event worth seeing.
        case maximum
    }

    var column: LiveColumn
    var scale: Double = 1
    var color: Color
    var filled = false
    var lineWidth: CGFloat = 2
    var reduction: Reduction = .mean
    /// Whether the spread of each bucket is drawn behind the line. Off for a
    /// companion line (the 5 and 15 minute load averages beside the 1 minute
    /// one), where three overlapping bands would only muddy the strip.
    var band = true
}

/// What a live chart surface draws: the same inputs as `TrendChart`, as a
/// value that is replaced whole on each tick.
struct TrendModel {
    var series: [TrendSurfaceSeries] = []
    var xDomain: ClosedRange<Date>?
    var yDomain: ClosedRange<Double>?
    var yTicks: [Double]?
    var yFormat: (Double) -> String = { String(Int($0)) }
    var rules: [TrendRule] = []
    var showsTimeAxis = false
    var timeAxis: TrendChart.TimeAxis = .clock
    var gapThreshold: TimeInterval?
    var plotBorder = false
    var leftGutter: CGFloat = 38
    /// A sparkline: the plot fills the view, nothing static is drawn.
    var bare = false
    var accessibilityLabel = "Trend"
    var accessibilityValue = ""
}

/// A live chart's data channel: the current model and the surfaces listening
/// for the next one. The store that owns the window publishes into it on every
/// tick; each attached surface repaints. Nothing in the SwiftUI tree observes
/// it, which is the point: a 4 Hz tick never re-evaluates or re-lays-out a
/// SwiftUI view, it repaints a few pixels. Main thread only.
final class TrendFeed {
    private(set) var model = TrendModel()
    private var observers: [UUID: () -> Void] = [:]

    func publish(_ model: TrendModel) {
        self.model = model
        for observer in observers.values { observer() }
    }

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

/// A `TrendChart` drawn by an AppKit view that repaints itself from a
/// `TrendFeed`. Use this for anything that updates at the dial rate; the
/// SwiftUI `TrendChart` remains for charts that update on a range change or a
/// slow cadence.
///
/// Why an NSView: in SwiftUI any view that re-renders inside a scroll view
/// invalidates the layout of the whole scrolled content, so five charts at
/// 4 Hz re-measured the entire Dashboard 20 times a second (about a third of
/// the main thread). This view's size is whatever SwiftUI proposes and never
/// changes from the inside, so a tick costs only the repaint.
struct LiveTrendChart: NSViewRepresentable {
    let feed: TrendFeed
    var scrubbable = false

    func makeNSView(context: Context) -> TrendSurfaceView {
        let view = TrendSurfaceView()
        view.scrubbable = scrubbable
        view.attach(feed)
        return view
    }

    func updateNSView(_ view: TrendSurfaceView, context: Context) {
        view.scrubbable = scrubbable
        if view.feed !== feed { view.attach(feed) }
    }

    static func dismantleNSView(_ view: TrendSurfaceView, coordinator: ()) {
        view.detach()
    }
}

/// The surface itself: a strip chart that scrolls by moving pixels, the way a
/// chart recorder or an oscilloscope does, rather than repainting them.
///
/// Repainting five retina-resolution area charts four times a second was the
/// largest main-thread cost left once SwiftUI was out of the tick path; the
/// pixels were almost all the same as the tick before, shifted left by a
/// fraction of a point. So the series now live in a `stripLayer` wider than
/// the plot, drawn one column per bucket of absolute time
/// (`LiveStripBuckets`), and a tick does three cheap things: repaint the last
/// few columns (the bucket still filling and its neighbours, a few points
/// wide), move the strip left by the tick's share of a column, and redraw the
/// small wall-clock label strip when a label crosses a pixel. Core Animation
/// composites the translation. The whole strip is repainted only when
/// something that changes every column changes: the range, the value axis,
/// the plot size, a series colour, the appearance, or the strip running out
/// of room to the right (every quarter window, it is re-homed).
///
/// Layers, bottom to top: the view's own backing layer (value gridlines and
/// labels, threshold rules, border, and the static "ago" time axis), the
/// plot-sized `clipLayer` holding the strip, the `axisLayer` with moving
/// wall-clock labels, and the `overlayLayer` with the scrub read-out. None of
/// this touches AppKit layout: the layers are positioned directly and the
/// view's size is whatever SwiftUI proposes.
final class TrendSurfaceView: LiveSurfaceView {
    private(set) var feed: TrendFeed?
    private var observation: UUID?
    private var scrubFraction: CGFloat?
    private var trackingArea: NSTrackingArea?
    private let labels = ChartLabelCache()

    private let clipLayer = CALayer()
    private let stripLayer = CALayer()
    private let axisLayer = CALayer()
    private let overlayLayer = CALayer()
    /// A dot riding the newest raw sample at the live edge. On long ranges a
    /// tick moves the trace by a fraction of a pixel, so this is what shows
    /// the dial rate; it is a plain layer moved by Core Animation, never
    /// repainted.
    private let markerLayer = CALayer()
    private var markerColor: NSColor?
    private static let markerRadius: CGFloat = 3
    private var layersInstalled = false

    /// Plot rectangle in view coordinates (flipped, so y grows downward).
    private var plot = CGRect.zero

    /// The strip's mapping from buckets of absolute time to columns.
    private struct Strip {
        /// Seconds per bucket; one bucket is one point of strip width.
        var bucketWidth: Double
        /// The bucket drawn at strip column 0.
        var home: Int
        /// Strip width in points (columns).
        var width: Int
        /// The newest bucket whose column has been painted.
        var drawnThrough: Int
    }
    private var strip: Strip?
    private var stripKey: StripKey?
    private var fullRedraw = false

    /// Everything the static layer depends on; it repaints only on a change.
    private struct StaticKey: Equatable {
        var size: CGSize
        var leftGutter: CGFloat
        var showsTimeAxis: Bool
        var timeAxis: TrendChart.TimeAxis
        var plotBorder: Bool
        var domain: ClosedRange<Double>
        var ticks: [Double]
        var tickLabels: [String]
        var rules: [TrendRule]
        var span: Double
        var appearance: NSAppearance.Name
    }
    private var staticKey: StaticKey?

    /// Everything that changes every column of the strip at once.
    private struct StripKey: Equatable {
        struct Style: Equatable {
            var color: Color
            var filled: Bool
            var lineWidth: CGFloat
            var scale: Double
        }
        var bucketWidth: Double
        var height: CGFloat
        var domain: ClosedRange<Double>
        var gapThreshold: Double
        var styles: [Style]
        var clockGrid: Bool
        var appearance: NSAppearance.Name
        var contentsScale: CGFloat
    }

    /// The current tick's frame of reference, shared by the painters.
    fileprivate struct TickFrame {
        var tMin: Double
        var tMax: Double
        var span: Double
        var domain: ClosedRange<Double>
        var gapThreshold: Double
        var hasTime: Bool
    }
    fileprivate var tick = TickFrame(
        tMin: 0, tMax: 0, span: 1, domain: 0...1, gapThreshold: 30, hasTime: false)

    private struct AxisLabel: Equatable {
        var text: String
        var x: CGFloat
    }
    private var axisLabels: [AxisLabel] = []
    /// Formatted wall-clock labels by tick time, so a tick formats only the
    /// label that just entered the window rather than every label.
    private var clockLabels: [Double: (step: Double, text: String)] = [:]
    private var gradients: [String: CGGradient] = [:]

    var scrubbable = false {
        didSet { if scrubbable != oldValue { updateTrackingAreas() } }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        installLayersIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { detach() }

    // MARK: Feed

    func attach(_ feed: TrendFeed) {
        detach()
        self.feed = feed
        observation = feed.observe { [weak self] in self?.feedDidPublish() }
        feedDidPublish()
    }

    func detach() {
        if let feed, let observation { feed.stopObserving(observation) }
        observation = nil
        feed = nil
    }

    private func feedDidPublish() {
        guard let model = feed?.model else { return }
        // `t(_:)` looks the string up as a key; a value some other file has
        // already fully interpolated (numbers baked in) simply falls back to
        // itself, matching prior behaviour, while a plain literal like "Trend"
        // timeline name or "No data yet." resolves against the shared table
        // regardless of which caller (SwiftUI or AppKit-driven) set it.
        setAccessibilityLabel(t(model.accessibilityLabel))
        setAccessibilityValue(t(model.accessibilityValue))
        update()
    }

    // MARK: Layers and geometry

    private func installLayersIfNeeded() {
        guard !layersInstalled, let backing = layer else { return }
        layersInstalled = true
        for sub in [clipLayer, stripLayer, axisLayer, overlayLayer, markerLayer] { configure(sub) }
        clipLayer.masksToBounds = true
        overlayLayer.isHidden = true
        axisLayer.isHidden = true
        markerLayer.isHidden = true
        markerLayer.bounds = CGRect(
            x: 0, y: 0, width: 2 * Self.markerRadius, height: 2 * Self.markerRadius)
        markerLayer.cornerRadius = Self.markerRadius
        markerLayer.borderWidth = 1
        clipLayer.addSublayer(stripLayer)
        backing.addSublayer(clipLayer)
        backing.addSublayer(axisLayer)
        backing.addSublayer(markerLayer)
        backing.addSublayer(overlayLayer)
        applyScale()
    }

    override var scaledLayers: [CALayer] { [contentLayer, stripLayer, axisLayer, overlayLayer] }

    private func layoutLayers() {
        clipLayer.frame = plot
        overlayLayer.frame = plot
        axisLayer.frame = CGRect(x: plot.minX, y: plot.maxY + 3, width: plot.width, height: 14)
        stripLayer.bounds = CGRect(
            x: 0, y: 0, width: stripLayer.bounds.width, height: plot.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installLayersIfNeeded()
        applyScale()
        fullRedraw = true
        update()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fullRedraw = true
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        labels.invalidate()
        gradients.removeAll()
        fullRedraw = true
        invalidateContent()
        axisLayer.setNeedsDisplay()
        overlayLayer.setNeedsDisplay()
        update()
    }

    override func sizeDidChange() {
        update()
    }

    // MARK: Per-tick update

    /// Reconcile the layers with the feed's model: repaint the static layer if
    /// its inputs changed, extend (or rebuild) the strip, slide it, and refresh
    /// the wall-clock labels if one moved a pixel.
    private func update() {
        guard let model = feed?.model, layersInstalled else { return }
        let geometry =
            model.bare
            ? TrendChartGeometry.bare
            : TrendChartGeometry(
                leftGutter: model.leftGutter, showsTimeAxis: model.showsTimeAxis,
                plotBorder: model.plotBorder)
        let newPlot = geometry.plotRect(in: bounds.size)
        let (tMin, tMax) = Self.timeBounds(model)
        let span = max(tMax - tMin, 0.0001)
        let domain = Self.resolvedDomain(model)
        let gapThreshold = model.gapThreshold ?? max(span / 24, 30)
        let hasTime = tMax > tMin && newPlot.width >= 2 && newPlot.height >= 2
        tick = TickFrame(
            tMin: tMin, tMax: tMax, span: span, domain: domain, gapThreshold: gapThreshold,
            hasTime: hasTime)

        let ticks = model.yTicks ?? TrendChart.defaultTicks(domain)
        let newStatic = StaticKey(
            size: bounds.size, leftGutter: model.leftGutter, showsTimeAxis: model.showsTimeAxis,
            timeAxis: model.timeAxis, plotBorder: model.plotBorder, domain: domain, ticks: ticks,
            tickLabels: ticks.map(model.yFormat), rules: model.rules, span: span,
            appearance: effectiveAppearance.name)
        if newStatic != staticKey {
            staticKey = newStatic
            invalidateContent()
        }

        // Layer changes ride the implicit transaction that commits at the end
        // of this run-loop pass. An explicit begin/commit here would be the
        // outermost transaction on the tick's main-queue block and would run
        // AppKit's whole display cycle (window layout included) once per
        // surface; the painter delegate already vetoes implicit animations.
        if newPlot != plot {
            plot = newPlot
            layoutLayers()
            strip = nil
        }

        guard hasTime, !model.series.isEmpty else {
            clipLayer.isHidden = true
            axisLayer.isHidden = true
            markerLayer.isHidden = true
            strip = nil
            return
        }
        clipLayer.isHidden = false
        updateMarker(model, domain: domain)

        let bucketWidth = span / Double(plot.width)
        let live = LiveStripBuckets.index(of: tMax, width: bucketWidth)
        let visibleColumns = Int(plot.width.rounded(.up))
        let clockGrid = model.showsTimeAxis && model.timeAxis == .clock
        let newKey = StripKey(
            bucketWidth: bucketWidth, height: plot.height, domain: domain,
            gapThreshold: gapThreshold,
            styles: model.series.map {
                StripKey.Style(
                    color: $0.color, filled: $0.filled, lineWidth: $0.lineWidth, scale: $0.scale)
            },
            clockGrid: clockGrid, appearance: effectiveAppearance.name,
            contentsScale: deviceScale)

        var dirtyFrom: Int?
        if var current = strip, newKey == stripKey, live >= current.home,
            live - current.home < current.width - 1
        {
            // Extend: the bucket still filling plus its neighbours, whose
            // joins depend on it, are repainted; everything older is final.
            // The line is a curve whose slope at a point depends on both
            // neighbours, so a new sample also reshapes the segment before the
            // previous one: repaint back past two sample spacings (the gap
            // threshold is three) so that segment gets its final tangent.
            let reach = Int((2 * gapThreshold / 3 / bucketWidth).rounded(.up))
            dirtyFrom = max(current.drawnThrough - 3 - reach, current.home)
            current.drawnThrough = live
            strip = current
        } else {
            // Rebuild or re-home: the live bucket starts a window's width plus
            // one column in, leaving a quarter window of room to slide into.
            stripKey = newKey
            let width = visibleColumns + max(64, visibleColumns / 4)
            strip = Strip(
                bucketWidth: bucketWidth, home: live - visibleColumns - 1, width: width,
                drawnThrough: live)
            stripLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: plot.height)
            gradients.removeAll()
            fullRedraw = true
        }
        guard let strip else { return }

        if fullRedraw {
            fullRedraw = false
            stripLayer.setNeedsDisplay()
        } else if let dirtyFrom {
            let x0 = CGFloat(dirtyFrom - strip.home)
            let x1 = CGFloat(live - strip.home + 1)
            stripLayer.setNeedsDisplay(CGRect(x: x0, y: 0, width: x1 - x0, height: plot.height))
        }

        // Slide: the live edge (tMax) sits at the plot's right edge.
        let liveX = CGFloat(tMax / bucketWidth - Double(strip.home))
        stripLayer.position = CGPoint(x: snap(plot.width - liveX), y: 0)

        if clockGrid {
            axisLayer.isHidden = false
            let step = TrendChart.clockTickStep(forSpan: span)
            var newLabels: [AxisLabel] = []
            for t in TrendChart.clockTickTimes(from: tMin, to: tMax, step: step) {
                let text: String
                if let hit = clockLabels[t], hit.step == step {
                    text = hit.text
                } else {
                    if clockLabels.count > 64 { clockLabels.removeAll(keepingCapacity: true) }
                    text = TrendChart.clockTickLabel(t, step: step)
                    clockLabels[t] = (step, text)
                }
                newLabels.append(
                    AxisLabel(text: text, x: snap(CGFloat((t - tMin) / span) * plot.width)))
            }
            if newLabels != axisLabels {
                axisLabels = newLabels
                axisLayer.setNeedsDisplay()
            }
        } else {
            axisLayer.isHidden = true
        }
        if scrubFraction != nil { overlayLayer.setNeedsDisplay() }
    }

    /// Place the live-edge dot on the first series' newest raw sample.
    private func updateMarker(_ model: TrendModel, domain: ClosedRange<Double>) {
        guard !model.bare, let first = model.series.first,
            let last = TrendRenderer.lineEndValue(
                first, smoothingSeconds: TrendRenderer.smoothingSeconds(span: tick.span))
        else {
            markerLayer.isHidden = true
            return
        }
        let color = NSColor(first.color)
        if color != markerColor {
            markerColor = color
            markerLayer.backgroundColor = color.cgColor
            markerLayer.borderColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        }
        let value = last
        let y = plot.maxY - CGFloat(LiveChartGeometry.normalizedY(value, in: domain)) * plot.height
        let r = Self.markerRadius
        markerLayer.position = CGPoint(x: snap(plot.maxX - r), y: snap(y - r))
        markerLayer.isHidden = false
    }

    // MARK: Painting

    /// The static layer: value axis, threshold rules, border, "ago" axis.
    override func paint(in ctx: CGContext, dirty: CGRect) {
        guard let model = feed?.model, !model.bare else { return }
        TrendRenderer.drawStatic(
            model, plot: plot, domain: tick.domain, span: tick.span, hasTime: tick.hasTime,
            context: ctx, labels: labels)
    }

    override func paintLayer(_ layer: CALayer, in ctx: CGContext) {
        guard layer !== contentLayer else {
            super.paintLayer(layer, in: ctx)
            return
        }
        let dirty = Self.prepare(ctx, height: layer.bounds.height)
        ctx.clear(dirty)
        ctx.clip(to: dirty)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if layer === stripLayer {
                paintStrip(in: ctx, dirty: dirty)
            } else if layer === axisLayer {
                paintAxis(in: ctx)
            } else if layer === overlayLayer {
                paintOverlay(in: ctx)
            }
        }
    }

    private func paintStrip(in ctx: CGContext, dirty: CGRect) {
        guard let model = feed?.model, let strip, tick.hasTime else { return }
        let height = stripLayer.bounds.height
        let first = strip.home + Int(dirty.minX.rounded(.down)) - 2
        let last = strip.home + Int(dirty.maxX.rounded(.up)) + 2
        TrendRenderer.drawColumns(
            model, tick: tick, bucketWidth: strip.bucketWidth, home: strip.home,
            buckets: first...last, height: height, context: ctx, gradients: &gradients)
    }

    private func paintAxis(in ctx: CGContext) {
        let height = axisLayer.bounds.height
        let strip = CGRect(x: 0, y: 0, width: axisLayer.bounds.width, height: height)
        for label in axisLabels {
            let laid = labels.label(label.text, style: .axis)
            let (at, anchor) = TrendChartGeometry.timeLabelPlacement(x: label.x, y: 0, in: strip)
            let originX: CGFloat
            switch anchor {
            case .topLeading: originX = at.x
            case .topTrailing: originX = at.x - laid.size.width
            default: originX = at.x - laid.size.width / 2
            }
            laid.draw(at: CGPoint(x: originX, y: at.y), in: ctx)
        }
    }

    private func paintOverlay(in ctx: CGContext) {
        guard let model = feed?.model, let scrubFraction, tick.hasTime,
            let point = TrendRenderer.nearestPoint(model, fraction: scrubFraction, tick: tick)
        else { return }
        TrendRenderer.drawScrub(
            model, point: point, tick: tick, plot: overlayLayer.bounds, context: ctx,
            labels: labels)
    }

    // MARK: Scrubbing

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard scrubbable else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { scrub(to: event) }
    override func mouseDragged(with event: NSEvent) { scrub(to: event) }
    override func mouseDown(with event: NSEvent) { scrub(to: event) }

    override func mouseExited(with event: NSEvent) {
        guard scrubFraction != nil else { return }
        scrubFraction = nil
        overlayLayer.isHidden = true
    }

    private func scrub(to event: NSEvent) {
        guard scrubbable, feed?.model != nil, plot.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let fraction = min(max((point.x - plot.minX) / max(plot.width, 1), 0), 1)
        if scrubFraction != fraction {
            scrubFraction = fraction
            overlayLayer.isHidden = false
            overlayLayer.setNeedsDisplay()
        }
    }

    // MARK: Model helpers

    fileprivate static func resolvedDomain(_ model: TrendModel) -> ClosedRange<Double> {
        if let yDomain = model.yDomain { return yDomain }
        var peak = 0.0
        for s in model.series {
            if let top = s.column.range?.max { peak = max(peak, top * s.scale) }
        }
        return 0...LiveChartGeometry.niceCeiling(max(peak * 1.1, 1))
    }

    fileprivate static func timeBounds(_ model: TrendModel) -> (Double, Double) {
        if let xDomain = model.xDomain {
            return (
                xDomain.lowerBound.timeIntervalSinceReferenceDate,
                xDomain.upperBound.timeIntervalSinceReferenceDate
            )
        }
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for s in model.series {
            if let first = s.column.times.first, first < lo { lo = first }
            if let last = s.column.times.last, last > hi { hi = last }
        }
        return lo <= hi ? (lo, hi) : (0, 0)
    }
}

/// Laid-out labels for the chart renderers, cached by text and style.
final class ChartLabelCache {
    enum Style {
        case axis
        case rule(NSColor)
        case readoutTime
        case readoutValue
        /// Legend text: caption2 (10 pt), secondary, monospaced digits.
        case legend
        /// Legend name: caption (11 pt), primary.
        case legendName

        var key: String {
            switch self {
            case .axis: return "axis"
            case .rule(let color): return "rule:\(color.description)"
            case .readoutTime: return "time"
            case .readoutValue: return "value"
            case .legend: return "legend"
            case .legendName: return "legendName"
            }
        }

        var attributes: [NSAttributedString.Key: Any] {
            switch self {
            // CoreText wants CGColors; these resolve against the appearance
            // current when the label is built, which is the view's own
            // (entries are only made inside `draw`).
            case .axis:
                return [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.secondaryLabelColor.cgColor,
                ]
            case .rule(let color):
                return [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: color.cgColor]
            case .readoutTime:
                return [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1),
                    .foregroundColor: NSColor.secondaryLabelColor.cgColor,
                ]
            case .readoutValue:
                return [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor.cgColor,
                ]
            case .legend:
                return [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor.cgColor,
                ]
            case .legendName:
                return [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.labelColor.cgColor,
                ]
            }
        }
    }

    private var cache: [String: ChartLabel] = [:]

    /// The laid-out line for `text` in `style`, built once and reused on every
    /// tick. Colours are resolved for the current appearance when the entry is
    /// made (inside `draw`, where AppKit has set the view's appearance), so the
    /// owning view clears the cache on `viewDidChangeEffectiveAppearance`.
    func label(_ text: String, style: Style) -> ChartLabel {
        let key = style.key + "|" + text
        if let hit = cache[key] { return hit }
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        let entry = ChartLabel(NSAttributedString(string: text, attributes: style.attributes))
        cache[key] = entry
        return entry
    }

    /// Drop every entry, for an appearance change (the cached colours are
    /// resolved) or a font/size change.
    func invalidate() {
        cache.removeAll(keepingCapacity: true)
    }
}

/// A laid-out label: a CoreText line plus its metrics. Drawing a `CTLine` is
/// a glyph run blit; `NSAttributedString.draw(at:)` re-runs the whole Cocoa
/// text layout engine on every call, which at a few dozen labels per tick was
/// about a fifth of a chart's draw time.
struct ChartLabel {
    let line: CTLine
    let size: NSSize
    let ascent: CGFloat

    init(_ attributed: NSAttributedString) {
        line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        self.ascent = ascent
        size = NSSize(width: ceil(width), height: ceil(ascent + descent + leading))
    }

    /// Draw with `origin` as the label's top-left corner, in a flipped (y down)
    /// context such as an `isFlipped` NSView's. The text matrix is not part of
    /// the graphics state, so it is set on every call rather than saved.
    func draw(at origin: CGPoint, in ctx: CGContext) {
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: origin.x, y: origin.y + ascent)
        CTLineDraw(line, ctx)
    }
}

/// Core Graphics painters for the surface's layers, all in flipped (y down)
/// coordinates.
enum TrendRenderer {
    /// A point on the scrubbed series.
    struct Nearest {
        var time: Double
        var value: Double
        var color: Color
    }

    fileprivate typealias TickFrame = TrendSurfaceView.TickFrame

    // MARK: Static layer

    /// Value gridlines and labels, threshold rules, the plot border and, for
    /// the "ago" axis, its gridlines and labels. Painted only when one of
    /// those changes.
    fileprivate static func drawStatic(
        _ model: TrendModel, plot: CGRect, domain: ClosedRange<Double>, span: Double,
        hasTime: Bool, context ctx: CGContext, labels: ChartLabelCache
    ) {
        let ticks = model.yTicks ?? TrendChart.defaultTicks(domain)
        func y(_ v: Double) -> CGFloat {
            plot.maxY - CGFloat(LiveChartGeometry.normalizedY(v, in: domain)) * plot.height
        }
        let gridColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor

        ctx.setLineWidth(0.5)
        for tick in ticks {
            let yy = y(tick)
            ctx.setStrokeColor(gridColor)
            ctx.move(to: CGPoint(x: plot.minX, y: yy))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: yy))
            ctx.strokePath()
            let label = labels.label(model.yFormat(tick), style: .axis)
            label.draw(
                at: CGPoint(x: plot.minX - 5 - label.size.width, y: yy - label.size.height / 2),
                in: ctx)
        }

        for rule in model.rules {
            let yy = y(rule.value)
            let color = NSColor(rule.color)
            ctx.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.move(to: CGPoint(x: plot.minX, y: yy))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: yy))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            let label = labels.label(t(rule.label), style: .rule(color))
            label.draw(at: CGPoint(x: plot.minX + 3, y: yy - 7), in: ctx)
        }

        if model.plotBorder {
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.22).cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(plot)
        }

        if model.showsTimeAxis, model.timeAxis == .ago, hasTime {
            let labelY = plot.maxY + 3
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(0.5)
            for mark in TrendChart.agoTicks(span: span) {
                let xx = plot.minX + CGFloat(mark.fraction) * plot.width
                ctx.move(to: CGPoint(x: xx, y: plot.minY))
                ctx.addLine(to: CGPoint(x: xx, y: plot.maxY))
                ctx.strokePath()
                let label = labels.label(mark.label, style: .axis)
                let (at, anchor) = TrendChartGeometry.timeLabelPlacement(x: xx, y: labelY, in: plot)
                let originX: CGFloat
                switch anchor {
                case .topLeading: originX = at.x
                case .topTrailing: originX = at.x - label.size.width
                default: originX = at.x - label.size.width / 2
                }
                label.draw(at: CGPoint(x: originX, y: at.y), in: ctx)
            }
        }
    }

    // MARK: Strip columns

    /// Paint the series (and, for the clock axis, its gridlines) for the
    /// buckets in `buckets` into strip space: x is `t / bucketWidth - home`
    /// points, y is the plot height flipped. The caller has clipped the
    /// context to the columns being repainted; the path is built from a couple
    /// of buckets either side so joins at the clip edges match a full repaint.
    /// Where the line actually ends: the same trailing reduction the line is
    /// drawn with, so the dot that marks the latest value sits on it rather
    /// than beside it at the raw sample.
    static func lineEndValue(_ series: TrendSurfaceSeries, smoothingSeconds: Double) -> Double? {
        let values = series.column.values
        let times = series.column.times
        guard let lastTime = times.last, !values.isEmpty else { return nil }
        guard smoothingSeconds > 0 else { return values.last.map { $0 * series.scale } }
        let cutoff = lastTime - smoothingSeconds
        var sum = 0.0
        var count = 0
        var peak = -Double.greatestFiniteMagnitude
        var i = times.endIndex - 1
        let valueOffset = values.startIndex - times.startIndex
        while i >= times.startIndex, times[i] >= cutoff {
            let v = values[i + valueOffset]
            sum += v
            peak = Swift.max(peak, v)
            count += 1
            i -= 1
        }
        guard count > 0 else { return values.last.map { $0 * series.scale } }
        let reduced = series.reduction == .maximum ? peak : sum / Double(count)
        return reduced * series.scale
    }

    /// Seconds of history behind each point of the line, aiming for about 120
    /// points across the whole span whatever the range.
    static func smoothingSeconds(span: Double) -> Double {
        span > 0 ? span / 120 : 0
    }

    /// A trailing average of `value` over `seconds` of history, reset at every
    /// gap so a pause does not drag an average across it.
    ///
    /// The window is a duration, not a number of buckets. Buckets are per
    /// column and only exist where a sample landed, so at short ranges most
    /// columns are empty: counting buckets made the window five times longer
    /// than intended and, worse, longer than the history the renderer fetches
    /// for it, so the live edge averaged over less than the rest of the line and
    /// drew a step.
    static func smoothed(
        _ buckets: [LiveStripBuckets.Bucket], seconds: Double, width: Double,
        value: (LiveStripBuckets.Bucket) -> Double
    ) -> [Double] {
        guard seconds > 0, width > 0, buckets.count > 1 else { return buckets.map(value) }
        var out: [Double] = []
        out.reserveCapacity(buckets.count)
        var start = 0
        var sum = 0.0
        var runStart = 0
        for (i, bucket) in buckets.enumerated() {
            if bucket.gapBefore {
                runStart = i
                start = i
                sum = 0
            }
            sum += value(bucket)
            let cutoff = bucketMidTime(bucket, width: width) - seconds
            while start < i, start < buckets.count,
                bucketMidTime(buckets[start], width: width) < cutoff, start >= runStart
            {
                sum -= value(buckets[start])
                start += 1
            }
            out.append(sum / Double(i - start + 1))
        }
        return out
    }

    /// The middle of a bucket in absolute time, so an aggregated line sits at
    /// the centre of the column it summarises rather than at whichever sample
    /// happened to be the extreme.
    fileprivate static func bucketMidTime(
        _ bucket: LiveStripBuckets.Bucket, width: Double
    )
        -> Double
    {
        (Double(bucket.index) + 0.5) * width
    }

    /// The minimum-to-maximum spread of each bucket, as one translucent shape
    /// behind the line. Runs break at gaps, exactly like the line does.
    fileprivate static func drawBand(
        _ buckets: [LiveStripBuckets.Bucket], width: Double, color: NSColor,
        x: (Double) -> CGFloat, y: (Double) -> CGFloat, context ctx: CGContext
    ) {
        var run: [LiveStripBuckets.Bucket] = []
        func flush() {
            defer { run = [] }
            guard run.count > 1 else { return }
            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            top.reserveCapacity(run.count)
            bottom.reserveCapacity(run.count)
            for bucket in run {
                let px = x(bucketMidTime(bucket, width: width))
                top.append(CGPoint(x: px, y: y(bucket.maxValue)))
                bottom.append(CGPoint(x: px, y: y(bucket.minValue)))
            }
            let path = CGMutablePath()
            MonotoneCurve.add(top, to: path)
            MonotoneCurve.add(bottom, to: path, reversed: true, move: false)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color.withAlphaComponent(0.22).cgColor)
            ctx.fillPath()
        }
        for bucket in buckets {
            if bucket.gapBefore { flush() }
            run.append(bucket)
        }
        flush()
    }

    fileprivate static func drawColumns(
        _ model: TrendModel, tick: TickFrame, bucketWidth: Double, home: Int,
        buckets: ClosedRange<Int>, height: CGFloat, context ctx: CGContext,
        gradients: inout [String: CGGradient]
    ) {
        func x(_ t: Double) -> CGFloat { CGFloat(t / bucketWidth - Double(home)) }
        func y(_ v: Double) -> CGFloat {
            height - CGFloat(LiveChartGeometry.normalizedY(v, in: tick.domain)) * height
        }

        if model.showsTimeAxis, model.timeAxis == .clock {
            let step = TrendChart.clockTickStep(forSpan: tick.span)
            let from = Double(buckets.lowerBound) * bucketWidth
            let to = Double(buckets.upperBound + 1) * bucketWidth
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(0.5)
            for t in TrendChart.clockTickTimes(from: from, to: to, step: step) {
                let xx = x(t)
                ctx.move(to: CGPoint(x: xx, y: 0))
                ctx.addLine(to: CGPoint(x: xx, y: height))
            }
            ctx.strokePath()
        }

        // Columns of extra history to the left, so a repaint of a few live
        // columns matches a full one exactly. The first visible curve segment
        // takes its shape from the two points before it, each at most a gap
        // threshold back (further and it is a new run), and each of those needs
        // the full trailing window behind it for its averaged value to agree.
        let smoothing = smoothingColumns(span: tick.span, bucketWidth: bucketWidth)
        let gapColumns = bucketWidth > 0 ? Int((tick.gapThreshold / bucketWidth).rounded(.up)) : 1
        let context = 2 * gapColumns + smoothing + 2

        for s in model.series {
            drawSeries(
                s, span: tick.span, bucketWidth: bucketWidth,
                buckets: (buckets.lowerBound - context)...buckets.upperBound,
                gapThreshold: tick.gapThreshold, x: x, y: y, fillTop: 0, fillBaseline: height,
                context: ctx, gradients: &gradients)
        }
    }

    /// How many columns of history the line averages over. One column holds
    /// two or three samples at an hour's span, and the mean of three noisy
    /// samples is still noisy, so bucketing to pixels barely smooths at all.
    /// Averaging over a window sized from the span does: a target of about
    /// 120 points across the plot puts thirty seconds behind each point at an
    /// hour, three minutes at six hours, and two seconds at five minutes,
    /// where the detail is still the point. See docs/chart-rules.md.
    static func smoothingColumns(span: Double, bucketWidth: Double) -> Int {
        bucketWidth > 0 ? max(1, Int((smoothingSeconds(span: span) / bucketWidth).rounded())) : 1
    }

    /// One series over `buckets`: the band of each column's spread, the
    /// smoothed line as a monotone curve, the optional fill, and a dot for an
    /// isolated reading. This is the whole of how a series is drawn, shared by
    /// the strip (which widens `buckets` to the left so a partial repaint
    /// agrees with a full one) and the Canvas charts (a full redraw of the
    /// visible buckets), so every chart in the app follows the same rules.
    static func drawSeries(
        _ s: TrendSurfaceSeries, span: Double, bucketWidth: Double, buckets: ClosedRange<Int>,
        gapThreshold: Double, x: (Double) -> CGFloat, y: (Double) -> CGFloat, fillTop: CGFloat,
        fillBaseline: CGFloat, context ctx: CGContext, gradients: inout [String: CGGradient]
    ) {
        let smoothingSeconds = smoothingSeconds(span: span)
        let smoothing = smoothingColumns(span: span, bucketWidth: bucketWidth)
        let extremes = LiveStripBuckets.buckets(
            times: s.column.times, values: s.column.values, highs: s.column.highs,
            width: bucketWidth, from: buckets.lowerBound, through: buckets.upperBound,
            gapThreshold: gapThreshold, scale: s.scale)
        guard !extremes.isEmpty else { return }
        let color = NSColor(s.color)

        // More than one sample per column means the samples cannot all be
        // drawn honestly. Rule 3: the line becomes the bucket's reduction
        // and the spread goes behind it as a band, instead of a spike per
        // column that turns a busy metric into a solid block.
        let aggregated = extremes.contains(where: \.isAggregate) || smoothing > 1
        if aggregated, s.band {
            drawBand(extremes, width: bucketWidth, color: color, x: x, y: y, context: ctx)
        }
        let line = TrendRenderer.smoothed(
            extremes, seconds: smoothingSeconds, width: bucketWidth,
            value: { s.reduction == .maximum ? $0.maxValue : $0.mean })

        // Gap-free runs of points in time order.
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (bucket, value) in zip(extremes, line) {
            if bucket.gapBefore, !current.isEmpty {
                runs.append(current)
                current = []
            }
            if aggregated {
                current.append(
                    CGPoint(x: x(bucketMidTime(bucket, width: bucketWidth)), y: y(value)))
            } else {
                for point in bucket.orderedPoints {
                    current.append(CGPoint(x: x(point.time), y: y(point.value)))
                }
            }
        }
        if !current.isEmpty { runs.append(current) }

        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            if run.count == 1 {
                ctx.setFillColor(color.cgColor)
                let r: CGFloat = 1.6
                ctx.fillEllipse(
                    in: CGRect(x: first.x - r, y: first.y - r, width: 2 * r, height: 2 * r))
                continue
            }
            let path = MonotoneCurve.path(run)
            if s.filled, let gradient = gradient(for: color, cache: &gradients) {
                let fill = path.mutableCopy() ?? CGMutablePath()
                fill.addLine(to: CGPoint(x: last.x, y: fillBaseline))
                fill.addLine(to: CGPoint(x: first.x, y: fillBaseline))
                fill.closeSubpath()
                ctx.saveGState()
                ctx.addPath(fill)
                ctx.clip()
                ctx.drawLinearGradient(
                    gradient, start: CGPoint(x: 0, y: fillTop),
                    end: CGPoint(x: 0, y: fillBaseline), options: [])
                ctx.restoreGState()
            }
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(s.lineWidth)
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.bevel)
            ctx.strokePath()
        }
    }

    private static func gradient(
        for color: NSColor, cache: inout [String: CGGradient]
    )
        -> CGGradient?
    {
        let key = color.description
        if let hit = cache[key] { return hit }
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color.withAlphaComponent(0.42).cgColor,
                color.withAlphaComponent(0.04).cgColor,
            ] as CFArray, locations: [0, 1])
        if let gradient { cache[key] = gradient }
        return gradient
    }

    // MARK: Scrub overlay

    fileprivate static func nearestPoint(
        _ model: TrendModel, fraction: CGFloat, tick: TickFrame
    ) -> Nearest? {
        let target = tick.tMin + Double(fraction) * tick.span
        var best: Nearest?
        var bestDistance = Double.greatestFiniteMagnitude
        for s in model.series {
            let times = s.column.times
            guard !times.isEmpty else { continue }
            var lo = times.startIndex
            var hi = times.endIndex
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if times[mid] < target { lo = mid + 1 } else { hi = mid }
            }
            let values = s.column.values
            let valueOffset = values.startIndex - times.startIndex
            for i in [lo - 1, lo] where i >= times.startIndex && i < times.endIndex {
                let distance = abs(times[i] - target)
                if distance < bestDistance {
                    bestDistance = distance
                    best = Nearest(
                        time: times[i], value: values[i + valueOffset] * s.scale, color: s.color)
                }
            }
        }
        return best
    }

    fileprivate static func drawScrub(
        _ model: TrendModel, point: Nearest, tick: TickFrame, plot: CGRect, context ctx: CGContext,
        labels: ChartLabelCache
    ) {
        let xx = plot.minX + CGFloat((point.time - tick.tMin) / tick.span) * plot.width
        let yy =
            plot.maxY - CGFloat(LiveChartGeometry.normalizedY(point.value, in: tick.domain))
            * plot.height
        ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: xx, y: plot.minY))
        ctx.addLine(to: CGPoint(x: xx, y: plot.maxY))
        ctx.strokePath()
        let color = NSColor(point.color)
        ctx.setFillColor(color.cgColor)
        let r: CGFloat = 3
        ctx.fillEllipse(in: CGRect(x: xx - r, y: yy - r, width: 2 * r, height: 2 * r))

        let time = labels.label(
            scrubTimeFormatter.string(from: Date(timeIntervalSinceReferenceDate: point.time)),
            style: .readoutTime)
        let value = labels.label(model.yFormat(point.value), style: .readoutValue)
        let width = max(time.size.width, value.size.width) + 12
        let height = time.size.height + value.size.height + 7
        let originX = min(max(xx - width / 2, plot.minX), plot.maxX - width)
        let box = CGRect(x: originX, y: plot.minY + 2, width: width, height: height)
        let rounded = CGPath(
            roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(rounded)
        ctx.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor)
        ctx.fillPath()
        ctx.addPath(rounded)
        ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        time.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), in: ctx)
        value.draw(
            at: CGPoint(x: box.minX + 6, y: box.minY + 3 + time.size.height + 1), in: ctx)
    }

    private static let scrubTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Hmmss")
        return formatter
    }()
}
