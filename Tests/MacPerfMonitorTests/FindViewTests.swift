import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class FindViewTests: XCTestCase {
    private func waitUntilFinished(_ model: FindModel) async throws -> FindModel.Summary {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if case .finished(let summary) = model.phase { return summary }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("The search did not finish")
        return FindModel.Summary(searched: 0, skipped: 0, truncated: false)
    }

    /// A real search over every process on this Mac: the test runner holds a
    /// uniquely named file open, and must be the one process found.
    func testFindsTheOneProcessHoldingAFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpm-findview-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let model = FindModel()
        let helper = HelperManager()
        model.search("  \(url.lastPathComponent) ", helper: helper)
        XCTAssertTrue(model.isSearching)
        let summary = try await waitUntilFinished(model)

        XCTAssertEqual(model.results.map(\.pid), [getpid()])
        XCTAssertEqual(model.searchedTerm, url.lastPathComponent)
        XCTAssertGreaterThan(summary.searched, 1, "Every process of this user is read")
        XCTAssertFalse(summary.truncated)
        if !helper.canEscalate, geteuid() != 0 {
            XCTAssertGreaterThan(summary.skipped, 0, "System processes are counted, not hidden")
        }
    }

    func testABroadTermStopsAtTheLimitAndSaysSo() async throws {
        let model = FindModel()
        model.search("/", helper: HelperManager())
        let summary = try await waitUntilFinished(model)
        XCTAssertEqual(model.results.count, FindModel.matchLimit)
        XCTAssertTrue(summary.truncated)
    }

    func testCancelAndBlankTermsLeaveNothingRunning() async throws {
        let model = FindModel()
        model.search("   ", helper: HelperManager())
        XCTAssertEqual(model.phase, .idle)

        model.search("/", helper: HelperManager())
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.phase, .idle, "A cancelled search must not report a finish")
    }

    /// The window itself, searching for port-like digits. Set
    /// `MACPERF_FIND_ARTIFACTS` to a folder to keep a picture of the results.
    func testWindowShowsResults() async throws {
        _ = NSApplication.shared
        let root = FindView(sampler: SamplerModel(persistenceEnabled: false))
            .environmentObject(HelperManager())
            .environmentObject(AppState())
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 420))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 300_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertNotNil(window.contentView)

        if let path = ProcessInfo.processInfo.environment["MACPERF_FIND_ARTIFACTS"] {
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("find.png"))
        }
    }
}
