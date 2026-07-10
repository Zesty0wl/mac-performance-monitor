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
        case .gpu, .energy, .network:
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
                "\(ByteFormat.rateCompact(rates.outBytesPerSec))↑")
        }
    }
}

@MainActor
enum CombinedMenuBarImage {
    private static let stripSeparatorWidth: CGFloat = 1.5

    static func image(
        readouts: [CombinedMenuBarReadout], presentation: MenuBarPresentation,
        alarmCount: Int, isDark: Bool
    ) -> NSImage {
        switch presentation {
        case .focus:
            return focusImage(readout: readouts[0], alarmCount: alarmCount, isDark: isDark)
        case .strip:
            return stripImage(readouts: readouts, alarmCount: alarmCount, isDark: isDark)
        }
    }

    static func metric(
        at imageX: CGFloat, readouts: [CombinedMenuBarReadout],
        presentation: MenuBarPresentation, alarmCount: Int, isDark: Bool
    ) -> MenuBarMetric? {
        guard let first = readouts.first else { return nil }
        guard presentation == .strip else { return first.metric }

        let layouts = readouts.map { layout(for: $0, isDark: isDark) }
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

        if alarmCount > 0, let alarmMetric = readouts.first(where: \.isAlarm)?.metric {
            return alarmMetric
        }
        return readouts.last?.metric
    }

    private static func focusImage(
        readout: CombinedMenuBarReadout, alarmCount: Int, isDark: Bool
    ) -> NSImage {
        let color = normalColor(isDark: isDark)
        let label = attributed(
            readout.metric.shortTitle,
            font: MenuBarReadoutImage.valueFont(size: 8, weight: .semibold), color: color)
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
            max(primary.size().width, secondary?.size().width ?? 0, networkSample?.size().width ?? 0))
        let alarmWidth = alarmBadgeWidth(count: alarmCount)
        let width = ceil(label.size().width) + gap + valuesWidth + alarmWidth + 1
        let height: CGFloat = secondary == nil ? 20 : 22

        return MenuBarReadoutImage.render(width: width, height: height) { size in
            label.draw(at: NSPoint(x: 0, y: (size.height - label.size().height) / 2))
            let valueX = label.size().width + gap
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
            if alarmWidth > 0 {
                drawAlarmBadge(
                    count: alarmCount,
                    in: NSRect(x: size.width - alarmWidth + 1, y: (size.height - 12) / 2,
                               width: alarmWidth - 1, height: 12))
            }
        }
    }

    private static func stripImage(
        readouts: [CombinedMenuBarReadout], alarmCount: Int, isDark: Bool
    ) -> NSImage {
        let layouts = readouts.map { layout(for: $0, isDark: isDark) }
        let alarmWidth = alarmBadgeWidth(count: alarmCount)
        let contentWidth = layouts.reduce(0) { $0 + $1.width }
            + stripSeparatorWidth * CGFloat(max(0, layouts.count - 1))
        let width = contentWidth + alarmWidth
        let height: CGFloat = 22

        return MenuBarReadoutImage.render(width: width, height: height) { size in
            var x: CGFloat = 0
            for (index, layout) in layouts.enumerated() {
                layout.draw(at: x, height: size.height)
                x += layout.width
                if index < layouts.count - 1 { x += stripSeparatorWidth }
            }
            if alarmWidth > 0 {
                drawAlarmBadge(
                    count: alarmCount,
                    in: NSRect(x: size.width - alarmWidth + 1, y: (size.height - 12) / 2,
                               width: alarmWidth - 1, height: 12))
            }
        }
    }

    private struct CellLayout {
        var width: CGFloat
        var draw: (_ x: CGFloat, _ height: CGFloat) -> Void

        func draw(at x: CGFloat, height: CGFloat) { draw(x, height) }
    }

    private static func layout(
        for readout: CombinedMenuBarReadout, isDark: Bool
    ) -> CellLayout {
        let color = normalColor(isDark: isDark)
        if let secondary = readout.secondaryValue {
            let figureFont = MenuBarReadoutImage.valueFont(size: 10 * 0.95, weight: .bold)
            let arrowFont = MenuBarReadoutImage.valueFont(size: 10, weight: .medium)
            let top = directionalAttributed(
                readout.value, figureFont: figureFont, arrowFont: arrowFont, color: color)
            let bottom = directionalAttributed(
                secondary, figureFont: figureFont, arrowFont: arrowFont, color: color)
            let sample = directionalAttributed(
                "999M↓", figureFont: figureFont, arrowFont: arrowFont, color: color)
            let width = ceil(max(top.size().width, bottom.size().width, sample.size().width)) + 1
            return CellLayout(width: width) { x, height in
                top.draw(at: NSPoint(x: x + width - top.size().width, y: height - top.size().height))
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
                at: NSPoint(x: x + (width - label.size().width) / 2,
                            y: height - label.size().height))
            value.draw(at: NSPoint(x: x + (width - value.size().width) / 2, y: 0))
        }
    }

    private static func attributed(_ text: String, font: NSFont, color: NSColor)
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

    private static func normalColor(isDark: Bool) -> NSColor {
        isDark ? .white : .black
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

    private static func drawAlarmBadge(count: Int, in rect: NSRect) {
        let symbolRect = NSRect(x: rect.minX, y: rect.minY, width: 12, height: rect.height)
        drawSymbol(
            "exclamationmark.triangle.fill", in: symbolRect, color: .systemRed, pointSize: 10)
        if count > 1 {
            let countText = attributed(
                "\(count)", font: MenuBarReadoutImage.valueFont(size: 8, weight: .bold),
                color: .systemRed)
            countText.draw(
                at: NSPoint(
                    x: symbolRect.maxX,
                    y: rect.midY - countText.size().height / 2))
        }
    }

    private static func alarmBadgeWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return count > 1 ? 22 : 14
    }
}
