import Darwin
import Foundation

struct ANEActivityReading: Equatable, Sendable {
    let millisecondsPerSecond: Double
    let isPartial: Bool
}

struct ANECounterSnapshot: Sendable {
    var counters: [UInt64: UInt64]
    var unreadableCount = 0
}

final class ANEActivityReader {
    private let readCounters: () -> ANECounterSnapshot?
    private let secondsPerTick: Double
    private var previous: ANECounterSnapshot?
    private var lastRead: TimeInterval?
    private var cached: ANEActivityReading?

    convenience init() {
        let source = ANECoalitionSource()
        var timebase = mach_timebase_info_data_t()
        let valid = mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom > 0
        self.init(
            secondsPerTick: valid ? Double(timebase.numer) / Double(timebase.denom) / 1e9 : 0,
            readCounters: { source?.read() })
    }

    init(secondsPerTick: Double, readCounters: @escaping () -> ANECounterSnapshot?) {
        self.secondsPerTick = secondsPerTick
        self.readCounters = readCounters
    }

    func read(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ANEActivityReading? {
        guard now.isFinite, secondsPerTick.isFinite, secondsPerTick > 0 else {
            reset()
            return nil
        }
        if let lastRead, now >= lastRead, now - lastRead < 1 { return cached }
        let elapsed = lastRead.map { now - $0 }
        lastRead = now
        guard let current = readCounters(), !current.counters.isEmpty else {
            previous = nil
            cached = nil
            return nil
        }
        defer { previous = current }
        guard let previous, let elapsed, elapsed >= 1, elapsed <= 30 else {
            cached = nil
            return nil
        }
        var ticks: UInt64 = 0
        for (identifier, value) in current.counters {
            guard let old = previous.counters[identifier] else { continue }
            guard value >= old else {
                cached = nil
                return nil
            }
            let (total, overflow) = ticks.addingReportingOverflow(value - old)
            guard !overflow else {
                cached = nil
                return nil
            }
            ticks = total
        }
        let rate = Double(ticks) * secondsPerTick * 1000 / elapsed
        guard rate.isFinite else {
            cached = nil
            return nil
        }
        cached = ANEActivityReading(
            millisecondsPerSecond: rate,
            isPartial: current.unreadableCount > 0 || previous.unreadableCount > 0
                || Set(current.counters.keys) != Set(previous.counters.keys))
        return cached
    }

    func reset() {
        previous = nil
        lastRead = nil
        cached = nil
    }
}

enum ANEAccountingRecord {
    static let sentinel = UInt64(0xA5A5_A5A5_A5A5_A5A5)
    static let wordCount = 64

    static func ticks(in words: [UInt64]) -> UInt64? {
        guard words.count == wordCount,
            let lastWritten = words.lastIndex(where: { $0 != sentinel }),
            [360, 400].contains((lastWritten + 1) * MemoryLayout<UInt64>.size),
            words[23] == 7,
            words[38] != sentinel
        else { return nil }
        return words[38]
    }
}

private final class ANECoalitionSource {
    private typealias List =
        @convention(c) (
            Int32, Int32, UnsafeMutableRawPointer?, Int32
        ) -> Int32
    private typealias Usage =
        @convention(c) (
            UInt64, UnsafeMutableRawPointer?, UInt
        ) -> Int32

    private let library: UnsafeMutableRawPointer
    private let list: List
    private let usage: Usage
    private var entries: [UInt64] = []
    private var record = [UInt64](
        repeating: ANEAccountingRecord.sentinel, count: ANEAccountingRecord.wordCount)

    init?() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
            let library = dlopen("/usr/lib/libproc.dylib", RTLD_NOW | RTLD_LOCAL)
        else { return nil }
        guard let listSymbol = dlsym(library, "proc_listcoalitions"),
            let usageSymbol = dlsym(library, "coalition_info_resource_usage")
        else {
            dlclose(library)
            return nil
        }
        self.library = library
        list = unsafeBitCast(listSymbol, to: List.self)
        usage = unsafeBitCast(usageSymbol, to: Usage.self)
    }

    deinit { dlclose(library) }

    func read() -> ANECounterSnapshot? {
        let required = list(2, 0, nil, 0)
        guard required > 0, required <= 1_048_576 else { return nil }
        let capacity = (Int(required) + 4096 + 7) / 8
        if entries.count < capacity { entries = [UInt64](repeating: 0, count: capacity) }
        let bytes = entries.withUnsafeMutableBytes { buffer in
            list(2, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0, bytes % 16 == 0, Int(bytes) < entries.count * 8 else { return nil }
        var snapshot = ANECounterSnapshot(counters: [:])
        snapshot.counters.reserveCapacity(Int(bytes) / 16)
        for offset in stride(from: 0, to: Int(bytes) / 8, by: 2) {
            let identifier = entries[offset]
            let kind = UInt32(truncatingIfNeeded: entries[offset + 1])
            let tasks = UInt32(truncatingIfNeeded: entries[offset + 1] >> 32)
            guard identifier > 0, kind == 0, snapshot.counters[identifier] == nil else {
                return nil
            }
            for index in record.indices { record[index] = ANEAccountingRecord.sentinel }
            let result = record.withUnsafeMutableBytes { buffer in
                usage(identifier, buffer.baseAddress, UInt(buffer.count))
            }
            guard result == 0 else {
                if !(errno == EINVAL && tasks == 0) { snapshot.unreadableCount += 1 }
                continue
            }
            guard let ticks = ANEAccountingRecord.ticks(in: record) else { return nil }
            snapshot.counters[identifier] = ticks
        }
        return snapshot
    }
}
