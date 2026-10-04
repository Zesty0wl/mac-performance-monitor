// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import XCTest

@testable import MacPerfMonitor
@testable import MacPerfMonitorCore

@MainActor
final class DisplayCaptureInsightTests: XCTestCase {
    func testCaptureAdvisoryFitsNativeCardsAtNarrowAndWideWidths() throws {
        _ = NSApplication.shared
        let model = SamplerModel(persistenceEnabled: false)
        let appState = AppState()
        let insight = captureInsight()
        for width in [340.0, 520.0] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(
                    rootView: InsightCard(insight: insight)
                        .environmentObject(model)
                        .environmentObject(appState)
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color(nsColor: .windowBackgroundColor)))
                let size = host.fittingSize
                XCTAssertEqual(size.width, width, accuracy: 1)
                XCTAssertGreaterThan(size.height, 70)
                XCTAssertLessThan(size.height, 340)
                let window = NSWindow(
                    contentRect: CGRect(x: 100, y: 100, width: width, height: size.height),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                XCTAssertGreaterThan(image.pixelsWide, 0)
                XCTAssertGreaterThan(image.pixelsHigh, 0)
                if let path = ProcessInfo.processInfo.environment["MACPERF_CAPTURE_ARTIFACTS"] {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(
                            to: directory.appendingPathComponent(
                                "capture-\(Int(width))-\(appearance.rawValue).png"))
                }
            }
        }
    }

    private func captureInsight() -> InsightEngine.Insight {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let helper = ProcessSample(
            timestamp: now, pid: 42, ppid: 1, name: "SkyComputerUseService",
            physFootprint: 0, residentSize: 0, virtualSize: 0, lifetimeMaxFootprint: 0,
            cpuPercent: 16, cpuTimeUser: 0, cpuTimeSystem: 0, threadCount: 1,
            fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0, fdOther: 0,
            diskBytesRead: 0, diskBytesWritten: 0,
            isTranslated: false, architecture: .arm64, startTime: now, uid: 501,
            dataSource: .directUserRead, footprintReadable: true)
        return InsightEngine.insights(
            InsightEngine.Inputs(
                now: now, totalRAM: 128 * 1024 * 1024 * 1024, currentPressure: .normal,
                systemHistory: [], leaks: [], events: [], consumers: [], consumerSeries: [:],
                rosetta: RosettaCost(processCount: 0, totalFootprint: 0),
                displayCapture: DisplayCaptureLoad.Finding(
                    windowServer: helper, replayd: helper, windowServerCPU: 93, replayCPU: 6,
                    helper: helper, helperCPU: 16))
        )
        .first { $0.kind == .displayCapture }!
    }
}
