import AppKit
import Combine
import Foundation
import GRDB
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class AskPreviewTests: XCTestCase {
    private actor Explainer: AskExplaining {
        var calls = 0
        var invalid = false
        var lastRequest: AskExplanationRequest?
        init(invalid: Bool = false) { self.invalid = invalid }

        func explain(_ request: AskExplanationRequest) async throws -> AskExplanationDraft {
            calls += 1
            lastRequest = request
            return AskExplanationDraft(
                topic: "memory", summary: "Memory is not the strongest lead in these readings.",
                interpretation:
                    "The current pressure reading is normal. Check a longer interval before attributing an intermittent slowdown to memory.",
                uncertainty: "The current readings do not explain every intermittent symptom.",
                nextCheck:
                    "Compare the affected app with a local app. If only one is slow, focus on that app's activity.",
                followUpQuestion: "Are unrelated local apps slow too?",
                evidenceIDs: [invalid ? "missing.fact" : "memory.pressure"], nextStep: .observe)
        }
    }

    private actor Router: AskQuestionRouting {
        var calls = 0
        let result: Result<AskTopic, AskPreviewError>

        init(_ result: Result<AskTopic, AskPreviewError>) { self.result = result }

        func topic(for question: String, previousTopic: AskTopic) async throws -> AskTopic {
            calls += 1
            return try result.get()
        }
    }

    private struct FailingExplainer: AskExplaining {
        let error: any Error & Sendable

        func explain(_ request: AskExplanationRequest) async throws -> AskExplanationDraft {
            throw error
        }
    }

    func testVerificationFailuresExplainTheirCauseAndKeepTheMeasuredReport() async throws {
        let suite = "ask-verification-messages-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        let failures: [(any Error & Sendable, String)] = [
            (
                AskExplanationError.unverifiedMeasurement,
                "The answer quoted a number we could not match to its sources. No AI answer is shown. You can still use the measured report."
            ),
            (
                AskExplanationError.invalidAnswer,
                "The answer did not pass the text or source checks. You can still use the measured report."
            ),
            (
                AskInvestigationError.invalidToolCall,
                "The model asked for a data check this app does not support. You can still use the measured report."
            ),
            (
                AskInvestigationError.unknownProcess,
                "The model named a process outside the results it received. You can still use the measured report."
            ),
        ]
        let reports = currentReports()
        for (error, message) in failures {
            let model = AskPreviewModel(
                readReports: { reports }, explainer: FailingExplainer(error: error),
                defaults: defaults, available: { nil }, resourcesPermitAI: { true })
            await completed(model) { model.askAbout(.overview) }
            XCTAssertEqual(model.message, t(message))
            XCTAssertNotNil(model.report)
            XCTAssertNil(model.explanation)
            XCTAssertFalse(model.isWorking)
        }
    }

    private struct Investigator: AskInvestigating {
        func investigate(
            _ request: AskExplanationRequest, read: @escaping AskToolReader,
            progress: @escaping AskToolProgress
        ) async throws -> AskInvestigationResult {
            try await AskInvestigation.run(
                request: request,
                choose: { state in
                    AskInvestigationDecision(
                        tool: state.completedChecks.isEmpty
                            ? AskToolCall(name: .systemHistory, metric: .cpu) : nil)
                },
                read: read, explain: { try await self.explain($0) }, progress: progress)
        }

        func explain(_ request: AskExplanationRequest) async throws -> AskExplanationDraft {
            guard let fact = request.facts.last else { throw AskExplanationError.invalidAnswer }
            return AskExplanationDraft(
                topic: "cpu", summary: "Recorded CPU activity is a lead worth checking.",
                interpretation:
                    "The history shows activity during the symptom. This does not prove a fault.",
                uncertainty: "Responsiveness was not measured.",
                nextCheck: "Compare responsiveness after the task naturally finishes.",
                followUpQuestion: "Which task is affected?",
                evidenceIDs: [fact.id], nextStep: .observe)
        }
    }

    func testInvestigationCoordinatorRechecksConsentAfterDatabaseReads() async throws {
        let suite = "ask-investigation-consent-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for revoke in [false, true] {
            for key in [
                AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
                AskPreviewPreferences.explanationsKey,
            ] {
                defaults.set(true, forKey: key)
            }
            let reports = currentReports()
            let model = AskPreviewModel(
                readReports: { reports }, explainer: Investigator(),
                readData: { _, _, _ in
                    if revoke { defaults.set(false, forKey: AskPreviewPreferences.explanationsKey) }
                    return AskDataRead(
                        result: AskToolResult(
                            facts: [
                                AskExplanationFact(
                                    id: "cpu", name: "Recorded CPU", value: "85.0%",
                                    meaning: "Historical load.")
                            ], limits: []))
                }, defaults: defaults, available: { nil }, resourcesPermitAI: { true })
            model.question = "Why was it slow?"
            await completed(model) { model.ask() }
            if revoke {
                XCTAssertNil(model.explanation)
                XCTAssertTrue(model.investigationChecks.isEmpty)
            } else {
                XCTAssertEqual(model.explanationFacts.map(\.id), ["check1.cpu"])
                XCTAssertEqual(model.investigationChecks.map(\.name), [.systemHistory])
            }
            XCTAssertNil(model.activeCheck)
            model.clear()
            XCTAssertTrue(model.investigationChecks.isEmpty)
        }
    }

    func testTypedQuestionDoesNotInvokeAIWithoutConsent() async throws {
        let suite = "ask-preview-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        let router = Router(.success(.cpu))
        var reads = 0
        let model = AskPreviewModel(
            readReports: {
                reads += 1
                return []
            }, router: router, defaults: defaults,
            available: { nil })
        model.question = "What uses my CPU?"
        model.ask()
        XCTAssertFalse(model.isWorking)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(reads, 0)
        let calls = await router.calls
        XCTAssertEqual(calls, 0)
    }

    func testAppleIsTheDefaultWithoutQwenOrItsSixteenGiBGate() async throws {
        let suite = "ask-apple-default-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-no-qwen-\(UUID())")
        let store = AskLocalModelStore(directory: directory, physicalMemory: { 8 << 30 })
        let apple = Explainer()
        let qwen = Explainer(invalid: true)
        let reports = currentReports()
        let model = AskPreviewModel(
            readReports: { reports }, explainer: apple, localModel: store,
            qwenExplainer: qwen, defaults: defaults, available: { nil }, resourcesPermitAI: { true }
        )
        await completed(model) { model.askAbout(.overview) }
        XCTAssertEqual(model.selectedBackend, .apple)
        XCTAssertEqual(model.answerBackend, .apple)
        XCTAssertNotNil(model.explanation)
        XCTAssertFalse(store.isDownloading)
        XCTAssertFalse(store.isInUse)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let appleCalls = await apple.calls
        let qwenCalls = await qwen.calls
        XCTAssertEqual(appleCalls, 1)
        XCTAssertEqual(qwenCalls, 0)
    }

    func testUnavailableAppleNeverSilentlySelectsOrDownloadsQwen() async throws {
        let suite = "ask-apple-unavailable-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-no-fallback-\(UUID())")
        let store = AskLocalModelStore(directory: directory, physicalMemory: { 32 << 30 })
        let qwen = Explainer()
        let model = AskPreviewModel(
            readReports: { [] }, localModel: store, qwenExplainer: qwen,
            defaults: defaults, available: { "Apple Intelligence is off" })
        model.askAbout(.overview)
        XCTAssertEqual(model.selectedBackend, .apple)
        XCTAssertEqual(model.message, "Apple Intelligence is off")
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(store.isDownloading)
        let calls = await qwen.calls
        XCTAssertEqual(calls, 0)
        await completed(model) { model.showReport(.cpu) }
        XCTAssertNotNil(model.report)
        defaults.set("qwen", forKey: AskPreviewPreferences.backendKey)
        XCTAssertEqual(model.selectedBackend, .qwen)
    }

    func testQwenDownloadCannotStartBelowSixteenGiB() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "qwen-gate-\(UUID())")
        let store = AskLocalModelStore(directory: directory, physicalMemory: { 8 << 30 })
        store.download()
        XCTAssertFalse(store.isEligible)
        XCTAssertFalse(store.isDownloading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNotNil(store.message)
        XCTAssertThrowsError(try store.beginUse())
    }

    func testSwitchingBackToQwenReportsMemoryPressureAndRecoversWithoutDownloading() async throws {
        let suite = "ask-qwen-switch-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try createSizedQwenFixture(in: directory)
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        var normalMemory = false
        let store = AskLocalModelStore(
            directory: directory, physicalMemory: { 32 << 30 }, memoryIsNormal: { normalMemory })
        let apple = Explainer()
        let qwen = Explainer()
        var reportReads = 0
        var resourcesPermitAI = true
        let reports = currentReports()
        let model = AskPreviewModel(
            readReports: {
                reportReads += 1
                return reports
            }, explainer: apple, localModel: store,
            qwenExplainer: qwen, defaults: defaults, available: { nil },
            resourcesPermitAI: { resourcesPermitAI })
        XCTAssertTrue(store.isInstalled)
        await completed(model) { model.askAbout(.overview) }
        XCTAssertEqual(model.answerBackend, .apple)

        defaults.set("qwen", forKey: AskPreviewPreferences.backendKey)
        model.clear()
        model.refreshAvailability()
        XCTAssertEqual(model.selectedBackend, .qwen)
        let paused = t(
            "Memory pressure is high or could not be read. %@ needs normal memory pressure to run. Close unused apps, then try again.",
            AskInferenceBackend.qwen.displayName)
        XCTAssertEqual(model.availabilityMessage, paused)
        model.askAbout(.overview)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.message, paused)
        XCTAssertEqual(reportReads, 1)
        let blockedCalls = await qwen.calls
        XCTAssertEqual(blockedCalls, 0)
        XCTAssertFalse(store.isDownloading)

        normalMemory = true
        model.refreshAvailability()
        XCTAssertNil(model.availabilityMessage)
        XCTAssertNil(model.message)
        await completed(model) { model.askAbout(.overview) }
        XCTAssertEqual(model.answerBackend, .qwen)
        XCTAssertNil(model.message)
        let qwenCalls = await qwen.calls
        XCTAssertEqual(qwenCalls, 1)
        XCTAssertFalse(store.isDownloading)
        XCTAssertFalse(store.isInUse)

        resourcesPermitAI = false
        await completed(model) { model.askAbout(.overview) }
        XCTAssertNotNil(model.availabilityMessage)
        XCTAssertEqual(model.message, model.availabilityMessage)
        let callsAfterPressure = await qwen.calls
        XCTAssertEqual(callsAfterPressure, 1)
        resourcesPermitAI = true
        model.refreshAvailability()
        XCTAssertNil(model.availabilityMessage)

        defaults.set("apple", forKey: AskPreviewPreferences.backendKey)
        model.clear()
        normalMemory = false
        model.refreshAvailability()
        XCTAssertNil(model.availabilityMessage)
        await completed(model) { model.askAbout(.overview) }
        XCTAssertEqual(model.answerBackend, .apple)
    }

    private func createSizedQwenFixture(
        in directory: URL, backend: AskInferenceBackend = .qwen
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for asset in try XCTUnwrap(AskLocalModels.definition(for: backend)).assets {
            let url = directory.appendingPathComponent(asset.name)
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(asset.bytes))
            try handle.close()
        }
    }

    func testExperimentalModelStoresKeepDownloadsAndUsageIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-models-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var stores: [AskInferenceBackend: AskLocalModelStore] = [:]
        for backend in AskInferenceBackend.allCases where backend.isLocal {
            let directory = root.appendingPathComponent(backend.rawValue)
            try createSizedQwenFixture(in: directory, backend: backend)
            let store = AskLocalModelStore(
                backend: backend, directory: directory,
                physicalMemory: { 32 << 30 }, memoryIsNormal: { true })
            XCTAssertTrue(store.isInstalled)
            XCTAssertNil(store.unavailabilityReason)
            stores[backend] = store
        }
        let library = AskLocalModelLibrary(stores: stores)
        let first = try XCTUnwrap(stores[.qwen35])
        let second = try XCTUnwrap(stores[.deepAnalyze])
        try first.beginUse()
        XCTAssertTrue(library.isInUse)
        XCTAssertThrowsError(try second.beginUse())
        first.endUse()
        try second.beginUse()
        second.endUse()
        XCTAssertFalse(library.isInUse)
        second.remove()
        XCTAssertFalse(second.isInstalled)
        XCTAssertTrue(first.isInstalled)
        XCTAssertTrue(try XCTUnwrap(stores[.qwen]).isInstalled)
        library.prepare(enabled: true, backend: .deepAnalyze)
        XCTAssertFalse(second.isDownloading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.directory.path))
        XCTAssertNil(AskLocalModels.definition(for: .apple))
    }

    func testEachLocalBackendUsesItsOwnProviderAndReadiness() async throws {
        let suite = "ask-local-selection-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        var stores: [AskInferenceBackend: AskLocalModelStore] = [:]
        var providers: [AskInferenceBackend: Explainer] = [:]
        var normalMemory = true
        for backend in AskInferenceBackend.allCases where backend.isLocal {
            let directory = root.appendingPathComponent(backend.rawValue)
            try createSizedQwenFixture(in: directory, backend: backend)
            stores[backend] = AskLocalModelStore(
                backend: backend, directory: directory, physicalMemory: { 32 << 30 },
                memoryIsNormal: { normalMemory })
            providers[backend] = Explainer()
        }
        let apple = Explainer()
        let reports = currentReports()
        let model = AskPreviewModel(
            readReports: { reports }, explainer: apple,
            localModels: AskLocalModelLibrary(stores: stores), localExplainers: providers,
            defaults: defaults, available: { "Apple unavailable" }, resourcesPermitAI: { true })
        for backend in AskInferenceBackend.allCases where backend.isLocal {
            defaults.set(backend.rawValue, forKey: AskPreviewPreferences.backendKey)
            model.clear()
            await completed(model) { model.askAbout(.overview) }
            XCTAssertEqual(model.answerBackend, backend)
            XCTAssertNotNil(model.explanation)
            XCTAssertNil(model.message)
            let provider = try XCTUnwrap(providers[backend])
            let calls = await provider.calls
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(
                defaults.string(forKey: AskPreviewPreferences.backendKey), backend.rawValue)
            normalMemory = false
            model.refreshAvailability()
            XCTAssertTrue(try XCTUnwrap(model.availabilityMessage).contains(backend.displayName))
            model.askAbout(.overview)
            XCTAssertFalse(model.isWorking)
            let blockedCalls = await provider.calls
            XCTAssertEqual(blockedCalls, calls)
            normalMemory = true
            model.refreshAvailability()
            XCTAssertNil(model.availabilityMessage)
            XCTAssertTrue(stores.values.allSatisfy { !$0.isDownloading && !$0.isInUse })
        }
        let appleCalls = await apple.calls
        XCTAssertEqual(appleCalls, 0)
    }

    func testNativeMemoryPressureWarningIsVisibleAndClearsAfterRecheck() async throws {
        _ = NSApplication.shared
        let suite = "ask-memory-warning-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try createSizedQwenFixture(in: directory)
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        defaults.set("qwen", forKey: AskPreviewPreferences.backendKey)
        var normalMemory = false
        let store = AskLocalModelStore(
            directory: directory, physicalMemory: { 32 << 30 }, memoryIsNormal: { normalMemory })
        let reports = currentReports()
        let model = AskPreviewModel(
            readReports: { reports }, localModel: store, qwenExplainer: Explainer(),
            defaults: defaults, available: { nil }, resourcesPermitAI: { true })

        for (name, settings, appearance) in [
            ("ask-memory-paused", false, NSAppearance.Name.aqua),
            ("settings-memory-paused", true, NSAppearance.Name.darkAqua),
        ] {
            normalMemory = false
            store.refresh()
            let appeared = expectation(description: "Memory-pressure warning appears")
            let root: AnyView
            if settings {
                root = AnyView(
                    Form { AskPreviewSettingsSection(localModel: store) }.formStyle(.grouped))
            } else {
                root = AnyView(AskPreviewView(model: model, openEvidence: { _, _ in }))
            }
            let host = NSHostingView(
                rootView: root.defaultAppStorage(defaults)
                    .frame(width: 680, height: 760)
                    .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 80, width: 680, height: 760),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertNotNil(store.unavailabilityReason)
            if !settings { XCTAssertNotNil(model.availabilityMessage) }
            XCTAssertLessThanOrEqual(host.fittingSize.width, 681)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 761)
            XCTAssertFalse(store.isDownloading)
            let warningPixels = try captureReadinessWindow(window, name: name)
            if let warningPixels { XCTAssertGreaterThan(warningPixels, 500) }
            normalMemory = true
            if settings { store.refresh() } else { model.refreshAvailability() }
            let refreshed = expectation(description: "Recheck clears the pressure warning")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { refreshed.fulfill() }
            await fulfillment(of: [refreshed], timeout: 3)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertNil(store.unavailabilityReason)
            if !settings { XCTAssertNil(model.availabilityMessage) }
            if let warningPixels,
                let remaining = try captureReadinessWindow(window, name: name + "-ready")
            {
                XCTAssertLessThan(remaining, warningPixels / 2)
            }
            XCTAssertEqual(defaults.string(forKey: AskPreviewPreferences.backendKey), "qwen")
            XCTAssertFalse(store.isDownloading)
        }
    }

    private func captureReadinessWindow(_ window: NSWindow, name: String) throws -> Int? {
        guard let path = ProcessInfo.processInfo.environment["MACPERF_ASK_ARTIFACTS"] else {
            return nil
        }
        let session = CGSessionCopyCurrentDictionary() as NSDictionary?
        try XCTSkipIf(
            session?["CGSSessionScreenIsLocked"] as? Bool == true,
            "Native screenshot verification needs an unlocked macOS session.")
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let imageURL = output.appendingPathComponent(name + ".png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), imageURL.path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: imageURL)))
        var orange = 0
        for row in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for column in stride(from: 0, to: image.pixelsWide, by: 2) {
                guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if color.redComponent > color.greenComponent + 0.02,
                    color.greenComponent > color.blueComponent + 0.02
                {
                    orange += 1
                }
            }
        }
        return orange
    }

    func testQwenDownloadAndInferenceNeedAnInstalledModel() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "qwen-missing-\(UUID())")
        let store = AskLocalModelStore(directory: directory, physicalMemory: { 16 << 30 })
        XCTAssertTrue(store.isEligible)
        XCTAssertFalse(store.isInstalled)
        XCTAssertThrowsError(try store.beginUse())
        XCTAssertFalse(store.isInUse)
    }

    func testExplanationPreparationDownloadsOnlyTheRequiredEligibleModel() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "qwen-automatic-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = AskLocalModelStore(
            directory: parent.appendingPathComponent("model"), physicalMemory: { 16 << 30 })
        store.prepareForExplanations(enabled: false, backend: .qwen)
        XCTAssertFalse(store.isDownloading)
        store.prepareForExplanations(enabled: true, backend: .apple)
        XCTAssertFalse(store.isDownloading)
        store.prepareForExplanations(enabled: true, backend: .qwen)
        XCTAssertTrue(store.isDownloading)
        store.prepareForExplanations(enabled: true, backend: .qwen)
        XCTAssertTrue(store.isDownloading)
        store.prepareForExplanations(enabled: true, backend: .apple)
        let stopped = expectation(description: "Cancelled automatic download stops")
        let subscription = store.$isDownloading.dropFirst().filter { !$0 }.sink { _ in
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 5)
        subscription.cancel()
        XCTAssertFalse(store.isInstalled)
        XCTAssertNil(store.message)
        let smallMac = AskLocalModelStore(
            directory: parent.appendingPathComponent("ineligible"), physicalMemory: { 8 << 30 })
        smallMac.prepareForExplanations(enabled: true, backend: .qwen)
        XCTAssertFalse(smallMac.isDownloading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: smallMac.directory.path))
    }

    func testQwenEntryPointRejectsAnIneligibleMacBeforeReadingEvidence() async throws {
        let suite = "ask-qwen-entry-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        defaults.set(true, forKey: AskPreviewPreferences.onDeviceKey)
        defaults.set(true, forKey: AskPreviewPreferences.explanationsKey)
        defaults.set("qwen", forKey: AskPreviewPreferences.backendKey)
        let store = AskLocalModelStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString),
            physicalMemory: { 8 << 30 })
        let provider = Explainer()
        var reads = 0
        let model = AskPreviewModel(
            readReports: {
                reads += 1
                return []
            }, localModel: store, qwenExplainer: provider,
            defaults: defaults, available: { nil })
        model.question = "What is taking RAM?"
        model.ask()
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(reads, 0)
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
    }

    func testGenerativeAnswersRequireSeparateEvidenceConsentAndClearTheirFacts() async throws {
        let suite = "ask-generation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        defaults.set(true, forKey: AskPreviewPreferences.onDeviceKey)
        let reports = currentReports()
        let provider = Explainer()
        let model = AskPreviewModel(
            readReports: { reports }, router: Router(.success(.memory)), explainer: provider,
            defaults: defaults, available: { nil }, resourcesPermitAI: { true })
        model.question = "Is memory the problem?"
        await completed(model) { model.ask() }
        var calls = await provider.calls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(model.explanation)
        defaults.set(true, forKey: AskPreviewPreferences.explanationsKey)
        await completed(model) { model.ask() }
        calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(model.explanation)
        XCTAssertEqual(model.explanationFacts.map(\.id), ["memory.pressure"])
        XCTAssertEqual(model.answerBackend, .apple)
        model.clear()
        XCTAssertNil(model.explanation)
        XCTAssertTrue(model.explanationFacts.isEmpty)
        XCTAssertNil(model.answerBackend)
    }

    func testDisablingExplanationsKeepsReportRoutingWithSavedQwenSelection() async throws {
        let suite = "ask-generation-off-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        defaults.set(true, forKey: AskPreviewPreferences.onDeviceKey)
        defaults.set(true, forKey: AskPreviewPreferences.explanationsKey)
        defaults.set("qwen", forKey: AskPreviewPreferences.backendKey)
        let store = AskLocalModelStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString), physicalMemory: { 8 << 30 })
        let reports = currentReports()
        let router = Router(.success(.cpu))
        let provider = Explainer()
        let model = AskPreviewModel(
            readReports: { reports }, router: router, explainer: provider,
            localModel: store, qwenExplainer: provider, defaults: defaults,
            available: { nil }, resourcesPermitAI: { true })
        model.refreshAvailability()
        XCTAssertNotNil(model.availabilityMessage)
        defaults.set(false, forKey: AskPreviewPreferences.explanationsKey)
        model.refreshAvailability()
        XCTAssertNil(model.availabilityMessage)
        XCTAssertEqual(model.selectedBackend, .qwen)
        model.question = "What is using CPU?"
        await completed(model) { model.ask() }
        XCTAssertEqual(model.report?.topic, .cpu)
        XCTAssertNil(model.explanation)
        XCTAssertNil(model.message)
        let routingCalls = await router.calls
        let explanationCalls = await provider.calls
        XCTAssertEqual(routingCalls, 1)
        XCTAssertEqual(explanationCalls, 0)
    }

    func testInvalidGeneratedAnswerKeepsTheFactualFallback() async throws {
        let suite = "ask-generation-invalid-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        let reports = currentReports()
        let model = AskPreviewModel(
            readReports: { reports }, explainer: Explainer(invalid: true), defaults: defaults,
            available: { nil }, resourcesPermitAI: { true })
        model.question = "Why is it slow?"
        await completed(model) { model.ask() }
        XCTAssertNotNil(model.report)
        XCTAssertNil(model.explanation)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.usedAI)
    }

    func testDeclinedGenerationKeepsTheFactualReport() async throws {
        let suite = "ask-generation-resource-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        let reports = currentReports()
        let provider = Explainer()
        let model = AskPreviewModel(
            readReports: { reports }, explainer: provider, defaults: defaults,
            available: { nil }, resourcesPermitAI: { false })
        model.question = "Why is this Mac slow?"
        await completed(model) { model.ask() }
        XCTAssertEqual(model.report?.topic, .overview)
        XCTAssertNil(model.explanation)
        XCTAssertFalse(model.isWorking)
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
    }

    func testRevokedEvidenceConsentPreventsGeneratedAnswerPublication() async throws {
        let suite = "ask-generation-revoke-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        let reports = currentReports()
        let provider = Explainer()
        let model = AskPreviewModel(
            readReports: {
                defaults.set(false, forKey: AskPreviewPreferences.explanationsKey)
                return reports
            },
            router: Router(.success(.memory)), explainer: provider, defaults: defaults,
            available: { nil }, resourcesPermitAI: { true })
        model.question = "Why is it slow?"
        await completed(model) { model.ask() }
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(model.explanation)
    }

    func testPresetReportWorksWithoutAI() async throws {
        let suite = "ask-preview-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        let router = Router(.success(.cpu))
        let model = AskPreviewModel(
            readReports: { [AskReport.make(topic: .memory, snapshot: nil)] },
            router: router, defaults: defaults, available: { "Unavailable" })
        await completed(model) { model.showReport(.memory) }
        XCTAssertEqual(model.report?.topic, .memory)
        XCTAssertFalse(model.usedAI)
        let calls = await router.calls
        XCTAssertEqual(calls, 0)
    }

    func testSuggestedSlowdownQuestionGeneratesAnExplanationWhenConsented() async throws {
        let suite = "ask-suggested-question-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        let reports = currentReports()
        let provider = Explainer()
        let model = AskPreviewModel(
            readReports: { reports }, explainer: provider, defaults: defaults,
            available: { nil }, resourcesPermitAI: { true })
        await completed(model) { model.askAbout(.overview) }
        XCTAssertEqual(model.submittedQuestion, AskTopic.overview.question)
        XCTAssertTrue(model.question.isEmpty)
        XCTAssertNotNil(model.explanation)
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        model.clear()
        defaults.set(false, forKey: AskPreviewPreferences.onDeviceKey)
        await completed(model) { model.askAbout(.cpu) }
        XCTAssertEqual(model.report?.topic, .cpu)
        XCTAssertNil(model.explanation)
        let finalCalls = await provider.calls
        XCTAssertEqual(finalCalls, 1)
    }

    func testFollowUpUsesFreshReportsAndClearsItsBoundedContext() async throws {
        let suite = "ask-follow-up-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        var reads = 0
        let provider = Explainer()
        let model = AskPreviewModel(
            readReports: {
                reads += 1
                return self.currentReports()
            }, explainer: provider,
            defaults: defaults, available: { nil }, resourcesPermitAI: { true })
        model.question = "Why does my Mac feel slow?"
        await completed(model) { model.ask() }
        model.question = "Only Safari; other local apps are fine."
        await completed(model) { model.ask() }
        let lastRequest = await provider.lastRequest
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.followUp?.question, "Why does my Mac feel slow?")
        XCTAssertEqual(request.followUp?.clarification, "Are unrelated local apps slow too?")
        XCTAssertEqual(request.question, "Only Safari; other local apps are fine.")
        XCTAssertEqual(reads, 2)
        model.clear()
        XCTAssertNil(model.submittedQuestion)
        await completed(model) { model.askAbout(.overview) }
        let next = await provider.lastRequest
        XCTAssertNil(next?.followUp)
    }

    func testOversizedQuestionIsNotTruncatedOrSubmitted() throws {
        let suite = "ask-preview-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AskPreviewModel(readReports: { [] }, defaults: defaults)
        let question = String(repeating: "A", count: 4097)
        model.question = question
        model.ask()
        XCTAssertEqual(model.question, question)
        XCTAssertEqual(model.message, AskPreviewError.tooLong.localizedDescription)
        XCTAssertFalse(model.isWorking)
    }

    func testClearRemovesQuestionAndReport() async throws {
        let suite = "ask-preview-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        let model = AskPreviewModel(readReports: { [] }, defaults: defaults)
        await completed(model) { model.showReport(.disk) }
        model.question = "Private question"
        model.clear()
        XCTAssertNil(model.report)
        XCTAssertTrue(model.question.isEmpty)
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isWorking)
    }

    func testIntentSharingRequiresSeparateConsentAndRechecksAfterRead() async throws {
        let suite = "ask-preview-intents-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        defaults.set(true, forKey: AskPreviewPreferences.onDeviceKey)
        var reads = 0
        let runtime = MonitorIntentRuntime(defaults: defaults) { topic in
            reads += 1
            defaults.set(false, forKey: AskPreviewPreferences.siriKey)
            return AskReport.make(topic: topic, snapshot: nil)
        }
        do {
            _ = try await runtime.currentReport(.cpu)
            XCTFail("Model consent must not grant Siri access")
        } catch is MonitorIntentError {}
        XCTAssertEqual(reads, 0)
        defaults.set(true, forKey: AskPreviewPreferences.siriKey)
        do {
            _ = try await runtime.currentReport(.cpu)
            XCTFail("Revoking consent during a read must block its result")
        } catch is MonitorIntentError {}
        XCTAssertEqual(reads, 1)
    }

    func testIntentReportsAreBoundedAndRevokedReferencesDoNotResolve() async throws {
        let suite = "ask-preview-intents-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        defaults.set(true, forKey: AskPreviewPreferences.siriKey)
        let runtime = MonitorIntentRuntime(defaults: defaults) { topic in
            AskReport.make(topic: topic, snapshot: nil)
        }
        var identifiers: [String] = []
        for _ in 0..<10 {
            let (_, entity) = try await runtime.currentReport(.memory)
            identifiers.append(entity.id)
        }
        XCTAssertTrue(try runtime.resolve([identifiers[0]]).isEmpty)
        XCTAssertEqual(try runtime.resolve(Array(identifiers.suffix(8))).count, 8)
        defaults.set(false, forKey: AskPreviewPreferences.siriKey)
        XCTAssertThrowsError(try runtime.resolve([identifiers[9]]))
        defaults.set(true, forKey: AskPreviewPreferences.siriKey)
        XCTAssertTrue(try runtime.resolve([identifiers[9]]).isEmpty)
    }

    func testTypedQuestionUsesOnlyTheSelectedVerifiedReport() async throws {
        let suite = "ask-preview-routing-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        defaults.set(true, forKey: AskPreviewPreferences.onDeviceKey)
        let reports = currentReports()
        let router = Router(.success(.memory))
        let model = AskPreviewModel(
            readReports: { reports }, router: router, defaults: defaults,
            available: { nil }, resourcesPermitAI: { true })
        model.question = "What is taking RAM?"
        await completed(model) { model.ask() }
        XCTAssertEqual(model.report, reports.first { $0.topic == .memory })
        XCTAssertTrue(model.usedAI)
        let calls = await router.calls
        XCTAssertEqual(calls, 1)
    }

    func testHistoricalQuestionDoesNotReturnCurrentFactsAsAnAnswer() async throws {
        let suite = "ask-preview-history-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        defaults.set(true, forKey: AskPreviewPreferences.onDeviceKey)
        let reports = currentReports()
        let model = AskPreviewModel(
            readReports: { reports }, router: Router(.failure(.history)), defaults: defaults,
            available: { nil }, resourcesPermitAI: { true })
        model.question = "Why was it slow yesterday?"
        await completed(model) { model.ask() }
        XCTAssertNil(model.report)
        XCTAssertEqual(model.message, AskPreviewError.history.localizedDescription)
        XCTAssertFalse(model.usedAI)
    }

    func testPressureGatePreventsModelRequest() async throws {
        let suite = "ask-preview-pressure-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        defaults.set(true, forKey: AskPreviewPreferences.onDeviceKey)
        let reports = currentReports()
        let router = Router(.success(.overview))
        let model = AskPreviewModel(
            readReports: { reports }, router: router, defaults: defaults,
            available: { nil }, resourcesPermitAI: { false })
        model.question = "Why is my Mac slow?"
        await completed(model) { model.ask() }
        let calls = await router.calls
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(model.usedAI)
    }

    func testCancelledReadCannotPublishLateEvidence() async throws {
        let suite = "ask-preview-cancel-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        let started = expectation(description: "Read started")
        let returned = expectation(description: "Read returned")
        var continuation: CheckedContinuation<[AskReport], Never>?
        let model = AskPreviewModel(
            readReports: {
                let result = await withCheckedContinuation { pending in
                    continuation = pending
                    started.fulfill()
                }
                returned.fulfill()
                return result
            }, defaults: defaults)
        model.showReport(.cpu)
        await fulfillment(of: [started], timeout: 5)
        model.clear()
        continuation?.resume(returning: currentReports())
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.report)
    }

    func testRevokingAIConsentDuringReadPreventsInference() async throws {
        let suite = "ask-preview-revocation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AskPreviewPreferences.enabledKey)
        defaults.set(true, forKey: AskPreviewPreferences.onDeviceKey)
        let reports = currentReports()
        let router = Router(.success(.cpu))
        let model = AskPreviewModel(
            readReports: {
                defaults.set(false, forKey: AskPreviewPreferences.onDeviceKey)
                return reports
            }, router: router, defaults: defaults,
            available: { nil }, resourcesPermitAI: { true })
        model.question = "What uses CPU?"
        await completed(model) { model.ask() }
        let calls = await router.calls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(model.report)
        XCTAssertFalse(model.isWorking)
    }

    func testPreviewWindowRendersAndClosingClearsPrivateState() async throws {
        _ = NSApplication.shared
        let suite = "ask-preview-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reports = currentReports()
        for (name, appearance, width, enabled) in [
            ("consent", NSAppearance.Name.aqua, CGFloat(820), false),
            ("report", NSAppearance.Name.aqua, CGFloat(820), true),
            ("compact-dark", NSAppearance.Name.darkAqua, CGFloat(680), true),
            ("explanation", NSAppearance.Name.aqua, CGFloat(820), true),
            ("explanation-compact-dark", NSAppearance.Name.darkAqua, CGFloat(680), true),
        ] {
            let isExplanation = name.hasPrefix("explanation")
            defaults.set(enabled, forKey: AskPreviewPreferences.enabledKey)
            defaults.set(isExplanation, forKey: AskPreviewPreferences.explanationsKey)
            defaults.set(isExplanation, forKey: AskPreviewPreferences.onDeviceKey)
            let model = AskPreviewModel(
                readReports: { reports }, explainer: Explainer(), defaults: defaults,
                available: { nil })
            if isExplanation {
                model.question = "Is memory the problem?"
                await completed(model) { model.ask() }
            } else if enabled {
                await completed(model) { model.showReport(.memory) }
            }
            let appeared = expectation(description: "Ask view appears")
            let host = NSHostingView(
                rootView: AskPreviewView(model: model, openEvidence: { _, _ in })
                    .defaultAppStorage(defaults)
                    .frame(width: width, height: 660)
                    .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: width, height: 660),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let pixels = try XCTUnwrap(image.bitmapData)
            let colors = Set(
                stride(
                    from: 0, to: image.bytesPerRow * image.pixelsHigh,
                    by: image.samplesPerPixel
                ).map { pixels[$0] })
            XCTAssertGreaterThan(colors.count, 20)
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
            _ = try captureReadinessWindow(window, name: name)
            model.question = "Private question"
            window.close()
            XCTAssertTrue(model.question.isEmpty)
            XCTAssertNil(model.report)
            XCTAssertNil(model.submittedQuestion)
        }
    }

    func testAllModelSettingsRenderWithoutStartingDownloads() async throws {
        _ = NSApplication.shared
        let suite = "ask-model-settings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let stores = Dictionary(
            uniqueKeysWithValues: AskInferenceBackend.allCases.filter(\.isLocal).map {
                (
                    $0,
                    AskLocalModelStore(
                        backend: $0, directory: root.appendingPathComponent($0.rawValue),
                        physicalMemory: { 32 << 30 }, memoryIsNormal: { true })
                )
            })
        let library = AskLocalModelLibrary(stores: stores)
        for key in [
            AskPreviewPreferences.enabledKey, AskPreviewPreferences.onDeviceKey,
            AskPreviewPreferences.explanationsKey,
        ] {
            defaults.set(true, forKey: key)
        }
        for (backend, appearance) in [
            (AskInferenceBackend.apple, NSAppearance.Name.aqua), (.qwen, .darkAqua),
            (.qwen35, .aqua), (.deepAnalyze, .darkAqua),
        ] {
            defaults.set(backend.rawValue, forKey: AskPreviewPreferences.backendKey)
            let appeared = expectation(description: "Model settings appear")
            let host = NSHostingView(
                rootView:
                    Form { AskPreviewSettingsSection(localModels: library) }
                    .formStyle(.grouped)
                    .defaultAppStorage(defaults)
                    .frame(width: 680, height: 720)
                    .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: 680, height: 720),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, 681)
            XCTAssertTrue(stores.values.allSatisfy { !$0.isDownloading })
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            XCTAssertEqual(
                defaults.string(forKey: AskPreviewPreferences.backendKey), backend.rawValue)
            _ = try captureReadinessWindow(window, name: backend.rawValue + "-settings")
            window.close()
        }
    }

    func testRealOnDeviceRoutingWhenExplicitlyEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPERF_TEST_FOUNDATION_MODELS"] == "1")
        if let unavailable = AskModelSupport.unavailabilityReason { throw XCTSkip(unavailable) }
        let router = AskModelSupport.makeRouter()
        for (question, expected) in [
            ("Why is my Mac slow?", AskTopic.overview),
            ("What is using my CPU?", .cpu),
            ("What is taking my RAM?", .memory),
            ("Why is my disk full?", .disk),
            ("Why is my network slow?", .network),
        ] {
            do {
                let topic = try await router.topic(for: question, previousTopic: .overview)
                XCTAssertEqual(topic, expected, question)
            } catch {
                XCTFail("Routing failed for '\(question)': \(error)")
            }
        }
        do {
            _ = try await router.topic(for: "Why was it slow yesterday?", previousTopic: .overview)
            XCTFail("Historical questions must not route to current facts")
        } catch let error as AskPreviewError {
            XCTAssertEqual(error, .history)
        }
    }

    func testLiveSamplerReturnsFreshReportsWithoutRecording() async throws {
        let sampler = SamplerModel(interval: 1, persistenceEnabled: false)
        sampler.start()
        defer { sampler.stop() }
        let reports = try await sampler.readAskReports()
        XCTAssertEqual(reports.map(\.topic), AskTopic.allCases)
        XCTAssertTrue(reports.contains { !$0.evidence.isEmpty })
        for report in reports {
            let sampledAt = try XCTUnwrap(report.sampledAt)
            XCTAssertLessThan(Date().timeIntervalSince(sampledAt), 10)
        }
    }

    func testRealAppleExplanationWhenExplicitlyEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPERF_TEST_FOUNDATION_MODELS"] == "1")
        if let reason = AskModelSupport.unavailabilityReason { throw XCTSkip(reason) }
        let request = AskExplanationRequest(
            question: "Why might my Mac feel slow, and is memory the likely cause?",
            previousTopic: .overview, reports: currentReports(), locale: "en_GB")
        let started = Date()
        let answer = try await AskExplainer.apple().explain(request)
        try answer.validate(against: request)
        print(
            "APPLE EXPLANATION \(Date().timeIntervalSince(started))s: \(answer.summary) \(answer.interpretation) \(answer.uncertainty)"
        )
    }

    func testRealAppleExplanationScenariosWhenExplicitlyEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPERF_TEST_FOUNDATION_MODELS"] == "1")
        if let reason = AskModelSupport.unavailabilityReason { throw XCTSkip(reason) }
        let provider = AskExplainer.apple()
        for topic in [AskTopic.memory, .disk, .network] {
            let reports = currentReports { system in
                system.bootVolumeFreeBytes = 200_000_000_000
                switch topic {
                case .memory:
                    system.pressureLevel = .warning
                    system.swapUsed = 4 << 30
                    system.swapOutBytesPerSecond = Double(2 << 20)
                case .disk:
                    system.diskUtilizationPercent = 95
                    system.diskReadLatencyMs = 40
                    system.diskWriteLatencyMs = 30
                default: break
                }
            }
            let question: String
            switch topic {
            case .memory:
                question =
                    "Is memory pressure contributing to the slowdown, and what should I compare next?"
            case .disk:
                question =
                    "File operations feel slow. Do these disk activity readings give us a lead?"
            default:
                question =
                    "Websites load slowly, but unrelated local apps feel fine. Can these readings explain it?"
            }
            let request = AskExplanationRequest(
                question: question, previousTopic: topic, reports: reports, locale: "en_GB")
            let answer = try await provider.explain(request)
            try answer.validate(against: request)
            XCTAssertTrue(
                answer.evidenceIDs.allSatisfy { identifier in
                    request.facts.contains { $0.id == identifier }
                })
            XCTAssertFalse(answer.nextCheck.isEmpty)
            if topic != .network {
                XCTAssertEqual(answer.topic, topic.rawValue)
                XCTAssertFalse(answer.nextCheck.lowercased().contains("website"))
            }
            if topic == .network {
                XCTAssertTrue(
                    [AskTopic.network.rawValue, AskTopic.overview.rawValue].contains(answer.topic))
                XCTAssertTrue(request.facts.allSatisfy { !$0.id.hasPrefix("network.") })
                XCTAssertFalse(answer.summary.lowercased().contains("hidden workload"))
                XCTAssertFalse(answer.summary.lowercased().contains("elevated whole-machine cpu"))
            } else if topic == .disk {
                XCTAssertFalse(answer.summary.lowercased().contains("within normal bounds"))
            } else if topic == .memory {
                XCTAssertFalse(
                    answer.uncertainty.lowercased().contains("no observation of active swap"))
            }
            print(
                "APPLE SCENARIO \(topic.rawValue): \(answer.summary) NEXT: \(answer.nextCheck) LIMIT: \(answer.uncertainty)"
            )
        }
    }

    func testRealQwenDownloadAndExplanationWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MACPERF_TEST_QWEN"] == "1")
        let directory = try XCTUnwrap(environment["MACPERF_TEST_QWEN_DIRECTORY"])
        let executable = try XCTUnwrap(environment["MACPERF_TEST_INFERENCE_BINARY"])
        let store = AskLocalModelStore(
            directory: URL(fileURLWithPath: directory, isDirectory: true))
        try XCTSkipUnless(store.isEligible)
        if !store.isInstalled {
            let finished = expectation(description: "Qwen download and verification finish")
            var began = false
            let subscription = store.$isDownloading.sink { downloading in
                if downloading { began = true }
                if began && !downloading { finished.fulfill() }
            }
            store.download()
            await fulfillment(of: [finished], timeout: 1800)
            subscription.cancel()
            XCTAssertNil(store.message)
            XCTAssertTrue(store.isInstalled)
        }
        let provider = LocalAskExplainer(store: store, executable: URL(fileURLWithPath: executable))
        let request = AskExplanationRequest(
            question: "Why might my Mac feel slow, and is memory the likely cause?",
            previousTopic: .overview, reports: currentReports(), locale: "en_GB")
        let answer = try await provider.explain(request)
        try answer.validate(against: request)
        XCTAssertFalse(store.isInUse)
        let metrics = try XCTUnwrap(provider.lastMetrics)
        XCTAssertLessThanOrEqual(metrics.inputTokens + metrics.outputTokens, 8192)
        print(
            "QWEN EXPLANATION \(metrics.elapsedSeconds)s, peak MLX \(metrics.peakMemoryBytes) bytes, \(metrics.inputTokens) input / \(metrics.outputTokens) output tokens: \(answer.summary) \(answer.interpretation) \(answer.uncertainty)"
        )
    }

    func testRealSelectedLocalModelWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawBackend = environment["MACPERF_TEST_LOCAL_BACKEND"] else {
            throw XCTSkip(
                "Model trials require an explicit backend and existing local model folder.")
        }
        let backend = try XCTUnwrap(AskInferenceBackend(rawValue: rawBackend))
        XCTAssertTrue(backend.isLocal)
        guard backend.isLocal else { return }
        let directory = try XCTUnwrap(environment["MACPERF_TEST_LOCAL_MODEL_DIRECTORY"])
        let executable = try XCTUnwrap(environment["MACPERF_TEST_INFERENCE_BINARY"])
        let store = AskLocalModelStore(
            backend: backend, directory: URL(fileURLWithPath: directory, isDirectory: true))
        try XCTSkipUnless(store.isEligible)
        guard store.isInstalled else { throw AskExplanationError.modelNotInstalled }
        let provider = LocalAskExplainer(store: store, executable: URL(fileURLWithPath: executable))
        try await checkRealInvestigation(provider, label: backend.displayName)
        XCTAssertFalse(store.isInUse)
        let metrics = try XCTUnwrap(provider.lastMetrics)
        XCTAssertLessThanOrEqual(metrics.inputTokens + metrics.outputTokens, 8192)
        XCTAssertLessThan(
            metrics.peakMemoryBytes, (backend == .deepAnalyze ? 8 : 5) * 1024 * 1024 * 1024)
        print(
            "MODEL TRIAL: \(backend.rawValue), \(metrics.elapsedSeconds)s, peak runtime memory \(metrics.peakMemoryBytes) bytes"
        )
    }

    func testRealQwenDatabaseInvestigationWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MACPERF_TEST_QWEN"] == "1")
        let directory = try XCTUnwrap(environment["MACPERF_TEST_QWEN_DIRECTORY"])
        let executable = try XCTUnwrap(environment["MACPERF_TEST_INFERENCE_BINARY"])
        let store = AskLocalModelStore(
            directory: URL(fileURLWithPath: directory, isDirectory: true))
        try XCTSkipUnless(store.isEligible && store.isInstalled)
        let provider = LocalAskExplainer(store: store, executable: URL(fileURLWithPath: executable))
        try await checkRealInvestigation(provider, label: "QWEN")
        XCTAssertFalse(store.isInUse)
    }

    func testRealQwenReadOnlyLocalHistoryWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MACPERF_TEST_QWEN"] == "1")
        guard let path = environment["MACPERF_TEST_ASK_DATABASE"] else {
            throw XCTSkip("Local history replay requires an explicit database path.")
        }
        let directory = try XCTUnwrap(environment["MACPERF_TEST_QWEN_DIRECTORY"])
        let executable = try XCTUnwrap(environment["MACPERF_TEST_INFERENCE_BINARY"])
        let store = AskLocalModelStore(
            directory: URL(fileURLWithPath: directory, isDirectory: true))
        try XCTSkipUnless(store.isEligible && store.isInstalled)
        let provider = LocalAskExplainer(store: store, executable: URL(fileURLWithPath: executable))
        try await checkReadOnlyLocalHistory(provider, path: path, label: "QWEN")
        XCTAssertFalse(store.isInUse)
    }

    func testRealAppleReadOnlyLocalHistoryWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MACPERF_TEST_FOUNDATION_MODELS"] == "1")
        guard let path = environment["MACPERF_TEST_ASK_DATABASE"] else {
            throw XCTSkip("Local history replay requires an explicit database path.")
        }
        if let reason = AskModelSupport.unavailabilityReason { throw XCTSkip(reason) }
        let provider = try XCTUnwrap(AskExplainer.apple() as? any AskInvestigating)
        try await checkReadOnlyLocalHistory(provider, path: path, label: "APPLE")
    }

    private func checkReadOnlyLocalHistory(
        _ provider: any AskInvestigating, path: String, label: String
    ) async throws {
        var configuration = Configuration()
        configuration.readonly = true
        let pool = try DatabasePool(path: path, configuration: configuration)
        let database = SampleStore(pool: pool)
        let sampler = SamplerModel(interval: 1, persistenceEnabled: false)
        sampler.start()
        let reports: [AskReport]
        do {
            reports = try await sampler.readAskReports()
        } catch {
            sampler.stop()
            throw error
        }
        sampler.stop()
        let request = AskExplanationRequest(
            question: "Why is my Mac slow?", previousTopic: .overview, reports: reports)
        let tools = TestDatabaseTools(store: database, capturedAt: request.capturedAt)
        let result = try await provider.investigate(
            request, read: { try await tools.read($0) },
            progress: { call in
                print("\(label) LOCAL CHECK: \(call.name.rawValue) \(call.metric.rawValue)")
            })
        try result.answer.validate(against: result.evidence)
        print(
            "\(label) LOCAL REPLAY: completed \(result.checks.count) checks with a validated answer; private content omitted."
        )
    }

    func testRealQwenPinnedAnswerWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MACPERF_TEST_QWEN"] == "1")
        guard let path = environment["MACPERF_TEST_ASK_DATABASE"],
            let timestamp = environment["MACPERF_TEST_ASK_DATE"],
            let capturedAt = ISO8601DateFormatter().date(from: timestamp)
        else { throw XCTSkip("A read-only database and fixed replay date are required.") }
        let directory = try XCTUnwrap(environment["MACPERF_TEST_QWEN_DIRECTORY"])
        let executable = try XCTUnwrap(environment["MACPERF_TEST_INFERENCE_BINARY"])
        var configuration = Configuration()
        configuration.readonly = true
        let pool = try DatabasePool(path: path, configuration: configuration)
        let tools = TestDatabaseTools(store: SampleStore(pool: pool), capturedAt: capturedAt)
        var request = AskExplanationRequest(
            question: "Why is my Mac slow?", previousTopic: .overview,
            reports: [AskReport.make(topic: .overview, snapshot: nil, now: capturedAt)])
        let ranking = try tools.read(AskToolCall(name: .topProcesses, metric: .cpu))
        request = request.adding(ranking, check: 1)
        let reference = try XCTUnwrap(ranking.processes.first?.reference)
        request = request.adding(
            try tools.read(
                AskToolCall(
                    name: .processHistory, metric: .cpu, processReference: reference)), check: 2)
        request = request.adding(
            try tools.read(AskToolCall(name: .systemHistory, metric: .cpu)), check: 3)
        request = request.investigationConclusion()
        let store = AskLocalModelStore(
            directory: URL(fileURLWithPath: directory, isDirectory: true))
        try XCTSkipUnless(store.isEligible && store.isInstalled)
        let provider = LocalAskExplainer(store: store, executable: URL(fileURLWithPath: executable))
        let answer = try await provider.explain(request)
        try answer.validate(against: request)
        XCTAssertFalse(store.isInUse)
        print(
            "QWEN PINNED REPLAY: validated final answer from fixed read-only evidence; private content omitted."
        )
    }

    func testWorkerHostPassesTheSelectedLocalModelIdentity() async throws {
        let request = AskExplanationRequest(
            question: "Check CPU", previousTopic: .cpu, reports: currentReports())
        for backend in AskInferenceBackend.allCases where backend.isLocal {
            let directory = try workerFixture(messages: [], earlyExit: 75)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await AskWorkerInvocation(
                    executable: directory.appendingPathComponent("worker"), directory: directory,
                    backend: backend
                ).run(request, read: nil, progress: nil)
                XCTFail("Expected the fixture to exit with a pressure refusal")
            } catch AskExplanationError.resourcePressure {}
            let arguments = try JSONDecoder().decode(
                [String].self, from: Data(contentsOf: directory.appendingPathComponent("arguments"))
            )
            XCTAssertEqual(arguments, ["--backend", backend.rawValue, "--model", directory.path])
        }
    }

    func testWorkerHostUsesOnlyHostSuppliedEvidenceAndRejectsForgedCitations() async throws {
        let request = AskExplanationRequest(
            question: "Why is my Mac slow?", previousTopic: .overview, reports: currentReports())
        let call = AskToolCall(name: .systemHistory, metric: .cpu)
        let facts = AskToolResult(
            facts: [
                AskExplanationFact(
                    id: "cpu", name: "Recorded CPU", value: "85.0%", meaning: "Recorded load.")
            ], limits: [])
        for forged in [false, true] {
            let answer = AskExplanationDraft(
                topic: "cpu", summary: "CPU activity is the strongest lead.",
                interpretation:
                    "Recorded activity was high. Memory was not measured in that interval.",
                uncertainty: "The affected task is not known.",
                nextCheck:
                    "Compare responsiveness while the task runs and after it naturally finishes.",
                followUpQuestion: "Which task feels slow?",
                evidenceIDs: [forged ? "fabricated" : "check1.cpu"], nextStep: .observe)
            let response = AskInferenceResponse(
                answer: answer, inputTokens: 400, outputTokens: 120, elapsedSeconds: 1,
                peakMemoryBytes: 0, evidence: request, checks: [call])
            let directory = try workerFixture(messages: [.tool(call), .complete(response)])
            defer { try? FileManager.default.removeItem(at: directory) }
            let invocation = AskWorkerInvocation(
                executable: directory.appendingPathComponent("worker"), directory: directory)
            do {
                let result = try await invocation.run(
                    request,
                    read: { received in
                        XCTAssertEqual(received, call)
                        return facts
                    }, progress: nil)
                XCTAssertFalse(forged)
                XCTAssertEqual(result.evidence?.facts.map(\.id), ["check1.cpu"])
                XCTAssertEqual(result.checks, [call])
            } catch AskExplanationError.invalidAnswer {
                XCTAssertTrue(forged)
            }
        }
    }

    func testWorkerHostValidatesTimesAgainstItsOwnToolResults() async throws {
        let request = AskExplanationRequest(
            question: "Why is my Mac slow?", previousTopic: .overview, reports: currentReports())
        let call = AskToolCall(name: .systemHistory, metric: .cpu)
        let domain = try call.domain(relativeTo: request.capturedAt)
        let window = AskEvidenceWindow(
            start: domain.lowerBound, end: domain.upperBound, kind: .requested)
        let facts = [
            AskExplanationFact(
                id: "cpu", name: "Recorded CPU", value: "17.9%", meaning: "Recorded activity.")
        ]
        let answer = AskExplanationDraft(
            topic: "cpu", summary: "The readings do not establish a cause.",
            interpretation: "The requested window is 5 minutes.",
            uncertainty: "Responsiveness was not measured.",
            nextCheck: "Compare unrelated local apps while the symptom occurs.",
            followUpQuestion: "Which app feels slow?",
            evidenceIDs: ["check1.cpu"], nextStep: .observe)
        for supported in [true, false] {
            let hostResult = AskToolResult(
                facts: facts, limits: [], timeWindows: supported ? [window] : [])
            let claimedEvidence = request.adding(
                AskToolResult(facts: facts, limits: [], timeWindows: [window]), check: 1)
            let response = AskInferenceResponse(
                answer: answer, inputTokens: 400, outputTokens: 100, elapsedSeconds: 1,
                peakMemoryBytes: 0, evidence: claimedEvidence, checks: [call])
            let directory = try workerFixture(messages: [.tool(call), .complete(response)])
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let result = try await AskWorkerInvocation(
                    executable: directory.appendingPathComponent("worker"), directory: directory
                )
                .run(request, read: { _ in hostResult }, progress: nil)
                XCTAssertTrue(supported)
                XCTAssertEqual(result.evidence?.timeWindows, [window])
            } catch AskExplanationError.unverifiedMeasurement {
                XCTAssertFalse(supported)
            }
        }
    }

    func testWorkerHostRejectsUnknownReferencesAndMapsEarlyPressureExit() async throws {
        let request = AskExplanationRequest(
            question: "Check CPU", previousTopic: .cpu, reports: currentReports())
        let invalid = AskToolCall(
            name: .processHistory, metric: .cpu, processReference: "not-issued")
        let directory = try workerFixture(messages: [.tool(invalid)])
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await AskWorkerInvocation(
                executable: directory.appendingPathComponent("worker"), directory: directory
            )
            .run(
                request,
                read: { _ in
                    XCTFail("Invalid reference reached the reader")
                    throw AskInvestigationError.unavailable
                }, progress: nil)
            XCTFail("Expected rejection")
        } catch AskInvestigationError.unknownProcess {}
        let early = try workerFixture(messages: [], earlyExit: 75)
        defer { try? FileManager.default.removeItem(at: early) }
        do {
            _ = try await AskWorkerInvocation(
                executable: early.appendingPathComponent("worker"), directory: early
            )
            .run(request, read: nil, progress: nil)
            XCTFail("Expected pressure refusal")
        } catch AskExplanationError.resourcePressure {}
    }

    func testWorkerHostCancelsWhileAwaitingADataReadAndReapsTheChild() async throws {
        let call = AskToolCall(name: .systemHistory, metric: .cpu)
        let directory = try workerFixture(messages: [.tool(call)], ignoreTermination: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let began = expectation(description: "Worker requested a read")
        let ended = expectation(description: "Worker and request ended")
        let request = AskExplanationRequest(
            question: "Check CPU", previousTopic: .cpu, reports: currentReports())
        let invocation = AskWorkerInvocation(
            executable: directory.appendingPathComponent("worker"), directory: directory)
        let task = Task {
            defer { ended.fulfill() }
            do {
                _ = try await invocation.run(
                    request,
                    read: { _ in
                        began.fulfill()
                        try await Task.sleep(for: .seconds(30))
                        throw AskInvestigationError.unavailable
                    }, progress: nil)
                XCTFail("Expected cancellation")
            } catch is CancellationError {
            } catch { XCTFail("Unexpected cancellation error: \(error)") }
        }
        await fulfillment(of: [began], timeout: 5)
        task.cancel()
        await fulfillment(of: [ended], timeout: 4)
        let pidText = try String(
            contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testWorkerHostPreservesModelFailureCategories() async throws {
        let request = AskExplanationRequest(
            question: "Check CPU", previousTopic: .cpu, reports: currentReports())
        for (code, expected) in [
            (67, AskExplanationError.invalidAnswer), (76, .unverifiedMeasurement),
        ] {
            let directory = try workerFixture(messages: [], earlyExit: code)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await AskWorkerInvocation(
                    executable: directory.appendingPathComponent("worker"), directory: directory
                ).run(request, read: nil, progress: nil)
                XCTFail("Expected a model failure")
            } catch let error as AskExplanationError {
                XCTAssertEqual(error, expected)
            }
        }
        for (code, expected) in [
            (68, AskInvestigationError.invalidToolCall), (78, .unknownProcess),
        ] {
            let directory = try workerFixture(messages: [], earlyExit: code)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await AskWorkerInvocation(
                    executable: directory.appendingPathComponent("worker"), directory: directory
                ).run(
                    request, read: { _ in throw AskInvestigationError.unavailable }, progress: nil)
                XCTFail("Expected an investigation failure")
            } catch let error as AskInvestigationError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    private func workerFixture(
        messages: [AskWorkerMessage], earlyExit: Int = 0, ignoreTermination: Bool = false
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-worker-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoded = String(decoding: try JSONEncoder().encode(messages), as: UTF8.self)
        let script = """
            #!/usr/bin/python3
            import json, os, signal, sys
            if \(ignoreTermination ? "True" : "False"):
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(os.path.join(sys.argv[-1], 'pid'), 'w') as handle:
                handle.write(str(os.getpid()))
            with open(os.path.join(sys.argv[-1], 'arguments'), 'w') as handle:
                json.dump(sys.argv[1:], handle)
            if \(earlyExit) != 0:
                sys.exit(\(earlyExit))
            request = json.loads(sys.stdin.readline())
            for message in json.loads(\(String(reflecting: encoded))):
                print(json.dumps(message), flush=True)
                if 'tool' in message:
                    result = sys.stdin.readline()
                    if not result:
                        sys.exit(1)
                    json.loads(result)
            """
        let executable = directory.appendingPathComponent("worker")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return directory
    }

    func testRealAppleDatabaseInvestigationWhenExplicitlyEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPERF_TEST_FOUNDATION_MODELS"] == "1")
        if let reason = AskModelSupport.unavailabilityReason { throw XCTSkip(reason) }
        let provider = try XCTUnwrap(AskExplainer.apple() as? any AskInvestigating)
        try await checkRealInvestigation(provider, label: "APPLE")
    }

    private func checkRealInvestigation(
        _ provider: any AskInvestigating, label: String
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ask-investigation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        let capturedAt = Date()
        var system = SystemSample(
            timestamp: capturedAt, totalRAM: 16 << 30, free: 4 << 30, active: 5 << 30,
            inactive: 2 << 30, wired: 2 << 30, speculative: 0, compressed: 1 << 30,
            appMemory: 6 << 30, cachedFiles: 2 << 30, swapTotal: 1 << 30, swapUsed: 0,
            pressureLevel: .normal, pressurePercent: 10, pageIns: 0, pageOuts: 0,
            compressions: 0, decompressions: 0, cpuLoad: 0.1, bootVolumeTotalBytes: 500 << 30,
            bootVolumeFreeBytes: 200 << 30, thermalPressure: .nominal,
            swapSampleValid: true, pressureSampleValid: true, swapInBytesPerSecond: 0,
            swapOutBytesPerSecond: 0)
        var process = ProcessSample(
            timestamp: capturedAt, pid: 700, ppid: 1, name: "BuildWorker",
            physFootprint: 2 << 30, residentSize: 0, virtualSize: 0, lifetimeMaxFootprint: 2 << 30,
            cpuPercent: 5, cpuTimeUser: 0, cpuTimeSystem: 0, threadCount: 12,
            fdTotal: 40, fdVnode: 40, fdSocket: 0, fdPipe: 0, fdOther: 0,
            diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false, architecture: .arm64,
            startTime: capturedAt.addingTimeInterval(-3600), uid: 501, dataSource: .directUserRead,
            footprintReadable: true)
        for offset in stride(from: -600, through: 0, by: 10) {
            let busy = offset >= -300 && offset < -10
            system.timestamp = capturedAt.addingTimeInterval(Double(offset))
            system.cpuLoad = busy ? 0.92 : 0.1
            process.timestamp = system.timestamp
            process.cpuPercent = busy ? 550 : 5
            try store.insert(system, processes: [process])
        }
        let snapshot = Sampler.Snapshot(
            system: system, processes: [process], unreadableProcessCount: 0)
        let request = AskExplanationRequest(
            question:
                "My Mac was sluggish during a build a few minutes ago. Use recorded history to find the most likely contributor and check whether memory was a better explanation.",
            previousTopic: .overview,
            reports: AskTopic.allCases.map {
                AskReport.make(topic: $0, snapshot: snapshot, now: capturedAt)
            }, locale: "en_GB")
        let tools = TestDatabaseTools(store: store, capturedAt: capturedAt)
        let started = Date()
        let result = try await provider.investigate(
            request, read: { try await tools.read($0) },
            progress: { call in
                print(
                    "\(label) TOOL \(call.name) \(call.metric) \(call.fromMinutesAgo)..\(call.toMinutesAgo) \(call.processReference)"
                )
            })
        try result.answer.validate(against: result.evidence)
        XCTAssertGreaterThanOrEqual(result.checks.count, 2)
        XCTAssertLessThanOrEqual(result.checks.count, AskInvestigation.maximumChecks)
        XCTAssertTrue(result.checks.contains { $0.name == .systemHistory && $0.metric == .cpu })
        XCTAssertTrue(
            result.checks.contains { $0.name == .topProcesses || $0.name == .processHistory })
        XCTAssertTrue(result.answer.evidenceIDs.contains { $0.hasPrefix("check") })
        print(
            "\(label) EVIDENCE "
                + result.evidence.facts.map { "\($0.id): \($0.value)" }.joined(separator: "; "))
        XCTAssertTrue(["cpu", "overview"].contains(result.answer.topic))
        XCTAssertTrue(result.evidence.facts.allSatisfy { $0.scope == "recorded_interval" })
        XCTAssertTrue(result.evidence.facts.contains { $0.id.contains("pressure") })
        print(
            "\(label) INVESTIGATION \(Date().timeIntervalSince(started))s: \(result.answer.summary) \(result.answer.interpretation) NEXT: \(result.answer.nextCheck) LIMIT: \(result.answer.uncertainty)"
        )
    }

    @MainActor
    private final class TestDatabaseTools {
        let store: SampleStore
        let capturedAt: Date
        var identities: [String: ProcessIdentity] = [:]

        init(store: SampleStore, capturedAt: Date) {
            self.store = store
            self.capturedAt = capturedAt
        }

        func read(_ call: AskToolCall) throws -> AskToolResult {
            let data = try store.readAskData(
                call, at: capturedAt, process: identities[call.processReference])
            identities.merge(data.identities) { existing, _ in existing }
            return data.result
        }
    }

    private func currentReports(configure: (inout SystemSample) -> Void = { _ in }) -> [AskReport] {
        var system = SystemSample(
            timestamp: Date(), totalRAM: 16 << 30, free: 4 << 30,
            active: 5 << 30, inactive: 2 << 30, wired: 2 << 30, speculative: 0,
            compressed: 1 << 30, appMemory: 6 << 30, cachedFiles: 2 << 30,
            swapTotal: 1 << 30, swapUsed: 0, pressureLevel: .normal, pressurePercent: 10,
            pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0, cpuLoad: 0.2,
            bootVolumeTotalBytes: 500_000_000_000, bootVolumeFreeBytes: 20_000_000_000,
            swapSampleValid: true, pressureSampleValid: true)
        configure(&system)
        let snapshot = Sampler.Snapshot(system: system, processes: [], unreadableProcessCount: 0)
        return AskTopic.allCases.map { AskReport.make(topic: $0, snapshot: snapshot) }
    }

    private func completed(_ model: AskPreviewModel, action: () -> Void) async {
        let finished = expectation(description: "Preview request finishes")
        var started = false
        let subscription = model.$isWorking.sink { working in
            if working { started = true }
            if started && !working { finished.fulfill() }
        }
        action()
        await fulfillment(of: [finished], timeout: 5)
        subscription.cancel()
    }
}
