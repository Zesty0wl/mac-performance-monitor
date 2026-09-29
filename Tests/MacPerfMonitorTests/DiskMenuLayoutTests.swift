import AppKit
import SwiftUI
import XCTest

@testable import MacPerfMonitor
@testable import MacPerfMonitorCore

@MainActor
final class DiskMenuLayoutTests: XCTestCase {
    func testDeviceRowSizeStaysFixedAsActivityAndWarningsChange() async {
        _ = NSApplication.shared
        for width in [320.0, 380, 440] {
            let host = NSHostingView(
                rootView: DiskMenuDeviceRow(device: device()).frame(width: width))
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: width, height: 150),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for sample in states {
                host.rootView = DiskMenuDeviceRow(device: sample).frame(width: width)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 0.5)
                XCTAssertEqual(host.fittingSize.height, DiskMenuDeviceRow.height, accuracy: 0.5)
            }
        }
    }

    func testMissingServiceTimeDoesNotBecomeZero() {
        XCTAssertEqual(DiskMenuDeviceRow.serviceTimeText(nil), "--")
        XCTAssertEqual(DiskMenuDeviceRow.serviceTimeText(.nan), "--")
        XCTAssertEqual(DiskMenuDeviceRow.serviceTimeText(.infinity), "--")
        XCTAssertEqual(DiskMenuDeviceRow.serviceTimeText(-1), "--")
        XCTAssertEqual(DiskMenuDeviceRow.serviceTimeText(0), "0.00 ms")
        XCTAssertEqual(DiskMenuDeviceRow.serviceTimeText(12.345), "12.35 ms")
    }

    func testPhysicalDeviceSectionKeepsFollowingContentInPlace() async throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: section(device()))
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: 404, height: 180),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let initialSize = host.fittingSize
            for (index, sample) in states.enumerated() {
                host.rootView = section(sample)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, initialSize.width, accuracy: 0.5)
                XCTAssertEqual(host.fittingSize.height, initialSize.height, accuracy: 0.5)
                window.setContentSize(initialSize)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try capture(host, name: "device-\(appearance.rawValue)-\(index)")
            }
        }
    }

    private func section(_ sample: DiskDeviceSample) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Physical devices").font(.caption).foregroundStyle(.secondary)
            DiskMenuDeviceRow(device: sample)
            Divider().padding(.vertical, 5)
            Text("Process-attributed I/O").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 380)
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MACPERF_DISK_MENU_ARTIFACTS"]
        else { return }
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let bytes = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent(name + ".png"))
    }

    private var states: [DiskDeviceSample] {
        let idle = device()
        var reading = idle
        reading.readBytesPerSec = 999 * 1024 * 1024
        reading.averageReadTimeMilliseconds = 0.12
        var writing = idle
        writing.writeBytesPerSec = 3 * 1024 * 1024 * 1024
        writing.averageWriteTimeMilliseconds = 12.34
        var warnings = writing
        warnings.readErrors = UInt64.max
        warnings.writeErrors = UInt64.max
        warnings.readRetries = UInt64.max
        warnings.writeRetries = UInt64.max
        warnings.averageReadTimeMilliseconds = 12345.67
        var unknown = idle
        unknown.model = "External RAID array with a very long manufacturer and product name"
        unknown.protocolName = nil
        unknown.sizeBytes = nil
        unknown.isInternal = nil
        var invalid = idle
        invalid.readBytesPerSec = .nan
        invalid.writeBytesPerSec = .infinity
        return [idle, reading, writing, warnings, unknown, invalid, idle]
    }

    private func device() -> DiskDeviceSample {
        DiskDeviceSample(
            registryEntryID: 1, bsdName: "disk0", model: "APPLE SSD AP0512Z",
            protocolName: "Apple Fabric", sizeBytes: 512 * 1024 * 1024 * 1024,
            isInternal: true, isRemovable: false, readBytesPerSec: 0, writeBytesPerSec: 0,
            readOperationsPerSec: 0, writeOperationsPerSec: 0,
            averageReadTimeMilliseconds: nil, averageWriteTimeMilliseconds: nil,
            readErrors: 0, writeErrors: 0, readRetries: 0, writeRetries: 0)
    }
}
