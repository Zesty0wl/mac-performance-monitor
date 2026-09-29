import Darwin
import Foundation

public enum AskWorkerMessage: Codable, Sendable {
    case tool(AskToolCall)
    case complete(AskInferenceResponse)
}

public final class AskInferenceChannel: @unchecked Sendable {
    private let input: FileHandle
    private var buffer = Data()
    private static let maximumBytes = 65536

    public init(input: FileHandle) { self.input = input }

    public func read<Value: Decodable>(_ type: Value.Type) throws -> Value {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                guard end < Self.maximumBytes else { throw AskExplanationError.contextLimit }
                let line = buffer.prefix(upTo: end)
                let value = try JSONDecoder().decode(type, from: line)
                buffer.removeSubrange(...end)
                return value
            }
            guard buffer.count < Self.maximumBytes else { throw AskExplanationError.contextLimit }
            var chunk = Data(count: 8192)
            let count = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(input.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == -1, errno == EINTR { continue }
            guard count >= 0 else { throw AskExplanationError.workerFailed }
            if count == 0 {
                guard !buffer.isEmpty else { throw AskExplanationError.workerFailed }
                let value = try JSONDecoder().decode(type, from: buffer)
                buffer.removeAll(keepingCapacity: true)
                return value
            }
            buffer.append(chunk.prefix(count))
        }
    }

    public static func write<Value: Encodable>(_ value: Value, to output: FileHandle) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count < maximumBytes else { throw AskExplanationError.contextLimit }
        data.append(10)
        try output.write(contentsOf: data)
    }
}
