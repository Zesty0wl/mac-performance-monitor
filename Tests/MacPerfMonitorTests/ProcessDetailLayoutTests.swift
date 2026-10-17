import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class ProcessDetailLayoutTests: XCTestCase {
    func testChangingProcessesKeepsTheInspectorScrollViewAndViewport() async throws {
        _ = NSApplication.shared
        for width in [MainWindowSize.minimumWidth, 1280, 1891] {
            try await checkSelectionChanges(width: width)
        }
    }

    private func checkSelectionChanges(width: CGFloat) async throws {
        let store = ChartBenchmark.ProcessScenarioStore(
            options: .init(arguments: ["--points", "50", "--interval", "1"]))
        store.prewarm(3)
        var snapshot = try XCTUnwrap(store.model.latest)
        snapshot.processes = Array(snapshot.processes.prefix(4))
        let names = [
            "Microsoft Teams WebView Helper (Renderer)", "WindowServer",
            "com.apple.icom.apple.registerassistantservice",
            "A process with a very long name that must not widen the inspector",
        ]
        for index in snapshot.processes.indices {
            snapshot.processes[index].name = names[index]
            snapshot.processes[index].executablePath =
                "/Applications/\(names[index]).app/Contents/MacOS/\(names[index])"
        }
        store.model.publishForBenchmark(snapshot)
        let identities = Array(store.model.displayProcesses.map(\.id).prefix(4))
        XCTAssertEqual(identities.count, 4)
        let selection = Selection(identity: try XCTUnwrap(identities.first))
        let host = NSHostingView(
            rootView: Harness(selection: selection)
                .environmentObject(store.model)
                .environment(\.samplerModel, store.model)
                .environmentObject(store.appState)
                .environmentObject(store.helper)
                .environmentObject(store.monitor)
                .environmentObject(store.groupStore)
                .environmentObject(store.components))
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: width, height: 720),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let original = try inspector(in: host)
        let viewport = original.convert(original.bounds, to: host)
        XCTAssertEqual(viewport.width, 360, accuracy: 0.5)
        XCTAssertLessThanOrEqual(viewport.maxX, host.bounds.width - 12 + 0.5)
        let table = try XCTUnwrap(
            scrollViews(in: host).first { $0.documentView is NSOutlineView })
        let tableFrame = table.convert(table.bounds, to: host)
        XCTAssertLessThanOrEqual(tableFrame.maxX, viewport.minX - 12 + 0.5)
        for identity in identities.dropFirst() + identities.prefix(1) {
            original.contentView.scroll(to: CGPoint(x: 0, y: 200))
            original.reflectScrolledClipView(original.contentView)
            XCTAssertGreaterThan(original.contentView.bounds.minY, 0)
            selection.identity = identity
            host.layoutSubtreeIfNeeded()
            for _ in 0..<25 {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
                let current = try inspector(in: host)
                XCTAssertTrue(
                    current === original,
                    "selection must not recreate the scroll view and reset its scrollbar")
                XCTAssertEqual(current.convert(current.bounds, to: host), viewport)
                XCTAssertEqual(table.convert(table.bounds, to: host), tableFrame)
                XCTAssertLessThanOrEqual(
                    try XCTUnwrap(current.documentView).bounds.width,
                    current.contentSize.width + 0.5)
            }
            XCTAssertEqual(original.contentView.bounds.minY, 0, accuracy: 0.5)
            let charts = chartSurfaces(in: original)
            XCTAssertEqual(charts.count, 5)
            XCTAssertTrue(charts.allSatisfy(\.rasterizesDrawing))
            XCTAssertTrue(charts.allSatisfy(\.scrubbable))
        }
        try capture(window, width: width)
    }

    private final class Selection: ObservableObject {
        @Published var identity: ProcessIdentity?
        init(identity: ProcessIdentity) { self.identity = identity }
    }

    private struct Harness: View {
        @ObservedObject var selection: Selection

        var body: some View {
            ProcessesTab(selection: $selection.identity, didAutoSelect: .constant(true))
        }
    }

    private func inspector(in root: NSView) throws -> NSScrollView {
        return try XCTUnwrap(
            scrollViews(in: root).max {
                $0.convert($0.bounds, to: root).minX < $1.convert($1.bounds, to: root).minX
            })
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func chartSurfaces(in view: NSView) -> [TrendSurfaceView] {
        (view as? TrendSurfaceView).map { [$0] } ?? view.subviews.flatMap(chartSurfaces)
    }

    private func capture(_ window: NSWindow, width: CGFloat) throws {
        guard let path = ProcessInfo.processInfo.environment["MACPERF_PROCESS_LAYOUT_ARTIFACTS"]
        else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [
            "-x", "-o", "-l", String(window.windowNumber),
            directory.appendingPathComponent("processes-\(Int(width)).png").path,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
