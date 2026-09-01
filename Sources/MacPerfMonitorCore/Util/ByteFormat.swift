import Foundation

/// Human-readable byte formatting shared across the CLI and UI.
///
/// Every numeric format passes `locale: .current` deliberately. `String(format:)`
/// without a locale formats in the POSIX locale, so "1.4 GB" stays "1.4 GB" for
/// a reader whose language writes "1,4 GB". Simplified Chinese uses the same
/// decimal separator as English, so this was invisible until the second
/// language; German, French, Spanish and Russian all show it.
public enum ByteFormat {
    /// Format a byte count using binary units (KiB/MiB/GiB), e.g. "1.4 GB".
    /// Uses the conventional macOS labels (GB) while computing on 1024 bases,
    /// matching how Activity Monitor presents memory.
    public static func string(_ bytes: UInt64, fractionDigits: Int = 1) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) bytes"
        }
        return String(
            format: "%.\(fractionDigits)f %@", locale: .current, value, units[unitIndex])
    }

    /// Format a fraction (0...1) as a percentage string, e.g. "42%".
    public static func percent(_ fraction: Double, fractionDigits: Int = 0) -> String {
        String(format: "%.\(fractionDigits)f%%", locale: .current, fraction * 100)
    }

    /// Format a throughput (bytes per second) for charts, menus, and tooltips,
    /// auto-scaling on 1024 bases like `string`, e.g. "2.5 MB/s" or "340 KB/s".
    /// Sub-kilobyte rates read as a whole number of bytes per second.
    public static func rate(_ bytesPerSecond: Double, fractionDigits: Int = 1) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = max(bytesPerSecond, 0)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 { return "\(Int(value.rounded())) B/s" }
        return String(
            format: "%.\(fractionDigits)f %@", locale: .current, value, units[unitIndex])
    }

    /// A very compact throughput for the cramped menu bar read-out: number plus a
    /// single unit letter, no "/s" and no "B" (the ↓/↑ arrows beside it carry the
    /// direction and the menu/tooltip the full units), e.g. "2.5M", "340K", "12G".
    /// One decimal below 10 so small movers stay legible, whole numbers above.
    public static func rateCompact(_ bytesPerSecond: Double) -> String {
        let units = ["", "K", "M", "G", "T"]
        var value = max(bytesPerSecond, 0)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 { return "\(Int(value.rounded()))" }
        if value < 10 {
            return String(format: "%.1f%@", locale: .current, value, units[unitIndex])
        }
        return String(format: "%.0f%@", locale: .current, value, units[unitIndex])
    }
}
