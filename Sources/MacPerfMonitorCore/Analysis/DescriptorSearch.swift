import Darwin
import Foundation

/// A process whose open descriptors a search will read.
public struct DescriptorSearchTarget: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    /// The owner, or nil when this user cannot read the process at all.
    public var uid: uid_t?

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, uid: uid_t?) {
        self.pid = pid
        self.name = name
        self.uid = uid
    }
}

/// One open descriptor that matched a search, with the process holding it.
public struct DescriptorMatch: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var processName: String
    public var descriptor: OpenFileDescriptor

    public var id: String { "\(pid):\(descriptor.fd)" }

    public init(pid: Int32, processName: String, descriptor: OpenFileDescriptor) {
        self.pid = pid
        self.processName = processName
        self.descriptor = descriptor
    }
}

/// Searching open files and sockets across processes: "what has this file
/// open?", "who is listening on port 8080?".
public enum DescriptorSearch {
    /// Every process on the Mac as a search target. Names come from the
    /// executable path, which is readable for other users' processes too.
    public static func targets(reader: ProcessReader = ProcessReader()) -> [DescriptorSearchTarget]
    {
        reader.listPIDs().map { pid in
            let info = reader.taskAllInfo(pid)
            let pathName = reader.path(pid).map { ($0 as NSString).lastPathComponent }
            let name =
                pathName.flatMap { $0.isEmpty ? nil : $0 } ?? info?.name ?? "PID \(pid)"
            return DescriptorSearchTarget(pid: pid, name: name, uid: info?.uid)
        }
    }

    /// Whether `descriptor` matches `term`.
    ///
    /// Text is matched anywhere in the path or endpoint, ignoring case. A term
    /// that is only digits is treated as a port when the descriptor is a
    /// socket: "80" matches ":80" but not ":8080" or ":443" on 10.80.0.1.
    public static func matches(_ descriptor: OpenFileDescriptor, term: String) -> Bool {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return false }
        if descriptor.kind == .socket, term.allSatisfy(\.isASCIIDigit) {
            return hasPort(term, in: descriptor.detail)
        }
        return descriptor.detail.range(of: term, options: [.caseInsensitive]) != nil
    }

    /// Whether `detail` contains ":<port>" with no further digit after it.
    private static func hasPort(_ port: String, in detail: String) -> Bool {
        var searchFrom = detail.startIndex
        while let found = detail.range(of: ":" + port, range: searchFrom..<detail.endIndex) {
            if found.upperBound == detail.endIndex || !detail[found.upperBound].isASCIIDigit {
                return true
            }
            searchFrom = found.upperBound
        }
        return false
    }

    /// The descriptors of one process that match `term`.
    public static func matches(
        in descriptors: [OpenFileDescriptor], of target: DescriptorSearchTarget, term: String
    ) -> [DescriptorMatch] {
        descriptors.filter { matches($0, term: term) }.map {
            DescriptorMatch(pid: target.pid, processName: target.name, descriptor: $0)
        }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
