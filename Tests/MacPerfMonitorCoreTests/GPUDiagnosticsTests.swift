import Metal
import XCTest

@testable import MacPerfMonitorCore

final class GPUDiagnosticsTests: XCTestCase {
    /// The `voltage-states9` bytes read from an M3 Pro's `pmgr` node.
    static let m3ProVoltageStates = Data(
        hex:
            "000000007d000000807825148f02000080eed524c602000000ff712fd00200000050973102030000001f133702030000005ebe38430300000048f13e43030000005a6b3f8403000080e373468403000080e37346b60300000088334eb6030000806a074ad903000000214152d9030000"
    )

    func testFrequencyTableDecodesTheM3ProTable() throws {
        let table = try XCTUnwrap(GPUFrequencyTable(voltageStates: Self.m3ProVoltageStates))
        XCTAssertEqual(
            table.megahertz,
            [338, 618, 796, 832, 924, 952, 1056, 1064, 1182, 1182, 1312, 1242, 1380])
        XCTAssertEqual(table.maximumMHz, 1380)
        XCTAssertEqual(table.frequency(ofState: "P1"), 338)
        XCTAssertEqual(table.frequency(ofState: "p13"), 1380)
        XCTAssertNil(table.frequency(ofState: "P14"))
        XCTAssertNil(table.frequency(ofState: "OFF"))
        XCTAssertNil(table.frequency(ofState: "P0"))
        XCTAssertNil(table.frequency(ofState: "SW_P1"))
    }

    func testFrequencyTableRejectsMalformedData() {
        XCTAssertNil(GPUFrequencyTable(voltageStates: Data()))
        XCTAssertNil(GPUFrequencyTable(voltageStates: Data(count: 12)))
        // Only the OFF entry.
        XCTAssertNil(GPUFrequencyTable(voltageStates: Data(count: 16)))
        // A 0 Hz entry after the first P-state is not a valid table.
        var bytes = [UInt8](Self.m3ProVoltageStates)
        for index in 16..<20 { bytes[index] = 0 }
        XCTAssertNil(GPUFrequencyTable(voltageStates: Data(bytes)))
        XCTAssertNil(GPUFrequencyTable(megahertz: [338]))
        XCTAssertNil(GPUFrequencyTable(megahertz: [338, .nan]))
        XCTAssertNil(GPUFrequencyTable(megahertz: [338, 20_000]))
    }

    func testEffectiveClockWeightsAwakeTimeOnly() throws {
        let table = try XCTUnwrap(GPUFrequencyTable(voltageStates: Self.m3ProVoltageStates))
        // Full load: 99.5% in P13, 0.5% in P11, as measured under a compute loop.
        let loaded = table.effectiveMHz(states: [
            .init(name: "P11", residency: 0.5), .init(name: "P13", residency: 99.5),
        ])
        XCTAssertEqual(try XCTUnwrap(loaded), 1312 * 0.005 + 1380 * 0.995, accuracy: 0.001)
        // OFF is ignored: a GPU in P1 whenever awake clocks at P1.
        XCTAssertEqual(
            table.effectiveMHz(states: [
                .init(name: "OFF", residency: 64.5), .init(name: "P1", residency: 35.5),
            ]), 338)
        XCTAssertNil(table.effectiveMHz(states: [.init(name: "OFF", residency: 100)]))
        XCTAssertNil(table.effectiveMHz(states: []))
        // More than 1% of awake time in a state the table cannot name.
        XCTAssertNil(
            table.effectiveMHz(states: [
                .init(name: "P1", residency: 50), .init(name: "P15", residency: 50),
            ]))
    }

