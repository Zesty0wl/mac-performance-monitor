import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class ProcessOutlineTableTests: XCTestCase {
    private func sample(
        _ pid: Int32, name: String, startedAgo seconds: TimeInterval
    )
        -> ProcessSample
    {
        ProcessSample(
            timestamp: Date(), pid: pid, ppid: 1, name: name, physFootprint: 0, residentSize: 0,
            virtualSize: 0, lifetimeMaxFootprint: 0, cpuPercent: 0, cpuTimeUser: 0,
            cpuTimeSystem: 0, threadCount: 1, fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0,
            fdOther: 0, diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false,
            architecture: .arm64, startTime: Date().addingTimeInterval(-seconds), uid: 501,
            dataSource: .directUserRead, footprintReadable: true)
    }

    /// A coordinator with three rows applied to a real outline view: a process
    /// that has run for an hour, one that just started, and one that just
    /// started but has already been stopped.
    private func loaded(
        highlight: Bool
    ) -> (
        ProcessOutlineTable.Coordinator, NSOutlineView, [ProcessOutlineTable.Item]
    ) {
        let old = sample(10, name: "old", startedAgo: 3600)
        let new = sample(11, name: "new", startedAgo: 1)
        let stopped = sample(12, name: "stopped", startedAgo: 1)
        let coordinator = ProcessOutlineTable.Coordinator()
        let outline = NSOutlineView()
        coordinator.outlineView = outline
        coordinator.highlightsNewProcesses = highlight
        coordinator.apply(
            rows: [old, new, stopped].map { ProcessNode(process: $0) }, revision: 1,
            layout: .processes, leakingIDs: [], terminatedIDs: [stopped.id])
        let items = [old, new, stopped].map {
            ProcessOutlineTable.Item(node: ProcessNode(process: $0))
        }
        return (coordinator, outline, items)
    }

    private func tint(
        _ coordinator: ProcessOutlineTable.Coordinator, _ outline: NSOutlineView,
        _ item: ProcessOutlineTable.Item
    ) -> NSColor? {
        (coordinator.outlineView(outline, rowViewForItem: item) as? ProcessRowView)?.tint
    }

    func testOnlyARunningNewProcessIsTinted() {
        let (coordinator, outline, items) = loaded(highlight: true)
        XCTAssertNil(tint(coordinator, outline, items[0]), "An old process is not new")
        XCTAssertEqual(tint(coordinator, outline, items[1]), .systemGreen)
        XCTAssertNil(tint(coordinator, outline, items[2]), "A stopped row keeps its grey look")
    }

    func testNothingIsTintedWhenHighlightingIsOff() {
        let (coordinator, outline, items) = loaded(highlight: false)
        for item in items { XCTAssertNil(tint(coordinator, outline, item)) }
    }

    func testAnAppRowIsNeverTinted() {
        let (coordinator, outline, _) = loaded(highlight: true)
        let leader = sample(20, name: "App", startedAgo: 1)
        let app = ProcessOutlineTable.Item(
            node: ProcessNode(process: leader, children: [], appID: leader.id))
        XCTAssertNil(tint(coordinator, outline, app))
    }

    func testTypeSelectMatchesOnTheNameShownInTheRow() {
        let (coordinator, outline, _) = loaded(highlight: false)
        var process = sample(30, name: "com.apple.WebK", startedAgo: 60)
        process.executablePath = "/System/x/com.apple.WebKit.WebContent"
        let item = ProcessOutlineTable.Item(node: ProcessNode(process: process))
        XCTAssertEqual(
            coordinator.outlineView(outline, typeSelectStringFor: nil, item: item),
            "com.apple.WebKit.WebContent")
    }

    /// The real table in a window, with one new, one suspended and one stopped
    /// row. Checks the rows materialise as tintable row views; set
    /// `MACPERF_PROCESS_TABLE_ARTIFACTS` to a folder to keep a picture.
    func testTableDrawsNewSuspendedAndStoppedRows() async throws {
        _ = NSApplication.shared
        var suspended = sample(41, name: "suspended", startedAgo: 600)
        suspended.isSuspended = true
        let stopped = sample(43, name: "stopped", startedAgo: 600)
        let rows = [
            sample(40, name: "steady", startedAgo: 600), suspended,
            sample(42, name: "just-started", startedAgo: 1), stopped,
        ].map { ProcessNode(process: $0) }
        let table = ProcessOutlineTable(
            rows: rows, revision: 1, layout: .processes, leakingIDs: [],
            terminatedIDs: [stopped.id], selection: .constant([]),
            sortOrder: .constant([]), menu: { _ in nil }, highlightsNewProcesses: true)
        let window = NSWindow(contentViewController: NSHostingController(rootView: table))
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 160))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 300_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { find(type, in: $0) }
        }
        let content = try XCTUnwrap(window.contentView)
        let rowViews = find(ProcessRowView.self, in: content)
        XCTAssertEqual(rowViews.count, 4)
        XCTAssertEqual(rowViews.filter { $0.tint == .systemGreen }.count, 1)

        if let path = ProcessInfo.processInfo.environment["MACPERF_PROCESS_TABLE_ARTIFACTS"] {
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("process-table.png"))
        }
    }
}
