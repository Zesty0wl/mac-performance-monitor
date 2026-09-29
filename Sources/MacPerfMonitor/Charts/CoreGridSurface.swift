import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The per-core utilisation strip as a self-painting AppKit view: every
/// logical core as a vertical bar, performance cluster first, with a legend
/// carrying the cluster averages. The SwiftUI `CoreGridView` drew the same
/// picture from eleven views that re-laid-out the page once a second.
final class CoreGridFeed {
    private(set) var cores: [CoreUsage] = []
    private var observers: [UUID: () -> Void] = [:]

    func publish(_ cores: [CoreUsage]) {
        self.cores = cores
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

struct CoreGridSurface: NSViewRepresentable {
    let feed: CoreGridFeed
    var barHeight: CGFloat = 44

    func makeNSView(context: Context) -> CoreGridSurfaceView {
        let view = CoreGridSurfaceView()
        view.barHeight = barHeight
        view.attach(feed)
        return view
    }

    func updateNSView(_ view: CoreGridSurfaceView, context: Context) {
        view.barHeight = barHeight
        if view.feed !== feed { view.attach(feed) }
    }

    static func dismantleNSView(_ view: CoreGridSurfaceView, coordinator: ()) {
        view.detach()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: CoreGridSurfaceView, context: Context
    )
        -> CGSize?
    {
        CGSize(
            width: proposal.width ?? 200, height: barHeight + 7 + CoreGridSurfaceView.legendHeight)
    }
}

final class CoreGridSurfaceView: LiveSurfaceView, NSViewToolTipOwner {
    static let legendHeight: CGFloat = 14
    private(set) var feed: CoreGridFeed?
    private var observation: UUID?
    private let labels = ChartLabelCache()
    var barHeight: CGFloat = 44 {
        didSet {
            guard barHeight != oldValue else { return }
            refreshToolTips(orderedCores)
            invalidateContent()
        }
    }
    private var shownCoreIndices: [Int] = []
    private var toolTipCoreIndices: [NSView.ToolTipTag: Int] = [:]

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("CPU cores")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { detach() }

    func attach(_ feed: CoreGridFeed) {
        detach()
        self.feed = feed
        observation = feed.observe { [weak self] in self?.feedDidPublish() }
        feedDidPublish()
    }

    func detach() {
        if let feed, let observation { feed.stopObserving(observation) }
        observation = nil
        feed = nil
        shownCoreIndices = []
        toolTipCoreIndices.removeAll()
        removeAllToolTips()
    }

    private var orderedCores: [CoreUsage] {
        let cores = feed?.cores ?? []
        return cores.filter { $0.kind != .efficiency } + cores.filter { $0.kind == .efficiency }
    }

    private func feedDidPublish() {
        let cores = orderedCores
        let indices = cores.map(\.index)
        if indices != shownCoreIndices {
            shownCoreIndices = indices
            refreshToolTips(cores)
        }
        setAccessibilityValue(
            cores.map { coreDescription($0) }.joined(separator: ", "))
        invalidateContent()
    }

    override func layout() {
        super.layout()
        refreshToolTips(orderedCores)
    }

    override func sizeDidChange() {
        super.sizeDidChange()
        refreshToolTips(orderedCores)
    }

    private func refreshToolTips(_ cores: [CoreUsage]) {
        removeAllToolTips()
        toolTipCoreIndices.removeAll(keepingCapacity: true)
        for (core, rect) in zip(cores, coreRects(count: cores.count)) {
            let hitRect = rect.intersection(bounds)
            guard !hitRect.isNull, hitRect.width > 0, hitRect.height > 0 else { continue }
            let tag = addToolTip(hitRect, owner: self, userData: nil)
            toolTipCoreIndices[tag] = core.index
        }
    }

    /// The owner reads the current feed when AppKit requests a tooltip. A
    /// string captured when the core count changed would stay stale forever.
    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let index = toolTipCoreIndices[tag],
            let core = feed?.cores.first(where: { $0.index == index })
        else { return "" }
        return coreDescription(core)
    }

    private func coreDescription(_ core: CoreUsage) -> String {
        func value(_ fraction: Double) -> String {
            fraction.isFinite
                ? String(format: "%.1f%%", fraction * 100) : t("Unavailable")
        }
        let kind = core.kind == .unknown ? t("Unknown core type") : core.kind.label
        return t(
            "Core %1$@ · %2$@\nCurrent busy %3$@ · User %4$@ · System %5$@",
            String(core.index), kind, value(core.usage), value(core.user), value(core.system))
    }

    /// Shared geometry keeps the drawn bars and their hover targets aligned,
    /// including on machines with many cores in a narrow rail.
    private func coreRects(count: Int) -> [CGRect] {
        guard count > 0, bounds.width.isFinite, bounds.width > 0,
            barHeight.isFinite, barHeight > 0
        else { return [] }
        let spacing = min(3, bounds.width / CGFloat(count) * 0.2)
        let width = (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { i in
            CGRect(x: CGFloat(i) * (width + spacing), y: 0, width: width, height: barHeight)
        }
    }

    /// The label cache holds colours resolved for one appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        labels.invalidate()
        invalidateContent()
    }

    override func paint(in context: CGContext, dirty: CGRect) {
        let cores = orderedCores
        guard !cores.isEmpty else {
            labels.label("Measuring cores…", style: .axis).draw(at: .zero, in: context)
            return
        }
        // Quiet: eleven empty tracks used to carry more weight on screen than
        // the fills inside them.
        let track = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        for (core, full) in zip(cores, coreRects(count: cores.count)) {
            context.setFillColor(track.cgColor)
            context.addPath(
                CGPath(roundedRect: full, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            context.fillPath()
            guard core.usage.isFinite else { continue }
            let fillHeight = max(2, barHeight * CGFloat(min(max(core.usage, 0), 1)))
            let fill = CGRect(
                x: full.minX, y: barHeight - fillHeight, width: full.width, height: fillHeight)
            context.setFillColor(NSColor(core.kind.accent).cgColor)
            context.addPath(
                CGPath(roundedRect: fill, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            context.fillPath()
        }

        // Legend: cluster averages.
        let efficiency = cores.filter { $0.kind == .efficiency }
        let performance = cores.filter { $0.kind != .efficiency }
        var items: [(NSColor, String)] = []
        func average(_ group: [CoreUsage]) -> Int {
            let measured = group.filter { $0.usage.isFinite }
            guard !measured.isEmpty else { return 0 }
            return Int(
                (measured.reduce(0.0) { $0 + min(max($1.usage, 0), 1) }
                    / Double(measured.count) * 100).rounded())
        }
        if efficiency.isEmpty {
            items.append(
                (
                    NSColor(CoreKind.performance.accent),
                    t(
                        "Cores · %1$@ · %2$@%%", String(performance.count),
                        String(average(performance)))
                ))
        } else {
            items.append(
                (
                    NSColor(CoreKind.performance.accent),
                    t(
                        "Performance · %1$@ · %2$@%%", String(performance.count),
                        String(average(performance)))
                ))
            items.append(
                (
                    NSColor(CoreKind.efficiency.accent),
                    t(
                        "Efficiency · %1$@ · %2$@%%", String(efficiency.count),
                        String(average(efficiency)))
                ))
        }
        var x: CGFloat = 0
        let y = barHeight + 7
        for (color, text) in items {
            context.setFillColor(color.cgColor)
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: x, y: y + 2, width: 9, height: 9), cornerWidth: 2,
                    cornerHeight: 2, transform: nil))
            context.fillPath()
            let label = labels.label(text, style: .legend)
            label.draw(at: CGPoint(x: x + 14, y: y), in: context)
            x += 14 + label.size.width + 14
        }
    }
}
