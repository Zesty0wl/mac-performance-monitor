// SPDX-License-Identifier: MIT
import AppKit
import MacPerfMonitorCore
import SwiftUI

/// Reuses a small CPU bitmap instead of drawing live paths into a display list.
final class ChartBitmap {
    private var context: CGContext?
    private var pixels = CGSize.zero

    func render(
        size: CGSize, scale: CGFloat, flipped: Bool = true,
        draw: (CGContext) -> Void
    ) -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0,
            size.width.isFinite, size.height.isFinite, scale.isFinite
        else { return nil }
        let next = CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
        guard next.width <= 16_384, next.height <= 16_384 else {
            AppLog.ui.error("chart bitmap dimensions exceed the supported size")
            return nil
        }
        if context == nil || pixels != next {
            context = CGContext(
                data: nil, width: Int(next.width), height: Int(next.height),
                bitsPerComponent: 8, bytesPerRow: Int(next.width) * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            pixels = next
        }
        guard let context else {
            AppLog.ui.error("could not allocate chart bitmap")
            return nil
        }
        context.clear(CGRect(origin: .zero, size: pixels))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        if flipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        draw(context)
        context.restoreGState()
        let image = context.makeImage()
        if image == nil { AppLog.ui.error("could not create chart bitmap image") }
        return image
    }
}

struct MenuBitmapChart: NSViewRepresentable {
    struct Series: Equatable {
        var values: [Double]
        var color: Color
        var smooth = true
        var fill = true
        var gradient = true
        var downward = false
        var lineWidth: CGFloat = MenuChart.lineWidth
        /// The lower edge of the fill, one value per sample, for a band stacked
        /// on another series; nil fills down to zero.
        var floor: [Double]? = nil
    }

    struct Model: Equatable {
        var series: [Series]
        var domain: ClosedRange<Double>
        var capacity: Int?
        var ticks: [Double] = []
        var labels: [String] = []
        var gutter: CGFloat = 0
        var caption: String?
        var inset: CGFloat = 2
        var accessibilityLabel = ""
        var accessibilityValue = ""
    }

    let model: Model
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> MenuBitmapChartView {
        MenuBitmapChartView()
    }

    func updateNSView(_ view: MenuBitmapChartView, context: Context) {
        view.update(model, colors: model.series.map { $0.color.resolve(in: environment).cgColor })
    }
}

