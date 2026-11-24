// SPDX-License-Identifier: MIT
import Foundation

/// How much memory the Mac needs, measured against installed RAM: the figure
/// the menu bar's RAM read-out shows by default. See docs/memory-taxonomy.md.
///
/// The pressure index (`PressureIndex`) only moves once macOS compresses or
/// swaps heavily, so on a Mac with plenty of RAM it reads 0 however much is in
/// use. This figure reads the way people expect a RAM gauge to read, and keeps
/// going past 100% when the Mac runs out of RAM:
///
///     bytes   = appMemory + wired + compressorStored
///     percent = bytes / totalRAM * 100
///
/// `compressorStored` is the original size of everything the compressor
/// holds, including the part it has moved out to swap. While everything fits,
/// this is close to Activity Monitor's Memory Used. Once it does not, the
/// excess over 100% is what macOS keeps compressed or in swap. Cached files
/// are left out because macOS frees them on demand.
public enum MemoryUsage {
    /// Memory in use, in bytes. Falls back to the compressor's footprint in
    /// RAM (`compressed`) when the original size was not read, which
    /// undercounts only what compression saved.
    public static func bytes(
        appMemory: UInt64, wired: UInt64, compressed: UInt64, compressorStored: UInt64?
    ) -> UInt64 {
        appMemory &+ wired &+ (compressorStored ?? compressed)
    }

    /// `bytes` as a percentage of installed RAM. Not capped: above 100, apps
    /// need more memory than the Mac has.
    public static func percent(bytes: UInt64, totalRAM: UInt64) -> Double {
        guard totalRAM > 0 else { return 0 }
        return Double(bytes) / Double(totalRAM) * 100
    }
}

extension SystemSample {
    /// Memory in use, in bytes, counting compressed memory at its original
    /// size. Can exceed `totalRAM`. See `MemoryUsage`.
    public var memoryUsageBytes: UInt64 {
        MemoryUsage.bytes(
            appMemory: appMemory, wired: wired, compressed: compressed,
            compressorStored: compressorStoredBytes)
    }

    /// `memoryUsageBytes` as a percentage of installed RAM; above 100 when the
    /// Mac needs more memory than it has.
    public var memoryUsagePercent: Double {
        MemoryUsage.percent(bytes: memoryUsageBytes, totalRAM: totalRAM)
    }
}