    /// The table wins whenever the chip has one, so the clock and the bar
    /// count never depend on the helper's frame. Build 307 preferred the
    /// helper and lost the clock on 35% of seconds while the GPU was awake.
    func testResolveClockPrefersTheTableAndFallsBackToTheHelper() throws {
        let table = try XCTUnwrap(GPUFrequencyTable(voltageStates: Self.m3ProVoltageStates))
        let now = Date()
        var sample = GPUSample(utilization: 90)
        sample.activeResidency = 100
        sample.performanceStates = [
            .init(name: "P12", residency: 0), .init(name: "P13", residency: 100),
            .init(name: "P14", residency: 0), .init(name: "P15", residency: 0),
        ]
        var tableOnly = sample
        tableOnly.resolveClock(table: table, helper: nil, now: now)
        XCTAssertEqual(tableOnly.clockMHz, 1380)
        XCTAssertEqual(tableOnly.clockSource, .frequencyTable)
        XCTAssertEqual(tableOnly.maximumClockMHz, 1380)
        // The empty states past the table are dropped; the named ones carry MHz.
        XCTAssertEqual(tableOnly.performanceStates?.map(\.name), ["P12", "P13"])
        XCTAssertEqual(tableOnly.performanceStates?.map(\.frequencyMHz), [1242, 1380])

        // A helper frame whose list covers only some states, or whose clock is
        // missing, changes nothing while the table exists.
        for helper in [
            ANEPowerReading(
                timestamp: now, interval: 1, watts: 0, gpuFrequencyMHz: nil,
                gpuStateFrequenciesMHz: [338, 796]),
            ANEPowerReading(
                timestamp: now, interval: 1, watts: 0, gpuFrequencyMHz: 1371,
                gpuStateFrequenciesMHz: nil),
        ] {
            var withHelper = sample
            withHelper.resolveClock(table: table, helper: helper, now: now)
            XCTAssertEqual(withHelper, tableOnly)
        }

        // No table: a helper list covering every state with time labels them.
        let full = ANEPowerReading(
            timestamp: now, interval: 1, watts: 0, gpuFrequencyMHz: 1371,
            gpuStateFrequenciesMHz: [
                338, 618, 796, 832, 924, 952, 1056, 1064, 1182, 1182, 1312, 1242, 1398,
            ])
        var helperLabels = sample
        helperLabels.resolveClock(table: nil, helper: full, now: now)
        XCTAssertEqual(helperLabels.clockMHz, 1398)
        XCTAssertEqual(helperLabels.clockSource, .powermetrics)
        XCTAssertEqual(helperLabels.performanceStates?.map(\.name), ["P12", "P13"])

        // No table and a list that misses a busy state: the helper's clock.
        let partial = ANEPowerReading(
            timestamp: now, interval: 1, watts: 0, gpuFrequencyMHz: 1371,
            gpuStateFrequenciesMHz: [338, 618])
        var helperClock = sample
        helperClock.resolveClock(table: nil, helper: partial, now: now)
        XCTAssertEqual(helperClock.clockMHz, 1371)
        XCTAssertEqual(helperClock.clockSource, .powermetrics)
        XCTAssertNil(helperClock.performanceStates?.first?.frequencyMHz)

        // A stale helper reading is ignored.
        var stale = sample
        stale.resolveClock(table: nil, helper: full, now: now.addingTimeInterval(60))
        XCTAssertNil(stale.clockMHz)

        // No table and no helper: names stay, no clock.
        var bare = sample
        bare.resolveClock(table: nil, helper: nil, now: now)
        XCTAssertNil(bare.clockMHz)
        XCTAssertNil(bare.clockSource)
        XCTAssertNil(bare.maximumClockMHz)
        XCTAssertEqual(bare.performanceStates?.count, 4)
    }

    func testContextSwitchChannelNamesAndPercentile() throws {
        let parsed = try XCTUnwrap(
            GPUContextSwitches.parse(channel: "3D CtxSwitch Latency Histogram Bucket 4 (<500us)"))
        XCTAssertEqual(parsed.prefix, "3D")
        XCTAssertEqual(parsed.upperBound, 500)
        let top = try XCTUnwrap(
            GPUContextSwitches.parse(
                channel: "CL CtxSwitch Latency Histogram Bucket Max (>=40000us)"))
        XCTAssertEqual(top.prefix, "CL")
        XCTAssertNil(top.upperBound)
        XCTAssertNil(GPUContextSwitches.parse(channel: "Total Restarts"))
        XCTAssertNil(GPUContextSwitches.parse(channel: "TA CtxSwitch Latency Histogram Bucket 0"))

        let switches = try XCTUnwrap(
            GPUContextSwitches(buckets: [
                .init(upperBoundMicroseconds: 200, count: 4),
                .init(upperBoundMicroseconds: 100, count: 90),
                .init(upperBoundMicroseconds: nil, count: 1),
            ]))
        XCTAssertEqual(switches.total, 95)
        XCTAssertEqual(switches.buckets.map(\.upperBoundMicroseconds), [100, 200, nil])
        XCTAssertEqual(switches.percentile95Microseconds, 200)
        let slow = try XCTUnwrap(
            GPUContextSwitches(buckets: [
                .init(upperBoundMicroseconds: 100, count: 1),
                .init(upperBoundMicroseconds: nil, count: 9),
            ]))
        XCTAssertEqual(slow.percentile95Microseconds, .infinity)
        let none = try XCTUnwrap(
            GPUContextSwitches(buckets: [.init(upperBoundMicroseconds: 100, count: 0)]))
        XCTAssertNil(none.percentile95Microseconds)
        XCTAssertNil(GPUContextSwitches(buckets: []))
    }

