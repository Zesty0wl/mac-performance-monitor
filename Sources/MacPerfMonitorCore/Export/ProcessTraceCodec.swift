// SPDX-License-Identifier: MIT

import Compression
import Foundation

/// Errors surfaced when reading or writing a `.mpmtrace` container.
public enum ProcessTraceError: Error, LocalizedError, Equatable {
    /// The data is too short or is not a trace container.
    case notATrace
    /// The container header is present but its version is newer than this build
    /// understands.
    case unsupportedContainerVersion(UInt8)
    /// The compression algorithm byte is one this build does not implement.
    case unsupportedCompression(UInt8)
    /// The payload could not be decompressed or decoded.
    case corruptPayload
    /// The container or its decoded payload exceeds the supported import size.
    case traceTooLarge
    /// The decoded document's schema version is not supported by this build.
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .notATrace:
            return "This file is not a Mac Performance Monitor trace."
        case .unsupportedContainerVersion(let v):
            return "This trace uses a newer container format (v\(v)). Update the app to open it."
        case .unsupportedCompression(let a):
            return "This trace uses an unsupported compression method (\(a))."
        case .corruptPayload:
            return "This trace file is damaged and could not be read."
        case .traceTooLarge:
            return "This trace is too large to open safely."
        case .unsupportedFormatVersion(let v):
            return "This trace uses an unsupported data format (schema v\(v))."
        }
    }
}

/// Reads and writes the compressed `.mpmtrace` container that wraps a
/// `ProcessTraceDocument`.
///
/// Layout: a fixed 8-byte header (magic `MPMT`, container version, compression
/// algorithm, two reserved bytes) followed by the compressed JSON payload. The
/// header lets a reader validate the file and pick the right decompressor before
/// it trusts a single byte of the payload, and versions the container itself
/// independently of the JSON schema (`ProcessTraceDocument.formatVersion`).
public enum ProcessTraceCodec {
    /// Preferred file extension for the container.
    public static let fileExtension = "mpmtrace"

    /// "MPMT": Mac Performance Monitor Trace.
    private static let magic: [UInt8] = [0x4D, 0x50, 0x4D, 0x54]
    private static let containerVersion: UInt8 = 1
    private static let headerLength = 8
    public static let maximumContainerBytes = 64 * 1024 * 1024
    public static let maximumDecodedPayloadBytes = 256 * 1024 * 1024
    public static let maximumPointCount = 1_000_000
    public static let maximumProcessCount = 4_096
    private static let decompressionChunkBytes = 64 * 1024
    private static let maximumShortStringLength = 1_024
    private static let maximumPathLength = 16_384
    private static let maximumCPUPercent = 1_000_000.0
    private static let maximumNetworkBytesPerSecond = 1_000_000_000_000_000.0
    private static let maximumDiskBytesPerSecond = 1_000_000_000_000_000.0
    private static let earliestSupportedDate = Date.distantPast.timeIntervalSince1970
    private static let latestSupportedDate = Date.distantFuture.timeIntervalSince1970

    /// Compression algorithms the container can carry. Stored as a byte so the
    /// choice can change later without breaking older files.
    private enum Algorithm: UInt8 {
        case zlib = 0

        var nsAlgorithm: NSData.CompressionAlgorithm {
            switch self {
            case .zlib: return .zlib
            }
        }

        var compressionAlgorithm: compression_algorithm {
            switch self {
            case .zlib: return COMPRESSION_ZLIB
            }
        }
    }

    /// The algorithm new files are written with.
    private static let writeAlgorithm: Algorithm = .zlib

    // MARK: Encoding

    /// Encode and compress a document into a `.mpmtrace` container.
    public static func encode(_ document: ProcessTraceDocument) throws -> Data {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = try encoder.encode(document)
        guard json.count <= maximumDecodedPayloadBytes else {
            throw ProcessTraceError.traceTooLarge
        }
        let compressed = try (json as NSData).compressed(using: writeAlgorithm.nsAlgorithm) as Data
        guard compressed.count <= maximumContainerBytes - headerLength else {
            throw ProcessTraceError.traceTooLarge
        }

        var out = Data(capacity: headerLength + compressed.count)
        out.append(contentsOf: magic)
        out.append(containerVersion)
        out.append(writeAlgorithm.rawValue)
        out.append(contentsOf: [0, 0])  // reserved
        out.append(compressed)
        return out
    }

