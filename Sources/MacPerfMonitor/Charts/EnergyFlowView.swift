import AppKit
import MacPerfMonitorCore
import QuartzCore
import SwiftUI

/// One process node in the energy-flow diagram: a stable identity, a display
/// name, an icon path, and its current energy figure. Lightweight so it can be
/// built from a live `ProcessSample` (current draw) without a full
/// `ProcessConsumer`.
struct EnergyFlowProcess: Identifiable {
    let id: ProcessIdentity
    let name: String
    let executablePath: String?
    let energy: Double
}

/// The Battery tab's signature visual: a live energy-flow diagram. The Mac sits
/// at the hub; power sources (the adapter and the battery) feed in from the
/// left, and the heaviest energy-using processes draw out to the right. Each
/// conduit carries animated pulses whose speed and thickness encode the rate of
/// flow, so charging vs. discharging and "who is drawing the power" are legible
/// at a glance — what a single signed wattage number never showed.
///
/// Honesty about units (mirrored in the panel footnote):
///   • Battery and adapter conduits carry **real watts** — `powerWatts`, signed
///     by the charge direction. These are measured.
///   • Process conduits carry **relative energy impact** (CPU + wakeups), not
///     measured watts; macOS exposes no per-process wattage without root. Their
///     pulse rate is each process's share of the shown leaders, so the diagram
///     ranks honestly without inventing per-app watts.
///
/// Motion is the whole point, so it is also the one place we spend it: pulses
/// are the only animation, and under Reduce Motion they freeze into static
/// thickness-coded streams (rate still reads from line weight).
struct EnergyFlowView: View {
    let battery: BatterySample
    /// The heaviest energy users *right now*, ranked by `energy` descending. Fed
    /// from the live snapshot (not a windowed average), so the branches track the
    /// current draw and the diagram stays alive.
    let processes: [EnergyFlowProcess]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState

    /// The most recent system load measured *on battery* — the SMC's SystemLoad,
    /// or the battery discharge rate when that telemetry is unavailable. On AC the
    /// live draw is confounded by charging current and the higher power limits the
    /// SoC runs at on wall power, so the per-app branches reuse this last-known
    /// on-battery load instead — keeping each app's dot at the same speed across a
    /// plug/unplug (the apps' actual work doesn't change when you plug in). Seeded
    /// with a default until the first time on battery.
    @State private var rememberedLoadWatts = Self.defaultLoadWatts
    /// The view size, read via a background GeometryReader, so the lines and the
    /// dots are laid out from one identical size.
    @State private var canvasSize: CGSize = .zero

    /// At most this many process nodes; more would crowd the right column.
    private static let maxProcesses = 5

    /// The system-load estimate used before we've ever measured a discharge
    /// (e.g. launched on AC). Once on battery, `rememberedLoadWatts` replaces it.
    private static let defaultLoadWatts: Double = 12

    private var shownProcesses: [EnergyFlowProcess] {
        Array(processes.prefix(Self.maxProcesses))
    }

    /// Whether this Mac has an internal battery. When false (a desktop — Mac mini,
    /// Studio, iMac) the diagram drops the battery node and draws the wall outlet
    /// feeding the Mac, which in turn feeds the heavy apps.
    private var hasBattery: Bool { battery.isPresent }

    /// The label inside the Mac node: a laptop's charge %, or a desktop's measured
    /// power draw in watts (falling back to "AC" when telemetry is unavailable).
    private var macNodeLabel: String {
        if hasBattery { return BatteryFormat.percent(battery.chargePercent) }
        return battery.systemPowerWatts > 0
            ? BatteryFormat.watts(battery.systemPowerWatts) : t("AC")
    }

    private enum SymbolID: Hashable { case mac, plug }

