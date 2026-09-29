import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class NetworkMenuLayoutTests: XCTestCase {
    func testConnectionSummarySizeStaysFixedDuringUpdates() async {
        _ = NSApplication.shared
        for width in [320.0, 336, 380, 440] {
            let host = NSHostingView(rootView: states[0].frame(width: width))
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: width, height: 180),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for state in states + [states[0]] {
                host.rootView = state.frame(width: width)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 0.5)
                XCTAssertEqual(host.fittingSize.height, NetworkMenuSummary.height, accuracy: 0.5)
            }
        }
    }

    func testMissingNetworkMeasurementsStayDistinctFromZero() {
        for invalid in [Double?.none, -.infinity, .infinity, .nan, -1] {
            XCTAssertEqual(NetworkMenuSummary.millisecondsText(invalid), "--")
            XCTAssertEqual(NetworkMenuSummary.lossText(invalid), "--")
            XCTAssertEqual(NetworkMenuSummary.rateText(invalid), "--")
        }
        XCTAssertEqual(NetworkMenuSummary.millisecondsText(0), "0.0 ms")
        XCTAssertEqual(NetworkMenuSummary.millisecondsText(12.34), "12.3 ms")
        XCTAssertEqual(NetworkMenuSummary.lossText(0), "0%")
        XCTAssertEqual(NetworkMenuSummary.lossText(0.25), "25%")
        XCTAssertEqual(NetworkMenuSummary.lossText(1), "100%")
        XCTAssertEqual(NetworkMenuSummary.lossText(1.1), "--")
        XCTAssertEqual(NetworkMenuSummary.rateText(0), ByteFormat.rate(0))
    }

    func testAppListReservesSixRowsWhileActivityChanges() async {
        _ = NSApplication.shared
        for width in [336.0, 380] {
            let host = NSHostingView(
                rootView: NetworkMenuAppList(processes: []).frame(width: width))
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: width, height: 200),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for samples in appStates {
                host.rootView = NetworkMenuAppList(processes: samples).frame(width: width)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 0.5)
                XCTAssertEqual(host.fittingSize.height, NetworkMenuAppList.height, accuracy: 0.5)
            }
        }
    }

    func testNetworkSectionKeepsFollowingContentInPlace() async throws {
        _ = NSApplication.shared
        for width in [336.0, 380] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: section(states[0], processes: [], width: width))
                let window = NSWindow(
                    contentRect: CGRect(x: 100, y: 100, width: width + 24, height: 400),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                let initialSize = host.fittingSize
                for (index, state) in states.enumerated() {
                    let samples = appStates[index % appStates.count]
                    host.rootView = section(state, processes: samples, width: width)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.fittingSize.width, initialSize.width, accuracy: 0.5)
                    XCTAssertEqual(host.fittingSize.height, initialSize.height, accuracy: 0.5)
                    window.setContentSize(initialSize)
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try capture(host, name: "network-\(Int(width))-\(appearance.rawValue)-\(index)")
                }
            }
        }
    }

    private func section(
        _ summary: NetworkMenuSummary, processes: [ProcessSample], width: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            Divider()
            NetworkMenuAppList(processes: processes)
            Divider()
            Text("Open Network").font(.caption)
        }
        .frame(width: width)
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appStates: [[ProcessSample]] {
        let samples = (0..<8).map(process)
        var invalid = samples[0]
        invalid.networkBytesPerSec = .nan
        return [[], [samples[0]], Array(samples.prefix(6)), samples, [invalid], []]
    }

    private func process(_ index: Int) -> ProcessSample {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ProcessSample(
            timestamp: timestamp, pid: Int32(1000 + index), ppid: 1,
            name: index == 0
                ? "Network client with a long application name" : "Network client \(index + 1)",
            physFootprint: 0, residentSize: 0, virtualSize: 0, lifetimeMaxFootprint: 0,
            cpuPercent: 0, cpuTimeUser: 0, cpuTimeSystem: 0, threadCount: 1,
            fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0, fdOther: 0,
            diskBytesRead: 0, diskBytesWritten: 0,
            networkBytesPerSec: pow(1024, Double(index % 4)) * Double(index + 1),
            isTranslated: false, architecture: .arm64, startTime: timestamp, uid: 501,
            dataSource: .directUserRead, footprintReadable: true)
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MACPERF_NETWORK_MENU_ARTIFACTS"]
        else { return }
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let bytes = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent(name + ".png"))
    }

    private var states: [NetworkMenuSummary] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let idle = NetworkSample(timestamp: now, primaryInterface: "en0", localIPv4: "192.168.1.5")
        let busy = NetworkSample(
            timestamp: now, inBytesPerSec: 999 * 1024 * 1024,
            outBytesPerSec: 3 * 1024 * 1024 * 1024,
            sessionInBytes: UInt64.max, sessionOutBytes: UInt64.max,
            primaryInterface: "en12", localIPv4: "255.255.255.255")
        let longInterface = NetworkSample(
            timestamp: now, primaryInterface: "External USB Ethernet adapter with a long name",
            localIPv4: "192.168.100.100")
        return [
            NetworkMenuSummary(network: nil, latencyMs: nil, jitterMs: nil, packetLoss: nil),
            NetworkMenuSummary(network: idle, latencyMs: 0, jitterMs: nil, packetLoss: 0),
            NetworkMenuSummary(network: busy, latencyMs: 12345.6, jitterMs: 9999, packetLoss: 0.75),
            NetworkMenuSummary(network: idle, latencyMs: nil, jitterMs: nil, packetLoss: 1),
            NetworkMenuSummary(
                network: NetworkSample(timestamp: now), latencyMs: .nan, jitterMs: .infinity,
                packetLoss: .nan),
            NetworkMenuSummary(
                network: longInterface, latencyMs: 12.3, jitterMs: 0.5, packetLoss: 0),
        ]
    }
}
