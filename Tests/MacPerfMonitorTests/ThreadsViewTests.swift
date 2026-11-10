import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

final class ThreadsViewTests: XCTestCase {
    private func row(name: String, index: Int, cpu: Double? = nil) -> ThreadRow {
        ThreadRow(
            snapshot: ThreadSnapshot(
                id: UInt64(index + 1), name: name, userNanos: 0, systemNanos: 0, state: .waiting,
                currentPriority: 31, basePriority: 31, sleepSeconds: 0),
            index: index, cpuPercent: cpu)
    }

    func testCPUTimeText() {
        XCTAssertEqual(ThreadRow.cpuTimeText(nanos: 0), "0.00 s")
        XCTAssertEqual(ThreadRow.cpuTimeText(nanos: 420_000_000), "0.42 s")
        XCTAssertEqual(ThreadRow.cpuTimeText(nanos: 59_990_000_000), "59.99 s")
        XCTAssertEqual(ThreadRow.cpuTimeText(nanos: 187_000_000_000), "3:07")
        XCTAssertEqual(ThreadRow.cpuTimeText(nanos: 3_765_000_000_000), "1:02:45")
    }

    func testUnnamedThreadsAreNamedByPosition() {
        XCTAssertEqual(
            row(name: "com.apple.NSEventThread", index: 3).displayName,
            "com.apple.NSEventThread")
        XCTAssertEqual(row(name: "", index: 0).displayName, t("Main thread"))
        XCTAssertEqual(row(name: "", index: 4).displayName, t("Thread %d", 5))
    }

    func testUnmeasuredThreadsSortBelowIdleOnes() {
        let rows = [
            row(name: "new", index: 0), row(name: "idle", index: 1, cpu: 0),
            row(name: "busy", index: 2, cpu: 80),
        ]
        let sorted = rows.sorted(using: [KeyPathComparator(\ThreadRow.cpuSortKey, order: .reverse)])
        XCTAssertEqual(sorted.map(\.snapshot.name), ["busy", "idle", "new"])
    }

    /// The real window, pointed at the test runner: it must load, and after a
    /// second refresh it must have a CPU rate for the threads it saw twice.
    /// Set `MACPERF_THREADS_ARTIFACTS` to a folder to keep a picture of it.
    @MainActor
    func testWindowLoadsAndMeasuresTheRunnersOwnThreads() async throws {
        _ = NSApplication.shared
        let info = try XCTUnwrap(ProcessReader().taskAllInfo(getpid()))
        let target = ThreadsTarget(
            pid: getpid(), startTime: info.startTime, name: "xctest", uid: UInt32(getuid()))
        let model = ThreadsModel()
        // A window made by a test is never "visible" to the window server, and
        // a hidden window rightly stops polling, so stand in for that check.
        let root = ThreadsView(target: target, model: model, isVisible: { true })
            .environmentObject(HelperManager())
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 520))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let deadline = Date().addingTimeInterval(ThreadsModel.interval * 3 + 2)
        while Date() < deadline, !model.rows.contains(where: { $0.cpuPercent != nil }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.state, .loaded)
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertTrue(model.rows.contains { $0.cpuPercent != nil }, "No rate after two reads")

        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if let path = ProcessInfo.processInfo.environment["MACPERF_THREADS_ARTIFACTS"] {
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("threads.png"))
        }
    }

    /// Nothing is read while the window is hidden behind others or minimised.
    @MainActor
    func testHiddenWindowDoesNotPoll() async throws {
        let info = try XCTUnwrap(ProcessReader().taskAllInfo(getpid()))
        let target = ThreadsTarget(
            pid: getpid(), startTime: info.startTime, name: "xctest", uid: UInt32(getuid()))
        let model = ThreadsModel()
        model.start(target: target, helper: HelperManager(), isVisible: { false })
        defer { model.stop() }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.state, .loading)
        XCTAssertTrue(model.rows.isEmpty)
    }

    @MainActor
    func testReusedPIDReadsAsExited() async throws {
        let info = try XCTUnwrap(ProcessReader().taskAllInfo(getpid()))
        // Same pid, different start time: the process the window was opened
        // for has gone and something else has its number.
        let target = ThreadsTarget(
            pid: getpid(), startTime: info.startTime.addingTimeInterval(-60), name: "old",
            uid: UInt32(getuid()))
        let model = ThreadsModel()
        model.refresh(target: target, helper: HelperManager())
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, model.state == .loading {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.state, .exited)
        XCTAssertTrue(model.rows.isEmpty)
    }
}