    var body: some View {
        // ONE source of truth: build the conduits once and hand the SAME links to
        // both the lines (SwiftUI Canvas) and the dots (AppKit). Computing them
        // separately is what let the two disagree — dots flowing from the battery
        // while the line came from the adapter, or in the wrong direction.
        let layout = FlowLayout(
            size: canvasSize, processCount: shownProcesses.count,
            isOnAC: battery.isOnAC, hasBattery: hasBattery)
        let links = energyLinks(
            layout: layout, battery: battery, processes: shownProcesses,
            rememberedLoadWatts: rememberedLoadWatts)
        return ZStack {
            // Conduit lines + labelled nodes. Text is shaped only when this redraws
            // (on a data change), never per animation frame.
            Canvas { ctx, _ in
                for link in links {
                    ctx.stroke(
                        link.path, with: .color(link.color.opacity(0.4)),
                        style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                }
                drawMacNode(ctx, layout: layout)
                if hasBattery { drawBatteryNode(ctx, layout: layout) }
                if battery.isOnAC || !hasBattery { drawAdapterNode(ctx, layout: layout) }
                for (index, consumer) in shownProcesses.enumerated() {
                    drawProcessNode(ctx, consumer: consumer, at: layout.process(index))
                }
            } symbols: {
                Image(systemName: hasBattery ? "laptopcomputer" : "desktopcomputer")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.primary)
                    .tag(SymbolID.mac)
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(BatteryStyle.charger)
                    .tag(SymbolID.plug)
            }

            // Exactly one travelling dot per conduit, flowing source→sink at a speed
            // set by the energy on that line. Drawn by Core Animation (render
            // server) so it stays smooth even while the main thread re-renders the
            // rest of the tab. Uses the SAME `links` as the lines above.
            FlowDotsView(links: links, paused: reduceMotion || !appState.mainWindowVisible)
                .allowsHitTesting(false)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
            }
        )
        // Keep the last on-battery load so the per-app branch speeds carry over a
        // plug/unplug continuously rather than jumping.
        .onChange(of: battery.powerWatts) { _, _ in
            guard hasBattery, !battery.isOnAC else { return }
            let live = battery.systemPowerWatts > 0 ? battery.systemPowerWatts : battery.powerWatts
            if live > 0.5 { rememberedLoadWatts = live }
        }
    }

    // MARK: - Node drawing (Canvas)

    private func drawLabel(
        _ ctx: GraphicsContext, _ string: String, font: Font, color: Color,
        at point: CGPoint, anchor: UnitPoint = .center
    ) {
        ctx.draw(Text(string).font(font).foregroundColor(color), at: point, anchor: anchor)
    }

    private func drawMacNode(_ ctx: GraphicsContext, layout: FlowLayout) {
        let c = layout.mac
        let s = FlowLayout.macSize
        let rect = CGRect(
            x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
        let box = Path(
            roundedRect: rect, cornerSize: CGSize(width: 14, height: 14), style: .continuous)
        ctx.fill(box, with: .color(Color.primary.opacity(0.07)))
        ctx.stroke(box, with: .color(Color.primary.opacity(0.12)), lineWidth: 0.5)
        if let sym = ctx.resolveSymbol(id: SymbolID.mac) {
            ctx.draw(sym, at: CGPoint(x: c.x, y: c.y - 11))
        }
        drawLabel(
            ctx, macNodeLabel, font: .callout.monospacedDigit().weight(.semibold),
            color: .primary, at: CGPoint(x: c.x, y: c.y + 17))
    }

    private func drawBatteryNode(_ ctx: GraphicsContext, layout: FlowLayout) {
        let c = layout.battery
        let level = BatteryLevel(percent: battery.chargePercent)
        drawBatteryGlyph(
            ctx, in: CGRect(x: c.x - 23, y: c.y - 17, width: 46, height: 22),
            percent: battery.chargePercent, tint: level.color)
        drawLabel(
            ctx, batteryLabel, font: .caption2.monospacedDigit().weight(.medium),
            color: batteryLabelColor, at: CGPoint(x: c.x, y: c.y + 13))
    }

    private func drawBatteryGlyph(
        _ ctx: GraphicsContext, in rect: CGRect, percent: Double, tint: Color
    ) {
        let capW = rect.width * 0.08
        let bodyW = rect.width - capW - 1
        let inset: CGFloat = 2.5
        let bodyRect = CGRect(x: rect.minX, y: rect.minY, width: bodyW, height: rect.height)
        ctx.stroke(
            Path(
                roundedRect: bodyRect, cornerSize: CGSize(width: 4, height: 4), style: .continuous),
            with: .color(.primary.opacity(0.45)), lineWidth: 1.2)
        let fillW = max(0, (bodyW - inset * 2) * percent / 100)
        let fillRect = CGRect(
            x: rect.minX + inset, y: rect.minY + inset, width: fillW,
            height: rect.height - inset * 2)
        ctx.fill(
            Path(
                roundedRect: fillRect, cornerSize: CGSize(width: 2, height: 2), style: .continuous),
            with: .color(tint))
        let capRect = CGRect(
            x: rect.minX + bodyW + 0.5, y: rect.midY - rect.height * 0.2,
            width: capW, height: rect.height * 0.4)
        ctx.fill(
            Path(roundedRect: capRect, cornerSize: CGSize(width: 1, height: 1), style: .continuous),
            with: .color(.primary.opacity(0.45)))
    }

    private func drawAdapterNode(_ ctx: GraphicsContext, layout: FlowLayout) {
        let c = layout.adapter
        if let plug = ctx.resolveSymbol(id: SymbolID.plug) {
            ctx.draw(plug, at: CGPoint(x: c.x, y: c.y - 9))
        }
        drawLabel(
            ctx, battery.adapterWatts.map { t("%@ W max", String($0)) } ?? t("AC"),
            font: .caption2.weight(.medium), color: .secondary, at: CGPoint(x: c.x, y: c.y + 11))
    }

    private func drawProcessNode(
        _ ctx: GraphicsContext, consumer: EnergyFlowProcess, at point: CGPoint
    ) {
        let leftX = point.x - FlowLayout.processNodeWidth / 2
        let iconRect = CGRect(x: leftX, y: point.y - 8, width: 16, height: 16)
        ctx.draw(
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: consumer.executablePath)),
            in: iconRect)
        let textX = leftX + 16 + 7
        let textWidth = FlowLayout.processNodeWidth - 16 - 7
        // Draw the (clipped) name on the upper line and the share below it.
        let name = ctx.resolve(
            Text(consumer.name).font(.caption.weight(.medium)).foregroundColor(.primary))
        ctx.draw(name, in: CGRect(x: textX, y: point.y - 13, width: textWidth, height: 13))
        drawLabel(
            ctx, shareLabel(consumer), font: .caption2.monospacedDigit(), color: .secondary,
            at: CGPoint(x: textX, y: point.y + 7), anchor: .leading)
    }

    // MARK: - Labels

    /// The battery node's caption — the signed rate at the battery terminal,
    /// which is exactly what flows into it (charging, "+22.1 W") or out of it
    /// (discharging, "−22.1 W"). On AC at full it reads "full"; otherwise idle.
    private var batteryLabel: String {
        if battery.isCharging { return "+" + BatteryFormat.watts(battery.powerWatts) }
        if battery.isOnAC { return battery.chargePercent >= 99 ? t("full") : t("holding") }
        return battery.powerWatts < 0.1 ? "—" : "\u{2212}" + BatteryFormat.watts(battery.powerWatts)
    }

    private var batteryLabelColor: Color {
        if battery.isCharging { return BatteryStyle.battery }
        if battery.isOnAC { return .secondary }
        return battery.powerWatts < 0.1 ? .secondary : BatteryStyle.battery
    }

    /// Each process's share of the energy among the shown leaders, e.g. "31%".
    private func shareLabel(_ consumer: EnergyFlowProcess) -> String {
        let total = shownProcesses.map(\.energy).reduce(0, +)
        guard total > 0 else { return "—" }
        return "\(Int((consumer.energy / total * 100).rounded()))%"
    }
}

