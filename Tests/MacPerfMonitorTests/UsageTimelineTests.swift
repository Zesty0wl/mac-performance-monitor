import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class UsageTimelineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var target: UsageTimelineTarget {
        UsageTimelineTarget(
            pid: 1234, startTime: now.addingTimeInterval(-3600), name: "Editor",
            bundleID: "com.example.Editor", uid: UInt32(getuid()))
    }

    func testUsageWindowDefaultsToThirtyMinutesAndSurvivesReopening() throws {
        let suite = "MacPerfMonitorTests.UsageRange.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requested: HistoryWindow?
        let loader: UsageTimelineModel.HistoryLoader = { _, window, _, completion in
            requested = window
            completion(.success(.init(intervals: [], bucketSeconds: 60)))
        }
        let model = UsageTimelineModel(
            target: target, now: now, preferences: defaults, loadHistory: loader)
        model.load()
        XCTAssertEqual(model.window, .thirtyMinutes)
        XCTAssertEqual(requested, .thirtyMinutes)
        model.load(window: .sevenDays)
        model.close()

        let reopened = UsageTimelineModel(
            target: target, now: now, preferences: defaults, loadHistory: loader)
        reopened.load()
        XCTAssertEqual(reopened.window, .sevenDays)
        XCTAssertEqual(requested, .sevenDays)
        XCTAssertEqual(reopened.endDate, now)

        defaults.set("obsoleteRange", forKey: UsageTimelineModel.windowDefaultsKey)
        XCTAssertEqual(
            UsageTimelineModel(target: target, preferences: defaults, loadHistory: loader).window,
            .thirtyMinutes)
    }

    func testAppleHistoryRequiresOptInAndIsClearedWhenDisabled() {
        var activityReads = 0
        var capturedBundle: String?
        var completeActivity:
            ((Result<[UsageTimeline.Interval], KnowledgeActivityReader.ReadError>) -> Void)?
        let model = UsageTimelineModel(
            target: target, now: now,
            loadHistory: { _, _, _, completion in
                completion(.success(.init(intervals: [], bucketSeconds: 60)))
            },
            loadActivity: { bundleID, _, completion in
                activityReads += 1
                capturedBundle = bundleID
                completeActivity = completion
            })

        model.load()
        XCTAssertEqual(activityReads, 0)
        model.includeAppleActivity(true)
        XCTAssertEqual(activityReads, 1)
        XCTAssertEqual(capturedBundle, target.bundleID)
        model.includeAppleActivity(false)
        completeActivity?(
            .success([
                .init(kind: .appUsage, start: now.addingTimeInterval(-60), end: now)
            ]))
        XCTAssertTrue(model.activity.isEmpty)
        XCTAssertFalse(model.includesAppleActivity)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(activityReads, 1)
    }

    func testOldHistoryResponseCannotReplaceNewTimeframe() {
        var completions: [(Result<UsageTimeline.ObservedHistory, Error>) -> Void] = []
        let model = UsageTimelineModel(
            target: target, now: now,
            loadHistory: { _, _, _, completion in completions.append(completion) })
        model.load()
        model.load(window: .oneHour)
        completions[1](.success(.init(intervals: [], bucketSeconds: 60)))
        completions[0](.failure(CocoaError(.fileReadUnknown)))

        XCTAssertEqual(model.window, .oneHour)
        XCTAssertEqual(model.endDate, now)
        XCTAssertEqual(model.range.upperBound.timeIntervalSince(model.range.lowerBound), 3600)
        XCTAssertFalse(model.historyUnavailable)
        XCTAssertFalse(model.loadingHistory)
        XCTAssertNotNil(model.history)
    }

    func testUnbundledAndOtherUserProcessesDoNotReadCurrentUserAppActivity() {
        var unbundled = target
        unbundled.bundleID = nil
        var otherUser = target
        otherUser.uid += 1
        for target in [unbundled, otherUser] {
            let model = UsageTimelineModel(
                target: target, now: now, loadHistory: { _, _, _, _ in },
                loadActivity: { _, _, _ in XCTFail("Activity must not be read for this process") })
            XCTAssertFalse(model.canReadAppleActivity)
            model.includeAppleActivity(true)
            XCTAssertFalse(model.includesAppleActivity)
        }
    }

    func testClosingDiscardsActivityAndIgnoresPendingReads() {
        var completions:
            [(Result<[UsageTimeline.Interval], KnowledgeActivityReader.ReadError>) -> Void] = []
        let model = UsageTimelineModel(
            target: target, now: now,
            loadHistory: { _, _, _, completion in
                completion(.success(.init(intervals: [], bucketSeconds: 60)))
            },
            loadActivity: { _, _, completion in completions.append(completion) })
        model.includeAppleActivity(true)
        completions[0](
            .success([
                .init(kind: .appUsage, start: now.addingTimeInterval(-60), end: now)
            ]))
        XCTAssertFalse(model.activity.isEmpty)
        model.load()
        model.close()
        completions[1](.failure(.permissionDenied))

        XCTAssertTrue(model.activity.isEmpty)
        XCTAssertFalse(model.includesAppleActivity)
        XCTAssertNil(model.activityError)
        XCTAssertFalse(model.isLoading)
    }

    func testWindowTargetPreservesProcessIdentityThroughEncoding() throws {
        let encoded = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(UsageTimelineTarget.self, from: encoded)
        XCTAssertEqual(decoded, target)
        XCTAssertEqual(decoded.id, ProcessIdentity(pid: target.pid, startTime: target.startTime))
    }

    func testNativeTimelineFitsCompactAndWideWindowsAndChangesRange() async throws {
        _ = NSApplication.shared
        for (name, width, appearance) in [
            ("compact-light", 680.0, NSAppearance.Name.aqua),
            ("wide-dark", 1040.0, NSAppearance.Name.darkAqua),
        ] {
            let model = fixtureModel()
            model.includeAppleActivity(true)
            let appeared = expectation(description: "The timeline appears")
            let host = NSHostingView(
                rootView: UsageTimelineView(model: model)
                    .environmentObject(FullDiskAccessManager())
                    .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = makeWindow(host, width: width, height: 720, appearance: appearance)
            defer { window.close() }
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            XCTAssertFalse(model.isLoading)
            XCTAssertEqual(Set(model.intervals.map(\.kind)), Set(UsageTimeline.Kind.allCases))
            let picker = try XCTUnwrap(rangeControl(in: host))
            XCTAssertEqual(picker.segmentCount, 5)
            XCTAssertEqual(model.window, .thirtyMinutes)
            XCTAssertEqual(picker.selectedSegment, 0)
            XCTAssertTrue(host.bounds.contains(picker.convert(picker.bounds, to: host)))
            try save(host, name: name)

            picker.selectedSegment = 1
            XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
            let changed = expectation(description: "The timeframe changes")
            DispatchQueue.main.async { changed.fulfill() }
            await fulfillment(of: [changed], timeout: 5)
            XCTAssertEqual(model.window, .oneHour)
            XCTAssertEqual(model.endDate, now)
            XCTAssertEqual(model.range.upperBound.timeIntervalSince(model.range.lowerBound), 3600)
            XCTAssertFalse(model.isLoading)
        }
    }

    func testNativeTimelineChartDrawsEveryEvidenceLane() async throws {
        _ = NSApplication.shared
        let model = fixtureModel()
        model.includeAppleActivity(true)
        let appeared = expectation(description: "The chart appears")
        let host = NSHostingView(
            rootView: UsageTimelineChart(intervals: model.intervals, range: model.range)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
        let window = makeWindow(host, width: 800, height: 300, appearance: .aqua)
        defer { window.close() }
        await fulfillment(of: [appeared], timeout: 5)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let image = try capture(host)
        var blue = 0
        var green = 0
        var orange = 0
        for vertical in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for horizontal in stride(from: 0, to: image.pixelsWide, by: 2) {
                guard let color = image.colorAt(x: horizontal, y: vertical)?.usingColorSpace(.sRGB)
                else { continue }
                if color.blueComponent > 0.5,
                    color.blueComponent > color.redComponent * 1.5,
                    color.blueComponent > color.greenComponent * 1.2
                {
                    blue += 1
                }
                if color.greenComponent > 0.4,
                    color.greenComponent > color.redComponent * 1.4,
                    color.greenComponent > color.blueComponent * 1.4
                {
                    green += 1
                }
                if color.redComponent > 0.65, color.greenComponent > 0.25,
                    color.redComponent > color.greenComponent * 1.2,
                    color.greenComponent > color.blueComponent * 1.5
                {
                    orange += 1
                }
            }
        }
        XCTAssertGreaterThan(blue, 500)
        XCTAssertGreaterThan(green, 500)
        XCTAssertGreaterThan(orange, 500)
        try save(host, name: "evidence-lanes")
    }

    func testNativeTimelineHandlesDeniedAccessAndUnbundledProcesses() async throws {
        _ = NSApplication.shared
        for missingBundle in [false, true] {
            var selected = target
            if missingBundle { selected.bundleID = nil }
            let model = UsageTimelineModel(
                target: selected, now: now,
                loadHistory: { _, _, _, completion in
                    completion(.success(.init(intervals: [], bucketSeconds: 60)))
                },
                loadActivity: { _, _, completion in completion(.failure(.permissionDenied)) })
            if !missingBundle { model.includeAppleActivity(true) }
            let appeared = expectation(description: "The empty timeline appears")
            let host = NSHostingView(
                rootView: UsageTimelineView(model: model)
                    .environmentObject(FullDiskAccessManager())
                    .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
            let window = makeWindow(host, width: 680, height: 720, appearance: .aqua)
            defer { window.close() }
            await fulfillment(of: [appeared], timeout: 5)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertTrue(model.intervals.isEmpty)
            XCTAssertFalse(model.isLoading)
            XCTAssertEqual(model.canReadAppleActivity, !missingBundle)
            if !missingBundle { XCTAssertEqual(model.activityError, .permissionDenied) }
            try save(host, name: missingBundle ? "unbundled" : "access-denied")
        }
    }

    func testProcessTableOffersTimelineForRightClickedExitedRowButNotBatchSelection() async throws {
        _ = NSApplication.shared
        let sample = ProcessSample(
            timestamp: now, pid: target.pid, ppid: 1, name: target.name,
            bundleID: target.bundleID, physFootprint: 200, residentSize: 200, virtualSize: 200,
            lifetimeMaxFootprint: 200, cpuPercent: 0, cpuTimeUser: 0, cpuTimeSystem: 0,
            threadCount: 1, fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0, fdOther: 0,
            diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false, architecture: .arm64,
            startTime: target.startTime, uid: uid_t(target.uid), dataSource: .directUserRead,
            footprintReadable: true)
        var second = sample
        second.pid += 1
        second.physFootprint = 100
        let sampler = SamplerModel(persistenceEnabled: false)
        let appeared = expectation(description: "The process table appears")
        let host = NSHostingView(
            rootView: ProcessListView(processes: [sample, second], selection: .constant(nil))
                .environmentObject(sampler)
                .environmentObject(AppState())
                .environmentObject(MonitorSelection())
                .environmentObject(ProcessGroupStore())
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
        let window = makeWindow(host, width: 840, height: 420, appearance: .aqua)
        defer { window.close() }
        await fulfillment(of: [appeared], timeout: 5)
        host.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(outlineView(in: host))
        XCTAssertEqual(outline.numberOfRows, 2)
        XCTAssertNil(sampler.currentSample(for: sample.id))
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let menu = try XCTUnwrap(outline.menuProvider?(0))
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: 0))
        let title = String(localized: "Usage Timeline\u{2026}")
        XCTAssertEqual(menu.items.filter { $0.title == title }.count, 1)
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.title == title }).isEnabled)
        XCTAssertEqual(UsageTimelineTarget(sample: sample).id, sample.id)

        outline.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let batch = try XCTUnwrap(outline.menuProvider?(0))
        XCTAssertFalse(batch.items.contains { $0.title == title })
    }

    private func fixtureModel() -> UsageTimelineModel {
        var selected = target
        selected.startTime = now.addingTimeInterval(-7 * 86400)
        return UsageTimelineModel(
            target: selected, now: now,
            loadHistory: { _, window, end, completion in
                let start = end.addingTimeInterval(-window.seconds)
                completion(
                    .success(
                        .init(
                            intervals: [
                                .init(
                                    kind: .observedRunning,
                                    start: start.addingTimeInterval(window.seconds * 0.1),
                                    end: start.addingTimeInterval(window.seconds * 0.4)),
                                .init(
                                    kind: .observedRunning,
                                    start: start.addingTimeInterval(window.seconds * 0.55),
                                    end: end),
                            ], bucketSeconds: window == .sevenDays ? 3600 : 60)))
            },
            loadActivity: { _, range, completion in
                let start = range.lowerBound
                let duration = range.upperBound.timeIntervalSince(start)
                completion(
                    .success([
                        .init(
                            kind: .appUsage, start: start.addingTimeInterval(duration * 0.12),
                            end: start.addingTimeInterval(duration * 0.3)),
                        .init(
                            kind: .appUsage, start: start.addingTimeInterval(duration * 0.6),
                            end: start.addingTimeInterval(duration * 0.8)),
                        .init(
                            kind: .mediaUsage, start: start.addingTimeInterval(duration * 0.65),
                            end: start.addingTimeInterval(duration * 0.9)),
                    ]))
            })
    }

    private func makeWindow(
        _ content: NSView, width: Double, height: Double, appearance: NSAppearance.Name
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 80, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = content
        window.orderFront(nil)
        return window
    }

    private func outlineView(in view: NSView) -> ContextMenuOutlineView? {
        if let outline = view as? ContextMenuOutlineView { return outline }
        for child in view.subviews {
            if let outline = outlineView(in: child) { return outline }
        }
        return nil
    }

    private func rangeControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for child in view.subviews {
            if let control = rangeControl(in: child) { return control }
        }
        return nil
    }

    private func capture(_ view: NSView) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    private func save(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MACPERF_USAGE_ARTIFACTS"] else {
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = try XCTUnwrap(view.window)
        let output = directory.appendingPathComponent(name + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: output)))
    }
}
