import CoreFoundation
import Darwin
import Foundation
import MacPerfMonitorCore

protocol ANEPowerProviding: Sendable {
    func read(for client: UUID, reply: @escaping @Sendable (ANEPowerReading?) -> Void)
    func stop(for client: UUID)
    func shutdown()
}

final class ANEPowerSampler: ANEPowerProviding, @unchecked Sendable {
    static let arguments = [
        "--samplers", "cpu_power,gpu_power,thermal", "-f", "plist",
        "-i", "1000", "-n", "60", "-b", "0",
    ]

    private struct Child {
        let identifier: UUID
        let process: Process
        let output: FileHandle
        let outputSource: DispatchSourceRead
        let started: TimeInterval
    }

    private let queue = DispatchQueue(label: "uk.co.bzwrd.macperfmonitor.ane-power", qos: .utility)
    private let canSample: @Sendable () -> Bool
    private let makeProcess: @Sendable () -> Process
    private let leaseInterval: TimeInterval
    private let maintenanceInterval: TimeInterval
    private let onSample: @Sendable (ANEPowerReading?) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private var leases: [UUID: TimeInterval] = [:]
    private var child: Child?
    private var stoppingChild: Process?
    private var timer: DispatchSourceTimer?
    private var decoder = ANEPowerFrameDecoder()
    private var latest: ANEPowerReading?
    private var lastFrameAt: TimeInterval = 0
    private var retryAt: TimeInterval = 0
    private var receivedFrames = 0

    init(
        canSample: @escaping @Sendable () -> Bool = { geteuid() == 0 },
        makeProcess: @escaping @Sendable () -> Process = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
            process.arguments = ANEPowerSampler.arguments
            return process
        },
        leaseInterval: TimeInterval = 5, maintenanceInterval: TimeInterval = 1,
        onSample: @escaping @Sendable (ANEPowerReading?) -> Void = { _ in },
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) {
        self.canSample = canSample
        self.makeProcess = makeProcess
        self.leaseInterval = leaseInterval
        self.maintenanceInterval = maintenanceInterval
        self.onSample = onSample
        self.onExit = onExit
    }

    deinit {
        timer?.cancel()
        child?.outputSource.cancel()
        if let child, child.process.isRunning { child.process.terminate() }
        if let stoppingChild, stoppingChild.isRunning { stoppingChild.terminate() }
    }

    func read(for client: UUID, reply: @escaping @Sendable (ANEPowerReading?) -> Void) {
        queue.async { [self] in
            guard canSample(), leases[client] != nil || leases.count < 16 else {
                reply(nil)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            leases[client] = now + leaseInterval
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(
                    deadline: .now() + maintenanceInterval, repeating: maintenanceInterval)
                timer.setEventHandler { [weak self] in self?.maintain() }
                self.timer = timer
                timer.resume()
            }
            if child == nil, stoppingChild == nil, now >= retryAt { start(now: now) }
            reply(latest.flatMap { $0.isFresh(at: Date()) ? $0 : nil })
        }
    }

    func stop(for client: UUID) {
        queue.async { [self] in
            leases[client] = nil
            if leases.isEmpty { stopAll() }
        }
    }

    func shutdown() {
        queue.async { [self] in stopAll() }
    }

    private func maintain() {
        let now = ProcessInfo.processInfo.systemUptime
        leases = leases.filter { $0.value > now }
        guard !leases.isEmpty else {
            stopAll()
            return
        }
        if let child, now - child.started > 75 || now - lastFrameAt > 10 {
            fail()
        }
    }

    private func start(now: TimeInterval) {
        let process = makeProcess()
        let pipe = Pipe()
        let identifier = UUID()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            retryAt = now + 30
            return
        }
        let outputSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        outputSource.setEventHandler { [weak self] in
            autoreleasepool { self?.readOutput(identifier: identifier) }
        }
        let output = pipe.fileHandleForReading
        outputSource.setCancelHandler { try? output.close() }
        outputSource.resume()
        process.qualityOfService = .utility
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                defer { self.onExit(process.terminationStatus) }
                if self.stoppingChild === process { self.stoppingChild = nil }
                guard self.child?.identifier == identifier else { return }
                self.stopChild()
                if process.terminationStatus != 0 || self.receivedFrames == 0 {
                    self.latest = nil
                    self.retryAt = ProcessInfo.processInfo.systemUptime + 30
                }
            }
        }
        child = Child(
            identifier: identifier, process: process, output: pipe.fileHandleForReading,
            outputSource: outputSource, started: now)
        decoder = ANEPowerFrameDecoder()
        receivedFrames = 0
        lastFrameAt = now
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
        } catch {
            try? pipe.fileHandleForWriting.close()
            fail()
        }
    }

    private func readOutput(identifier: UUID) {
        guard let child, child.identifier == identifier else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(child.output.fileDescriptor, &bytes, bytes.count)
        if count > 0 {
            accept(Data(bytes.prefix(count)), identifier: identifier)
        } else if count == 0 {
            child.outputSource.cancel()
        } else if errno != EAGAIN && errno != EINTR {
            fail()
        }
    }

    private func accept(_ data: Data, identifier: UUID) {
        guard child?.identifier == identifier, !data.isEmpty else { return }
        do {
            for reading in try decoder.append(data) {
                lastFrameAt = ProcessInfo.processInfo.systemUptime
                latest = reading.flatMap { $0.isFresh(at: Date()) ? $0 : nil }
                if latest != nil { receivedFrames += 1 }
                onSample(latest)
            }
        } catch { fail() }
    }

    private func fail() {
        latest = nil
        retryAt = ProcessInfo.processInfo.systemUptime + 30
        stopChild()
    }

    private func stopAll() {
        leases.removeAll()
        latest = nil
        timer?.cancel()
        timer = nil
        stopChild()
    }

    private func stopChild() {
        guard let child else { return }
        self.child = nil
        child.outputSource.cancel()
        decoder = ANEPowerFrameDecoder()
        if child.process.isRunning {
            stoppingChild = child.process
            child.process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.process.isRunning { kill(child.process.processIdentifier, SIGKILL) }
            }
        }
    }
}

