import XCTest

@testable import MacPerfMonitorCore

#if canImport(FoundationModels) && compiler(>=6.4)
import FoundationModels
#endif

final class GPUAttributionTests: XCTestCase {
    func testGPUAwakeTimeRequiresAValidOffState() {
        XCTAssertEqual(PowerReader.activeResidency(in: [.init(name: "OFF", residency: 75)]), 25)
        XCTAssertEqual(PowerReader.activeResidency(in: [.init(name: "off", residency: 100)]), 0)
        XCTAssertEqual(PowerReader.activeResidency(in: [.init(name: "OFF", residency: 0)]), 100)
        XCTAssertNil(PowerReader.activeResidency(in: []))
        XCTAssertNil(PowerReader.activeResidency(in: [.init(name: "P1", residency: 100)]))
        for invalid in [-1.0, 101, .infinity, .nan] {
            XCTAssertNil(PowerReader.activeResidency(in: [.init(name: "OFF", residency: invalid)]))
        }
        XCTAssertNil(
            PowerReader.activeResidency(in: [
                .init(name: "OFF", residency: 20), .init(name: "OFF", residency: 30),
            ]))
    }

    func testGPUBandwidthKeepsReportedBinsWithoutInventingAnExactRate() throws {
        let histogram = try XCTUnwrap(
            GPUBandwidthHistogram(labels: [" 1GB/s", "2GB/s", "32GB/s"], counts: [30, 0, 10]))
        XCTAssertEqual(histogram.bins.map(\.label), ["1GB/s", "2GB/s", "32GB/s"])
        XCTAssertEqual(histogram.totalEvents, 40)
        XCTAssertEqual(histogram.bins.map { histogram.percent(in: $0) }, [75, 0, 25])
        XCTAssertNil(GPUBandwidthHistogram(labels: [], counts: []))
        XCTAssertNil(GPUBandwidthHistogram(labels: ["1GB/s"], counts: []))
        XCTAssertNil(GPUBandwidthHistogram(labels: ["1GB/s"], counts: [0]))
        XCTAssertNil(GPUBandwidthHistogram(labels: ["1GB/s"], counts: [-1]))
        XCTAssertNil(GPUBandwidthHistogram(labels: ["1GB/s", "2GB/s"], counts: [.max, 1]))
        XCTAssertNil(GPUBandwidthHistogram(labels: ["1GB/s", "1GB/s"], counts: [1, 1]))
        XCTAssertNil(GPUBandwidthHistogram(labels: ["2GB/s", "1GB/s"], counts: [1, 1]))
        XCTAssertNil(GPUBandwidthHistogram(labels: ["Unknown"], counts: [1]))
        XCTAssertNil(GPUBandwidthHistogram(labels: ["infGB/s"], counts: [1]))
        XCTAssertNil(
            GPUBandwidthHistogram(
                labels: (1...129).map { "\($0)GB/s" }, counts: Array(repeating: 1, count: 129)))
    }

    func testGPUBandwidthAverageWeightsReportedRatesByEventCount() throws {
        for multiplier: Int64 in [1, 100, 100_000_000_000] {
            let histogram = try XCTUnwrap(
                GPUBandwidthHistogram(
                    labels: ["1GB/s", "5GB/s", "32GB/s"],
                    counts: [2 * multiplier, 6 * multiplier, 0]))
            let average = try XCTUnwrap(histogram.estimatedAverage)
            XCTAssertEqual(average.gigabytesPerSecond, 4, accuracy: 0.000_001)
            XCTAssertFalse(average.onlyLowestBin)
            XCTAssertFalse(average.includesHighestBin)
            let now = Date()
            for interval in [0.5, 1, 10, 30] {
                let sample = try XCTUnwrap(
                    GPUBandwidthSample(timestamp: now, interval: interval, combined: histogram))
                XCTAssertEqual(sample.combined?.estimatedAverage, average)
            }
        }
    }

