import CMacPerfMonitor
import Foundation

/// Reads the NVMe SMART / Health log through the `IONVMeSMARTUserClient`
/// plug-in interface. The C shim fetches the raw 512 bytes (the COM-style
/// plug-in dance cannot be written in Swift); everything here is parsing, so
/// the decoder is fully testable against fixture blobs. Never called from the
/// sampler: the Disk page pulls it at its slow poll cadence, and the caller
/// throttles per device.
public final class NVMeSMARTReader {
    private let fetch: (UInt64) -> [UInt8]?

    public convenience init() {
        self.init(fetch: Self.fetchViaShim)
    }

    init(fetch: @escaping (UInt64) -> [UInt8]?) {
        self.fetch = fetch
    }

    /// Try each candidate registry entry (the controller, then the block
    /// storage device; which one exposes the plug-in varies by macOS release)
    /// and return the first log that decodes. Nil means SMART is simply not
    /// available for this disk, the expected outcome for externals.
    public func read(candidateRegistryEntryIDs: [UInt64]) -> NVMeSMARTSnapshot? {
        for id in candidateRegistryEntryIDs {
            if let bytes = fetch(id), let snapshot = Self.parse(Data(bytes)) {
                return snapshot
            }
        }
        return nil
    }

    /// Decode the standard 512-byte SMART / Health log page (NVMe spec figure
    /// 194 layout, all fields little-endian, 128-bit counters truncated to
    /// their low 64 bits). Returns nil for short input; a real log is always
    /// exactly 512 bytes.
    static func parse(_ data: Data) -> NVMeSMARTSnapshot? {
        guard data.count >= 512 else { return nil }
        let kelvin = uint16(data, at: 1)
        return NVMeSMARTSnapshot(
            criticalWarning: data[data.startIndex],
            temperatureCelsius: kelvin == 0 ? nil : Double(kelvin) - 273.15,
            availableSparePercent: data[data.startIndex + 3],
            spareThresholdPercent: data[data.startIndex + 4],
            percentageUsed: data[data.startIndex + 5],
            dataUnitsRead: uint64(data, at: 32),
            dataUnitsWritten: uint64(data, at: 48),
            hostReadCommands: uint64(data, at: 64),
            hostWriteCommands: uint64(data, at: 80),
            controllerBusyTimeMinutes: uint64(data, at: 96),
            powerCycles: uint64(data, at: 112),
            powerOnHours: uint64(data, at: 128),
            unsafeShutdowns: uint64(data, at: 144),
            mediaErrors: uint64(data, at: 160),
            errorLogEntries: uint64(data, at: 176))
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for byte in 0..<8 {
            value |= UInt64(data[base + byte]) << (8 * byte)
        }
        return value
    }

    private static func fetchViaShim(_ registryEntryID: UInt64) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 512)
        guard cmacperfmonitor_nvme_smart_read(registryEntryID, &buffer) == 0 else { return nil }
        return buffer
    }
}
