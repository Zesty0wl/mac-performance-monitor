// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Draws the Dock tile: a dark plate in the shape of a macOS icon, a caption
/// row, and the trend filling the rest.
@MainActor
enum DockTileRenderer {
    /// The Dock lays tiles out on a 128 point grid.
    static let canvas = CGSize(width: 128, height: 128)
    /// Pixels per point. The Dock magnifies tiles up to 256 points, so this is
    /// sharp at the largest size on a Retina display.
    static let scale: CGFloat = 4

    static func image(
        _ content: DockTileContent, size: DockTileSize = .large,
        bitmap: ChartBitmap = ChartBitmap()
    ) -> NSImage? {
        guard
            let cgImage = bitmap.render(
                size: canvas, scale: scale, draw: { draw(content, size: size, in: $0) })
        else { return nil }
        return NSImage(cgImage: cgImage, size: canvas)
    }

    static func draw(_ content: DockTileContent, size: DockTileSize, in context: CGContext) {
        let plate = size.plate
        let platePath = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            .path(in: plate).cgPath

        // The plate, with the soft drop shadow other Dock icons carry.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 1.5), blur: 3,
            color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addPath(platePath)
        context.setFillColor(NSColor(white: 0.11, alpha: 1).cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(platePath)
        context.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(white: 0.20, alpha: 1).cgColor, NSColor(white: 0.08, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 1])
        if let gradient {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: plate.midX, y: plate.minY),
                end: CGPoint(x: plate.midX, y: plate.maxY), options: [])
        }

        // Without captions the trend takes the whole plate, less a margin so
        // a peak does not touch the rounded top.
        let captions = captionLayout(content, size: size)
        let header = captions?.header ?? bareHeader
        let plot = CGRect(
            x: plate.minX, y: plate.minY + header, width: plate.width,
            height: plate.height - header)
        drawGrid(in: plot, context: context)
        for line in content.lines {
            drawLine(line, top: content.top, in: plot, context: context)
        }
        context.restoreGState()

        // A hairline edge, so the plate holds its shape against a dark Dock.
        context.addPath(platePath)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(0.75)
        context.strokePath()

        if let captions { drawCaptions(captions, context: context) }
    }

    private static func drawGrid(in plot: CGRect, context: CGContext) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
        context.setLineWidth(0.75)
        for fraction in [0.25, 0.5, 0.75] {
            let lineY = plot.maxY - plot.height * fraction
            context.move(to: CGPoint(x: plot.minX, y: lineY))
            context.addLine(to: CGPoint(x: plot.maxX, y: lineY))
        }
        context.strokePath()
    }

    static var bridgedGap: Int { DockTileBuckets.bridgedGap }

    /// Runs of points, split wherever more than `bridgedGap` slots in a row had
    /// no samples. A shorter gap is joined straight across.
    static func runs(_ values: [Double?], top: Double, in plot: CGRect) -> [[CGPoint]] {
        guard values.count > 1, top > 0 else { return [] }
        let step = plot.width / CGFloat(values.count - 1)
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        var missing = 0
        for (index, value) in values.enumerated() {
            guard let value else {
                missing += 1
                continue
            }
            if missing > bridgedGap, !current.isEmpty {
                runs.append(current)
                current = []
            }
            missing = 0
            let fraction = min(max(value / top, 0), 1)
            // Keep the line off the plate's bottom edge so zero still reads.
            let pointY = plot.maxY - 2 - (plot.height - 4) * CGFloat(fraction)
            current.append(CGPoint(x: plot.minX + CGFloat(index) * step, y: pointY))
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func drawLine(
        _ line: DockTileContent.Line, top: Double, in plot: CGRect, context: CGContext
    ) {
        let color = line.color.usingColorSpace(.deviceRGB) ?? line.color
        for run in runs(line.values, top: top, in: plot) {
            guard let first = run.first, let last = run.last else { continue }
            let curve = MonotoneCurve.path(run)

            let fill = curve.mutableCopy() ?? CGMutablePath()
            fill.addLine(to: CGPoint(x: last.x, y: plot.maxY))
            fill.addLine(to: CGPoint(x: first.x, y: plot.maxY))
            fill.closeSubpath()
            context.saveGState()
            context.addPath(fill)
            context.clip()
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    color.withAlphaComponent(0.42).cgColor, color.withAlphaComponent(0.02).cgColor,
                ] as CFArray, locations: [0, 1])
            if let gradient {
                context.drawLinearGradient(
                    gradient, start: CGPoint(x: plot.midX, y: plot.minY),
                    end: CGPoint(x: plot.midX, y: plot.maxY), options: [])
            }
            context.restoreGState()

            context.addPath(curve)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(2.5)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.strokePath()
        }
    }

    /// The caption row, measured: where each caption draws and how much of
    /// the plate's top it takes.
    struct CaptionLayout {
        var leading: (text: NSAttributedString, origin: CGPoint)
        var trailing: (text: NSAttributedString, origin: CGPoint)?
        /// Distance from the plate's top to the top of the plot.
        var header: CGFloat
    }

    /// Space above the caps of the tallest caption, and between the
    /// captions and the plot. A centred label row sits tighter.
    static func captionTop(centered: Bool) -> CGFloat { centered ? 5 : 7 }
    static func captionGap(centered: Bool) -> CGFloat { centered ? 4 : 6 }
    /// Plate margin above the plot when there is no text: just enough that a
    /// line at the very top is not cut in half.
    static let bareHeader: CGFloat = 3

    /// Lay out the caption row: the leading and trailing captions share a
    /// baseline, and both shrink together if they would collide, so "100%" or
    /// a long rate still fits beside its label. The row is only as tall as
    /// its text, so a label on its own leaves the plot more room.
    static func captionLayout(_ content: DockTileContent, size: DockTileSize) -> CaptionLayout? {
        guard let first = content.leading ?? content.trailing else { return nil }
        // A lone caption sits on the left.
        let second = content.leading == nil ? nil : content.trailing
        let plate = size.plate
        let available = plate.width - size.inset * 2
        let gap: CGFloat = 6

        func font(_ points: CGFloat) -> NSFont {
            let font = NSFont.monospacedDigitSystemFont(ofSize: points, weight: .semibold)
            return font.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: points) } ?? font
        }
        func attributed(
            _ caption: DockTileContent.Caption, scale: CGFloat
        )
            -> (text: NSAttributedString, font: NSFont)
        {
            let font = font(caption.size * size.textScale * scale)
            return (
                NSAttributedString(
                    string: caption.text,
                    attributes: [.font: font, .foregroundColor: caption.color]), font
            )
        }

        var leading = attributed(first, scale: 1)
        var trailing = second.map { attributed($0, scale: 1) }
        // The space between the captions does not shrink with the text, so
        // scale only the text to fit what is left. A centred pair keeps a
        // wider space between its marks.
        let spacing = trailing == nil ? 0 : (content.centersCaptions ? gap * 2 : gap)
        func textWidth() -> CGFloat {
            leading.text.size().width + (trailing?.text.size().width ?? 0)
        }
        // Text width does not scale exactly with point size (glyph metrics are
        // rounded), so measure again after each shrink until it fits.
        var scale: CGFloat = 1
        for _ in 0..<3 where textWidth() + spacing > available {
            scale *= max(available - spacing, 1) / textWidth()
            leading = attributed(first, scale: scale)
            trailing = second.map { attributed($0, scale: scale) }
        }
        let centered = content.centersCaptions
        let capHeight = max(leading.font.capHeight, trailing?.font.capHeight ?? 0)
        let top = captionTop(centered: centered)
        let baseline = plate.minY + top + capHeight
        let header = top + capHeight + captionGap(centered: centered)
        if centered {
            // The labels as one centred group: "CPU", or "↓  ↑".
            let width =
                leading.text.size().width + (trailing.map { $0.text.size().width + spacing } ?? 0)
            let start = plate.midX - width / 2
            return CaptionLayout(
                leading: (leading.text, CGPoint(x: start, y: baseline - leading.font.ascender)),
                trailing: trailing.map {
                    (
                        $0.text,
                        CGPoint(
                            x: start + width - $0.text.size().width,
                            y: baseline - $0.font.ascender)
                    )
                }, header: header)
        }
        return CaptionLayout(
            leading: (
                leading.text,
                CGPoint(x: plate.minX + size.inset, y: baseline - leading.font.ascender)
            ),
            trailing: trailing.map {
                (
                    $0.text,
                    CGPoint(
                        x: plate.maxX - size.inset - $0.text.size().width,
                        y: baseline - $0.font.ascender)
                )
            },
            header: header)
    }

    private static func drawCaptions(_ layout: CaptionLayout, context: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        layout.leading.text.draw(at: layout.leading.origin)
        if let trailing = layout.trailing { trailing.text.draw(at: trailing.origin) }
    }
}
