import AppKit
import MacPerfMonitorCore
import SwiftUI

/// What the pointer is over, for the SwiftUI hover card. `node` is
/// `TreemapCell.aggregateNode` for the "N more items" cell.
struct TreemapHover: Equatable {
    let node: Int32
    let parent: Int32
    let rect: CGRect
    let aggregateCount: UInt32
    let aggregateBytes: UInt64
}

/// The treemap as an AppKit surface. Drawing thousands of rectangles with
/// labels is a job for Core Graphics and a `CTLine` cache (`ctx.resolve(Text)`
/// in a Canvas costs tens of microseconds per label, which blows the frame
/// budget at two hundred labels), and AppKit gives click counts, a tracking
/// area, key events and accessibility children directly. The cells live on
/// the content layer and repaint only when the scene changes; hover and
/// selection rings live on a separate layer so moving the mouse never
/// repaints the map.
struct TreemapSurface: NSViewRepresentable {
    let tree: FileTree?
    let revision: Int
    let zoomRoot: Int32
    let selection: Int32?
    let colorMode: DiskMapColorMode
    let onSelect: (Int32?) -> Void
    let onOpen: (Int32) -> Void
    let onBack: () -> Void
    let onHover: (TreemapHover?) -> Void
    let onQuickLook: (Int32) -> Void
    let menu: (Int32) -> NSMenu?

    func makeNSView(context: Context) -> TreemapSurfaceView {
        let view = TreemapSurfaceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: TreemapSurfaceView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: TreemapSurfaceView) {
        view.handlers = TreemapSurfaceView.Handlers(
            onSelect: onSelect, onOpen: onOpen, onBack: onBack, onHover: onHover,
            onQuickLook: onQuickLook, menu: menu)
        view.setTree(tree, revision: revision, zoomRoot: zoomRoot)
        view.colorMode = colorMode
        view.selection = selection
    }
}

final class TreemapSurfaceView: LiveSurfaceView {
    struct Handlers {
        var onSelect: (Int32?) -> Void = { _ in }
        var onOpen: (Int32) -> Void = { _ in }
        var onBack: () -> Void = {}
        var onHover: (TreemapHover?) -> Void = { _ in }
        var onQuickLook: (Int32) -> Void = { _ in }
        var menu: (Int32) -> NSMenu? = { _ in nil }
    }

    var handlers = Handlers()

    /// Hover and selection rings are border-only layers moved over the map:
    /// no drawing, no repaint of anything, whatever the map's size.
    private let hoverLayer = CALayer()
    private let selectionLayer = CALayer()
    private var layersInstalled = false
    private var trackingArea: NSTrackingArea?
    private let labels = TreemapLabelCache()
    private var accessibilityCells: [NSAccessibilityElement] = []

    private var tree: FileTree?
    private var revision = Int.min
    private(set) var zoomRoot: Int32 = 0
    private var scene = TreemapScene.empty
    private var sceneSize = CGSize.zero
    private var hoverIndex: Int?
    /// Label texts per cell, decided once per scene (nil where there is no
    /// room), so a repaint never formats a byte count or decodes a name.
    private var cellTexts: [CellText?] = []
    private var palette: Palette?

    private struct CellText {
        let name: String
        let size: String
    }

    /// Every colour a paint can need, resolved to `CGColor` once per colour
    /// mode and appearance. Converting an `NSColor` per cell cost more than
    /// filling the cell.
    private struct Palette {
        let mode: DiskMapColorMode
        let dark: Bool
        let kind: [CGColor]
        let kindLight: [Bool]
        let age: [CGColor]
        let ageLight: [Bool]
        let depth: [CGColor]
        let depthLight: [Bool]
        let container: CGColor
        let containerBorder: CGColor
        let aggregate: CGColor
        let aggregateLight: Bool
        let folderMark: CGColor

        init(mode: DiskMapColorMode, dark: Bool) {
            self.mode = mode
            self.dark = dark
            func light(_ color: NSColor) -> Bool {
                DiskMapStyle.labelColor(on: color).whiteComponentIsHigh
            }
            let kinds = FileKind.allCases.sorted { $0.rawValue < $1.rawValue }
            var kindColors = [CGColor](repeating: NSColor.gray.cgColor, count: kinds.count)
            var kindLights = [Bool](repeating: false, count: kinds.count)
            for kind in kinds {
                let color = DiskMapStyle.kindColor(kind, dark: dark)
                kindColors[Int(kind.rawValue)] = color.cgColor
                kindLights[Int(kind.rawValue)] = light(color)
            }
            self.kind = kindColors
            self.kindLight = kindLights
            let ages = (0..<5).map { DiskMapStyle.ageColor(band: $0, dark: dark) }
            age = ages.map(\.cgColor)
            ageLight = ages.map(light)
            let depths = (0..<6).map { DiskMapStyle.depthColor(depth: $0, dark: dark) }
            depth = depths.map(\.cgColor)
            depthLight = depths.map(light)
            container = DiskMapStyle.containerFill(dark: dark).cgColor
            containerBorder = DiskMapStyle.containerBorder(dark: dark).cgColor
            let aggregateColor = DiskMapStyle.aggregateFill(dark: dark)
            aggregate = aggregateColor.cgColor
            aggregateLight = light(aggregateColor)
            folderMark = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.22).cgColor
        }

