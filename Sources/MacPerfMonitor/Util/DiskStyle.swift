import AppKit
import MacPerfMonitorCore
import SwiftUI

enum DiskStyle {
    static let read = Color.blue
    static let write = Color.orange

    /// Utilization gauge tint: neutral until the disk is genuinely busy.
    static func utilization(_ percent: Double) -> Color {
        percent >= 90 ? .red : percent >= 60 ? .orange : .secondary
    }

    // MARK: - Capacity bar

    // The capacity slices use a fixed five-slot categorical order validated
    // for adjacent-pair colorblind separation on light and dark surfaces
    // (adjacent hues in render order: blue, orange, aqua, yellow, magenta).
    // Slices always render in this order: named volumes take slots 0 to 2,
    // purgeable is always slot 3, folded "other volumes" slot 4, and free is
    // a recessive track rather than a data hue. Reordering the slots breaks
    // the validated adjacency; do not shuffle them.
    private static let slots: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5),  // blue
        dynamic(light: 0xEB6834, dark: 0xD95926),  // orange
        dynamic(light: 0x1BAF7A, dark: 0x199E70),  // aqua
        dynamic(light: 0xEDA100, dark: 0xC98500),  // yellow (purgeable)
        dynamic(light: 0xE87BA4, dark: 0xD55181),  // magenta (other volumes)
    ]

    static func capacityColor(for slice: DiskCapacitySlice, namedIndex: Int) -> Color {
        switch slice.kind {
        case .volume: return slots[min(namedIndex, 2)]
        case .purgeable: return slots[3]
        case .otherVolumes: return slots[4]
        case .free: return freeTrack
        }
    }

    /// Free space is absence, not a data series: a near-surface track fill.
    static let freeTrack = Color.primary.opacity(0.10)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    let match = appearance.bestMatch(from: [.aqua, .darkAqua])
                    return NSColor(hex: match == .darkAqua ? dark : light)
                }))
    }
}

extension NSColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
