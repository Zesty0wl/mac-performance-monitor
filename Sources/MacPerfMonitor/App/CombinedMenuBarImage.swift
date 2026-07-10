import AppKit
import MacPerfMonitorCore

struct CombinedMenuBarReadout {
    var metric: MenuBarMetric
    var value: String
    var secondaryValue: String?
    var isAlarm: Bool
}

extension MenuBarMetric {
    func isAlarm(in activeKinds: Set<Alert.Kind>) -> Bool {
        switch self {
        case .pressure:
            return !activeKinds.isDisjoint(with: [
                .criticalPressure, .swap, .processCeiling, .leak,
            ])
        case .cpu:
            return activeKinds.contains(.highCPU)
        case .gpu, .energy, .network, .disk:
            return false
        }
    }
}

@MainActor
enum CombinedMenuBarReadouts {
    static func current(
        for metrics: [MenuBarMetric], model: SamplerModel
    ) -> [CombinedMenuBarReadout] {
        metrics.map { metric in
            let values = values(for: metric, model: model)
            return CombinedMenuBarReadout(
                metric: metric, value: values.0, secondaryValue: values.1,
                isAlarm: metric.isAlarm(in: model.activeAlertKinds))
        }
    }

    private static func values(
        for metric: MenuBarMetric, model: SamplerModel
    ) -> (String, String?) {
        switch metric {
        case .pressure:
            let value = model.liveSystem.map { "\(Int($0.pressurePercent.rounded()))%" } ?? "--"
            return (value, nil)
        case .cpu:
            let value = model.smoothedCPU.map { "\(Int(($0.totalUsage * 100).rounded()))%" } ?? "--"
            return (value, nil)
        case .gpu:
            let value = model.smoothedGPUUtilization.map { "\(Int($0.rounded()))%" } ?? "--"
            return (value, nil)
        case .energy:
            guard let battery = model.latestBattery else { return ("--", nil) }
            if battery.isPresent {
                return ("\(Int(battery.chargePercent.rounded()))%", nil)
            }
            let watts = battery.systemPowerWatts
            return (watts > 0 ? "\(Int(watts.rounded()))W" : "--", nil)
        case .network:
            guard let rates = model.smoothedNetworkRates else { return ("--↓", "--↑") }
            return (
                "\(ByteFormat.rateCompact(rates.inBytesPerSec))↓",
                "\(ByteFormat.rateCompact(rates.outBytesPerSec))↑"
            )
        case .disk:
            guard let rates = model.smoothedDiskRates else { return ("--↓", "--↑") }
            return (
                "\(ByteFormat.rateCompact(rates.readBytesPerSec))↓",
                "\(ByteFormat.rateCompact(rates.writeBytesPerSec))↑"
            )
        }
    }
}

@MainActor
enum CombinedMenuBarImage {
    private static let stripSeparatorWidth: CGFloat = 1.5

    static func image(
        readouts: [CombinedMenuBarReadout], presentation: MenuBarPresentation
    ) -> NSImage {
        let image =
            switch presentation {
            case .focus:
                focusImage(readout: readouts[0])
            case .strip:
                stripImage(readouts: readouts)
            }
        // A status item is mirrored to every display. Template tinting lets each
        // menu bar choose its own contrasting color instead of sharing pixels
        // baked for whichever display was active on the last sample.
        image.isTemplate = true
        return image
    }

    static func metric(
        at imageX: CGFloat, readouts: [CombinedMenuBarReadout],
        presentation: MenuBarPresentation
    ) -> MenuBarMetric? {
        guard let first = readouts.first else { return nil }
        guard presentation == .strip else { return first.metric }

        let layouts = readouts.map { layout(for: $0) }
        var x: CGFloat = 0
        for index in readouts.indices {
            let end = x + layouts[index].width
            if imageX <= end { return readouts[index].metric }
            if index < readouts.count - 1 {
                let separatorEnd = end + stripSeparatorWidth
                if imageX < separatorEnd {
                    return imageX - end < stripSeparatorWidth / 2
                        ? readouts[index].metric : readouts[index + 1].metric
                }
                x = separatorEnd
            }
        }

        return readouts.last?.metric
    }