        func fill(
            kind: FileKind, isDirectory: Bool, modified: UInt32, depth level: Int, now: UInt32
        )
            -> (CGColor, Bool)
        {
            switch mode {
            case .kind:
                let k = isDirectory && kind == .folder ? FileKind.folder : kind
                return (self.kind[Int(k.rawValue)], kindLight[Int(k.rawValue)])
            case .age:
                let band = DiskMapStyle.ageBand(modified: modified, now: now)
                return (age[band], ageLight[band])
            case .depth:
                let d = min(max(level, 0), depth.count - 1)
                return (depth[d], depthLight[d])
            }
        }
    }

    var colorMode: DiskMapColorMode = .kind {
        didSet { if colorMode != oldValue { invalidateContent() } }
    }

    var selection: Int32? {
        didSet { if selection != oldValue { updateSelectionLayer() } }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Disk map")
        installLayersIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Data

    func setTree(_ tree: FileTree?, revision: Int, zoomRoot: Int32) {
        let changed =
            revision != self.revision || zoomRoot != self.zoomRoot
            || (tree == nil) != (self.tree == nil)
        if revision != self.revision { labels.invalidate() }
        self.tree = tree
        self.revision = revision
        self.zoomRoot = zoomRoot
        if changed { rebuildScene() }
    }

    private static let timing = ProcessInfo.processInfo.environment["MPM_DISKMAP_TIMING"] == "1"

    private func rebuildScene() {
        let size = bounds.size
        sceneSize = size
        let started = CFAbsoluteTimeGetCurrent()
        if let tree, Int(zoomRoot) < tree.nodeCount, size.width > 0, size.height > 0 {
            scene = TreemapScene.build(
                tree: tree, root: zoomRoot,
                bounds: TreemapRect(x: 0, y: 0, width: size.width, height: size.height))
        } else {
            scene = .empty
        }
        cellTexts = Self.texts(for: scene, tree: tree)
        updateSelectionLayer()
        if Self.timing {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            FileHandle.standardError.write(
                Data(
                    "[treemap] scene \(scene.cells.count) cells in \(String(format: "%.2f", ms)) ms\n"
                        .utf8))
        }
        if hoverIndex != nil {
            hoverIndex = nil
            handlers.onHover(nil)
        }
        accessibilityCells = []
        invalidateContent()
    }

    // MARK: - Layers

    private func installLayersIfNeeded() {
        guard !layersInstalled, let backing = layer else { return }
        layersInstalled = true
        for ring in [hoverLayer, selectionLayer] {
            // No delegate: these layers have no contents, only a border.
            ring.anchorPoint = .zero
            ring.isHidden = true
            ring.actions = [
                "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(),
                "borderColor": NSNull(), "backgroundColor": NSNull(),
            ]
        }
        hoverLayer.cornerRadius = 2
        hoverLayer.borderWidth = 1.5
        selectionLayer.cornerRadius = 3
        selectionLayer.borderWidth = 2.5
        backing.addSublayer(hoverLayer)
        backing.addSublayer(selectionLayer)
    }

    override func sizeDidChange() {
        installLayersIfNeeded()
        if bounds.size != sceneSize { rebuildScene() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installLayersIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        labels.invalidate()
        invalidateContent()
        updateHoverLayer()
        updateSelectionLayer()
    }

    private func updateHoverLayer() {
        guard let hoverIndex, hoverIndex < scene.cells.count else {
            hoverLayer.isHidden = true
            return
        }
        let dark = isDark
        hoverLayer.frame = cgRect(scene.cells[hoverIndex].rect).insetBy(dx: 0.75, dy: 0.75)
        hoverLayer.borderColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor
        hoverLayer.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.10 : 0.16).cgColor
        hoverLayer.isHidden = false
    }

    private func updateSelectionLayer() {
        guard let selection, let cell = scene.cell(for: selection) else {
            selectionLayer.isHidden = true
            return
        }
        selectionLayer.frame = cgRect(cell.rect).insetBy(dx: 1, dy: 1)
        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        selectionLayer.isHidden = false
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Painting

    private static let leafLabelMinimumWidth = 44.0
    private static let leafLabelMinimumHeight = 15.0

    private static func texts(for scene: TreemapScene, tree: FileTree?) -> [CellText?] {
        guard let tree else { return [] }
        return scene.cells.map { cell in
            if cell.isAggregate {
                guard cell.rect.width >= leafLabelMinimumWidth,
                    cell.rect.height >= leafLabelMinimumHeight
                else { return nil }
                return CellText(
                    name: "\(cell.aggregateCount.formatted()) more",
                    size: ByteFormat.string(cell.aggregateBytes))
            }
            let i = Int(cell.node)
            if cell.isSubdivided {
                guard cell.labelStrip != nil else { return nil }
                return CellText(
                    name: tree.name(of: cell.node), size: ByteFormat.string(tree.bytes[i]))
            }
            guard cell.rect.width >= leafLabelMinimumWidth,
                cell.rect.height >= leafLabelMinimumHeight
            else { return nil }
            let flags = tree.flags[i]
            let name: String
            if flags.contains(.smallFilesFold) {
                let kind = tree.kind[i]
                name =
                    "\(tree.count[i].formatted()) small \(kind == .other ? "items" : kind.label.lowercased())"
            } else {
                name = tree.name(of: cell.node)
            }
            return CellText(name: name, size: ByteFormat.string(tree.bytes[i]))
        }
    }

    override func paint(in ctx: CGContext, dirty: CGRect) {
        guard let tree, !scene.cells.isEmpty else { return }
        let started = CFAbsoluteTimeGetCurrent()
        let dark = isDark
        if palette?.mode != colorMode || palette?.dark != dark {
            palette = Palette(mode: colorMode, dark: dark)
        }
        guard let palette else { return }
        let now = UInt32(clamping: Int(Date().timeIntervalSince1970))
        let dirtyRect = TreemapRect(
            x: dirty.minX, y: dirty.minY, width: dirty.width, height: dirty.height)
        var painted = 0
        let scale = deviceScale
        for (index, cell) in scene.cells.enumerated() where cell.rect.intersects(dirtyRect) {
            paint(
                cell, text: index < cellTexts.count ? cellTexts[index] : nil, tree: tree,
                palette: palette, now: now, scale: scale, in: ctx)
            painted += 1
        }
        if Self.timing {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            FileHandle.standardError.write(
                Data("[treemap] paint \(painted) cells in \(String(format: "%.2f", ms)) ms\n".utf8))
        }
    }

    private func paint(
        _ cell: TreemapCell, text: CellText?, tree: FileTree, palette: Palette, now: UInt32,
        scale: CGFloat, in ctx: CGContext
    ) {
        let rect = cgRect(cell.rect, scale: scale)
        if cell.isAggregate {
            fillCell(rect, color: palette.aggregate, in: ctx)
            if let text {
                drawLeafLabels(text, rect: rect, light: palette.aggregateLight, in: ctx)
            }
            return
        }
        let i = Int(cell.node)
        let flags = tree.flags[i]
        if cell.isSubdivided {
            fillCell(rect, color: palette.container, in: ctx)
            ctx.setStrokeColor(palette.containerBorder)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            if let text, let strip = cell.labelStrip {
                drawStripLabels(text, strip: cgRect(strip, scale: scale), in: ctx)
            }
            return
        }
        let (fill, light) = palette.fill(
            kind: tree.kind[i], isDirectory: flags.contains(.directory), modified: tree.modified[i],
            depth: cell.depth, now: now)
        fillCell(rect, color: fill, in: ctx)
        if flags.contains(.directory), !flags.contains(.smallFilesFold), rect.width >= 40,
            rect.height >= 24
        {
            // A folder drawn as a leaf (too small to open, or a package): a
            // thin inner line marks it as something that can be entered.
            ctx.setStrokeColor(palette.folderMark)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
        }
        if let text {
            drawLeafLabels(text, rect: rect, light: light, in: ctx)
        }
    }

    private func fillCell(_ rect: CGRect, color: CGColor, in ctx: CGContext) {
        ctx.setFillColor(color)
        if rect.width >= 24, rect.height >= 24 {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
        } else {
            ctx.fill(rect)
        }
    }

    private func drawLeafLabels(_ text: CellText, rect: CGRect, light: Bool, in ctx: CGContext) {
        let inset: CGFloat = 4
        let maxWidth = rect.width - inset * 2
        let nameLabel = labels.label(text.name, style: .leafName(light: light), maxWidth: maxWidth)
        ctx.saveGState()
        ctx.clip(to: rect)
        var y = rect.minY + 2
        nameLabel.draw(at: CGPoint(x: rect.minX + inset, y: y), in: ctx)
        y += nameLabel.size.height
        if rect.height >= y - rect.minY + 12 {
            let sizeLabel = labels.label(
                text.size, style: .leafSize(light: light), maxWidth: maxWidth)
            sizeLabel.draw(at: CGPoint(x: rect.minX + inset, y: y), in: ctx)
        }
        ctx.restoreGState()
    }

    private func drawStripLabels(_ text: CellText, strip: CGRect, in ctx: CGContext) {
        let inset: CGFloat = 5
        let sizeLabel = labels.label(text.size, style: .stripSize, maxWidth: 80)
        let nameWidth = strip.width - inset * 2 - sizeLabel.size.width - 6
        guard nameWidth > 12 else { return }
        let nameLabel = labels.label(text.name, style: .stripName, maxWidth: nameWidth)
        let y = strip.minY + (strip.height - nameLabel.size.height) / 2
        ctx.saveGState()
        ctx.clip(to: strip)
        nameLabel.draw(at: CGPoint(x: strip.minX + inset, y: y), in: ctx)
        sizeLabel.draw(
            at: CGPoint(x: strip.maxX - inset - sizeLabel.size.width, y: y + 0.5), in: ctx)
        ctx.restoreGState()
    }

    private func cgRect(_ r: TreemapRect) -> CGRect {
        cgRect(r, scale: deviceScale)
    }

    private func cgRect(_ r: TreemapRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (r.x * scale).rounded() / scale, y: (r.y * scale).rounded() / scale,
            width: (r.width * scale).rounded() / scale,
            height: (r.height * scale).rounded() / scale)
    }

    // MARK: - Hit testing and hover

    private func cellIndex(at point: CGPoint) -> Int? {
        let x = Double(point.x)
        let y = Double(point.y)
        var index = scene.cells.count - 1
        while index >= 0 {
            if scene.cells[index].rect.contains(x: x, y: y) { return index }
            index -= 1
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHover(cellIndex(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
    }

    private func setHover(_ index: Int?) {
        guard index != hoverIndex else { return }
        hoverIndex = index
        updateHoverLayer()
        if let index, index < scene.cells.count {
            let cell = scene.cells[index]
            handlers.onHover(
                TreemapHover(
                    node: cell.node, parent: cell.parent, rect: cgRect(cell.rect),
                    aggregateCount: cell.aggregateCount, aggregateBytes: cell.aggregateBytes))
        } else {
            handlers.onHover(nil)
        }
    }

    // MARK: - Mouse and keyboard

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = cellIndex(at: point) else {
            handlers.onSelect(nil)
            return
        }
        let cell = scene.cells[index]
        if event.clickCount == 2, canOpen(cell) {
            handlers.onOpen(cell.node)
        } else if event.clickCount == 1 {
            handlers.onSelect(cell.isAggregate ? cell.parent : cell.node)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = cellIndex(at: point) else { return }
        let cell = scene.cells[index]
        let node = cell.isAggregate ? cell.parent : cell.node
        handlers.onSelect(node)
        guard let menu = handlers.menu(node) else { return }
        menu.popUp(positioning: nil, at: point, in: self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape
            handlers.onBack()
        case 36, 76:  // Return, keypad Enter
            if let selection, let cell = scene.cell(for: selection), canOpen(cell) {
                handlers.onOpen(selection)
            } else if let selection, let tree, tree.flags[Int(selection)].contains(.directory),
                tree.childCount[Int(selection)] > 0
            {
                handlers.onOpen(selection)
            }
        case 49:  // Space
            if let selection { handlers.onQuickLook(selection) }
        case 123: moveSelection(by: -1)
        case 124: moveSelection(by: 1)
        case 126: selectParent()
        case 125: selectFirstChild()
        default:
            super.keyDown(with: event)
        }
    }

    private func canOpen(_ cell: TreemapCell) -> Bool {
        guard let tree, !cell.isAggregate else { return false }
        let i = Int(cell.node)
        return tree.flags[i].contains(.directory) && !tree.flags[i].contains(.smallFilesFold)
            && tree.childCount[i] > 0
    }

    private func moveSelection(by delta: Int) {
        let siblings: [TreemapCell]
        if let selection, let cell = scene.cell(for: selection) {
            siblings = scene.children(of: cell.parent).filter { !$0.isAggregate }
            guard let position = siblings.firstIndex(where: { $0.node == selection }) else {
                return
            }
            let next = (position + delta + siblings.count) % siblings.count
            handlers.onSelect(siblings[next].node)
        } else {
            siblings = scene.children(of: zoomRoot).filter { !$0.isAggregate }
            if let first = siblings.first { handlers.onSelect(first.node) }
        }
    }

    private func selectParent() {
        guard let selection, let cell = scene.cell(for: selection) else { return }
        if cell.parent == zoomRoot {
            handlers.onBack()
        } else {
            handlers.onSelect(cell.parent)
        }
    }

    private func selectFirstChild() {
        guard let selection else {
            moveSelection(by: 0)
            return
        }
        if let first = scene.children(of: selection).first(where: { !$0.isAggregate }) {
            handlers.onSelect(first.node)
        }
    }

    // MARK: - Accessibility

    override func accessibilityChildren() -> [Any]? {
        if accessibilityCells.isEmpty, let tree {
            accessibilityCells = scene.children(of: zoomRoot).prefix(60).map { cell in
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityParent(self)
                let label: String
                if cell.isAggregate {
                    label =
                        "\(cell.aggregateCount) more items, \(ByteFormat.string(cell.aggregateBytes))"
                } else {
                    label =
                        "\(tree.name(of: cell.node)), \(ByteFormat.string(tree.bytes[Int(cell.node)]))"
                }
                element.setAccessibilityLabel(label)
                element.setAccessibilityFrameInParentSpace(cgRect(cell.rect))
                return element
            }
        }
        return accessibilityCells
    }
}

// MARK: - Labels

/// Laid-out, truncated labels for the map, cached by style, text and width
/// bucket; the same idea as `ChartLabelCache`, plus `CTLineCreateTruncatedLine`
/// so a long file name fits its cell.
private final class TreemapLabelCache {
    enum Style {
        case leafName(light: Bool)
        case leafSize(light: Bool)
        case stripName
        case stripSize

        var key: String {
            switch self {
            case .leafName(let light): return light ? "ln1" : "ln0"
            case .leafSize(let light): return light ? "ls1" : "ls0"
            case .stripName: return "sn"
            case .stripSize: return "ss"
            }
        }

        var attributes: [NSAttributedString.Key: Any] {
            switch self {
            case .leafName(let light):
                return [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                    .foregroundColor:
                        (light
                        ? NSColor.white.withAlphaComponent(0.94)
                        : NSColor.black.withAlphaComponent(0.8)).cgColor,
                ]
            case .leafSize(let light):
                return [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor:
                        (light
                        ? NSColor.white.withAlphaComponent(0.78)
                        : NSColor.black.withAlphaComponent(0.6)).cgColor,
                ]
            case .stripName:
                return [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor.cgColor,
                ]
            case .stripSize:
                return [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor.cgColor,
                ]
            }
        }
    }

    struct Label {
        let line: CTLine
        let size: CGSize
        let ascent: CGFloat

        func draw(at origin: CGPoint, in ctx: CGContext) {
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: origin.x, y: origin.y + ascent)
            CTLineDraw(line, ctx)
        }
    }

    /// Enough for two full scenes of labels; a `CTLine` is about a kilobyte.
    private static let capacity = 24_000
    private var cache: [String: Label] = [:]

    func label(_ text: String, style: Style, maxWidth: CGFloat) -> Label {
        let bucket = Int(maxWidth / 8)
        let key = "\(style.key)|\(bucket)|\(text)"
        if let hit = cache[key] { return hit }
        if cache.count >= Self.capacity {
            // Halve rather than empty: the labels of the current scene stay
            // mostly warm across a zoom in and out.
            for (i, victim) in cache.keys.enumerated() where i % 2 == 0 {
                cache.removeValue(forKey: victim)
            }
        }
        let attributes = style.attributes
        let attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        var width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let limit = Double(bucket * 8)
        if width > limit, limit > 8 {
            let ellipsis = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\u{2026}", attributes: attributes))
            if let truncated = CTLineCreateTruncatedLine(line, limit, .end, ellipsis) {
                line = truncated
                width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            }
        }
        let label = Label(
            line: line, size: CGSize(width: ceil(width), height: ceil(ascent + descent + leading)),
            ascent: ascent)
        cache[key] = label
        return label
    }

    func invalidate() {
        cache.removeAll(keepingCapacity: true)
    }
}

extension NSColor {
    /// True for the light (white) label variant, used as a cache key.
    fileprivate var whiteComponentIsHigh: Bool {
        (usingColorSpace(.sRGB)?.redComponent ?? 0) > 0.5
    }
}