struct ANEPowerFrameDecoder {
    enum Failure: Error { case oversizedFrame, invalidPropertyList }
    static let maximumFrameBytes = 1_048_576
    private var pending = Data()

    mutating func append(_ data: Data) throws -> [ANEPowerReading?] {
        guard data.count <= Self.maximumFrameBytes else { throw Failure.oversizedFrame }
        pending.append(data)
        var readings: [ANEPowerReading?] = []
        while let delimiter = pending.firstIndex(of: 0) {
            let size = pending.distance(from: pending.startIndex, to: delimiter)
            guard size <= Self.maximumFrameBytes else { throw Failure.oversizedFrame }
            let frame = pending.prefix(upTo: delimiter)
            pending.removeSubrange(...delimiter)
            guard !frame.isEmpty else { continue }
            guard
                let propertyList = try? PropertyListSerialization.propertyList(
                    from: Data(frame), options: [], format: nil),
                let report = propertyList as? [String: Any]
            else { throw Failure.invalidPropertyList }
            readings.append(Self.reading(from: report))
        }
        guard pending.count <= Self.maximumFrameBytes else { throw Failure.oversizedFrame }
        return readings
    }

    static func reading(from report: [String: Any]) -> ANEPowerReading? {
        guard let timestamp = report["timestamp"] as? Date,
            let nanoseconds = number(report["elapsed_ns"]), nanoseconds > 0,
            let processor = report["processor"] as? [String: Any]
        else { return nil }
        let interval = nanoseconds / 1e9
        let watts: Double
        if processor["ane_energy"] != nil {
            guard let millijoules = number(processor["ane_energy"]), millijoules >= 0 else {
                return nil
            }
            watts = millijoules / 1000 / interval
        } else {
            guard let milliwatts = number(processor["ane_power"]), milliwatts >= 0 else {
                return nil
            }
            watts = milliwatts / 1000
        }
        let reading = ANEPowerReading(timestamp: timestamp, interval: interval, watts: watts)
        return reading.isFresh(at: timestamp) ? reading : nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.doubleValue.isFinite
        else { return nil }
        return value.doubleValue
    }
}