    // MARK: Decoding

    /// Validate, decompress, and decode a `.mpmtrace` container.
    public static func decode(_ data: Data) throws -> ProcessTraceDocument {
        guard data.count > headerLength else { throw ProcessTraceError.notATrace }
        guard data.count <= maximumContainerBytes else { throw ProcessTraceError.traceTooLarge }

        // Copy the header into a plain array so slicing does not depend on the
        // source Data's start index.
        let header = [UInt8](data.prefix(headerLength))
        guard Array(header[0..<4]) == magic else { throw ProcessTraceError.notATrace }

        let version = header[4]
        guard version == containerVersion else {
            throw ProcessTraceError.unsupportedContainerVersion(version)
        }
        guard let algorithm = Algorithm(rawValue: header[5]) else {
            throw ProcessTraceError.unsupportedCompression(header[5])
        }
        guard header[6] == 0, header[7] == 0 else {
            throw ProcessTraceError.corruptPayload
        }

        let payload = data.subdata(in: data.startIndex.advanced(by: headerLength)..<data.endIndex)
        let json: Data
        do {
            json = try decompress(
                payload,
                using: algorithm,
                maximumOutputSize: maximumDecodedPayloadBytes)
        } catch ProcessTraceError.traceTooLarge {
            throw ProcessTraceError.traceTooLarge
        } catch {
            throw ProcessTraceError.corruptPayload
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let document: ProcessTraceDocument
        do {
            document = try decoder.decode(ProcessTraceDocument.self, from: json)
        } catch {
            throw ProcessTraceError.corruptPayload
        }
        guard document.formatVersion == ProcessTraceDocument.currentFormatVersion else {
            throw ProcessTraceError.unsupportedFormatVersion(document.formatVersion)
        }
        try validate(document)
        return document
    }

    /// Read at most one supported container from disk, then decode it. The size
    /// check is repeated after opening so a file that changes during the read
    /// cannot bypass the allocation bound.
    public static func decode(contentsOf url: URL) throws -> ProcessTraceDocument {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > maximumContainerBytes
        {
            throw ProcessTraceError.traceTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumContainerBytes + 1) ?? Data()
        guard data.count <= maximumContainerBytes else {
            throw ProcessTraceError.traceTooLarge
        }
        return try decode(data)
    }

    private static func validate(_ document: ProcessTraceDocument) throws {
        guard document.formatVersion == ProcessTraceDocument.currentFormatVersion else {
            throw ProcessTraceError.unsupportedFormatVersion(document.formatVersion)
        }
        guard document.processes.count <= maximumProcessCount,
            validDate(document.exportedAt),
            validDate(document.startDate),
            validDate(document.endDate),
            document.startDate <= document.endDate,
            document.resolutionSeconds.isFinite,
            document.resolutionSeconds > 0,
            validShortString(document.generator),
            validShortString(document.source.osVersion),
            validOptionalShortString(document.source.machineModel),
            validOptionalShortString(document.source.hostLabel)
        else {
            throw ProcessTraceError.corruptPayload
        }

        var identities = Set<ProcessIdentity>()
        var pointCount = 0
        for series in document.processes {
            guard validDate(series.startTime),
                validShortString(series.name),
                validOptionalString(series.executablePath, maximumLength: maximumPathLength),
                validOptionalShortString(series.bundleID),
                validOptionalShortString(series.teamID),
                validOptionalShortString(series.architecture),
                identities.insert(series.identity).inserted,
                series.points.count <= maximumPointCount - pointCount
            else {
                throw ProcessTraceError.corruptPayload
            }
            pointCount += series.points.count

            var previousTimestamp: Double?
            var previousDiskRead: UInt64?
            var previousDiskWritten: UInt64?
            for point in series.points {
                let diskRateIsValid: Bool
                if let previousTimestamp, let previousDiskRead, let previousDiskWritten {
                    let interval = point.t - previousTimestamp
                    let readDelta =
                        point.diskRead >= previousDiskRead
                        ? Double(point.diskRead - previousDiskRead) : 0
                    let writeDelta =
                        point.diskWritten >= previousDiskWritten
                        ? Double(point.diskWritten - previousDiskWritten) : 0
                    let rate = (readDelta + writeDelta) / interval
                    diskRateIsValid = rate.isFinite && rate <= maximumDiskBytesPerSecond
                } else {
                    diskRateIsValid = true
                }
                guard validTimestamp(point.t),
                    point.t >= document.startDate.timeIntervalSince1970,
                    point.t <= document.endDate.timeIntervalSince1970,
                    point.cpu.isFinite, point.cpu >= 0, point.cpu <= maximumCPUPercent,
                    point.fd >= 0,
                    point.net.isFinite, point.net >= 0,
                    point.net <= maximumNetworkBytesPerSecond,
                    diskRateIsValid,
                    previousTimestamp.map({ point.t > $0 }) ?? true
                else {
                    throw ProcessTraceError.corruptPayload
                }
                previousTimestamp = point.t
                previousDiskRead = point.diskRead
                previousDiskWritten = point.diskWritten
            }
        }
    }

    private static func validDate(_ date: Date) -> Bool {
        validTimestamp(date.timeIntervalSince1970)
    }

    private static func validTimestamp(_ value: Double) -> Bool {
        value.isFinite && value >= earliestSupportedDate && value <= latestSupportedDate
    }

    private static func validShortString(_ value: String) -> Bool {
        value.count <= maximumShortStringLength
    }

    private static func validOptionalShortString(_ value: String?) -> Bool {
        validOptionalString(value, maximumLength: maximumShortStringLength)
    }

    private static func validOptionalString(_ value: String?, maximumLength: Int) -> Bool {
        value.map { $0.count <= maximumLength } ?? true
    }

    static func decompressZlib(_ data: Data, maximumOutputSize: Int) throws -> Data {
        try decompress(data, using: .zlib, maximumOutputSize: maximumOutputSize)
    }

    private static func decompress(
        _ data: Data,
        using algorithm: Algorithm,
        maximumOutputSize: Int
    ) throws -> Data {
        guard maximumOutputSize > 0, !data.isEmpty else {
            throw ProcessTraceError.corruptPayload
        }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: decompressionChunkBytes)
        defer { destination.deallocate() }

        return try data.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                throw ProcessTraceError.corruptPayload
            }