    func testControllerAndLostPerformanceClassification() {
        XCTAssertEqual(GPUControllerState("IDLE_OFF").kind, .idle)
        XCTAssertEqual(GPUControllerState("PERF").kind, .demand)
        XCTAssertEqual(GPUControllerState("CLTMLIMI").kind, .thermal)
        XCTAssertEqual(GPUControllerState("PPMLIMIT").kind, .power)
        // Names whose meaning is not plain stay unclassified.
        XCTAssertEqual(GPUControllerState("FAST_DIE").kind, .other)
        XCTAssertEqual(GPUControllerState("SE").kind, .other)

        var diagnostics = GPUDiagnostics()
        XCTAssertNil(diagnostics.limitedResidency)
        XCTAssertNil(diagnostics.lostResidency)
        diagnostics.controllerStates = [
            .init(name: "PERF", residency: 60), .init(name: "CLTMLIMI", residency: 25),
            .init(name: "POWER", residency: 10), .init(name: "SE", residency: 5),
        ]
        XCTAssertEqual(diagnostics.limitedResidency, 35)
        diagnostics.lostPerformanceKnown = true
        XCTAssertEqual(diagnostics.lostResidency, 0)
        diagnostics.lostPerformance = [.init(name: "GPU3_TH", residency: 4)]
        XCTAssertEqual(diagnostics.lostResidency, 4)

        let thermal = GPULostPerformanceReason("GPU3_TH")
        XCTAssertEqual(thermal.block, "GPU3")
        XCTAssertEqual(thermal.limit, .thermal)
        XCTAssertEqual(GPULostPerformanceReason("AFR0_EMT").limit, .electrical)
        XCTAssertEqual(GPULostPerformanceReason("FAB0_TH").block, "FAB0")
        XCTAssertEqual(GPULostPerformanceReason("INVALID").limit, .other)
    }

    func testHealthCountersAndMemoryLimit() {
        var health = GPUHealthCounters()
        XCTAssertFalse(health.isClean, "Nothing read is not the same as clean")
        health.restarts = 0
        health.killedWork = [.compute: 0, .fragment: 0]
        XCTAssertTrue(health.isClean)
        XCTAssertEqual(health.killedTotal, 0)
        health.killedWork[.compute] = 2
        XCTAssertFalse(health.isClean)
        XCTAssertEqual(health.killedTotal, 2)

        let ram: UInt64 = 36 * 1_073_741_824
        XCTAssertEqual(
            GPUMemoryLimit.resolve(
                wiredLimitMB: 0, recommendedBytes: 28_000_000_000, physicalMemory: ram),
            GPUMemoryLimit(bytes: 28_000_000_000, isCustom: false))
        XCTAssertEqual(
            GPUMemoryLimit.resolve(
                wiredLimitMB: 32_768, recommendedBytes: 28_000_000_000, physicalMemory: ram),
            GPUMemoryLimit(bytes: 32_768 * 1_048_576, isCustom: true))
        XCTAssertNil(
            GPUMemoryLimit.resolve(wiredLimitMB: nil, recommendedBytes: nil, physicalMemory: ram))
        XCTAssertNil(
            GPUMemoryLimit.resolve(wiredLimitMB: 0, recommendedBytes: ram * 2, physicalMemory: ram))
        XCTAssertNil(
            GPUMemoryLimit.resolve(
                wiredLimitMB: 64 * 1024, recommendedBytes: nil, physicalMemory: ram))
    }

    func testClusterSplitNeedsTheBitsToMatchTheCoreCount() {
        // 445 = 0b110111101: seven enabled cores in each of an M3 Pro's two clusters.
        XCTAssertEqual(
            GPUReader.clusters(from: ["core_mask_list": [445, 445]], coreCount: 14), [7, 7])
        XCTAssertNil(GPUReader.clusters(from: ["core_mask_list": [445, 445]], coreCount: 16))
        XCTAssertNil(GPUReader.clusters(from: ["core_mask_list": [445]], coreCount: nil))
        XCTAssertNil(GPUReader.clusters(from: [:], coreCount: 14))
    }

    func testDiagnosticsSurviveCodableRoundTrip() throws {
        var sample = GPUSample(utilization: 10)
        var diagnostics = GPUDiagnostics()
        diagnostics.engines[.compute] = GPUEngineActivity(submissionsPerSecond: 12)
        diagnostics.wakeupsPerSecond = 3
        sample.diagnostics = diagnostics
        sample.clockMHz = 900
        sample.clockSource = .frequencyTable
        var health = GPUHealthCounters()
        health.killedWork[.fragment] = 1
        sample.health = health
        let decoded = try JSONDecoder().decode(
            GPUSample.self, from: JSONEncoder().encode(sample))
        XCTAssertEqual(decoded, sample)
        // A reading from an older helper, without the GPU fields, still decodes.
        let old = #"{"timestamp":0,"interval":1,"watts":0.5}"#.data(using: .utf8)!
        let reading = try JSONDecoder().decode(ANEPowerReading.self, from: old)
        XCTAssertNil(reading.gpuFrequencyMHz)
        XCTAssertNil(reading.gpuStateFrequenciesMHz)
    }