// MARK: - Layout

/// Computes the diagram's node positions and the curved conduits between them
/// for a given canvas size. Centralised so the Canvas (drawing links) and the
/// overlaid node views read from the exact same geometry.
private struct FlowLayout {
    let size: CGSize
    let processCount: Int
    /// On AC the left column stacks the adapter above the battery; on battery the
    /// battery sits alone, centred opposite the Mac.
    let isOnAC: Bool
    /// False on a desktop: there is no battery node, and the adapter (wall outlet)
    /// sits alone, centred opposite the Mac.
    let hasBattery: Bool

    static let macSize = CGSize(width: 86, height: 64)
    static let processNodeWidth: CGFloat = 132

    /// Named anchor points the conduits connect, resolved to the node edge that
    /// faces the Mac so links meet the boxes cleanly rather than at their centres.
    enum Anchor {
        case adapter, battery, macLeft, macLeftTop, macLeftBottom, macRight, process(Int)
    }

    private var leftX: CGFloat { 56 }
    private var centerX: CGFloat { size.width / 2 }
    private var rightX: CGFloat { size.width - Self.processNodeWidth - 8 }
    private var midY: CGFloat { size.height / 2 }

    var mac: CGPoint { CGPoint(x: centerX, y: midY) }

    /// The adapter sits above the battery when both are shown (laptop on AC);
    /// otherwise it is the only left-column node and sits centred opposite the Mac.
    var adapter: CGPoint {
        CGPoint(x: leftX, y: midY - (hasBattery ? size.height * 0.26 : 0))
    }
    var battery: CGPoint {
        CGPoint(x: leftX, y: midY + (isOnAC ? size.height * 0.24 : 0))
    }

