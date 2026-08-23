import AppKit

/// Base for the AppKit views that paint live data with Core Graphics
/// (`TrendSurfaceView`, `SparklineSurfaceView`, `CoreGridSurfaceView`,
/// `TaxonomySurfaceView`): flipped, layer-backed, and painting into a plain
/// `CALayer` of their own (`contentLayer`) rather than through `draw(_:)`.
///
/// Why not `draw(_:)`: AppKit records a view's drawing into a display list
/// and replays it, on every repaint, into a float-format "ContentLayer" sized
/// to the drawing (`CABackingStoreUpdate_` > `CGDisplayListDrawInContext` >
/// `aa_render` in a profile). For a sparkline repainted four times a second
/// the replay cost several times the drawing itself. A `CALayer` with a
/// delegate and an 8-bit store is drawn straight into its backing store, and
/// `setNeedsDisplay(_:)` on it repaints only the given rectangle, which is
/// what lets `TrendSurfaceView` repaint a few columns per tick.
///
/// Subclasses override `paint(in:dirty:)` (flipped coordinates, y down, the
/// context clipped and cleared to `dirty`) and call `invalidateContent()`
/// where they would have set `needsDisplay`. Nothing here touches AppKit
/// layout: the view's size is whatever SwiftUI proposes.
class LiveSurfaceView: NSView {
    /// The layer the subclass paints; always the view's size.
    let contentLayer = CALayer()
    private(set) lazy var painter = SurfacePainter(view: self)
    private var installed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        installIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func installIfNeeded() {
        guard !installed, let backing = layer else { return }
        installed = true
        configure(contentLayer)
        contentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        backing.addSublayer(contentLayer)
        applyScale()
    }

    /// Set a layer up to be painted by this view: delegate, 8-bit store, no
    /// implicit animations, origin anchored at its top-left.
    func configure(_ layer: CALayer) {
        layer.delegate = painter
        layer.anchorPoint = .zero
        layer.contentsFormat = .RGBA8Uint
        layer.needsDisplayOnBoundsChange = false
    }

    /// The window's backing scale (2 on a Retina display).
    var deviceScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Snap to the device pixel grid so edges stay crisp.
    func snap(_ x: CGFloat) -> CGFloat {
        let scale = deviceScale
        return (x * scale).rounded() / scale
    }

    /// Layers whose `contentsScale` follows the window. Subclasses with extra
    /// painted layers append them.
    var scaledLayers: [CALayer] { [contentLayer] }

    func applyScale() {
        let scale = deviceScale
        for layer in scaledLayers where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
    }

    /// Repaint the content layer on the next display pass.
    func invalidateContent() {
        contentLayer.setNeedsDisplay()
    }

    /// Paint the content layer. `ctx` is in flipped view coordinates (y down),
    /// clipped and cleared to `dirty`.
    func paint(in ctx: CGContext, dirty: CGRect) {}

    /// Called after the view (and `contentLayer`) changed size.
    func sizeDidChange() {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        installIfNeeded()
        contentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        sizeDidChange()
        invalidateContent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installIfNeeded()
        applyScale()
        invalidateContent()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
        invalidateContent()
    }

    /// Put a layer's drawing context into flipped (y down) coordinates and
    /// return the dirty rect in that space. Under a flipped backing layer
    /// Core Animation already hands over a flipped context (`ctm.d < 0`).
    static func prepare(_ ctx: CGContext, height: CGFloat) -> CGRect {
        var dirty = ctx.boundingBoxOfClipPath
        if ctx.ctm.d > 0 {
            ctx.translateBy(x: 0, y: height)
            ctx.scaleBy(x: 1, y: -1)
            dirty.origin.y = height - dirty.maxY
        }
        return dirty
    }

    /// Route a layer's display to the painter for it. Subclasses with extra
    /// layers override this and call `super` for `contentLayer`.
    func paintLayer(_ layer: CALayer, in ctx: CGContext) {
        let dirty = Self.prepare(ctx, height: layer.bounds.height)
        ctx.clear(dirty)
        ctx.clip(to: dirty)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            paint(in: ctx, dirty: dirty)
        }
    }
}

/// Delegate for a surface's painted layers: routes drawing to the view and
/// vetoes every implicit animation, so a slide is a plain position change and
/// a repaint never cross-fades.
final class SurfacePainter: NSObject, CALayerDelegate {
    unowned let view: LiveSurfaceView

    init(view: LiveSurfaceView) {
        self.view = view
    }

    func draw(_ layer: CALayer, in ctx: CGContext) {
        view.paintLayer(layer, in: ctx)
    }

    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}
