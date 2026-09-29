import CryptoKit
import XCTest

@testable import MacPerfMonitorCore

final class AskReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMissingSnapshotDoesNotInventFacts() {
        let report = AskReport.make(topic: .overview, snapshot: nil, now: now)
        XCTAssertTrue(report.evidence.isEmpty)
        XCTAssertNil(report.sampledAt)
        XCTAssertFalse(report.limits.isEmpty)
    }

    func testStaleSnapshotDoesNotDescribeCurrentActivity() {
        let report = AskReport.make(
            topic: .cpu, snapshot: snapshot(at: now.addingTimeInterval(-30)), now: now)
        XCTAssertTrue(report.evidence.isEmpty)
        XCTAssertTrue(report.summary.contains("too old"))
    }

    func testUnknownPressureAndNetworkStayUnknown() {
        let report = AskReport.make(topic: .overview, snapshot: snapshot(at: now), now: now)
        XCTAssertFalse(report.evidence.contains { $0.id == "pressure" })
        XCTAssertFalse(report.evidence.contains { $0.id == "network-in" })
        XCTAssertTrue(report.limits.contains { $0.contains("tracking is off") })
    }

    func testValidPressureAndCapacityCarryTheirLimits() {
        var sample = snapshot(at: now)
        sample.system.pressureSampleValid = true
        sample.system.swapSampleValid = true
        sample.system.bootVolumeTotalBytes = 500_000_000_000
        sample.system.bootVolumeFreeBytes = 20_000_000_000
        let report = AskReport.make(topic: .overview, snapshot: sample, now: now)
        XCTAssertTrue(report.evidence.contains { $0.id == "pressure" && $0.value == "Normal" })
        XCTAssertTrue(
            report.evidence.contains {
                $0.id == "disk-space" && $0.detail.contains("once a minute")
            })
    }

    func testContextBudgetReservesOutputAndNeverAssumesEightK() {
        for size in [4096, 8192] {
            let budget = AskContextBudget(reportedSize: size)
            XCTAssertEqual(budget.inputLimit, 2800)
            XCTAssertTrue(budget.admits(inputTokens: 2800))
            XCTAssertFalse(budget.admits(inputTokens: 2801))
            XCTAssertFalse(budget.admits(inputTokens: -1))
        }
        XCTAssertFalse(AskContextBudget(reportedSize: 1000).admits(inputTokens: 0))
        XCTAssertFalse(AskContextBudget(reportedSize: -1).admits(inputTokens: 0))
    }

    func testSlowdownReportsIncludeActivePagingThermalsAndDiskEvidence() {
        var sample = snapshot(at: now)
        sample.system.pressureSampleValid = true
        sample.system.swapSampleValid = true
        sample.system.swapUsed = 4 << 30
        sample.system.swapInBytesPerSecond = 0
        sample.system.swapOutBytesPerSecond = Double(2 << 20)
        sample.system.thermalPressure = .serious
        sample.system.bootVolumeTotalBytes = 100 << 30
        sample.system.bootVolumeFreeBytes = 4 << 30
        sample.system.diskUtilizationPercent = 95
        sample.system.diskReadLatencyMs = 40
        var writer = process(pid: 21, cpu: 5)
        writer.diskWriteBytesPerSec = Double(50 << 20)
        sample.processes = [writer]
        let reports = AskTopic.allCases.map {
            AskReport.make(topic: $0, snapshot: sample, now: now)
        }
        let request = AskExplanationRequest(
            question: "Why is my Mac slow?", previousTopic: .overview, reports: reports)
        for id in [
            "cpu.thermal", "memory.swap-in", "memory.swap-out", "disk.disk-busy",
            "disk.disk-free-percent", "disk.disk-read-latency", "disk.process-0",
        ] {
            XCTAssertTrue(request.facts.contains { $0.id == id }, id)
        }
        XCTAssertTrue(
            request.facts.contains { $0.id == "disk.disk-free-percent" && $0.value == "4.0%" })
        XCTAssertTrue(reports[0].resourceConstrained)
        XCTAssertTrue(reports[0].summary.contains("thermal pressure"))
        sample.system.pressureLevel = .critical
        let pressured = AskReport.make(topic: .overview, snapshot: sample, now: now)
        XCTAssertTrue(pressured.summary.contains("memory strain"))
    }

    func testMissingOrInvalidDiagnosticReadingsAreNotReportedAsZero() {
        var sample = snapshot(at: now)
        sample.system.swapInBytesPerSecond = .nan
        sample.system.swapOutBytesPerSecond = -1
        sample.system.diskUtilizationPercent = 101
        sample.system.diskReadLatencyMs = -.infinity
        let report = AskReport.make(topic: .overview, snapshot: sample, now: now)
        XCTAssertFalse(
            report.evidence.contains {
                [
                    "thermal", "swap-in", "swap-out", "disk-busy", "disk-read-latency",
                    "disk-write-latency",
                ].contains($0.id)
            })
    }

    func testQwenEligibilityUsesAnInclusiveSixteenGiBBoundary() {
        let threshold = AskLocalModelPolicy.minimumPhysicalMemoryBytes
        for memory in [UInt64(0), 8 << 30, threshold - 1] {
            XCTAssertFalse(
                AskLocalModelPolicy.isEligible(physicalMemoryBytes: memory, isAppleSilicon: true))
        }
        for memory in [threshold, 18 << 30, 32 << 30] {
            XCTAssertTrue(
                AskLocalModelPolicy.isEligible(physicalMemoryBytes: memory, isAppleSilicon: true))
        }
        XCTAssertFalse(
            AskLocalModelPolicy.isEligible(physicalMemoryBytes: 32 << 30, isAppleSilicon: false))
    }

    func testInvestigationUsesToolEvidenceThenStopsRepeatedQueries() async throws {
        let request = AskExplanationRequest(
            question: "Why is my Mac slow?", previousTopic: .overview,
            reports: [AskReport.make(topic: .cpu, snapshot: snapshot(at: now), now: now)])
        let call = AskToolCall(name: .systemHistory, metric: .cpu)
        let result = try await AskInvestigation.run(
            request: request, choose: { _ in AskInvestigationDecision(tool: call) },
            read: { _ in
                AskToolResult(
                    facts: [
                        AskExplanationFact(
                            id: "cpu-mean", name: "Mean CPU", value: "85.0%",
                            meaning: "Recorded mean over the observed interval.")
                    ], limits: [])
            },
            explain: { evidence in
                XCTAssertTrue(evidence.facts.contains { $0.id == "check1.cpu-mean" })
                XCTAssertFalse(evidence.facts.contains { $0.id == "cpu.cpu" })
                return AskExplanationDraft(
                    topic: "cpu", summary: "CPU activity is a lead worth checking.",
                    interpretation:
                        "The recorded CPU mean is elevated. Process history could narrow the source.",
                    uncertainty: "The task affected by the slowdown is not yet known.",
                    nextCheck: "Compare responsiveness when the current task naturally finishes.",
                    followUpQuestion: "Which task feels slow?", evidenceIDs: ["check1.cpu-mean"],
                    nextStep: .inspectProcesses)
            })
        XCTAssertEqual(result.checks, [call])
    }

    func testInvestigationRejectsInvalidWindowsAndUnknownProcessReferences() async throws {
        for call in [
            AskToolCall(name: .systemHistory, metric: .cpu, fromMinutesAgo: 10081),
            AskToolCall(name: .systemHistory, metric: .cpu, fromMinutesAgo: 5, toMinutesAgo: 5),
            AskToolCall(name: .processHistory, metric: .memory),
            AskToolCall(
                name: .findProcesses, metric: .cpu, search: String(repeating: "x", count: 161)),
        ] { XCTAssertThrowsError(try call.validate()) }
        let request = AskExplanationRequest(
            question: "Check an app", previousTopic: .cpu, reports: [])
        do {
            _ = try await AskInvestigation.run(
                request: request,
                choose: { _ in
                    AskInvestigationDecision(
                        tool: AskToolCall(
                            name: .processHistory, metric: .cpu, processReference: "invented"))
                },
                read: { _ in
                    XCTFail("Invalid references must not reach the database")
                    throw AskInvestigationError.unavailable
                },
                explain: { _ in throw AskInvestigationError.unavailable })
            XCTFail("Expected an unknown-reference error")
        } catch let error as AskInvestigationError { XCTAssertEqual(error, .unknownProcess) }
    }

    func testInvestigationVerifiesARankedCandidateEvenWhenTheModelRepeatsItsRequest() async throws {
        let request = AskExplanationRequest(
            question: "Why is it slow?", previousTopic: .overview, reports: [])
        let ranking = AskToolCall(name: .topProcesses, metric: .cpu)
        let result = try await AskInvestigation.run(
            request: request,
            choose: { _ in AskInvestigationDecision(tool: ranking) },
            read: { call in
                AskToolResult(
                    facts: [
                        AskExplanationFact(
                            id: "observed", name: "CPU", value: "85.0%",
                            meaning: "Recorded activity.")
                    ],
                    limits: [],
                    processes: call.name == .topProcesses
                        ? [AskProcessReference(reference: "candidate", name: "BuildWorker")] : [])
            },
            explain: { evidence in
                AskExplanationDraft(
                    topic: "cpu", summary: "Build activity is a possible contributor.",
                    interpretation:
                        "The candidate and machine histories were checked. Load alone does not prove a fault.",
                    uncertainty: "Responsiveness was not directly measured.",
                    nextCheck: "Compare responsiveness after the task naturally finishes.",
                    followUpQuestion: "Which task feels slow?", evidenceIDs: [evidence.facts[0].id],
                    nextStep: .inspectProcesses)
            })
        XCTAssertEqual(result.checks.map(\.name), [.topProcesses, .processHistory, .systemHistory])
        XCTAssertLessThanOrEqual(result.checks.count, AskInvestigation.maximumChecks)
    }

    func testDatabaseToolsReadPinnedIntervalsAndReturnOpaqueProcessReferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-db-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        for offset in [-180.0, -120, -60, 0] {
            let date = now.addingTimeInterval(offset)
            var system = snapshot(at: date).system
            system.cpuLoad = offset < -60 ? 0.8 : 0.1
            var process = self.process(pid: 21, cpu: offset < -60 ? 200 : 5)
            process.timestamp = date
            process.startTime = now.addingTimeInterval(-600)
            process.executablePath = "/Users/private/worker"
            try store.insert(system, processes: [process])
        }
        let earlier = try store.readAskData(
            AskToolCall(name: .systemHistory, metric: .cpu, fromMinutesAgo: 3, toMinutesAgo: 2),
            at: now)
        XCTAssertTrue(earlier.result.facts.contains { $0.id == "cpu-mean" && $0.value == "80.0%" })
        XCTAssertTrue(
            earlier.result.timeWindows.contains {
                $0.kind == .requested && $0.start == now.addingTimeInterval(-180)
                    && $0.end == now.addingTimeInterval(-120)
            })
        XCTAssertTrue(
            earlier.result.timeWindows.contains {
                $0.kind == .observed && $0.start == now.addingTimeInterval(-180)
                    && $0.end == now.addingTimeInterval(-120)
            })
        let top = try store.readAskData(AskToolCall(name: .topProcesses, metric: .cpu), at: now)
        let reference = try XCTUnwrap(top.result.processes.first?.reference)
        XCTAssertNotNil(top.identities[reference])
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(top.result), as: UTF8.self).contains(
                "/Users/"))
        let history = try store.readAskData(
            AskToolCall(name: .processHistory, metric: .cpu, processReference: reference), at: now,
            process: top.identities[reference])
        XCTAssertFalse(history.result.facts.isEmpty)
        let missing = try store.readAskData(
            AskToolCall(name: .systemHistory, metric: .gpu), at: now)
        XCTAssertTrue(missing.result.facts.isEmpty)
        XCTAssertFalse(missing.result.limits.isEmpty)
        XCTAssertTrue(missing.result.timeWindows.allSatisfy { $0.kind == .requested })
        let injection = try store.readAskData(
            AskToolCall(name: .findProcesses, metric: .cpu, search: "' OR 1=1 --"), at: now)
        XCTAssertTrue(injection.result.processes.isEmpty)
        XCTAssertFalse(
            try store.readAskData(AskToolCall(name: .systemHistory, metric: .cpu), at: now).result
                .facts.isEmpty)
    }

    func testInferenceChannelSeparatesFramesAndRejectsOversizedInput() throws {
        let pipe = Pipe()
        let channel = AskInferenceChannel(input: pipe.fileHandleForReading)
        for metric in [AskDiagnosticMetric.cpu, .disk] {
            try AskInferenceChannel.write(
                AskToolCall(name: .systemHistory, metric: metric), to: pipe.fileHandleForWriting)
        }
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try channel.read(AskToolCall.self).metric, .cpu)
        XCTAssertEqual(try channel.read(AskToolCall.self).metric, .disk)
        XCTAssertThrowsError(try channel.read(AskToolCall.self))
        try pipe.fileHandleForReading.close()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-frame-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 32, count: 65536).write(to: file)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        XCTAssertThrowsError(try AskInferenceChannel(input: input).read(AskToolCall.self)) {
            error in
            XCTAssertEqual(error as? AskExplanationError, .contextLimit)
        }
    }

    func testDatabaseMemoryEvidenceHonorsValidityAndKeepsUnknownAsUnknown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-validity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        var sample = snapshot(at: now).system
        sample.pressureLevel = .normal
        sample.pressureSampleValid = false
        sample.swapSampleValid = false
        try store.insert(systemSample: sample)
        let invalid = try store.readAskData(
            AskToolCall(name: .systemHistory, metric: .memory), at: now)
        XCTAssertFalse(invalid.result.facts.contains { $0.id == "pressure" })
        XCTAssertTrue(invalid.result.limits.contains { $0.contains("validity") })
        sample.timestamp = now.addingTimeInterval(1)
        sample.pressureSampleValid = true
        sample.pressureLevel = .warning
        sample.swapOutBytesPerSecond = Double(2 << 20)
        try store.insert(systemSample: sample)
        let valid = try store.readAskData(
            AskToolCall(name: .systemHistory, metric: .cpu), at: sample.timestamp)
        XCTAssertTrue(valid.result.facts.contains { $0.id == "pressure" && $0.value == "Warning" })
        let swap = try store.readAskData(
            AskToolCall(name: .systemHistory, metric: .swap), at: sample.timestamp)
        XCTAssertTrue(swap.result.facts.contains { $0.id == "swap-out-mean" })
        XCTAssertFalse(swap.result.facts.contains { $0.id == "swap-mean" })
    }

    func testQwenRequiresCurrentPressureAndThermalHeadroom() {
        for pressure: PressureLevel? in [nil, .warning, .critical] {
            XCTAssertFalse(
                AskLocalModelPolicy.permitsInference(
                    physicalMemoryBytes: 18 << 30, isAppleSilicon: true,
                    pressure: pressure, thermalIsConstrained: false))
        }
        XCTAssertFalse(
            AskLocalModelPolicy.permitsInference(
                physicalMemoryBytes: 18 << 30, isAppleSilicon: true,
                pressure: .normal, thermalIsConstrained: true))
        XCTAssertTrue(
            AskLocalModelPolicy.permitsInference(
                physicalMemoryBytes: 16 << 30, isAppleSilicon: true,
                pressure: .normal, thermalIsConstrained: false))
    }

    func testQwenContextLimitDoesNotExpandTheAppleBudget() {
        let qwen = AskContextBudget(
            reportedSize: 262144, maximumContext: AskLocalModelPolicy.maximumContextTokens)
        XCTAssertEqual(qwen.contextSize, 8192)
        XCTAssertTrue(qwen.admits(inputTokens: 6896))
        XCTAssertFalse(qwen.admits(inputTokens: 6897))
        XCTAssertEqual(AskContextBudget(reportedSize: 8192).inputLimit, 2800)
    }

    func testLocalModelDefinitionPreservesTheExistingQwenDownload() {
        let definition = AskQwenModel.definition
        XCTAssertEqual(definition.identifier, "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        XCTAssertEqual(definition.revision, "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b")
        XCTAssertEqual(definition.directoryName, AskQwenModel.directoryName)
        XCTAssertEqual(definition.assets.map(\.name), AskQwenModel.assets.map(\.name))
        XCTAssertEqual(definition.downloadBytes, AskQwenModel.downloadBytes)
        XCTAssertEqual(definition.requiredFreeDiskBytes, AskQwenModel.requiredFreeDiskBytes)
    }

    func testExperimentalModelsHavePinnedIndependentVerifiedDownloads() throws {
        XCTAssertEqual(AskInferenceBackend(rawValue: "qwen"), .qwen)
        XCTAssertNil(AskLocalModels.definition(for: .apple))
        let backends = AskInferenceBackend.allCases.filter(\.isLocal)
        XCTAssertEqual(backends, [.qwen, .qwen35, .deepAnalyze])
        let definitions = try backends.map { try XCTUnwrap(AskLocalModels.definition(for: $0)) }
        XCTAssertEqual(Set(definitions.map(\.directoryName)).count, 3)
        for definition in definitions {
            XCTAssertEqual(definition.revision.count, 40)
            XCTAssertGreaterThan(definition.downloadBytes, 0)
            XCTAssertGreaterThan(definition.requiredFreeDiskBytes, definition.downloadBytes * 2)
            XCTAssertEqual(Set(definition.assets.map(\.name)).count, definition.assets.count)
            for asset in definition.assets {
                XCTAssertEqual(asset.sha256.count, 64, asset.name)
                XCTAssertTrue(asset.sha256.allSatisfy(\.isHexDigit))
                XCTAssertEqual(asset.url.scheme, "https")
                if definition.identifier != AskQwenModel.identifier {
                    XCTAssertFalse(asset.url.path.contains("/main/"))
                }
                XCTAssertEqual(asset.name, URL(fileURLWithPath: asset.name).lastPathComponent)
            }
        }
        XCTAssertEqual(AskLocalModels.qwen35.format, .mlx)
        XCTAssertEqual(AskLocalModels.deepAnalyze.format, .gguf)
        XCTAssertTrue(AskInferenceBackend.deepAnalyze.isExperimental)
        XCTAssertFalse(AskInferenceBackend.qwen.isExperimental)
    }

    func testRecordedWindowReferencesAreNotMistakenForInventedMeasurements() throws {
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-18T09:33:10Z"))
        let window = AskEvidenceWindow(
            start: end.addingTimeInterval(-300), end: end,
            kind: .requested, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let facts = [
            AskExplanationFact(
                id: "cpu", name: "Whole-machine CPU", value: "17.9%", meaning: "Observed activity.")
        ]
        let request = AskExplanationRequest(
            question: "Why slow?", previousTopic: .cpu, reports: [], locale: "en_GB"
        )
        .adding(AskToolResult(facts: facts, limits: [], timeWindows: [window]), check: 1)
        var answer = AskExplanationDraft(
            topic: "cpu", summary: "The readings do not establish a cause.",
            interpretation: "The requested interval was from 09:28:10 to 09:33:10.",
            uncertainty: "A 5-minute window cannot explain every intermittent symptom.",
            nextCheck: "Compare responsiveness after the current task finishes.",
            followUpQuestion: "Which app feels slow?", evidenceIDs: ["check1.cpu"],
            nextStep: .observe)
        XCTAssertNoThrow(try answer.validate(against: request))
        answer.interpretation = "The requested interval was from 9:28 to 9:33 AM."
        XCTAssertNoThrow(try answer.validate(against: request))
        for duration in ["300 seconds", "5 min", "0.08333333333333333 hours"] {
            answer.uncertainty = "The requested window was \(duration)."
            XCTAssertNoThrow(try answer.validate(against: request), duration)
        }
        for unsupported in [
            "30 minutes", "50 minutes", "-5 minutes", "5 MB", "5%", "18:33:10", "09:33:11",
        ] {
            answer.uncertainty = "The reading was \(unsupported)."
            XCTAssertEqual(
                answer.validationIssue(against: request), .unverifiedMeasurement, unsupported)
        }
        answer.uncertainty = "The requested window was 5 minutes."
        let noWindow = AskExplanationRequest(
            question: "Why slow?", previousTopic: .cpu, reports: [], locale: "en_GB"
        )
        .adding(AskToolResult(facts: facts, limits: []), check: 1)
        XCTAssertEqual(answer.validationIssue(against: noWindow), .unverifiedMeasurement)
        XCTAssertEqual(request.withCitationLabels().timeWindows, [window])
    }

    func testGeneratedExplanationMustCiteRealFactsAndCannotInventMeasurements() throws {
        let report = AskReport.make(topic: .cpu, snapshot: snapshot(at: now), now: now)
        let input = AskExplanationRequest(
            question: "Why is it slow?", previousTopic: .overview, reports: [report])
        var answer = AskExplanationDraft(
            topic: "cpu", summary: "The CPU is not saturated in this reading.",
            interpretation: "The available CPU reading does not establish a sustained bottleneck.",
            uncertainty: "A recent trend would help explain an intermittent slowdown.",
            nextCheck:
                "Compare the affected app with a local app. If both are slow, watch their activity together.",
            followUpQuestion: "Does this affect one app or several?",
            evidenceIDs: ["cpu.cpu"], nextStep: .observe)
        XCTAssertNoThrow(try answer.validate(against: input))
        answer.summary = "The CPU reading is 20.0% in this snapshot."
        XCTAssertNoThrow(try answer.validate(against: input))
        answer.nextCheck =
            "Compare the app while the task runs and after it finishes. Check whether responsiveness improves."
        XCTAssertNoThrow(try answer.validate(against: input))
        answer.interpretation = "This proves the CPU caused the slowdown."
        XCTAssertEqual(answer.validationIssue(against: input), .unsafeWording)
        answer.interpretation = "The CPU is a possible contributor, not a proven cause."
        XCTAssertNoThrow(try answer.validate(against: input))
        answer.nextCheck = "Watch for 99 percent CPU."
        XCTAssertThrowsError(try answer.validate(against: input))
        answer.nextCheck = "inspectProcesses"
        XCTAssertThrowsError(try answer.validate(against: input))
        answer.nextCheck = "Compare a local app with the affected app while it is slow."
        answer.followUpQuestion = " "
        XCTAssertThrowsError(try answer.validate(against: input))
        answer.followUpQuestion = "Does this affect one app or several?"
        answer.evidenceIDs = ["invented"]
        XCTAssertThrowsError(try answer.validate(against: input))
        answer.evidenceIDs = ["cpu.cpu"]
        answer.summary = "The CPU reached 99 percent."
        XCTAssertThrowsError(try answer.validate(against: input))
        answer.summary = "Run sudo rm -rf to fix this."
        XCTAssertThrowsError(try answer.validate(against: input))
    }

    func testExplanationContextHasScopedIDsAndNeverSerializesPathsOrProcessIdentity() throws {
        var sample = snapshot(at: now)
        var row = process(pid: 10, cpu: 80)
        row.executablePath = "/Users/private/example"
        sample.processes = [row]
        let reports = AskTopic.allCases.map {
            AskReport.make(topic: $0, snapshot: sample, now: now)
        }
        let request = AskExplanationRequest(
            question: "What is using CPU?", previousTopic: .cpu, reports: reports)
        XCTAssertLessThanOrEqual(request.facts.count, 24)
        XCTAssertEqual(Set(request.facts.map(\.id)).count, request.facts.count)
        XCTAssertTrue(request.facts.contains { $0.id == "cpu.process-0" })
        let json = try request.prompt()
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains("processIdentity"))
        XCTAssertFalse(json.contains("startTime"))
    }

    func testRecentHistoryUsesTimeWeightsAndRejectsGaps() {
        func point(_ offset: Double, cpu: Double) -> SystemHistoryPoint {
            SystemHistoryPoint(
                date: now.addingTimeInterval(offset), pressurePercent: 10,
                appMemory: 0, wired: 0, compressed: 0, cachedFiles: 0, swapUsed: 0, cpuLoad: cpu)
        }
        var report = AskReport.make(topic: .cpu, snapshot: snapshot(at: now), now: now)
        report.includeRecentHistory([point(-60, cpu: 0), point(-30, cpu: 0.8), point(0, cpu: 0.8)])
        XCTAssertTrue(report.evidence.contains { $0.id == "cpu-trend" && $0.value.contains("80") })
        var gapped = AskReport.make(topic: .cpu, snapshot: snapshot(at: now), now: now)
        gapped.includeRecentHistory([point(-120, cpu: 0), point(-30, cpu: 0.8), point(0, cpu: 0.8)])
        XCTAssertFalse(gapped.evidence.contains { $0.id == "cpu-trend" })
        XCTAssertTrue(gapped.limits.contains { $0.contains("continuous history") })
    }

    func testModelAssetVerificationRejectsTamperingAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-asset-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("verified".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("model")
        let asset = AskModelAsset(name: "model", bytes: Int64(data.count), sha256: hash, url: file)
        try data.write(to: file)
        XCTAssertNoThrow(try asset.verify(at: file))
        try Data("tampered".utf8).write(to: file)
        XCTAssertThrowsError(try asset.verify(at: file))
        try data.write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try asset.verify(at: link))
        XCTAssertFalse(AskQwenModel.hasCompleteFiles(in: directory))
    }

    func testCPUCanExceedOneHundredPercentAndKeepsProcessIdentity() {
        var sample = snapshot(at: now)
        sample.processes = [process(pid: 10, cpu: 20), process(pid: 20, cpu: 250)]
        let report = AskReport.make(topic: .cpu, snapshot: sample, now: now)
        let ranked = report.evidence.filter { $0.processIdentity != nil }
        XCTAssertEqual(ranked.map { $0.processIdentity?.pid }, [20, 10])
        XCTAssertTrue(ranked[0].value.contains("250"))
        XCTAssertTrue(ranked[0].detail.contains("one core"))
        XCTAssertEqual(ranked[0].processIdentity, sample.processes[1].id)
        XCTAssertTrue(report.summary.contains("Process 20"))
    }

    func testUnreadableFootprintsAndStaleProcessesDoNotEnterMemoryRanking() {
        var sample = snapshot(at: now)
        var unreadable = process(pid: 10, cpu: 1)
        unreadable.footprintReadable = false
        var stale = process(pid: 20, cpu: 1)
        stale.timestamp = now.addingTimeInterval(-60)
        sample.processes = [unreadable, stale, process(pid: 30, cpu: 1)]
        let report = AskReport.make(topic: .memory, snapshot: sample, now: now)
        XCTAssertEqual(report.evidence.compactMap { $0.processIdentity?.pid }, [30])
        XCTAssertTrue(report.limits.contains { $0.contains("stale") })
        XCTAssertTrue(report.limits.contains { $0.contains("incomplete") })
    }

    func testDisabledNetworkTrackingDoesNotReportPerAppZeros() {
        var sample = snapshot(at: now)
        var row = process(pid: 10, cpu: 1)
        row.networkBytesPerSec = 100_000
        sample.processes = [row]
        let disabled = AskReport.make(topic: .network, snapshot: sample, now: now)
        XCTAssertTrue(disabled.evidence.allSatisfy { $0.processIdentity == nil })
        let enabled = AskReport.make(
            topic: .network, snapshot: sample, now: now, networkTrackingEnabled: true)
        XCTAssertEqual(enabled.evidence.compactMap { $0.processIdentity?.pid }, [10])
    }

    func testInvalidCPUAndImpossibleCapacityAreOmitted() {
        var sample = snapshot(at: now)
        sample.system.cpuLoad = .nan
        sample.system.bootVolumeTotalBytes = 10
        sample.system.bootVolumeFreeBytes = 20
        let report = AskReport.make(topic: .overview, snapshot: sample, now: now)
        XCTAssertFalse(report.evidence.contains { $0.id == "cpu" || $0.id == "disk-space" })
    }

    func testCriticalOrUnknownPressurePreventsInference() {
        var sample = snapshot(at: now)
        XCTAssertTrue(
            AskReport.make(topic: .memory, snapshot: sample, now: now).resourceConstrained)
        sample.system.pressureSampleValid = true
        sample.system.pressureLevel = .critical
        XCTAssertTrue(
            AskReport.make(topic: .memory, snapshot: sample, now: now).resourceConstrained)
        sample.system.pressureLevel = .normal
        XCTAssertFalse(
            AskReport.make(topic: .memory, snapshot: sample, now: now).resourceConstrained)
    }

    func testPlannerAcceptsOnlyUnusedFieldOmissionsAndRepairsInvalidDecisions() async throws {
        let json = """
            {"tool":{"name":"systemHistory","metric":"cpu","fromMinutesAgo":5,"toMinutesAgo":0}}
            """
        let decoded = try JSONDecoder().decode(AskInvestigationDecision.self, from: Data(json.utf8))
        let call = try XCTUnwrap(decoded.tool)
        XCTAssertNoThrow(try call.validate())
        XCTAssertEqual(call.search, "")
        XCTAssertEqual(call.processReference, "")
        XCTAssertThrowsError(
            try JSONDecoder().decode(AskInvestigationDecision.self, from: Data("{}".utf8)))
        let missingReference = json.replacingOccurrences(
            of: "systemHistory", with: "processHistory")
        let process = try JSONDecoder().decode(
            AskInvestigationDecision.self, from: Data(missingReference.utf8))
        XCTAssertThrowsError(try process.tool?.validate())
        let state = AskInvestigationState(
            evidence: AskExplanationRequest(
                question: "Why is it slow?", previousTopic: .cpu, reports: []),
            completedChecks: [], processes: [], remainingChecks: 4)
        let repaired = try await AskInvestigationDecision.generateValidated(for: state) { issue in
            if issue == nil { return "not JSON" }
            XCTAssertEqual(issue, .invalidJSON)
            return json
        }
        XCTAssertEqual(repaired.tool, call)
        do {
            _ = try await AskInvestigationDecision.generateValidated(for: state) { _ in
                missingReference
            }
            XCTFail("Missing required process references must stay rejected")
        } catch let error as AskInvestigationError { XCTAssertEqual(error, .invalidToolCall) }
    }

    func testMeasurementValidationDoesNotCorruptOverlappingCitedValues() {
        let request = AskExplanationRequest(
            question: "Why is it slow?", previousTopic: .cpu, reports: []
        )
        .adding(
            AskToolResult(
                facts: [
                    AskExplanationFact(
                        id: "small", name: "Other activity", value: "0.0%", meaning: "Recorded."),
                    AskExplanationFact(
                        id: "large", name: "Whole-machine CPU", value: "20.0%", meaning: "Recorded."
                    ),
                ], limits: []), check: 1)
        var answer = AskExplanationDraft(
            topic: "cpu", summary: "CPU measured 20.0% in this interval.",
            interpretation: "Other activity measured 0.0%.",
            uncertainty: "Responsiveness was not measured.",
            nextCheck: "Compare responsiveness while the task runs and after it finishes.",
            followUpQuestion: "Which task is affected?",
            evidenceIDs: ["check1.small", "check1.large"], nextStep: .observe)
        XCTAssertNoThrow(try answer.validate(against: request))
        answer.evidenceIDs = ["check1.small"]
        XCTAssertEqual(answer.validationIssue(against: request), .unverifiedMeasurement)
        answer.evidenceIDs = ["check1.small", "check1.large"]
        answer.summary = "CPU measured 120.0% in this interval."
        XCTAssertEqual(answer.validationIssue(against: request), .unverifiedMeasurement)
    }

    func testCitedPercentagesAllowEquivalentFormattingButNotDifferentMeasurements() {
        let request = AskExplanationRequest(
            question: "Why is it slow?", previousTopic: .cpu, reports: [], locale: "en_GB"
        )
        .adding(
            AskToolResult(
                facts: [
                    AskExplanationFact(
                        id: "cpu", name: "BuildWorker", value: "118.0%",
                        meaning: "Recorded process CPU.")
                ], limits: []), check: 1)
        var answer = AskExplanationDraft(
            topic: "cpu", summary: "BuildWorker used 118 percent.",
            interpretation: "The recorded activity is a possible contributor.",
            uncertainty: "Responsiveness was not measured.",
            nextCheck: "Compare responsiveness after the task finishes.",
            followUpQuestion: "Which app feels slow?",
            evidenceIDs: ["check1.cpu"], nextStep: .inspectProcesses)
        for value in ["118 percent", "118.00%", "118.0 %", "118 per cent"] {
            answer.summary = "BuildWorker used \(value)."
            XCTAssertNoThrow(try answer.validate(against: request), value)
        }
        for value in [
            "1180 percent", "118.1%", "-118%", "118 MB", "118", "1.18%", "118,1%", "118.0.0%",
            "118,000%",
        ] {
            answer.summary = "BuildWorker used \(value)."
            XCTAssertEqual(answer.validationIssue(against: request), .unverifiedMeasurement, value)
        }
        answer.summary = "BuildWorker used 118 percent."
        answer.evidenceIDs = []
        XCTAssertTrue(answer.validationIssues(against: request).contains(.unverifiedMeasurement))
        let german = AskExplanationRequest(
            question: "Warum langsam?", previousTopic: .cpu, reports: [], locale: "de_DE"
        )
        .adding(
            AskToolResult(
                facts: [
                    AskExplanationFact(
                        id: "cpu", name: "BuildWorker", value: "39,5%", meaning: "Recorded.")
                ], limits: []), check: 1)
        answer.evidenceIDs = ["check1.cpu"]
        answer.summary = "BuildWorker: 39,50 %."
        XCTAssertNoThrow(try answer.validate(against: german))
        let grouped = AskExplanationRequest(
            question: "Why slow?", previousTopic: .cpu, reports: [], locale: "en_GB"
        )
        .adding(
            AskToolResult(
                facts: [
                    AskExplanationFact(
                        id: "cpu", name: "BuildWorker", value: "1,118.0%", meaning: "Recorded.")
                ], limits: []), check: 1)
        answer.summary = "BuildWorker: 1118 percent."
        XCTAssertNoThrow(try answer.validate(against: grouped))
        answer.summary = "BuildWorker: 1 percent."
        XCTAssertEqual(answer.validationIssue(against: grouped), .unverifiedMeasurement)
    }

    func testQuotedMeasurementsGainTheirRealSourcesWithoutAcceptingInventedFacts() throws {
        let facts = (1...6).map { number in
            AskExplanationFact(
                id: "source-\(number)", name: "Worker \(number)", value: "\(number + 10).0%",
                meaning: "Recorded.")
        }
        let request = AskExplanationRequest(
            question: "Why slow?", previousTopic: .cpu, reports: [], locale: "en_GB"
        )
        .adding(AskToolResult(facts: facts, limits: []), check: 1)
        var draft = AskExplanationDraft(
            topic: "cpu", summary: "Recorded CPU was 16 percent.",
            interpretation: "This is an observation, not proof of a cause.",
            uncertainty: "Response times were not measured.",
            nextCheck: "Compare responsiveness after the task finishes.",
            followUpQuestion: "Which app feels slow?",
            evidenceIDs: (1...5).map { "check1.source-\($0)" }, nextStep: .observe)
        let grounded = draft.includingQuotedEvidence(from: request)
        XCTAssertEqual(grounded.evidenceIDs, (1...6).map { "check1.source-\($0)" })
        XCTAssertNoThrow(try grounded.validate(against: request))
        draft.summary = "Recorded CPU was 116.0%."
        let inventedValue = draft.includingQuotedEvidence(from: request)
        XCTAssertEqual(inventedValue.evidenceIDs.count, 5)
        XCTAssertEqual(inventedValue.validationIssue(against: request), .unverifiedMeasurement)
        draft.summary = "Recorded CPU was 16 percent."
        draft.evidenceIDs = ["invented-source"]
        XCTAssertEqual(
            draft.includingQuotedEvidence(from: request).validationIssue(against: request),
            .invalidCitations)
        draft.evidenceIDs = ["check1.source-1"]
        draft.summary = "Worker 6 has recorded activity."
        XCTAssertNoThrow(
            try draft.includingQuotedEvidence(from: request).validate(against: request))
    }

    func testNumericDetectionIncludesUnicodeNumberForms() {
        for text in [
            "118", "\u{00b9}\u{00b9}\u{2078}", "\u{0661}\u{0668}", "\u{ff11}\u{ff18}", "\u{2460}",
        ] {
            XCTAssertTrue(AskExplanationDraft.containsNumericCharacters(text))
        }
        for text in ["A", "BuildWorker", "CPU is busy.", "\u{4e00}"] {
            XCTAssertFalse(AskExplanationDraft.containsNumericCharacters(text))
        }
    }

    func testNumericRepairIdentifiesOnlyFieldsWithUnsupportedNumbers() {
        let request = AskExplanationRequest(
            question: "Why slow?", previousTopic: .cpu, reports: [], locale: "en_GB"
        )
        .adding(
            AskToolResult(
                facts: [
                    AskExplanationFact(
                        id: "cpu", name: "Worker 2", value: "118.0%", meaning: "Recorded.")
                ], limits: []), check: 1)
        var answer = AskExplanationDraft(
            topic: "cpu", summary: "Worker 2 used 118 percent.",
            interpretation: "CPU use reached 119 percent.",
            uncertainty: "The spike lasted 8 seconds.",
            nextCheck: "Compare the app while it runs and after it finishes.",
            followUpQuestion: "Which task felt slow?", evidenceIDs: ["check1.cpu"],
            nextStep: .observe)
        XCTAssertEqual(
            answer.unverifiedMeasurementFields(against: request), ["interpretation", "uncertainty"])
        XCTAssertEqual(answer.validationIssue(against: request), .unverifiedMeasurement)
        answer.interpretation = "The recorded work is a possible contributor."
        answer.uncertainty = "The spike duration is unknown."
        XCTAssertEqual(answer.unverifiedMeasurementFields(against: request), [])
        XCTAssertNoThrow(try answer.validate(against: request))
        answer.followUpQuestion = "Did it use 118 MB?"
        XCTAssertEqual(answer.unverifiedMeasurementFields(against: request), ["followUpQuestion"])
        XCTAssertEqual(answer.validationIssue(against: request), .unverifiedMeasurement)
    }

    func testFinalResponseCitationLabelsResolveOnlyToSuppliedFacts() throws {
        let request = AskExplanationRequest(question: "Why slow?", previousTopic: .cpu, reports: [])
            .adding(
                AskToolResult(
                    facts: [
                        AskExplanationFact(
                            id: "cpu", name: "Worker 2", value: "118.0%", meaning: "Recorded.",
                            processReference: "private-handle"),
                        AskExplanationFact(
                            id: "pressure", name: "Memory pressure", value: "Normal",
                            meaning: "Recorded."),
                    ], limits: []), check: 1)
        let labelled = request.withCitationLabels()
        XCTAssertEqual(labelled.facts.map(\.id), ["A", "B"])
        XCTAssertNil(labelled.facts.first?.processReference)
        var answer = AskExplanationDraft(
            topic: "cpu", summary: "The cited process is a possible contributor.",
            interpretation: "CPU activity was recorded. Memory pressure was normal.",
            uncertainty: "Responsiveness was not measured.",
            nextCheck: "Compare responsiveness after the task finishes.",
            followUpQuestion: "Which app feels slow?",
            evidenceIDs: ["A", "B"], nextStep: .inspectProcesses)
        let restored = try answer.resolvingCitationLabels(against: request)
        XCTAssertEqual(restored.evidenceIDs, ["check1.cpu", "check1.pressure"])
        XCTAssertNoThrow(try restored.validate(against: request))
        answer.evidenceIDs = ["Z"]
        XCTAssertThrowsError(try answer.resolvingCitationLabels(against: request))
    }

    func testRejectedModelAnswerGetsOneCorrectionWithoutRelaxingValidation() async throws {
        let request = AskExplanationRequest(
            question: "Why is it slow?", previousTopic: .overview,
            reports: [AskReport.make(topic: .cpu, snapshot: snapshot(at: now), now: now)])
        let valid = AskExplanationDraft(
            topic: "cpu", summary: "The readings do not establish a cause.",
            interpretation: "Current CPU activity cannot establish a past slowdown.",
            uncertainty: "The affected task is not known.",
            nextCheck:
                "Compare the affected app with an unrelated local app while the symptom occurs.",
            followUpQuestion: "Are unrelated apps slow too?", evidenceIDs: ["cpu.cpu"],
            nextStep: .observe)
        var invalid = valid
        invalid.evidenceIDs = ["invented"]
        invalid.summary = "The CPU was at 99 percent."
        let validJSON = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
        let invalidJSON = String(decoding: try JSONEncoder().encode(invalid), as: UTF8.self)
        let repaired = AnswerResponses([invalidJSON, validJSON])
        let rejectedDraft = invalid
        let answer = try await AskExplanationDraft.generateValidated(against: request) {
            issue, rejected in
            if issue.isEmpty {
                XCTAssertNil(rejected)
            } else {
                XCTAssertEqual(rejected, rejectedDraft)
            }
            return await repaired.next(issue)
        }
        XCTAssertEqual(answer, valid)
        let reasons = await repaired.reasons
        XCTAssertEqual(reasons, [[], [.invalidCitations, .unverifiedMeasurement]])
        let malformed = AnswerResponses(["{\"summary\":", validJSON])
        _ = try await AskExplanationDraft.generateValidated(against: request) { issues, rejected in
            XCTAssertNil(rejected)
            return await malformed.next(issues)
        }
        let malformedReasons = await malformed.reasons
        XCTAssertEqual(malformedReasons, [[], [.invalidJSON]])
        let failed = AnswerResponses([invalidJSON, invalidJSON, validJSON])
        do {
            _ = try await AskExplanationDraft.generateValidated(against: request) { issues, _ in
                await failed.next(issues)
            }
            XCTFail("A second invalid answer must not be published")
        } catch let error as AskExplanationError { XCTAssertEqual(error, .invalidAnswer) }
        let attempts = await failed.reasons.count
        XCTAssertEqual(attempts, 2)
    }

    private actor AnswerResponses {
        let responses: [String]
        var reasons: [[AskAnswerIssue]] = []

        init(_ responses: [String]) { self.responses = responses }

        func next(_ issues: [AskAnswerIssue]) -> String {
            let output = responses[min(reasons.count, responses.count - 1)]
            reasons.append(issues)
            return output
        }
    }

    private func process(pid: Int32, cpu: Double) -> ProcessSample {
        ProcessSample(
            timestamp: now, pid: pid, ppid: 1, name: "Process \(pid)",
            physFootprint: UInt64(pid) << 20, residentSize: 0, virtualSize: 0,
            lifetimeMaxFootprint: 0, cpuPercent: cpu, cpuTimeUser: 0, cpuTimeSystem: 0,
            threadCount: 2, fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0, fdOther: 0,
            diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false, architecture: .arm64,
            startTime: now.addingTimeInterval(-100), uid: 501, dataSource: .directUserRead,
            footprintReadable: true)
    }

    private func snapshot(at date: Date) -> Sampler.Snapshot {
        Sampler.Snapshot(
            system: SystemSample(
                timestamp: date, totalRAM: 16 << 30, free: 4 << 30,
                active: 5 << 30, inactive: 2 << 30, wired: 2 << 30, speculative: 0,
                compressed: 1 << 30, appMemory: 6 << 30, cachedFiles: 2 << 30,
                swapTotal: 1 << 30, swapUsed: 0, pressureLevel: .normal, pressurePercent: 10,
                pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0, cpuLoad: 0.2),
            processes: [], unreadableProcessCount: 0)
    }
}