    private static func focusImage(readout: CombinedMenuBarReadout) -> NSImage {
        let color = NSColor.black
        let label = attributed(
            readout.metric.shortTitle,
            font: MenuBarReadoutImage.valueFont(size: 8, weight: .semibold), color: color)
        let hasDirectionalValues = readout.secondaryValue != nil
        let labelWidth: CGFloat = hasDirectionalValues ? 14 : ceil(label.size().width)
        let valueFont = MenuBarReadoutImage.valueFont(
            size: readout.secondaryValue == nil ? 13 * 1.05 : 13 * 0.95, weight: .bold)
        let primary =
            readout.secondaryValue == nil
            ? attributed(readout.value, font: valueFont, color: color)
            : directionalAttributed(
                readout.value, figureFont: valueFont,
                arrowFont: MenuBarReadoutImage.valueFont(size: 13, weight: .medium),
                color: color)
        let secondary = readout.secondaryValue.map {
            directionalAttributed(
                $0, figureFont: MenuBarReadoutImage.valueFont(size: 10.5 * 0.95, weight: .bold),
                arrowFont: MenuBarReadoutImage.valueFont(size: 10.5, weight: .medium),
                color: color)
        }
        let networkSample = readout.secondaryValue.map { _ in
            directionalAttributed(
                "999M↓", figureFont: valueFont,
                arrowFont: MenuBarReadoutImage.valueFont(size: 13, weight: .medium),
                color: color)
        }
        let gap: CGFloat = 4
        let valuesWidth = ceil(
            max(
                primary.size().width, secondary?.size().width ?? 0, networkSample?.size().width ?? 0
            ))
        let width = labelWidth + gap + valuesWidth + 1
        let height: CGFloat = secondary == nil ? 20 : 22

        return MenuBarReadoutImage.render(width: width, height: height) { size in
            if hasDirectionalValues {
                drawSymbol(
                    readout.metric.symbolName,
                    in: NSRect(x: 0, y: (size.height - 13) / 2, width: 13, height: 13),
                    color: color, pointSize: 11)
            } else {
                label.draw(at: NSPoint(x: 0, y: (size.height - label.size().height) / 2))
            }
            let valueX = labelWidth + gap
            if let secondary {
                primary.draw(
                    at: NSPoint(
                        x: valueX + valuesWidth - primary.size().width,
                        y: size.height - primary.size().height))
                secondary.draw(
                    at: NSPoint(x: valueX + valuesWidth - secondary.size().width, y: 0))
            } else {
                primary.draw(
                    at: NSPoint(
                        x: valueX,
                        y: (size.height - primary.size().height) / 2))
            }
        }
    }

    private static func stripImage(readouts: [CombinedMenuBarReadout]) -> NSImage {
        let layouts = readouts.map { layout(for: $0) }
        let contentWidth =
            layouts.reduce(0) { $0 + $1.width }
            + stripSeparatorWidth * CGFloat(max(0, layouts.count - 1))
        let width = contentWidth
        let height: CGFloat = 22

        return MenuBarReadoutImage.render(width: width, height: height) { size in
            var x: CGFloat = 0
            for (index, layout) in layouts.enumerated() {
                layout.draw(at: x, height: size.height)
                x += layout.width
                if index < layouts.count - 1 { x += stripSeparatorWidth }
            }
        }
    }

    private struct CellLayout {
        var width: CGFloat
        var draw: (_ x: CGFloat, _ height: CGFloat) -> Void

        func draw(at x: CGFloat, height: CGFloat) { draw(x, height) }
    }

    private static func layout(for readout: CombinedMenuBarReadout) -> CellLayout {
        let color = NSColor.black
        if let secondary = readout.secondaryValue {
            let labelWidth: CGFloat = 14
            let figureFont = MenuBarReadoutImage.valueFont(size: 10 * 0.95, weight: .bold)
            let arrowFont = MenuBarReadoutImage.valueFont(size: 10, weight: .medium)
            let top = directionalAttributed(
                readout.value, figureFont: figureFont, arrowFont: arrowFont, color: color)
            let bottom = directionalAttributed(
                secondary, figureFont: figureFont, arrowFont: arrowFont, color: color)
            let sample = directionalAttributed(
                "999M↓", figureFont: figureFont, arrowFont: arrowFont, color: color)
            let figuresWidth = ceil(max(top.size().width, bottom.size().width, sample.size().width))
            let gap: CGFloat = 2
            let width = labelWidth + gap + figuresWidth + 1
            return CellLayout(width: width) { x, height in
                drawSymbol(
                    readout.metric.symbolName,
                    in: NSRect(x: x, y: (height - 13) / 2, width: 13, height: 13),
                    color: color, pointSize: 11)
                top.draw(
                    at: NSPoint(x: x + width - top.size().width, y: height - top.size().height))
                bottom.draw(at: NSPoint(x: x + width - bottom.size().width, y: 0))
            }
        }

        let label = attributed(
            readout.metric.shortTitle,
            font: MenuBarReadoutImage.valueFont(size: 7, weight: .semibold), color: color)
        let font = MenuBarReadoutImage.valueFont(size: 11.5 * 1.05, weight: .bold)
        let compactValue =
            readout.value.hasSuffix("%") ? String(readout.value.dropLast()) : readout.value
        let value = attributed(compactValue, font: font, color: color)
        let sampleText = readout.value.hasSuffix("%") ? "100" : "199W"
        let sample = attributed(sampleText, font: font, color: color)
        let width = ceil(max(value.size().width, sample.size().width, label.size().width)) + 1
        return CellLayout(width: width) { x, height in
            label.draw(
                at: NSPoint(
                    x: x + (width - label.size().width) / 2,
                    y: height - label.size().height))
            value.draw(at: NSPoint(x: x + (width - value.size().width) / 2, y: 0))
        }
    }

    private static func attributed(
        _ text: String, font: NSFont, color: NSColor
    )
        -> NSAttributedString
    {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    private static func directionalAttributed(
        _ text: String, figureFont: NSFont, arrowFont: NSFont, color: NSColor
    ) -> NSAttributedString {
        guard let arrow = text.last else {
            return attributed(text, font: figureFont, color: color)
        }
        let result = NSMutableAttributedString(
            attributedString: attributed(
                String(text.dropLast()), font: figureFont, color: color))
        result.append(
            NSAttributedString(
                string: String(arrow),
                attributes: [.font: arrowFont, .foregroundColor: color]))
        return result
    }

    private static func drawSymbol(
        _ name: String, in rect: NSRect, color: NSColor, pointSize: CGFloat
    ) {
        guard
            let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let symbol = base.withSymbolConfiguration(
                .init(pointSize: pointSize, weight: .semibold))
        else { return }
        symbol.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
    }

}