    /// Process node centres, evenly distributed down the right column. `.position`
    /// centres a view, so the x is offset by half the node width to keep the
    /// node's left edge — where its conduit lands — at `rightX`.
    func process(_ index: Int) -> CGPoint {
        CGPoint(x: rightX + Self.processNodeWidth / 2, y: rowY(index))
    }

    private func rowY(_ index: Int) -> CGFloat {
        guard processCount > 1 else { return midY }
        let top = size.height * 0.12
        let bottom = size.height * 0.88
        let step = (bottom - top) / CGFloat(processCount - 1)
        return top + step * CGFloat(index)
    }

    private func point(_ anchor: Anchor) -> CGPoint {
        switch anchor {
        case .adapter: return CGPoint(x: adapter.x + 26, y: adapter.y)
        case .battery: return CGPoint(x: battery.x + 30, y: battery.y)
        case .macLeft: return CGPoint(x: mac.x - Self.macSize.width / 2, y: mac.y)
        case .macLeftTop: return CGPoint(x: mac.x - Self.macSize.width / 2, y: mac.y - 12)
        case .macLeftBottom: return CGPoint(x: mac.x - Self.macSize.width / 2, y: mac.y + 12)
        case .macRight: return CGPoint(x: mac.x + Self.macSize.width / 2, y: mac.y)
        case .process(let i): return CGPoint(x: rightX, y: rowY(i))
        }
    }

    /// A horizontal-easing cubic between two anchors: control handles are pulled
    /// out sideways so the conduit leaves and arrives flat, reading as a smooth
    /// pipe rather than a straight wire.
    func curve(from: Anchor, to: Anchor) -> Conduit {
        let a = point(from)
        let b = point(to)
        let dx = (b.x - a.x) * 0.5
        return Conduit(
            a: a,
            c1: CGPoint(x: a.x + dx, y: a.y),
            c2: CGPoint(x: b.x - dx, y: b.y),
            b: b)
    }
}

/// A cubic-Bézier conduit between two anchors. Stores its control points so the
/// diagram can both stroke the route and place dots at any point along it.
private struct Conduit {
    var a: CGPoint
    var c1: CGPoint
    var c2: CGPoint
    var b: CGPoint

    var path: Path {
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: c1, control2: c2)
        return p
    }

    /// The point at parameter `t` (0...1) along the cubic Bézier.
    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let w0 = u * u * u
        let w1 = 3 * u * u * t
        let w2 = 3 * u * t * t
        let w3 = t * t * t
        return CGPoint(
            x: w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * b.x,
            y: w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * b.y)
    }

    /// Approximate arc length by sampling — enough to space dots evenly.
    var approxLength: CGFloat {
        var total: CGFloat = 0
        var prev = a
        for i in 1...12 {
            let p = point(at: CGFloat(i) / 12)
            total += hypot(p.x - prev.x, p.y - prev.y)
            prev = p
        }
        return total
    }
}

// MARK: - Flow links (shared by the base diagram and the animated dot layer)

