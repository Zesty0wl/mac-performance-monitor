import AppKit
import MacPerfMonitorCore
import SwiftUI

/// A metric card's live channel: the headline value and the sparkline series,
/// published by the owning store on every tick and painted by AppKit views
/// that sit inside the otherwise static SwiftUI card. Main thread only.
///
/// The sparkline is a bare `TrendSurfaceView` (no axes, no padding) driven
/// through `trend`, so it scrolls by sliding pixels like the page's charts
/// instead of restroking its whole path four times a second.
/// A secondary line drawn on a card strip in the strip's own tint, fainter and
/// thinner than the main one: the 5 and 15 minute load averages beside the
/// 1 minute line, the way beszel shows load.
struct MetricCardCompanion {
    /// Legend label for the detail sheet, a catalog key such as "5 min".
    var label: String
    var column: LiveColumn
    var alpha: CGFloat
    var lineWidth: CGFloat = 1.2
}

final class MetricCardFeed {
    private(set) var value: String?

    /// The largest value in the window, already formatted. Drawn in the corner
    /// of the strip so a bare sparkline has something to read against.
    private(set) var peak: String?
    private(set) var tint: NSColor = .labelColor
    /// The raw window column behind the sparkline, zero-copy.
    private(set) var column: LiveColumn?
    private(set) var companions: [MetricCardCompanion] = []
    private(set) var scale: Double = 1
    private(set) var xDomain: ClosedRange<Date>?
    private(set) var yDomain: ClosedRange<Double>?
    /// The sparkline's own feed, republished from `publish`.
    let trend = TrendFeed()
    private var observers: [UUID: () -> Void] = [:]

    func publish(
        value: String?, tint: NSColor, column: LiveColumn?, scale: Double = 1,
        xDomain: ClosedRange<Date>?, yDomain: ClosedRange<Double>?, peak: String? = nil,
        reduction: TrendSurfaceSeries.Reduction = .mean, companions: [MetricCardCompanion] = []
    ) {
        self.value = value
        self.peak = peak
        self.tint = tint
        self.column = column
        self.companions = companions
        self.scale = scale
        self.xDomain = xDomain
        self.yDomain = yDomain
        var model = TrendModel()
        model.bare = true
        if let column {
            // Companions go first so the main line is drawn over them.
            model.series = companions.map { companion in
                TrendSurfaceSeries(
                    column: companion.column, scale: scale,
                    color: Color(nsColor: tint.withAlphaComponent(companion.alpha)),
                    lineWidth: companion.lineWidth, reduction: reduction, band: false)
            }
            model.series.append(
                TrendSurfaceSeries(
                    column: column, scale: scale, color: Color(nsColor: tint), lineWidth: 1.5,
                    reduction: reduction))
        }
        model.xDomain = xDomain
        model.yDomain = yDomain
        model.gapThreshold = xDomain.map {
            max($0.upperBound.timeIntervalSince($0.lowerBound) / 24, 30)
        }
        trend.publish(model)
        for observer in observers.values { observer() }
    }

    /// The sparkline's series as timestamped samples, for the detail sheet.
    /// Every sample, with its stored peak: the sheet's chart reduces at draw
    /// time like every other chart (docs/chart-rules.md, rule 1). Built on
    /// demand, when the sheet opens, not on every tick.
    var samples: [MetricSample] {
        guard let column else { return [] }
        return Self.samples(column, scale: scale)
    }

    /// The companion lines the same way, labelled for the sheet's legend.
    var companionSamples: [MetricCompanionSamples] {
        companions.map {
            MetricCompanionSamples(
                label: $0.label, alpha: $0.alpha, samples: Self.samples($0.column, scale: scale))
        }
    }

    private static func samples(_ column: LiveColumn, scale: Double) -> [MetricSample] {
        LiveTrend.allPoints(column).map {
            MetricSample(date: $0.date, value: $0.value * scale, high: $0.high.map { $0 * scale })
        }
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

/// The card's sparkline as a self-scrolling AppKit surface.
struct LiveSparkline: NSViewRepresentable {
    let feed: MetricCardFeed
    var lineWidth: CGFloat = 1.5

    func makeNSView(context: Context) -> TrendSurfaceView {
        let view = TrendSurfaceView()
        view.setAccessibilityElement(false)
        view.attach(feed.trend)
        return view
    }

    func updateNSView(_ view: TrendSurfaceView, context: Context) {
        if view.feed !== feed.trend { view.attach(feed.trend) }
    }

    static func dismantleNSView(_ view: TrendSurfaceView, coordinator: ()) {
        view.detach()
    }
}

/// The card's headline figure as an AppKit label that updates in place. Its
/// reported size is constant, so a new value never re-lays-out the card.
struct LiveValueLabel: NSViewRepresentable {
    let feed: MetricCardFeed
    var height: CGFloat = 22

    func makeNSView(context: Context) -> LiveValueField {
        let field = LiveValueField(fixedHeight: height)
        field.attach(feed)
        return field
    }

    func updateNSView(_ field: LiveValueField, context: Context) {
        if field.feed !== feed { field.attach(feed) }
    }

    static func dismantleNSView(_ field: LiveValueField, coordinator: ()) {
        field.detach()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: LiveValueField, context: Context
    )
        -> CGSize?
    {
        CGSize(width: proposal.width ?? 120, height: height)
    }
}

final class LiveValueField: NSTextField {
    private(set) var feed: MetricCardFeed?
    private var observation: UUID?
    private let fixedHeight: CGFloat

    init(fixedHeight: CGFloat) {
        self.fixedHeight = fixedHeight
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        textColor = .labelColor
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { detach() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fixedHeight)
    }

    /// See `LiveTextField.invalidateIntrinsicContentSize`: the value changes
    /// four times a second and never changes this field's size, so the
    /// invalidation `NSTextField` raises on every `stringValue` set must not
    /// reach SwiftUI's host, which would re-lay out the whole window for it.
    override func invalidateIntrinsicContentSize() {}

    func attach(_ feed: MetricCardFeed) {
        detach()
        self.feed = feed
        observation = feed.observe { [weak self] in self?.refresh() }
        refresh()
    }

    func detach() {
        if let feed, let observation { feed.stopObserving(observation) }
        observation = nil
        feed = nil
    }

    private func refresh() {
        let value = feed?.value ?? "--"
        if stringValue != value { stringValue = value }
    }
}
