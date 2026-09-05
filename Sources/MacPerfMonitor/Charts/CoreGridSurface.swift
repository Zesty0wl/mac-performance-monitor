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

final class CoreGridSurfaceView: LiveSurfaceView {
    static let legendHeight: CGFloat = 14
    private(set) var feed: CoreGridFeed?
    private var observation: UUID?
    private let labels = ChartLabelCache()
    var barHeight: CGFloat = 44 { didSet { invalidateContent() } }
    private var shownCoreCount = -1

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
    }

    private var orderedCores: [CoreUsage] {
        let cores = feed?.cores ?? []
        return cores.filter { $0.kind != .efficiency } + cores.filter { $0.kind == .efficiency }
    }

    private func feedDidPublish() {
        let cores = orderedCores
        if cores.count != shownCoreCount {
            shownCoreCount = cores.count
            refreshToolTips(cores)
        }
        setAccessibilityValue(
            cores.map { "Core \($0.index) \(Int(($0.usage * 100).rounded())) percent" }
                .joined(separator: ", "))
        invalidateContent()
    }

    override func layout() {
        super.layout()
        refreshToolTips(orderedCores)
    }

    private func refreshToolTips(_ cores: [CoreUsage]) {
        removeAllToolTips()
        guard !cores.isEmpty else { return }
        let width = (bounds.width - 3 * CGFloat(cores.count - 1)) / CGFloat(cores.count)
        for (i, core) in cores.enumerated() {
            let rect = NSRect(x: CGFloat(i) * (width + 3), y: 0, width: width, height: barHeight)
            addToolTip(
                rect, owner: t("Core %1$@ · %2$@", String(core.index), core.kind.label) as NSString,
                userData: nil)
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
        let spacing: CGFloat = 3
        let width = (bounds.width - spacing * CGFloat(cores.count - 1)) / CGFloat(cores.count)
        // Quiet: eleven empty tracks used to carry more weight on screen than
        // the fills inside them.
        let track = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        for (i, core) in cores.enumerated() {
            let x = CGFloat(i) * (width + spacing)
            let full = CGRect(x: x, y: 0, width: width, height: barHeight)
            context.setFillColor(track.cgColor)
            context.addPath(
                CGPath(roundedRect: full, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            context.fillPath()
            let fillHeight = max(2, barHeight * CGFloat(min(max(core.usage, 0), 1)))
            let fill = CGRect(x: x, y: barHeight - fillHeight, width: width, height: fillHeight)
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
            guard !group.isEmpty else { return 0 }
            return Int((group.reduce(0.0) { $0 + $1.usage } / Double(group.count) * 100).rounded())
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