    func testGPUBandwidthAverageFlagsUnresolvedLowAndHighReadings() throws {
        let labels = ["1GB/s", "2GB/s", "32GB/s"]
        let lowest = try XCTUnwrap(
            GPUBandwidthHistogram(labels: labels, counts: [100, 0, 0])?.estimatedAverage)
        XCTAssertTrue(lowest.onlyLowestBin)
        XCTAssertFalse(lowest.includesHighestBin)
        let overflow = try XCTUnwrap(
            GPUBandwidthHistogram(labels: labels, counts: [30, 0, 10])?.estimatedAverage)
        XCTAssertEqual(overflow.gigabytesPerSecond, 8.75, accuracy: 0.000_001)
        XCTAssertFalse(overflow.onlyLowestBin)
        XCTAssertTrue(overflow.includesHighestBin)
        XCTAssertNil(GPUBandwidthHistogram(labels: ["1GB/s"], counts: [4])?.estimatedAverage)
    }

    func testGPUBandwidthMissingStaleAndInvalidIntervalsStayUnavailable() throws {
        let now = Date()
        let histogram = try XCTUnwrap(GPUBandwidthHistogram(labels: ["1GB/s"], counts: [4]))
        XCTAssertNil(GPUBandwidthSample(timestamp: now, interval: 1))
        for interval in [0.0, -1, 31, .infinity, .nan] {
            XCTAssertNil(GPUBandwidthSample(timestamp: now, interval: interval, read: histogram))
        }
        let sample = try XCTUnwrap(GPUBandwidthSample(timestamp: now, interval: 1, read: histogram))
        XCTAssertTrue(sample.isFresh(at: now))
        XCTAssertFalse(sample.isFresh(at: now.addingTimeInterval(6)))
        XCTAssertFalse(sample.isFresh(at: now.addingTimeInterval(-2)))
        XCTAssertNil(sample.write)
        XCTAssertNil(sample.combined)
        var gpu = GPUSample(utilization: 5)
        gpu.bandwidth = sample
        let decoded = try JSONDecoder().decode(GPUSample.self, from: JSONEncoder().encode(gpu))
        XCTAssertEqual(decoded.bandwidth, sample)
        XCTAssertNil(
            try JSONDecoder().decode(GPUSample.self, from: Data("{\"utilization\":5}".utf8))
                .bandwidth)
    }

