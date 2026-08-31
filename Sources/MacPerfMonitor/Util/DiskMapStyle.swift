import AppKit
import MacPerfMonitorCore
import SwiftUI

/// How the treemap colours cells.
enum DiskMapColorMode: String, CaseIterable, Identifiable {
    case kind = "Kind"
    case age = "Age"
    case safety = "Safety"
    case depth = "Depth"
    var id: String { rawValue }

    var help: String {
        switch self {
        case .kind: return "Colour by what a file is: video, images, code, archives and so on."
        case .age:
            return "Colour by when a file was last modified, cool for recent and warm for old."
        case .safety:
            return
                "Colour by how safe it is to remove: caches in green, your files in blue, app-managed in orange, macOS in grey."
        case .depth: return "One hue, darker the deeper an item sits in the folder tree."
        }
    }
}

/// The Disk Map's palette: a categorical ramp per file kind, a five-band age
/// ramp, and a depth shade, each with a light and a dark variant chosen to
/// read against the page background of that appearance. `DiskStyle.slots` is
/// the capacity bar's contract and is not touched; this ramp is the map's.
enum DiskMapStyle {
    // MARK: - Kinds

    /// Light and dark hex pairs. Hues were picked so the kinds most likely to
    /// sit side by side in a real home folder (video/images/audio, code/data,
    /// archives/documents) differ in hue and lightness at once.
    private static let kindHex: [FileKind: (light: UInt32, dark: UInt32)] = [
        .folder: (0x7C8DA6, 0x5F6F87),
        .application: (0x3B82F6, 0x4F8DF7),
        .video: (0x8B5CF6, 0x9D74F7),
        .image: (0xF97316, 0xF08030),
        .audio: (0xEC4899, 0xE45C9E),
        .archive: (0x14B8A6, 0x22B5A5),
        .document: (0xEAB308, 0xD4A517),
        .code: (0x6366F1, 0x7478F2),
        .data: (0x0EA5E9, 0x2AA9E4),
        .cache: (0xA16207, 0xB07414),
        .system: (0x64748B, 0x707E94),
        .other: (0x9CA3AF, 0x7B8290),
    ]

    static func kindColor(_ kind: FileKind, dark: Bool) -> NSColor {
        let pair = kindHex[kind] ?? kindHex[.other]!
        return NSColor(hex: dark ? pair.dark : pair.light)
    }

    // MARK: - Age

    static let ageBandLabels = [
        "Under 1 month", "1 to 6 months", "6 to 12 months", "1 to 2 years", "Over 2 years",
    ]

    private static let ageHex: [(light: UInt32, dark: UInt32)] = [
        (0x3B82F6, 0x4F8DF7),  // cool blue: recent
        (0x14B8A6, 0x22B5A5),  // teal
        (0xEAB308, 0xD4A517),  // yellow
        (0xF97316, 0xF08030),  // orange
        (0xB91C1C, 0xC63B3B),  // deep red: old
    ]

    /// 0 (recent) to 4 (old). Unknown dates land in the oldest band so they
    /// never masquerade as fresh.
    static func ageBand(modified: UInt32, now: UInt32) -> Int {
        guard modified > 0, now > modified else { return modified > 0 ? 0 : 4 }
        let days = Double(now - modified) / 86_400
        switch days {
        case ..<30: return 0
        case ..<182: return 1
        case ..<365: return 2
        case ..<730: return 3
        default: return 4
        }
    }

    static func ageColor(band: Int, dark: Bool) -> NSColor {
        let pair = ageHex[min(max(band, 0), ageHex.count - 1)]
        return NSColor(hex: dark ? pair.dark : pair.light)
    }

    // MARK: - Safety

    private static let safetyHex: [DiskMapSafetyTier: (light: UInt32, dark: UInt32)] = [
        .systemProtected: (0x64748B, 0x707E94),
        .managedByApp: (0xF97316, 0xF08030),
        .reviewBeforeRemoving: (0x3B82F6, 0x4F8DF7),
        .safeToRemove: (0x16A34A, 0x2BB85E),
    ]

    static func safetyColor(_ tier: DiskMapSafetyTier, dark: Bool) -> NSColor {
        let pair = safetyHex[tier]!
        return NSColor(hex: dark ? pair.dark : pair.light)
    }

    static func safetyTint(_ tier: DiskMapSafetyTier) -> Color {
        dynamic { safetyColor(tier, dark: $0) }
    }

    // MARK: - Depth

    /// One blue, stepping darker and more saturated with each level so the
    /// nesting reads even without borders.
    static func depthColor(depth: Int, dark: Bool) -> NSColor {
        let level = CGFloat(min(max(depth, 0), 5))
        if dark {
            return NSColor(
                hue: 0.59, saturation: 0.45 + 0.07 * level, brightness: 0.78 - 0.08 * level,
                alpha: 1)
        }
        return NSColor(
            hue: 0.59, saturation: 0.35 + 0.09 * level, brightness: 0.92 - 0.07 * level, alpha: 1)
    }

    // MARK: - Cells

    static func cellColor(
        mode: DiskMapColorMode, kind: FileKind, isDirectory: Bool, modified: UInt32, depth: Int,
        tier: DiskMapSafetyTier, now: UInt32, dark: Bool
    ) -> NSColor {
        switch mode {
        case .kind:
            return kindColor(isDirectory && kind == .folder ? .folder : kind, dark: dark)
        case .age:
            return ageColor(band: ageBand(modified: modified, now: now), dark: dark)
        case .safety:
            return safetyColor(tier, dark: dark)
        case .depth:
            return depthColor(depth: depth, dark: dark)
        }
    }

    /// The fill of a subdivided directory, seen in the gutters between its
    /// children and under its title strip.
    static func containerFill(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.045)
    }

    static func containerBorder(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.12)
    }

    /// The "N more items" cell: deliberately recessive.
    static func aggregateFill(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
    }

    /// Text that reads on a given fill.
    static func labelColor(on fill: NSColor) -> NSColor {
        let rgb = fill.usingColorSpace(.sRGB) ?? fill
        let luminance =
            0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.62
            ? NSColor.black.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.94)
    }

    // MARK: - Legends (SwiftUI)

    struct LegendEntry: Identifiable {
        let label: String
        let color: Color
        var id: String { label }
    }

    static func legend(for mode: DiskMapColorMode) -> [LegendEntry] {
        switch mode {
        case .kind:
            return ([.folder] + FileKind.displayOrder).map { kind in
                LegendEntry(
                    label: kind == .folder ? "Folders" : kind.label,
                    color: dynamic { kindColor(kind, dark: $0) })
            }
        case .age:
            return ageBandLabels.enumerated().map { band, label in
                LegendEntry(label: label, color: dynamic { ageColor(band: band, dark: $0) })
            }
        case .safety:
            return [
                DiskMapSafetyTier.safeToRemove, .reviewBeforeRemoving, .managedByApp,
                .systemProtected,
            ].map { tier in
                LegendEntry(label: tier.label, color: dynamic { safetyColor(tier, dark: $0) })
            }
        case .depth:
            return (0..<4).map { depth in
                LegendEntry(
                    label: depth == 0 ? "Top level" : "\(depth) deep",
                    color: dynamic { depthColor(depth: depth, dark: $0) })
            }
        }
    }

    private static func dynamic(_ make: @escaping (Bool) -> NSColor) -> Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    make(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
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
