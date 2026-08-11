import Foundation

/// Decoded NVMe SMART / Health log for one controller. Available unprivileged
/// for the internal Apple SSD; external and USB enclosures usually refuse the
/// query, in which case the whole snapshot is absent rather than partial.
public struct NVMeSMARTSnapshot: Sendable, Equatable {
    /// Bit flags; 0 means no active warning. Bit 0 = spare below threshold,
    /// bit 1 = temperature out of range, bit 2 = media degraded, bit 3 =
    /// volatile memory backup failed.
    public var criticalWarning: UInt8
    /// Composite controller temperature; nil when the drive reports 0 Kelvin
    /// (unpopulated).
    public var temperatureCelsius: Double?
    /// Remaining spare capacity as a percentage of the initial spare pool.
    public var availableSparePercent: UInt8
    /// When available spare falls below this, the drive raises bit 0 above.
    public var spareThresholdPercent: UInt8
    /// Vendor estimate of life used, 0 to 100 (can exceed 100; capped at 255).
    public var percentageUsed: UInt8
    /// 1000-unit counts of 512-byte data units, low 64 bits of the spec's
    /// 128-bit counters (the high half is beyond any real drive's lifetime).
    public var dataUnitsRead: UInt64
    public var dataUnitsWritten: UInt64
    public var hostReadCommands: UInt64
    public var hostWriteCommands: UInt64
    public var controllerBusyTimeMinutes: UInt64
    public var powerCycles: UInt64
    public var powerOnHours: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaErrors: UInt64
    public var errorLogEntries: UInt64

    public var isHealthy: Bool { criticalWarning == 0 }

    /// Lifetime bytes, saturating rather than trapping on a fictional drive
    /// that overflows UInt64 (one data unit = 1000 x 512 bytes).
    public var bytesRead: UInt64 { Self.bytes(fromDataUnits: dataUnitsRead) }
    public var bytesWritten: UInt64 { Self.bytes(fromDataUnits: dataUnitsWritten) }

    static func bytes(fromDataUnits units: UInt64) -> UInt64 {
        let (value, overflow) = units.multipliedReportingOverflow(by: 512_000)
        return overflow ? .max : value
    }
}