    @MainActor
    func testNativeGPUBandwidthWhenExplicitlyEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACPERF_TEST_GPU_BANDWIDTH"] == "1")
        let sampler = Sampler()
        defer { sampler.reset() }
        _ = sampler.tickSystem(readGPU: true, gpuReadInterval: 0)
        let ready = expectation(description: "A new GPU bandwidth interval is available")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        let snapshot = sampler.tickSystem(readGPU: true, gpuReadInterval: 0)
        let gpu = try XCTUnwrap(snapshot.gpu)
        let memory = try XCTUnwrap(gpu.inUseMemoryBytes)
        XCTAssertGreaterThan(memory, 0)
        XCTAssertEqual(snapshot.system.gpuMemoryBytes, memory)
        let awake = try XCTUnwrap(gpu.activeResidency)
        XCTAssertTrue((0...100).contains(awake))
        XCTAssertEqual(snapshot.system.gpuActiveResidency, awake)
        XCTAssertNotNil(gpu.gpuPowerWatts)
        XCTAssertFalse(gpu.performanceStates?.isEmpty ?? true)
        let reading = try XCTUnwrap(gpu.bandwidth)
        for histogram in [reading.read, reading.write, reading.combined] {
            let histogram = try XCTUnwrap(histogram)
            XCTAssertGreaterThan(histogram.totalEvents, 0)
            XCTAssertEqual(
                histogram.bins.reduce(0.0) { $0 + histogram.percent(in: $1) }, 100, accuracy: 0.001)
        }
        XCTAssertTrue(reading.isFresh(at: Date()))
        let bandwidth = reading.estimatedRates(at: snapshot.system.timestamp)
        XCTAssertEqual(snapshot.system.gpuReadBandwidthGBps, bandwidth.read)
        XCTAssertEqual(snapshot.system.gpuWriteBandwidthGBps, bandwidth.write)
        XCTAssertEqual(snapshot.system.gpuTotalBandwidthGBps, bandwidth.total)
        let disabled = sampler.tickSystem(readGPU: false)
        XCTAssertNil(disabled.gpu)
        XCTAssertNil(disabled.system.gpuMemoryBytes)
        XCTAssertNil(disabled.system.gpuActiveResidency)
        XCTAssertNil(disabled.system.gpuReadBandwidthGBps)
        XCTAssertNil(disabled.system.gpuWriteBandwidthGBps)
        XCTAssertNil(disabled.system.gpuTotalBandwidthGBps)
        print(
            "GPU sampler: memory reaches system history, all three bandwidth channels are present, and the GPU sampling gate clears both. No helper connection."
        )
    }

    func testANEPowerCacheRefreshesWithoutDependingOnTheUIDial() async throws {
        let refreshed = expectation(description: "Power is refreshed independently of UI ticks")
        refreshed.expectedFulfillmentCount = 3
        let stopped = expectation(description: "Independent polling stops with sampling")
        let provider = DelayedPowerProvider(
            requested: { refreshed.fulfill() },
            stopped: { stopped.fulfill() }, automatic: true)
        let reader = ANEPowerReader()
        reader.setProvider(provider)
        XCTAssertNil(reader.read())
        await fulfillment(of: [refreshed], timeout: 5)
        let reading = try XCTUnwrap(reader.read())
        XCTAssertEqual(reading.watts, 2.5)
        XCTAssertLessThan(Date().timeIntervalSince(reading.timestamp), 1.5)
        reader.stop()
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testANEPowerCacheNeverBlocksSamplingAndExpiresOldData() async throws {
        let requested = expectation(description: "The helper request starts asynchronously")
        let stopped = expectation(description: "Sampling stop releases the helper lease")
        let provider = DelayedPowerProvider(
            requested: { requested.fulfill() }, stopped: { stopped.fulfill() })
        let reader = ANEPowerReader()
        XCTAssertTrue(reader.requiresHelper)
        reader.setProvider(provider)
        XCTAssertFalse(reader.requiresHelper)
        let now = Date()
        XCTAssertNil(reader.read(at: now, uptime: 0))
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertNil(reader.read(at: now, uptime: 0.25))
        provider.complete(ANEPowerReading(timestamp: now, interval: 1, watts: 4.25))
        XCTAssertEqual(reader.read(at: now, uptime: 0.5)?.watts, 4.25)
        XCTAssertNil(reader.read(at: now.addingTimeInterval(6), uptime: 0.75))
        reader.stop()
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testANEPowerCacheDropsLateRepliesAfterConsentIsRemoved() async {
        let requested = expectation(description: "Helper receives request")
        let stopped = expectation(description: "Removing the helper releases power sampling")
        let provider = DelayedPowerProvider(
            requested: { requested.fulfill() }, stopped: { stopped.fulfill() })
        let reader = ANEPowerReader()
        reader.setProvider(provider)
        XCTAssertNil(reader.read(uptime: 0))
        await fulfillment(of: [requested], timeout: 2)
        reader.setProvider(nil)
        provider.complete(ANEPowerReading(timestamp: Date(), interval: 1, watts: 9))
        XCTAssertNil(reader.read(uptime: 1))
        XCTAssertTrue(reader.requiresHelper)
        await fulfillment(of: [stopped], timeout: 2)
    }

    private final class DelayedPowerProvider: PrivilegedReader, @unchecked Sendable {
        private let lock = NSLock()
        private var reply: (@Sendable (ANEPowerReading?) -> Void)?
        private let requested: @Sendable () -> Void
        private let stopped: @Sendable () -> Void
        private let automatic: Bool

        init(
            requested: @escaping @Sendable () -> Void, stopped: @escaping @Sendable () -> Void,
            automatic: Bool = false
        ) {
            self.requested = requested
            self.stopped = stopped
            self.automatic = automatic
        }

        func readProcesses(pids: [Int32]) -> [Int32: RawProcessRead] { [:] }

        func readANEPower(reply: @escaping @Sendable (ANEPowerReading?) -> Void) {
            lock.withLock { self.reply = reply }
            if automatic { reply(ANEPowerReading(timestamp: Date(), interval: 1, watts: 2.5)) }
            requested()
        }

        func stopANEPower() { stopped() }

        func complete(_ reading: ANEPowerReading?) {
            let callback = lock.withLock { reply }
            callback?(reading)
        }
    }

    @MainActor
    func testProductionSamplerReadsANEDuringAppleInferenceWhenExplicitlyEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPERF_TEST_FOUNDATION_MODELS"] == "1")
        #if canImport(FoundationModels) && compiler(>=6.4)
        guard #available(macOS 27, *) else {
            throw XCTSkip("This accounting preview needs macOS 27.")
        }
        try XCTSkipUnless(SystemLanguageModel.default.isAvailable)
        let capture = ANESamplerCapture()
        capture.sample()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { capture.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions:
                "Interpret only the synthetic performance facts. Write two short paragraphs.")
        let response = try await session.respond(
            to:
                "A synthetic Mac felt slow during a build. Recorded whole-machine CPU was high and the build process used several cores. Valid memory pressure was normal. Explain a possible contributor, the limits of this evidence, and a useful comparison.",
            options: GenerationOptions(temperature: 0, maximumResponseTokens: 300))
        capture.sample()
        XCTAssertFalse(response.content.isEmpty)
        let rates = capture.samples.compactMap { $0.0.aneTimeMillisecondsPerSecond }
        XCTAssertGreaterThanOrEqual(rates.count, 2)
        XCTAssertTrue(rates.contains { $0 > 0 }, "Production sampling must observe real ANE time.")
        for (system, gpu) in capture.samples {
            XCTAssertEqual(system.aneTimeMillisecondsPerSecond, gpu?.aneTimeMillisecondsPerSecond)
            XCTAssertEqual(system.aneSampleIsPartial, gpu?.aneSampleIsPartial)
            XCTAssertNil(system.anePowerWatts)
        }
        print(
            "PRODUCTION ANE: \(rates.count) readings, peak \(rates.max() ?? 0) ms/s; synthetic model content omitted."
        )
        #else
        throw XCTSkip("Foundation Models is not available in this toolchain.")
        #endif
    }

    func testANESampleCodingPreservesUnknownAndPartialCoverage() throws {
        let older = try JSONDecoder().decode(GPUSample.self, from: Data("{\"utilization\":7}".utf8))
        XCTAssertNil(older.aneTimeMillisecondsPerSecond)
        XCTAssertNil(older.aneSampleIsPartial)
        var gpu = GPUSample(utilization: 7)
        gpu.aneTimeMillisecondsPerSecond = 1250
        gpu.aneSampleIsPartial = true
        let decoded = try JSONDecoder().decode(GPUSample.self, from: JSONEncoder().encode(gpu))
        XCTAssertEqual(decoded.aneTimeMillisecondsPerSecond, 1250)
        XCTAssertEqual(decoded.aneSampleIsPartial, true)
    }

    func testANEAccountingUsesMachTimeAndKeepsUnclampedRates() throws {
        var snapshot: ANECounterSnapshot? = ANECounterSnapshot(counters: [1: 100, 2: 200])
        let reader = ANEActivityReader(secondsPerTick: 0.001, readCounters: { snapshot })
        XCTAssertNil(reader.read(now: 10))
        snapshot = ANECounterSnapshot(counters: [1: 1100, 2: 1200])
        let reading = try XCTUnwrap(reader.read(now: 11))
        XCTAssertEqual(reading.millisecondsPerSecond, 2000, accuracy: 0.001)
        XCTAssertFalse(reading.isPartial)
        snapshot = ANECounterSnapshot(counters: [1: 1100, 2: 1200])
        XCTAssertEqual(reader.read(now: 12)?.millisecondsPerSecond, 0)
    }

    func testANEReaderPollsAtMostOncePerSecondAndResets() {
        var calls = 0
        let reader = ANEActivityReader(secondsPerTick: 0.001) {
            calls += 1
            return ANECounterSnapshot(counters: [1: UInt64(calls * 100)])
        }
        XCTAssertNil(reader.read(now: 0))
        XCTAssertNil(reader.read(now: 0.5))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(reader.read(now: 1)?.millisecondsPerSecond, 100)
        XCTAssertEqual(reader.read(now: 1.5)?.millisecondsPerSecond, 100)
        XCTAssertEqual(calls, 2)
        reader.reset()
        XCTAssertNil(reader.read(now: 2))
        XCTAssertEqual(calls, 3)
    }

    func testANEUnavailableAndResetCountersDoNotBecomeZero() {
        var snapshot: ANECounterSnapshot? = ANECounterSnapshot(counters: [1: 100])
        let reader = ANEActivityReader(secondsPerTick: 0.001, readCounters: { snapshot })
        XCTAssertNil(reader.read(now: 0))
        snapshot = nil
        XCTAssertNil(reader.read(now: 1))
        snapshot = ANECounterSnapshot(counters: [1: 900])
        XCTAssertNil(reader.read(now: 2))
        snapshot = ANECounterSnapshot(counters: [1: 1])
        XCTAssertNil(reader.read(now: 3))
        snapshot = ANECounterSnapshot(counters: [1: 101])
        XCTAssertEqual(reader.read(now: 4)?.millisecondsPerSecond, 100)
        XCTAssertNil(reader.read(now: 50))
        XCTAssertNil(reader.read(now: 2))
    }

    func testANECoalitionChurnAndUnreadableRecordsArePartial() throws {
        var snapshot: ANECounterSnapshot? = ANECounterSnapshot(counters: [1: 100, 2: 900])
        let reader = ANEActivityReader(secondsPerTick: 0.001, readCounters: { snapshot })
        XCTAssertNil(reader.read(now: 0))
        snapshot = ANECounterSnapshot(counters: [1: 300, 3: 50_000], unreadableCount: 1)
        let reading = try XCTUnwrap(reader.read(now: 1))
        XCTAssertEqual(reading.millisecondsPerSecond, 200, accuracy: 0.001)
        XCTAssertTrue(reading.isPartial)
        snapshot = ANECounterSnapshot(counters: [1: 400, 3: 50_100])
        XCTAssertTrue(try XCTUnwrap(reader.read(now: 2)).isPartial)
        XCTAssertFalse(try XCTUnwrap(reader.read(now: 3)).isPartial)
    }

    func testANERejectsUnknownRecordLayoutsAndMissingFields() {
        var words = [UInt64](repeating: ANEAccountingRecord.sentinel, count: 64)
        XCTAssertNil(ANEAccountingRecord.ticks(in: words))
        for index in 0..<50 { words[index] = 0 }
        words[23] = 7
        words[38] = 12345
        XCTAssertEqual(ANEAccountingRecord.ticks(in: words), 12345)
        words[50] = 0
        XCTAssertNil(ANEAccountingRecord.ticks(in: words))
        words[50] = ANEAccountingRecord.sentinel
        words[23] = 6
        XCTAssertNil(ANEAccountingRecord.ticks(in: words))
    }

    func testANERejectsOverflowAndInvalidTimebase() {
        var snapshot: ANECounterSnapshot? = ANECounterSnapshot(counters: [1: 0, 2: 0])
        let reader = ANEActivityReader(secondsPerTick: 0.001, readCounters: { snapshot })
        XCTAssertNil(reader.read(now: 0))
        snapshot = ANECounterSnapshot(counters: [1: UInt64.max, 2: 1])
        XCTAssertNil(reader.read(now: 1))
        let invalid = ANEActivityReader(secondsPerTick: .nan, readCounters: { snapshot })
        XCTAssertNil(invalid.read(now: 0))
    }

    // MARK: - GPUProcessReader parsing

    func testCreatorStringYieldsPID() {
        XCTAssertEqual(GPUProcessReader.pid(fromCreator: "pid 413, WindowServer"), 413)
        XCTAssertEqual(GPUProcessReader.pid(fromCreator: "pid 96180, Screen Sharing"), 96180)
        XCTAssertNil(GPUProcessReader.pid(fromCreator: "WindowServer"))
        XCTAssertNil(GPUProcessReader.pid(fromCreator: "pid , x"))
    }

    func testAppUsageSumsContextsAndKeepsNewestSubmission() {
        let usage = GPUProcessReader.usage(
            pid: 413,
            appUsage: [
                [
                    "API": "Metal", "accumulatedGPUTime": 20_828_301_005_375,
                    "lastSubmittedTime": 170_032_797_844_625,
                ],
                [
                    "API": "Metal", "accumulatedGPUTime": 103_470_833,
                    "lastSubmittedTime": 169_600_337_130_166,
                ],
                ["API": "Metal", "accumulatedGPUTime": 0, "lastSubmittedTime": 0],
            ])
        XCTAssertEqual(usage.pid, 413)
        XCTAssertEqual(usage.gpuTimeNanos, 20_828_301_005_375 + 103_470_833)
        XCTAssertEqual(usage.lastSubmittedNanos, 170_032_797_844_625)
        XCTAssertEqual(usage.contextCount, 3)
    }

    func testEmptyAppUsageIsOneIdleContext() {
        let usage = GPUProcessReader.usage(pid: 7, appUsage: [])
        XCTAssertEqual(usage.gpuTimeNanos, 0)
        XCTAssertEqual(usage.lastSubmittedNanos, 0)
        XCTAssertEqual(usage.contextCount, 1)
    }

    func testMachNanosConvertToWallClock() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let machNow: UInt64 = 170_036_000_000_000
        // Ten seconds before "now".
        let date = GPUProcessReader.date(
            fromMachNanos: machNow - 10_000_000_000, now: now, machNow: machNow)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_999_999_990, accuracy: 0.001)
        XCTAssertNil(GPUProcessReader.date(fromMachNanos: 0, now: now, machNow: machNow))
        XCTAssertNil(GPUProcessReader.date(fromMachNanos: machNow + 1, now: now, machNow: machNow))
    }

    // MARK: - Workload classification

    func testKnownAIRuntimesAreRecognised() {
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "ollama", bundleID: nil, executablePath: "/usr/local/bin/ollama"),
            "Ollama")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "ollama runner", bundleID: nil,
                executablePath: "/Applications/Ollama.app/Contents/Resources/ollama"),
            "Ollama")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(name: "llama-server", bundleID: nil, executablePath: nil),
            "llama.cpp")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "LM Studio Helper", bundleID: "ai.elementlabs.lmstudio.helper",
                executablePath: nil),
            "LM Studio")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(name: "aned", bundleID: nil, executablePath: "/usr/libexec/aned"),
            "Core ML")
        XCTAssertEqual(
            GPUWorkload.category(name: "mediaanalysisd", bundleID: nil, executablePath: nil), .aiML)
    }

    func testInterpretersNeedTheCommandLine() {
        XCTAssertNil(
            GPUWorkload.aiRuntime(
                name: "python3.12", bundleID: nil, executablePath: "/usr/bin/python3"))
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "python3.12", bundleID: nil, executablePath: "/opt/homebrew/bin/python3",
                arguments: [
                    "python3", "-m", "mlx_lm.server", "--model", "mlx-community/Llama-3.2-3B",
                ]),
            "MLX")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "python", bundleID: nil, executablePath: nil,
                arguments: ["python", "train.py", "--backend", "torch"]),
            "PyTorch")
        XCTAssertEqual(
            GPUWorkload.category(
                name: "python", bundleID: nil, executablePath: nil,
                arguments: ["python", "serve.py"]),
            .other)
    }

    func testDisplayAndMediaCategories() {
        XCTAssertEqual(
            GPUWorkload.category(name: "WindowServer", bundleID: nil, executablePath: nil),
            .displayUI)
        XCTAssertEqual(
            GPUWorkload.category(
                name: "Google Chrome Helper (GPU)", bundleID: "com.google.Chrome.helper",
                executablePath: nil),
            .displayUI)
        XCTAssertEqual(
            GPUWorkload.category(
                name: "com.apple.WebKit.GPU", bundleID: "com.apple.WebKit.GPU", executablePath: nil),
            .displayUI)
        XCTAssertEqual(
            GPUWorkload.category(name: "VTDecoderXPCService", bundleID: nil, executablePath: nil),
            .media)
        XCTAssertEqual(
            GPUWorkload.category(name: "Screen Sharing", bundleID: nil, executablePath: nil), .media
        )
        XCTAssertEqual(
            GPUWorkload.category(
                name: "Blender", bundleID: "org.blenderfoundation.blender", executablePath: nil),
            .other)
    }

    func testModelHintFromArguments() {
        XCTAssertEqual(
            GPUWorkload.modelHint(arguments: [
                "llama-server", "-m", "/models/Qwen2.5-7B-Q4_K_M.gguf",
            ]),
            "Qwen2.5-7B-Q4_K_M.gguf")
        XCTAssertEqual(
            GPUWorkload.modelHint(arguments: [
                "python", "-m", "mlx_lm.server", "--model=mlx-community/gemma-2-9b",
            ]),
            "gemma-2-9b")
        XCTAssertEqual(
            GPUWorkload.modelHint(arguments: [
                "python", "-m", "mlx_lm.server", "--model", "mistral",
            ]),
            "mistral")
        XCTAssertNil(GPUWorkload.modelHint(arguments: ["ollama", "serve"]))
        XCTAssertNil(GPUWorkload.modelHint(arguments: nil))
    }

    @MainActor
    private final class ANESamplerCapture {
        let sampler = Sampler()
        var samples: [(SystemSample, GPUSample?)] = []

        func sample() {
            let reading = sampler.tickSystem(readGPU: true, gpuReadInterval: 0)
            samples.append((reading.system, reading.gpu))
        }
    }
}