/// One drawable conduit: the curve it follows, a colour, and the watts flowing on
/// it. Watts drive the travelling dot's speed and size. File-scope so both the
/// static base Canvas and `EnergyDotsLayer` build identical links from identical
/// geometry.
private struct Link {
    let id: AnyHashable
    let conduit: Conduit
    let color: Color
    let watts: Double
    let path: Path
    let length: CGFloat

    init(id: AnyHashable, conduit: Conduit, color: Color, watts: Double) {
        self.id = id
        self.conduit = conduit
        self.color = color
        self.watts = watts
        self.path = conduit.path
        self.length = conduit.approxLength
    }
}

/// Dot travel speed: proportional to the watts on the line, with a floor so a
/// faint flow still drifts rather than freezing.
private func energySpeed(watts: Double) -> Double { max(16, 12 * watts) }

/// Build the conduits for the current geometry and battery/app state. Pure, so
/// the base diagram and the animated dots derive identical links. See the long
/// notes in `EnergyFlowView` for the two-load (trunk vs branch) reasoning.
private func energyLinks(
    layout: FlowLayout, battery: BatterySample, processes: [EnergyFlowProcess],
    rememberedLoadWatts: Double
) -> [Link] {
    let hasBattery = battery.isPresent
    var links: [Link] = []

    let trunkLoadWatts =
        battery.systemPowerWatts > 0
        ? battery.systemPowerWatts
        : (battery.isOnAC ? rememberedLoadWatts : battery.powerWatts)
    let branchLoadWatts =
        hasBattery && battery.isOnAC
        ? rememberedLoadWatts
        : (battery.systemPowerWatts > 0 ? battery.systemPowerWatts : battery.powerWatts)

    if !hasBattery {
        links.append(
            Link(
                id: "trunk", conduit: layout.curve(from: .adapter, to: .macLeft),
                color: BatteryStyle.charger, watts: trunkLoadWatts))
    } else if battery.isOnAC {
        let adapterWatts = (battery.isCharging ? battery.powerWatts : 0) + trunkLoadWatts
        links.append(
            Link(
                id: "trunk", conduit: layout.curve(from: .adapter, to: .macLeftTop),
                color: BatteryStyle.charger, watts: adapterWatts))
        if battery.isCharging {
            links.append(
                Link(
                    id: "charge", conduit: layout.curve(from: .macLeftBottom, to: .battery),
                    color: BatteryStyle.battery, watts: battery.powerWatts))
        }
    } else {
        // On battery: the battery feeds the Mac with the whole system load, which
        // then splits among the apps. Use `branchLoadWatts` (the total the
        // branches sum to) so the trunk is always the fastest line — the power
        // visibly comes from the battery and spreads out, thinner, to each process
        // — rather than the raw terminal-discharge figure, which can read lower
        // than a heavy app's branch and make the trunk look slower than its slices.
        links.append(
            Link(
                id: "trunk", conduit: layout.curve(from: .battery, to: .macLeftBottom),
                color: BatteryStyle.battery, watts: branchLoadWatts))
    }

    let total = processes.map(\.energy).reduce(0, +)
    for (index, consumer) in processes.enumerated() {
        let share = total > 0 ? consumer.energy / total : 0
        links.append(
            Link(
                id: consumer.id, conduit: layout.curve(from: .macRight, to: .process(index)),
                color: BatteryStyle.consumer, watts: branchLoadWatts * share))
    }
    return links
}

// MARK: - Animated dot layer (Core Animation)

/// The travelling pulses, animated by Core Animation on a layer-backed NSView —
/// deliberately NOT a SwiftUI `TimelineView`/`Canvas` and NOT a main-thread
/// timer. Both were tried and both stutter, for different reasons:
///   • a SwiftUI per-frame animation inside the tab's ScrollView re-lays-out the
///     whole tab every frame (the layout storm); and
///   • a main-thread `Timer`/`drawRect` is itself frozen by the ~2 s whole-tab
///     re-render, so the dots hitch every couple of seconds regardless.
/// A `CAKeyframeAnimation` runs on the render server, so the pulses keep flowing
/// smoothly even while the app's main thread is busy re-rendering the page.
private struct FlowDotsView: NSViewRepresentable {
    let links: [Link]
    let paused: Bool

