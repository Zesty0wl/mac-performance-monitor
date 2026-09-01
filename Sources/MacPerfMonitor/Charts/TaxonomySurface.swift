import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The live memory-taxonomy breakdown as a self-painting AppKit view: one
/// stacked bar whose slices sum to total RAM, and a legend with each
/// category's bytes and share. The SwiftUI `TaxonomySection` drew the bar with
/// Swift Charts and the legend in a lazy grid, re-laid-out every second.
final class TaxonomyFeed {
    private(set) var slices: [TaxonomySlice] = []
    private(set) var total: UInt64 = 0
    private var observers: [UUID: () -> Void] = [:]

    func publish(slices: [TaxonomySlice], total: UInt64) {
        guard slices != self.slices || total != self.total else { return }
        self.slices = slices
        self.total = total
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

struct TaxonomySurface: NSViewRepresentable {
    let feed: TaxonomyFeed

    func makeNSView(context: Context) -> TaxonomySurfaceView {
        let view = TaxonomySurfaceView()
        view.attach(feed)
        return view
    }

    func updateNSView(_ view: TaxonomySurfaceView, context: Context) {
        if view.feed !== feed { view.attach(feed) }
    }

    static func dismantleNSView(_ view: TaxonomySurfaceView, coordinator: ()) {
        view.detach()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: TaxonomySurfaceView, context: Context
    )
        -> CGSize?
    {
        let width = proposal.width ?? 260
        return CGSize(
            width: width,
            height: TaxonomySurfaceView.height(forWidth: width, slices: feed.slices.count))
    }
}

final class TaxonomySurfaceView: LiveSurfaceView {
    static let barHeight: CGFloat = 30
    static let legendSpacing: CGFloat = 12
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 8
    static let minColumnWidth: CGFloat = 132

    static func columns(forWidth width: CGFloat) -> Int {
        max(1, Int((width + rowSpacing) / (minColumnWidth + rowSpacing)))
    }

    static func height(forWidth width: CGFloat, slices: Int) -> CGFloat {
        guard slices > 0 else { return 16 }
        let rows = Int(ceil(Double(slices) / Double(columns(forWidth: width))))
        return barHeight + legendSpacing + CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1))
            * rowSpacing
    }

    private(set) var feed: TaxonomyFeed?
    private var observation: UUID?
    private let labels = ChartLabelCache()
    private var shownSliceCount = -1

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(t("Memory composition"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { detach() }

    func attach(_ feed: TaxonomyFeed) {
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
        guard let feed else { return }
        if feed.slices.count != shownSliceCount {
            shownSliceCount = feed.slices.count
            invalidateIntrinsicContentSize()
            refreshToolTips()
        }
        setAccessibilityValue(
            t(
                "Memory taxonomy: %@",
                feed.slices.map { "\($0.name) \(percent($0.bytes))" }.joined(separator: ", ")))
        invalidateContent()
    }

    override func layout() {
        super.layout()
        refreshToolTips()
    }

    private func percent(_ bytes: UInt64) -> String {
        guard let total = feed?.total, total > 0 else { return "0%" }
        return String(format: "%.0f%%", Double(bytes) / Double(total) * 100)
    }

    /// Legend cell rects in reading order, for drawing and tooltips.
    private func legendRects() -> [CGRect] {
        guard let feed else { return [] }
        let columns = Self.columns(forWidth: bounds.width)
        let cellWidth = (bounds.width - Self.rowSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        return feed.slices.indices.map { i in
            let row = i / columns
            let column = i % columns
            return CGRect(
                x: CGFloat(column) * (cellWidth + Self.rowSpacing),
                y: Self.barHeight + Self.legendSpacing + CGFloat(row)
                    * (Self.rowHeight + Self.rowSpacing),
                width: cellWidth, height: Self.rowHeight)
        }
    }

    private func refreshToolTips() {
        removeAllToolTips()
        guard let feed else { return }
        for (slice, rect) in zip(feed.slices, legendRects()) {
            addToolTip(rect, owner: slice.explanation as NSString, userData: nil)
        }
    }

    /// The label cache holds colours resolved for one appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        labels.invalidate()
        invalidateContent()
    }

    override func paint(in context: CGContext, dirty: CGRect) {
        guard let feed else { return }
        guard !feed.slices.isEmpty else {
            labels.label(t("Collecting the first sample…"), style: .axis).draw(
                at: .zero, in: context)
            return
        }
        // The stacked bar, clipped to a rounded rect.
        let bar = CGRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        context.saveGState()
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.clip()
        let total = Double(max(feed.total, 1))
        var x: CGFloat = 0
        for slice in feed.slices {
            let width = bounds.width * CGFloat(Double(slice.bytes) / total)
            context.setFillColor(NSColor(slice.category.color).cgColor)
            context.fill(CGRect(x: x, y: 0, width: width, height: Self.barHeight))
            x += width
        }
        context.restoreGState()

        // The legend.
        for (slice, rect) in zip(feed.slices, legendRects()) {
            context.setFillColor(NSColor(slice.category.color).cgColor)
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: rect.minX, y: rect.minY + 8, width: 11, height: 11),
                    cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            let name = labels.label(slice.name, style: .legendName)
            name.draw(at: CGPoint(x: rect.minX + 18, y: rect.minY), in: context)
            let detail = labels.label(
                "\(ByteFormat.string(slice.bytes)) · \(percent(slice.bytes))", style: .legend)
            detail.draw(
                at: CGPoint(x: rect.minX + 18, y: rect.minY + name.size.height + 1), in: context)
        }
    }
}
