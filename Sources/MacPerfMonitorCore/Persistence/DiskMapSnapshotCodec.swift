// SPDX-License-Identifier: MIT

import Compression
import Foundation

public enum DiskMapSnapshotError: Error, LocalizedError, Equatable {
    case notASnapshot
    case unsupportedVersion(UInt8)
    case corrupt
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notASnapshot: return "This file is not a Disk Map snapshot."
        case .unsupportedVersion(let v):
            return "This snapshot uses a newer format (v\(v)). Update the app to open it."
        case .corrupt: return "This snapshot is damaged and could not be read."
        case .tooLarge: return "This snapshot is too large to open safely."
        }
    }
}

/// Reads and writes the `.mpmdisk` container that keeps the last scan between
/// launches, so the Disk Map opens instantly instead of rescanning three
/// million files.
///
/// Layout: a fixed 8-byte header (magic `MPMD`, container version, algorithm,
/// two reserved bytes) then an LZFSE payload. The payload is the arena's raw
/// little-endian arrays plus the name buffer, with the small structured parts
/// (scope, reconciliation) as JSON: a million nodes decode in the time it
/// takes to memcpy them, which JSON could never do. Every length is checked
/// against a cap before allocation and the decoded tree must pass
/// `FileTree.isStructurallyValid`, so a corrupt or hostile file cannot crash
/// a later walk.
public enum DiskMapSnapshotCodec {
    public static let fileExtension = "mpmdisk"

    /// "MPMD": Mac Performance Monitor Disk map.
    private static let magic: [UInt8] = [0x4D, 0x50, 0x4D, 0x44]
    private static let containerVersion: UInt8 = 1
    private static let payloadVersion: UInt32 = 1
    private static let headerLength = 8
    private static let algorithmLZFSE: UInt8 = 1
    public static let maximumContainerBytes = 512 * 1024 * 1024
    public static let maximumPayloadBytes = 1536 * 1024 * 1024
    public static let maximumNodeCount = 16_000_000
    public static let maximumNameBytes = 768 * 1024 * 1024
    private static let maximumJSONBytes = 4 * 1024 * 1024
    private static let decompressionChunkBytes = 256 * 1024

    // MARK: Encoding

    public static func encode(_ snapshot: DiskMapSnapshot) throws -> Data {
        let tree = snapshot.tree
        guard tree.nodeCount <= maximumNodeCount, tree.nameBytes.count <= maximumNameBytes else {
            throw DiskMapSnapshotError.tooLarge
        }
        var writer = PayloadWriter()
        writer.append(payloadVersion)
        let encoder = JSONEncoder()
        writer.appendBlob(try encoder.encode(snapshot.scope))
        writer.appendBlob(Data(snapshot.rootPath.utf8))
        writer.append(snapshot.scannedAt.timeIntervalSince1970.bitPattern)
        writer.append(snapshot.duration.bitPattern)
        writer.append(UInt8(snapshot.partial ? 1 : 0))
        writer.append(snapshot.smallFileThreshold)
        writer.append(UInt32(clamping: snapshot.revision))
        writer.appendBlob(try encoder.encode(snapshot.reconciliation))

        writer.append(UInt32(tree.nodeCount))
        writer.appendArray(tree.parent)
        writer.appendArray(tree.firstChild)
        writer.appendArray(tree.childCount)
        writer.appendArray(tree.bytes)
        writer.appendArray(tree.shared)
        writer.appendArray(tree.fileID)
        writer.appendArray(tree.modified)
        writer.appendArray(tree.count)
        writer.appendArray(tree.flags.map(\.rawValue))
        writer.appendArray(tree.kind.map(\.rawValue))
        writer.appendArray(tree.nameOffsets)
        writer.append(UInt32(tree.nameBytes.count))
        writer.appendArray(tree.nameBytes)

        guard writer.data.count <= maximumPayloadBytes else { throw DiskMapSnapshotError.tooLarge }
        let compressed = try (writer.data as NSData).compressed(using: .lzfse) as Data
        guard compressed.count <= maximumContainerBytes - headerLength else {
            throw DiskMapSnapshotError.tooLarge
        }
        var out = Data(capacity: headerLength + compressed.count)
        out.append(contentsOf: magic)
        out.append(containerVersion)
        out.append(algorithmLZFSE)
        out.append(contentsOf: [0, 0])
        out.append(compressed)
        return out
    }

