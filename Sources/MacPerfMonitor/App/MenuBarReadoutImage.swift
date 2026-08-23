import AppKit
import CoreText

/// Core Text rendering of the menu-bar read-out images.
///
/// The read-outs were SwiftUI views rasterised through `ImageRenderer` on every
/// value change — which spins up a whole SwiftUI render graph (ViewGraph → CALayer
/// → bitmap) just to draw a few characters, and profiling showed it to be the
/// dominant idle CPU cost in menu-bar-only mode (1–2 rasterisations/second of a
/// full SwiftUI graph). Drawing the text straight into a cached retina bitmap with
/// Core Text is far cheaper — what lightweight monitors do — while keeping the same
/// two-line look. Each `*MenuBarImage` enum keeps its once-per-change cache, so an
/// unchanged tick re-renders nothing and the bar just re-blits the cached bitmap.
@MainActor
enum MenuBarReadoutImage {
    // MARK: - Fonts

    /// Bold/semibold, rounded, monospaced-digit system font — matches the old
    /// `.system(…, design: .rounded).monospacedDigit()` so digits keep a fixed
    /// width (no horizontal twitch) and the rounded look is preserved.
    static func valueFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let key = "\(size)|\(weight.rawValue)"
        if let cached = fontCache[key] { return cached }
        let font = makeValueFont(size: size, weight: weight)
        fontCache[key] = font
        return font
    }

    /// Fonts by size and weight: building the rounded, monospaced-digit
    /// descriptor is not free and every strip cell asked for it each redraw.
    private static var fontCache: [String: NSFont] = [:]

    private static func makeValueFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: weight)
        var desc = fallback.fontDescriptor
        if let rounded = desc.withDesign(.rounded) { desc = rounded }
        desc = desc.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: Int(kNumberSpacingType),
                    NSFontDescriptor.FeatureKey.selectorIdentifier: Int(kMonospacedNumbersSelector),
                ]
            ]
        ])
        return NSFont(descriptor: desc, size: size) ?? fallback
    }

    // MARK: - Colours (non-template images, so chosen for the real bar appearance)

    /// The muted caption colour: translucent white on a dark bar, translucent black
    /// on a light one — matching the old SwiftUI read-outs.
    static func captionColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 0, alpha: 0.6)
    }

    /// The network figure colour (slightly stronger than the caption).
    static func figureColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(white: 1, alpha: 0.95) : NSColor(white: 0, alpha: 0.85)
    }

    // MARK: - Layouts

    /// A small centred caption stacked over a bold value (the CPU / Pressure /
    /// Battery / Energy items). The column is sized to the wider of the value and
    /// `widthSample`, so it never twitches as the figure gains or loses a digit.
    static func captionedValue(
        caption: String, captionColor: NSColor, value: String, valueColor: NSColor,
        widthSample: String, captionSize: CGFloat = 7, valueSize: CGFloat = 11
    ) -> NSImage {
        let cAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: captionSize, weight: .semibold),
            .foregroundColor: captionColor,
        ]
        let vAttr: [NSAttributedString.Key: Any] = [
            .font: valueFont(size: valueSize, weight: .bold), .foregroundColor: valueColor,
        ]
        let cStr = NSAttributedString(string: caption, attributes: cAttr)
        let vStr = NSAttributedString(string: value, attributes: vAttr)
        let cSize = cStr.size()
        let vSize = vStr.size()
        let sampleW = NSAttributedString(string: widthSample, attributes: vAttr).size().width
        let gap: CGFloat = -1  // matches the old VStack(spacing: -1)
        let width = ceil(max(cSize.width, vSize.width, sampleW)) + 2
        let height = ceil(cSize.height + vSize.height + gap)
        return render(width: width, height: height) { size in
            vStr.draw(at: NSPoint(x: (size.width - vSize.width) / 2, y: 0))
            cStr.draw(at: NSPoint(x: (size.width - cSize.width) / 2, y: vSize.height + gap))
        }
    }

    /// The network read-out: a download row (↓) over an upload row (↑) — a small
    /// direction arrow flush left with the rate flush right, so the two rows form a
    /// tidy column that holds steady (sized to `widthSample`). The digits use the
    /// monospaced value font; the arrow uses the plain system font at the same size.
    static func networkRows(
        down: String, up: String, color: NSColor, widthSample: String, size: CGFloat = 9
    ) -> NSImage {
        let arrowAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color,
        ]
        let figAttr: [NSAttributedString.Key: Any] = [
            .font: valueFont(size: size, weight: .semibold), .foregroundColor: color,
        ]
        let downArrow = NSAttributedString(string: "\u{2193}", attributes: arrowAttr)
        let upArrow = NSAttributedString(string: "\u{2191}", attributes: arrowAttr)
        let downFig = NSAttributedString(string: down, attributes: figAttr)
        let upFig = NSAttributedString(string: up, attributes: figAttr)
        let arrowW = ceil(max(downArrow.size().width, upArrow.size().width))
        let gap: CGFloat = 3
        let figSampleW = NSAttributedString(string: widthSample, attributes: figAttr).size().width
        let figW = ceil(max(downFig.size().width, upFig.size().width, figSampleW))
        let rowH = max(downFig.size().height, upFig.size().height)
        let width = arrowW + gap + figW + 1
        let height = ceil(rowH * 2)
        return render(width: width, height: height) { size in
            downArrow.draw(at: NSPoint(x: 0, y: rowH))
            upArrow.draw(at: NSPoint(x: 0, y: 0))
            downFig.draw(at: NSPoint(x: size.width - downFig.size().width, y: rowH))
            upFig.draw(at: NSPoint(x: size.width - upFig.size().width, y: 0))
        }
    }

    /// The network figures WITHOUT the direction arrows — a download rate over an
    /// upload rate, right-aligned — for the activity-LED read-out, where blinking
    /// LEDs (drawn separately, to the left) carry the direction instead of arrows.
    static func networkFigures(
        down: String, up: String, color: NSColor, widthSample: String, size: CGFloat = 9
    ) -> NSImage {
        let figAttr: [NSAttributedString.Key: Any] = [
            .font: valueFont(size: size, weight: .semibold), .foregroundColor: color,
        ]
        let downFig = NSAttributedString(string: down, attributes: figAttr)
        let upFig = NSAttributedString(string: up, attributes: figAttr)
        let figSampleW = NSAttributedString(string: widthSample, attributes: figAttr).size().width
        let figW = ceil(max(downFig.size().width, upFig.size().width, figSampleW))
        let rowH = max(downFig.size().height, upFig.size().height)
        let width = figW + 1
        let height = ceil(rowH * 2)
        return render(width: width, height: height) { size in
            downFig.draw(at: NSPoint(x: size.width - downFig.size().width, y: rowH))
            upFig.draw(at: NSPoint(x: size.width - upFig.size().width, y: 0))
        }
    }

    // MARK: - Bitmap

    /// Draw into a crisp, cached retina bitmap (point coordinates, origin
    /// bottom-left). Non-template so the colour tints survive the menu bar (the
    /// system would otherwise flatten a template image to one colour).
    static func render(width: CGFloat, height: CGFloat, _ draw: (NSSize) -> Void) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pxW = max(1, Int((width * scale).rounded()))
        let pxH = max(1, Int((height * scale).rounded()))
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage(size: NSSize(width: width, height: height)) }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSSize(width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}