    /// Opt-in, on real hardware: `MACPERF_TEST_GPU_DIAGNOSTICS=1 swift test
    /// --filter GPUDiagnosticsTests/testLiveReadersUnderComputeLoad`. Runs a
    /// Metal compute loop and checks the readers see it without root.
    func testLiveReadersUnderComputeLoad() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPERF_TEST_GPU_DIAGNOSTICS"] == "1")
        // Before the load: a desktop GPU wakes many times a second, so the
        // busy-period histogram has entries and the rates are real numbers.
        let idleReader = PowerReader()
        _ = idleReader.read(now: Date())
        Thread.sleep(forTimeInterval: 2)
        let idle = try XCTUnwrap(idleReader.read(now: Date())?.gpuDiagnostics)
        print(
            "GPU idle: wakeups \(idle.wakeupsPerSecond ?? -1)/s busy \(idle.meanBusyMilliseconds ?? -1) ms idle \(idle.meanIdleMilliseconds ?? -1) ms"
        )
        XCTAssertNotNil(idle.wakeupsPerSecond)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void spin(device float* out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
                float x = i;
                for (int j = 0; j < 20000; j++) { x = fma(x, 1.0001, 0.5); }
                out[i] = x;
            }
            """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(
            function: XCTUnwrap(library.makeFunction(name: "spin")))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffer = try XCTUnwrap(device.makeBuffer(length: 4 << 20))
        let stop = ManagedAtomicFlag()
        let worker = Thread {
            while !stop.isSet {
                guard let commands = queue.makeCommandBuffer(),
                    let encoder = commands.makeComputeCommandEncoder()
                else { return }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.dispatchThreads(
                    MTLSize(width: 1 << 20, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                encoder.endEncoding()
                commands.commit()
                commands.waitUntilCompleted()
            }
        }
        worker.start()
        defer { stop.set() }
        Thread.sleep(forTimeInterval: 1)

        let gpuReader = GPUReader()
        let powerReader = PowerReader()
        _ = powerReader.read(now: Date())
        Thread.sleep(forTimeInterval: 2)
        var sample = try XCTUnwrap(gpuReader.read())
        let power = try XCTUnwrap(powerReader.read(now: Date()))
        sample.performanceStates = power.gpuStates
        sample.activeResidency = power.gpuActiveResidency
        sample.diagnostics = power.gpuDiagnostics
        sample.health = power.gpuHealth
        sample.resolveClock(table: gpuReader.frequencyTable, helper: nil)
        let summary: [String] = [
            "clock \(sample.clockMHz ?? -1) of \(sample.maximumClockMHz ?? -1) MHz",
            "clusters \(sample.coreClusters ?? [])",
            "limit \(sample.memoryLimit.map { "\($0.bytes) custom \($0.isCustom)" } ?? "nil")",
            "controller \(power.gpuDiagnostics?.controllerStates.map { "\($0.name) \($0.residency)" } ?? [])",
            "lost known \(power.gpuDiagnostics?.lostPerformanceKnown ?? false) \(power.gpuDiagnostics?.lostPerformance.map(\.name) ?? [])",
            "engines \(power.gpuDiagnostics?.engines.mapValues { "\($0.submissionsPerSecond ?? -1)/s switches \($0.contextSwitchesPerSecond ?? -1)/s p95 \($0.contextSwitches?.percentile95Microseconds ?? -1)" } ?? [:])",
            "wakeups \(power.gpuDiagnostics?.wakeupsPerSecond ?? -1) busy \(power.gpuDiagnostics?.meanBusyMilliseconds ?? -1) idle \(power.gpuDiagnostics?.meanIdleMilliseconds ?? -1)",
            "health \(String(describing: power.gpuHealth))",
        ]
        print("GPU diagnostics live:\n  " + summary.joined(separator: "\n  "))
        XCTAssertNotNil(gpuReader.frequencyTable)
        XCTAssertGreaterThan(try XCTUnwrap(sample.clockMHz), 300)
        XCTAssertEqual(sample.clockSource, .frequencyTable)
        XCTAssertFalse(try XCTUnwrap(power.gpuDiagnostics).controllerStates.isEmpty)
        XCTAssertTrue(try XCTUnwrap(power.gpuDiagnostics).lostPerformanceKnown)
        let compute = try XCTUnwrap(power.gpuDiagnostics?.engines[.compute]?.submissionsPerSecond)
        XCTAssertGreaterThan(compute, 1)
        XCTAssertNotNil(power.gpuHealth?.restarts)
        XCTAssertNotNil(sample.memoryLimit)
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

extension Data {
    fileprivate init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