    /// Write atomically with owner-only permissions: the file is an index of
    /// paths the user may have granted Full Disk Access to read.
    public static func write(_ snapshot: DiskMapSnapshot, to url: URL) throws {
        let data = try encode(snapshot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Decoding

    public static func decode(contentsOf url: URL) throws -> DiskMapSnapshot {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > maximumContainerBytes
        {
            throw DiskMapSnapshotError.tooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumContainerBytes + 1) ?? Data()
        guard data.count <= maximumContainerBytes else { throw DiskMapSnapshotError.tooLarge }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> DiskMapSnapshot {
        guard data.count > headerLength else { throw DiskMapSnapshotError.notASnapshot }
        guard data.count <= maximumContainerBytes else { throw DiskMapSnapshotError.tooLarge }
        let header = [UInt8](data.prefix(headerLength))
        guard Array(header[0..<4]) == magic else { throw DiskMapSnapshotError.notASnapshot }
        guard header[4] == containerVersion else {
            throw DiskMapSnapshotError.unsupportedVersion(header[4])
        }
        guard header[5] == algorithmLZFSE, header[6] == 0, header[7] == 0 else {
            throw DiskMapSnapshotError.corrupt
        }
        let compressed = data.subdata(
            in: data.startIndex.advanced(by: headerLength)..<data.endIndex)
        let payload = try decompress(compressed, maximumOutputSize: maximumPayloadBytes)

        var reader = PayloadReader(data: payload)
        guard try reader.read(UInt32.self) == payloadVersion else {
            throw DiskMapSnapshotError.corrupt
        }
        let decoder = JSONDecoder()
        let scope: DiskMapScope
        do {
            scope = try decoder.decode(
                DiskMapScope.self, from: try reader.readBlob(maximumJSONBytes))
        } catch {
            throw DiskMapSnapshotError.corrupt
        }
        let rootPath = String(decoding: try reader.readBlob(64 * 1024), as: UTF8.self)
        let scannedAt = Date(
            timeIntervalSince1970: Double(bitPattern: try reader.read(UInt64.self)))
        let duration = Double(bitPattern: try reader.read(UInt64.self))
        let partial = try reader.read(UInt8.self) != 0
        let threshold = try reader.read(UInt64.self)
        let revision = Int(try reader.read(UInt32.self))
        let reconciliation: DiskMapReconciliation
        do {
            reconciliation = try decoder.decode(
                DiskMapReconciliation.self, from: try reader.readBlob(maximumJSONBytes))
        } catch {
            throw DiskMapSnapshotError.corrupt
        }
        guard scannedAt.timeIntervalSince1970.isFinite, duration.isFinite, duration >= 0 else {
            throw DiskMapSnapshotError.corrupt
        }

        let nodeCount = Int(try reader.read(UInt32.self))
        guard nodeCount <= maximumNodeCount else { throw DiskMapSnapshotError.tooLarge }
        let parent: [Int32] = try reader.readArray(count: nodeCount)
        let firstChild: [Int32] = try reader.readArray(count: nodeCount)
        let childCount: [Int32] = try reader.readArray(count: nodeCount)
        let bytes: [UInt64] = try reader.readArray(count: nodeCount)
        let shared: [UInt64] = try reader.readArray(count: nodeCount)
        let fileID: [UInt64] = try reader.readArray(count: nodeCount)
        let modified: [UInt32] = try reader.readArray(count: nodeCount)
        let count: [UInt32] = try reader.readArray(count: nodeCount)
        let rawFlags: [UInt16] = try reader.readArray(count: nodeCount)
        let rawKinds: [UInt8] = try reader.readArray(count: nodeCount)
        let nameOffsets: [UInt32] = try reader.readArray(count: nodeCount + 1)
        let nameBytesCount = Int(try reader.read(UInt32.self))
        guard nameBytesCount <= maximumNameBytes else { throw DiskMapSnapshotError.tooLarge }
        let nameBytes: [UInt8] = try reader.readArray(count: nameBytesCount)
        guard reader.isAtEnd else { throw DiskMapSnapshotError.corrupt }

        let tree = FileTree(
            parent: parent, firstChild: firstChild, childCount: childCount, bytes: bytes,
            shared: shared, fileID: fileID, modified: modified, count: count,
            flags: rawFlags.map(FileNodeFlags.init(rawValue:)),
            kind: rawKinds.map { FileKind(rawValue: $0) ?? .other },
            nameOffsets: nameOffsets, nameBytes: nameBytes)
        guard tree.isStructurallyValid else { throw DiskMapSnapshotError.corrupt }

        return DiskMapSnapshot(
            scope: scope, rootPath: rootPath, tree: tree, reconciliation: reconciliation,
            scannedAt: scannedAt, duration: duration, partial: partial,
            smallFileThreshold: threshold, revision: max(1, revision))
    }

    // MARK: - Payload helpers

    private struct PayloadWriter {
        var data = Data()

        mutating func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        mutating func appendBlob(_ blob: Data) {
            append(UInt32(blob.count))
            data.append(blob)
        }

        mutating func appendArray<T: FixedWidthInteger>(_ array: [T]) {
            array.withUnsafeBytes { data.append(contentsOf: $0) }
        }
    }

    private struct PayloadReader {
        let data: Data
        var offset = 0

        init(data: Data) {
            self.data = data
        }

        var isAtEnd: Bool { offset == data.count }

        mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw DiskMapSnapshotError.corrupt }
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { target in
                data.copyBytes(
                    to: target, from: (data.startIndex + offset)..<(data.startIndex + offset + size)
                )
            }
            offset += size
            return T(littleEndian: value)
        }

        mutating func readBlob(_ maximum: Int) throws -> Data {
            let length = Int(try read(UInt32.self))
            guard length <= maximum, offset + length <= data.count else {
                throw DiskMapSnapshotError.corrupt
            }
            let start = data.startIndex + offset
            let blob = data.subdata(in: start..<(start + length))
            offset += length
            return blob
        }

        mutating func readArray<T: FixedWidthInteger>(count: Int) throws -> [T] {
            let size = MemoryLayout<T>.size
            guard count >= 0, count <= Int.max / max(size, 1), offset + count * size <= data.count
            else { throw DiskMapSnapshotError.corrupt }
            let start = data.startIndex + offset
            let end = start + count * size
            let array = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer), from: start..<end)
                initialized = count
            }
            offset += count * size
            return array
        }
    }

    /// Bounded LZFSE decompression: output is capped so a crafted file cannot
    /// balloon memory, and a truncated stream is rejected rather than trusted.
    static func decompress(_ data: Data, maximumOutputSize: Int) throws -> Data {
        guard maximumOutputSize > 0, !data.isEmpty else { throw DiskMapSnapshotError.corrupt }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: decompressionChunkBytes)
        defer { destination.deallocate() }
        return try data.withUnsafeBytes { sourceBytes -> Data in
            guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                throw DiskMapSnapshotError.corrupt
            }
            var stream = compression_stream(
                dst_ptr: destination, dst_size: decompressionChunkBytes, src_ptr: source,
                src_size: sourceBytes.count, state: nil)
            guard
                compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE)
                    != COMPRESSION_STATUS_ERROR
            else { throw DiskMapSnapshotError.corrupt }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = source
            stream.src_size = sourceBytes.count

            var output = Data()
            output.reserveCapacity(
                min(maximumOutputSize, max(decompressionChunkBytes, data.count * 3)))
            while true {
                let sourceBefore = stream.src_size
                stream.dst_ptr = destination
                stream.dst_size = decompressionChunkBytes
                let status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = decompressionChunkBytes - stream.dst_size
                guard produced <= maximumOutputSize - output.count else {
                    throw DiskMapSnapshotError.tooLarge
                }
                output.append(destination, count: produced)
                switch status {
                case COMPRESSION_STATUS_END:
                    guard stream.src_size == 0 else { throw DiskMapSnapshotError.corrupt }
                    return output
                case COMPRESSION_STATUS_OK:
                    guard produced > 0 || stream.src_size < sourceBefore else {
                        throw DiskMapSnapshotError.corrupt
                    }
                default:
                    throw DiskMapSnapshotError.corrupt
                }
            }
        }
    }
}

