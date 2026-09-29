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
    var barHeight: CGFloat = 30

    func makeNSView(context: Context) -> TaxonomySurfaceView {
        let view = TaxonomySurfaceView()
        view.stackHeight = barHeight
        view.attach(feed)
        return view
    }

    func updateNSView(_ view: TaxonomySurfaceView, context: Context) {
        view.stackHeight = barHeight
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
            height: TaxonomySurfaceView.height(
                forWidth: width, slices: feed.slices.count, barHeight: barHeight))
    }
}

final class TaxonomySurfaceView: LiveSurfaceView, NSViewToolTipOwner {
    static let barHeight: CGFloat = 30
    static let legendSpacing: CGFloat = 12
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 8
    static let minColumnWidth: CGFloat = 132

    static func columns(forWidth width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int((width + rowSpacing) / (minColumnWidth + rowSpacing)))
    }

    static func height(forWidth width: CGFloat, slices: Int, barHeight: CGFloat = 30) -> CGFloat {
        guard slices > 0 else { return 16 }
        let rows = Int(ceil(Double(slices) / Double(columns(forWidth: width))))
        return barHeight + legendSpacing + CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1))
            * rowSpacing
    }

    private(set) var feed: TaxonomyFeed?
    private var observation: UUID?
    private let labels = ChartLabelCache()
    private var shownSliceCount = -1
    var stackHeight: CGFloat = TaxonomySurfaceView.barHeight {
        didSet {
            guard stackHeight != oldValue else { return }
            refreshToolTips()
            invalidateContent()
        }
    }

    private struct ToolTipRegion: Equatable {
        let category: TaxonomyCategory
        let rect: CGRect
    }
    private var toolTipRegions: [ToolTipRegion] = []
    private var registeredToolTips: [(region: ToolTipRegion, tag: NSView.ToolTipTag)] = []
    private var toolTipCategories: [NSView.ToolTipTag: TaxonomyCategory] = [:]

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
        shownSliceCount = -1
        toolTipRegions = []
        registeredToolTips = []
        toolTipCategories.removeAll()
        removeAllToolTips()
    }

    private func feedDidPublish() {
        guard let feed else { return }
        if feed.slices.count != shownSliceCount {
            shownSliceCount = feed.slices.count
            invalidateIntrinsicContentSize()
        }
        // Segment widths change with the readings, not just with layout. Only
        // replace the native hit regions; never request layout for a new value.
        refreshToolTips()
        setAccessibilityValue(
            t(
                "Memory taxonomy: %@",
                feed.slices.map {
                    "\($0.name) \(ByteFormat.string($0.bytes)), \(percent($0.bytes))"
                }.joined(separator: ", ")))
        invalidateContent()
    }

    override func layout() {
        super.layout()
        refreshToolTips()
    }

    override func sizeDidChange() {
        super.sizeDidChange()
        refreshToolTips()
    }

    private func percent(_ bytes: UInt64) -> String {
        guard let total = feed?.total, total > 0 else { return t("Share unavailable") }
        return String(format: "%.0f%%", Double(bytes) / Double(total) * 100)
    }

    /// One rect per slice, including zero-width slices so zip stays aligned.
    /// Both the paint path and the native hover regions use these boundaries.
    private func segmentRects() -> [CGRect] {
        guard let feed, feed.total > 0, bounds.width.isFinite, bounds.width > 0,
            stackHeight.isFinite, stackHeight > 0
        else { return [] }
        var x: CGFloat = 0
        return feed.slices.map { slice in
            let width = min(
                bounds.width * CGFloat(Double(slice.bytes) / Double(feed.total)),
                max(0, bounds.width - x))
            let rect = CGRect(x: x, y: 0, width: width, height: stackHeight)
            x += width
            return rect
        }
    }

    /// Legend cell rects in reading order, for drawing and tooltips.
    private func legendRects() -> [CGRect] {
        guard let feed, bounds.width.isFinite, bounds.width > 0 else { return [] }
        let columns = Self.columns(forWidth: bounds.width)
        let cellWidth = (bounds.width - Self.rowSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        return feed.slices.indices.map { i in
            let row = i / columns
            let column = i % columns
            return CGRect(
                x: CGFloat(column) * (cellWidth + Self.rowSpacing),
                y: stackHeight + Self.legendSpacing + CGFloat(row)
                    * (Self.rowHeight + Self.rowSpacing),
                width: cellWidth, height: Self.rowHeight)
        }
    }

    private func refreshToolTips() {
        guard let feed else { return }
        var regions: [ToolTipRegion] = []
        for rects in [segmentRects(), legendRects()] {
            for (slice, rect) in zip(feed.slices, rects) {
                // Subpixel changes must not keep restarting AppKit's hover
                // delay. Native targets follow the visible pixel boundaries.
                let aligned = CGRect(
                    x: snap(rect.minX), y: snap(rect.minY),
                    width: max(0, snap(rect.maxX) - snap(rect.minX)),
                    height: max(0, snap(rect.maxY) - snap(rect.minY)))
                let hitRect = aligned.intersection(bounds)
                guard !hitRect.isNull, hitRect.width > 0, hitRect.height > 0 else { continue }
                regions.append(ToolTipRegion(category: slice.category, rect: hitRect))
            }
        }
        guard regions != toolTipRegions else { return }
        toolTipRegions = regions
        var next: [(region: ToolTipRegion, tag: NSView.ToolTipTag)] = []
        for region in regions {
            if let existing = registeredToolTips.first(where: { $0.region == region }) {
                next.append(existing)
            } else {
                let tag = addToolTip(region.rect, owner: self, userData: nil)
                toolTipCategories[tag] = region.category
                next.append((region: region, tag: tag))
            }
        }
        let kept = Set(next.map(\.tag))
        for existing in registeredToolTips where !kept.contains(existing.tag) {
            removeToolTip(existing.tag)
            toolTipCategories.removeValue(forKey: existing.tag)
        }
        // In particular, stable legend targets survive changes to the stack.
        registeredToolTips = next
    }

    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let feed, let category = toolTipCategories[tag],
            let slice = feed.slices.first(where: { $0.category == category })
        else { return "" }
        let share =
            feed.total > 0
            ? String(format: "%.1f%%", Double(slice.bytes) / Double(feed.total) * 100)
            : t("Share unavailable")
        return t(
            "%1$@: %2$@ (%3$@ bytes)\n%4$@ of %5$@ total RAM\n%6$@",
            slice.name, ByteFormat.string(slice.bytes), slice.bytes.formatted(), share,
            ByteFormat.string(feed.total), slice.explanation)
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
        let bar = CGRect(x: 0, y: 0, width: bounds.width, height: stackHeight)
        context.saveGState()
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.clip()
        for (slice, rect) in zip(feed.slices, segmentRects()) {
            context.setFillColor(NSColor(slice.category.color).cgColor)
            context.fill(rect)
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