            var stream = compression_stream(
                dst_ptr: destination,
                dst_size: decompressionChunkBytes,
                src_ptr: source,
                src_size: sourceBytes.count,
                state: nil)
            guard
                compression_stream_init(
                    &stream,
                    COMPRESSION_STREAM_DECODE,
                    algorithm.compressionAlgorithm
                ) != COMPRESSION_STATUS_ERROR
            else {
                throw ProcessTraceError.corruptPayload
            }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = source
            stream.src_size = sourceBytes.count

            var output = Data()
            output.reserveCapacity(
                min(maximumOutputSize, max(decompressionChunkBytes, data.count * 4)))

            while true {
                let sourceBytesBefore = stream.src_size
                stream.dst_ptr = destination
                stream.dst_size = decompressionChunkBytes

                let status = compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = decompressionChunkBytes - stream.dst_size

                guard produced <= maximumOutputSize - output.count else {
                    throw ProcessTraceError.traceTooLarge
                }
                output.append(destination, count: produced)

                switch status {
                case COMPRESSION_STATUS_END:
                    guard stream.src_size == 0 else {
                        throw ProcessTraceError.corruptPayload
                    }
                    return output
                case COMPRESSION_STATUS_OK:
                    guard produced > 0 || stream.src_size < sourceBytesBefore else {
                        throw ProcessTraceError.corruptPayload
                    }
                default:
                    throw ProcessTraceError.corruptPayload
                }
            }
        }
    }
}