/// Where snapshots live and how they roll over: one file per scope under the
/// app's Application Support directory (beside the history database), the
/// previous scan kept as `.prev` for the changed-since-last-scan view.
public enum DiskMapSnapshotStore {
    public static func directory() -> URL {
        MacPerfMonitorDatabase.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("diskmap", isDirectory: true)
    }

    public static func url(
        for scope: DiskMapScope, previous: Bool = false, in directory: URL = directory()
    ) -> URL {
        directory.appendingPathComponent(
            scope.id + (previous ? ".prev." : ".") + DiskMapSnapshotCodec.fileExtension)
    }

    /// Persist a completed scan, rolling the existing file to `.prev`.
    public static func save(_ snapshot: DiskMapSnapshot, in directory: URL = directory()) throws {
        let current = url(for: snapshot.scope, in: directory)
        let previous = url(for: snapshot.scope, previous: true, in: directory)
        let fm = FileManager.default
        if fm.fileExists(atPath: current.path) {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: current, to: previous)
        }
        try DiskMapSnapshotCodec.write(snapshot, to: current)
    }

    public static func load(
        for scope: DiskMapScope, previous: Bool = false, in directory: URL = directory()
    ) throws -> DiskMapSnapshot? {
        let file = url(for: scope, previous: previous, in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try DiskMapSnapshotCodec.decode(contentsOf: file)
    }

    public static func remove(for scope: DiskMapScope, in directory: URL = directory()) {
        try? FileManager.default.removeItem(at: url(for: scope, in: directory))
        try? FileManager.default.removeItem(at: url(for: scope, previous: true, in: directory))
    }
}