    func makeNSView(context: Context) -> DotsNSView { DotsNSView() }

    func updateNSView(_ view: DotsNSView, context: Context) {
        view.update(links: links, paused: paused)
    }
}

/// Layer-backed view whose dots are `CALayer`s driven by an infinite
/// `CAKeyframeAnimation` along each conduit's path. Driven by the SAME `links` the
/// lines use, so the two can never disagree. It rebuilds only when the dots would
/// actually differ (which links exist, their routes, or a coarse speed bucket) —
/// never on the per-tick watt jitter — so the render-server animation is not
/// restarted every sample, and stays smooth while the main thread is busy.
private final class DotsNSView: NSView {
    private var isPaused = false
    private var dots: [CALayer] = []
    private var links: [Link] = []
    private var signature = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// SwiftUI hosts this NSView in a top-left coordinate space already, so the
    /// backing layer is top-left too — matching the conduit paths and the SwiftUI
    /// Canvas that strokes the LINES. Do NOT set `isGeometryFlipped`: that mirrors
    /// the layer vertically and floats the dots off the lines.
    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.masksToBounds = false
        return layer
    }

    func update(links: [Link], paused: Bool) {
        self.links = links
        rebuild()
        setPaused(paused)
    }

    override func layout() {
        super.layout()
        rebuild()  // a resize changes both the routes and the flip height
    }

    private func rebuild() {
        let h = bounds.height
        guard h > 1 else { return }
        // Rebuild only when the dots would differ — the routes (so an AC<->battery
        // switch re-routes them in the right direction), a coarse speed bucket (so a
        // real energy change updates the speed), and the height (resize) — but NOT
        // on the tiny per-tick watt jitter, which would restart the animation every
        // sample and make it jump.
        let sig =
            "\(Int(h))|"
            + links.map { link in
                let a = link.conduit.a, b = link.conduit.b
                return "\(link.id):\(Int(a.x)),\(Int(a.y))>\(Int(b.x)),\(Int(b.y)):"
                    + "\(Int(energySpeed(watts: link.watts) / 20))"
            }.joined(separator: "|")
        guard sig != signature else { return }
        signature = sig

        dots.forEach { $0.removeFromSuperlayer() }
        dots.removeAll()

        // The conduit paths are in the SwiftUI Canvas's top-left space; this NSView
        // renders bottom-up, so flip y by the height to land the dots EXACTLY on the
        // lines the Canvas strokes (the dots-off-the-line bug).
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for link in links where link.length > 1 {
            // Exactly one dot per conduit, its size a touch larger for more watts.
            let r = 2.85 + min(1, link.watts / 40) * 1.95
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            dot.cornerRadius = r
            dot.backgroundColor = NSColor(link.color).withAlphaComponent(0.95).cgColor
            let start = link.conduit.point(at: 0)
            dot.position = CGPoint(x: start.x, y: h - start.y)
            layer?.addSublayer(dot)
            dots.append(dot)

            // Travels the path from source to sink. Constant speed along the curve;
            // the duration encodes the energy on the line — more watts → shorter
            // trip → faster dot.
            let anim = CAKeyframeAnimation(keyPath: "position")
            anim.path = link.path.cgPath.copy(using: &flip) ?? link.path.cgPath
            anim.calculationMode = .paced
            anim.duration = max(0.4, Double(link.length) / energySpeed(watts: link.watts))
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            dot.add(anim, forKey: "flow")
        }
        CATransaction.commit()
        applyPausedState()
    }

    private func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        applyPausedState()
    }

    /// Freeze/resume all animations by pausing the host layer's timing (this
    /// covers Reduce Motion and the window being off-screen) — the standard
    /// CoreAnimation pause dance.
    private func applyPausedState() {
        guard let l = layer else { return }
        if isPaused, l.speed != 0 {
            let t = l.convertTime(CACurrentMediaTime(), from: nil)
            l.speed = 0
            l.timeOffset = t
        } else if !isPaused, l.speed == 0 {
            let pausedAt = l.timeOffset
            l.speed = 1
            l.timeOffset = 0
            l.beginTime = 0
            let since = l.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
            l.beginTime = since
        }
    }
}