final class MenuBitmapChartView: NSView {
    private let bitmap = ChartBitmap()
    private(set) var model: MenuBitmapChart.Model?
    private var colors: [CGColor] = []
    private var renderedSize = CGSize.zero
    private var renderedScale: CGFloat = 0
    private(set) var renderCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ model: MenuBitmapChart.Model, colors: [CGColor]) {
        guard self.model != model || self.colors != colors else { return }
        self.model = model
        self.colors = colors
        setAccessibilityElement(!model.accessibilityLabel.isEmpty)
        setAccessibilityLabel(model.accessibilityLabel)
        setAccessibilityValue(model.accessibilityValue)
        render()
    }

    override func layout() {
        super.layout()
        if renderedSize != bounds.size || renderedScale != scale { render() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func render() {
        guard let model, bounds.width > 0, bounds.height > 0 else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let image = bitmap.render(size: bounds.size, scale: scale) { context in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                Self.draw(model, colors: colors, in: context, size: bounds.size)
                NSGraphicsContext.restoreGraphicsState()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = scale
            layer?.contents = image
            CATransaction.commit()
        }
        renderedSize = bounds.size
        renderedScale = scale
        renderCount += 1
    }

    static func draw(
        _ model: MenuBitmapChart.Model, colors: [CGColor], in context: CGContext, size: CGSize
    ) {
        let plot = CGRect(
            x: max(model.gutter, model.inset), y: model.inset,
            width: max(1, size.width - max(model.gutter, model.inset) - model.inset),
            height: max(1, size.height - 2 * model.inset))
        func y(_ value: Double) -> CGFloat {
            plot.maxY - CGFloat(LiveChartGeometry.normalizedY(value, in: model.domain))
                * plot.height
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (index, tick) in model.ticks.enumerated() {
            let yy = y(tick)
            context.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: plot.minX, y: yy))
            context.addLine(to: CGPoint(x: plot.maxX, y: yy))
            context.strokePath()
            if model.labels.indices.contains(index) {
                let text = NSAttributedString(string: model.labels[index], attributes: attributes)
                text.draw(
                    at: CGPoint(
                        x: model.gutter - 4 - text.size().width,
                        y: min(max(yy, 5), size.height - 5) - text.size().height / 2))
            }
        }
        if let caption = model.caption {
            NSAttributedString(string: caption, attributes: attributes)
                .draw(at: CGPoint(x: plot.minX, y: plot.minY + 4))
        }
        context.saveGState()
        context.clip(to: plot.insetBy(dx: -1, dy: -1))
        for (index, series) in model.series.enumerated() where colors.indices.contains(index) {
            var run: [CGPoint] = []
            var floorRun: [CGPoint] = []
            func paintRun() {
                guard let first = run.first else { return }
                let line = CGMutablePath()
                if run.count == 1 {
                    line.move(to: CGPoint(x: first.x - 2, y: first.y))
                    line.addLine(to: CGPoint(x: first.x + 2, y: first.y))
                } else if series.smooth {
                    MonotoneCurve.add(run, to: line)
                } else {
                    line.move(to: first)
                    for point in run.dropFirst() { line.addLine(to: point) }
                }
                let color = colors[index]
                if series.fill, run.count > 1, let last = run.last {
                    let baseline = y(0)
                    let area = CGMutablePath()
                    area.addPath(line)
                    if floorRun.count == run.count {
                        for point in floorRun.reversed() { area.addLine(to: point) }
                    } else {
                        area.addLine(to: CGPoint(x: last.x, y: baseline))
                        area.addLine(to: CGPoint(x: first.x, y: baseline))
                    }
                    area.closeSubpath()
                    context.saveGState()
                    context.addPath(area)
                    context.clip()
                    if series.gradient,
                        let start = color.copy(alpha: color.alpha * 0.22),
                        let end = color.copy(alpha: 0),
                        let gradient = CGGradient(
                            colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [start, end] as CFArray, locations: [0, 1])
                    {
                        context.drawLinearGradient(
                            gradient,
                            start: CGPoint(x: 0, y: series.downward ? plot.maxY : plot.minY),
                            end: CGPoint(x: 0, y: baseline), options: [])
                    } else {
                        context.setFillColor(color.copy(alpha: color.alpha * 0.18) ?? color)
                        context.fill(plot)
                    }
                    context.restoreGState()
                }
                context.addPath(line)
                context.setStrokeColor(color)
                context.setLineWidth(series.lineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
            }
            for (slot, value) in series.values.enumerated() {
                let floor = series.floor.map { $0.indices.contains(slot) ? $0[slot] : .nan }
                guard value.isFinite, floor?.isFinite ?? true else {
                    paintRun()
                    run.removeAll(keepingCapacity: true)
                    floorRun.removeAll(keepingCapacity: true)
                    continue
                }
                let x: Double
                if let capacity = model.capacity, capacity > 0 {
                    x = LiveChartGeometry.normalizedSlot(
                        index: slot, count: series.values.count, capacity: capacity)
                } else {
                    x = series.values.count > 1 ? Double(slot) / Double(series.values.count - 1) : 0
                }
                let xx = plot.minX + CGFloat(x) * plot.width
                run.append(CGPoint(x: xx, y: y(series.downward ? -value : value)))
                if let floor {
                    floorRun.append(CGPoint(x: xx, y: y(series.downward ? -floor : floor)))
                }
            }
            paintRun()
        }
        context.restoreGState()
    }
}
