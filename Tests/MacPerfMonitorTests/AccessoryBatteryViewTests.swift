import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class AccessoryBatteryViewTests: XCTestCase {
    private final class Reader: AccessoryBatteryReading, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [[AccessoryBattery]?]
        private var calls = 0
        private let beforeRead: @Sendable () -> Void

        init(
            _ results: [[AccessoryBattery]?],
            beforeRead: @escaping @Sendable () -> Void = {}
        ) {
            self.results = results
            self.beforeRead = beforeRead
        }

        var count: Int { lock.withLock { calls } }

        func read() -> [AccessoryBattery]? {
            XCTAssertFalse(Thread.isMainThread)
            beforeRead()
            return lock.withLock {
                calls += 1
                return results.isEmpty ? nil : results.removeFirst()
            }
        }
    }

    private var mouse: AccessoryBattery {
        AccessoryBattery(
            id: "mouse", name: "Mouse", kind: .mouse,
            parts: [.init(component: .battery, percent: 20, isCharging: nil)])
    }

    private func completedRead(
        _ model: AccessoryBatteryModel, action: () -> Void
    ) async {
        let completed = expectation(description: "The battery read finishes")
        let subscription = model.$status.dropFirst().prefix(1).sink { _ in completed.fulfill() }
        action()
        await fulfillment(of: [completed], timeout: 5)
        subscription.cancel()
    }

    func testOptInPollsWithoutPanelAndSharesTheSameMinuteLimit() async {
        var now = 0.0
        let reader = Reader([[mouse], [mouse], [mouse]])
        let model = AccessoryBatteryModel(
            reader: reader, uptime: { now }, date: { Date(timeIntervalSince1970: now) })
        var notifications: [AccessoryBatteryAlert] = []
        model.onLowBatteryAlert = { alert, completion in
            notifications.append(alert)
            completion(true)
        }
        defer {
            model.configureAlerts(.default)
            model.stop()
        }
        await completedRead(model) {
            model.configureAlerts(AlertConfig(accessoryBatteryEnabled: true))
        }
        XCTAssertEqual(reader.count, 1)
        model.start()
        model.stop()
        now = 59
        model.refresh()
        XCTAssertEqual(reader.count, 1)
        XCTAssertTrue(notifications.isEmpty)
        now = 60
        await completedRead(model) { model.refresh() }
        XCTAssertEqual(reader.count, 2)
        XCTAssertEqual(notifications.count, 1)

        model.configureAlerts(.default)
        now = 120
        model.refresh()
        XCTAssertEqual(reader.count, 2)
        await completedRead(model) { model.start() }
        XCTAssertEqual(reader.count, 3)
        XCTAssertEqual(notifications.count, 1)
    }

    func testNotifiedEpisodesPersistAcrossModelRestarts() async throws {
        let suite = "accessory-alerts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = 0.0
        let config = AlertConfig(accessoryBatteryEnabled: true)
        let first = AccessoryBatteryModel(
            reader: Reader([[mouse], [mouse]]), uptime: { now },
            date: { Date(timeIntervalSince1970: now) }, defaults: defaults)
        var notices = 0
        first.onLowBatteryAlert = { _, completion in
            notices += 1
            completion(true)
        }
        await completedRead(first) { first.configureAlerts(config) }
        now = 60
        await completedRead(first) { first.refresh() }
        XCTAssertEqual(notices, 1)
        first.configureAlerts(.default)

        let restarted = AccessoryBatteryModel(
            reader: Reader([[mouse], [mouse]]), uptime: { now },
            date: { Date(timeIntervalSince1970: now) }, defaults: defaults)
        defer { restarted.configureAlerts(.default) }
        restarted.onLowBatteryAlert = { _, completion in
            notices += 1
            completion(true)
        }
        now = 120
        await completedRead(restarted) { restarted.configureAlerts(config) }
        now = 180
        await completedRead(restarted) { restarted.refresh() }
        XCTAssertEqual(notices, 1)
    }

    func testDisablingAlertsDuringReadPreventsDelivery() async {
        var now = 0.0
        let began = expectation(description: "Both background reads start")
        began.expectedFulfillmentCount = 2
        let gate = DispatchSemaphore(value: 0)
        gate.signal()
        let model = AccessoryBatteryModel(
            reader: Reader([[mouse], [mouse]]) {
                began.fulfill()
                _ = gate.wait(timeout: .now() + 5)
            }, uptime: { now }, date: { Date(timeIntervalSince1970: now) })
        var notices = 0
        model.onLowBatteryAlert = { _, completion in
            notices += 1
            completion(true)
        }
        await completedRead(model) {
            model.configureAlerts(AlertConfig(accessoryBatteryEnabled: true))
        }
        now = 60
        model.refresh()
        await fulfillment(of: [began], timeout: 5)
        model.configureAlerts(.default)
        await completedRead(model) { gate.signal() }
        XCTAssertEqual(notices, 0)
    }

    func testFailedNotificationSchedulingCanRetryWithoutDuplicateSuccesses() async {
        var now = 0.0
        let failed = expectation(description: "The failed callback is handled on the main queue")
        let model = AccessoryBatteryModel(
            reader: Reader([[mouse], [mouse], [mouse], [mouse], [mouse]]),
            uptime: { now }, date: { Date(timeIntervalSince1970: now) })
        defer { model.configureAlerts(.default) }
        var attempts = 0
        model.onLowBatteryAlert = { _, completion in
            attempts += 1
            if attempts == 1 {
                DispatchQueue.global().async {
                    completion(false)
                    DispatchQueue.main.async { failed.fulfill() }
                }
            } else {
                completion(true)
            }
        }
        await completedRead(model) {
            model.configureAlerts(AlertConfig(accessoryBatteryEnabled: true))
        }
        now = 60
        await completedRead(model) { model.refresh() }
        await fulfillment(of: [failed], timeout: 5)
        now = 120
        await completedRead(model) { model.refresh() }
        XCTAssertEqual(attempts, 1)
        now = 180
        await completedRead(model) { model.refresh() }
        XCTAssertEqual(attempts, 2)
        now = 240
        await completedRead(model) { model.refresh() }
        XCTAssertEqual(attempts, 2)
    }

    func testAlertSettingsPersistAndRenderInTheExistingForm() async throws {
        _ = NSApplication.shared
        let suite = "accessory-alert-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AlertSettings(defaults: defaults)
        XCTAssertFalse(settings.config.accessoryBatteryEnabled)
        XCTAssertEqual(settings.config.accessoryBatteryThresholdPercent, 20)
        settings.config.accessoryBatteryEnabled = true
        settings.config.accessoryBatteryThresholdPercent = 15
        let restored = AlertSettings(defaults: defaults)
        XCTAssertTrue(restored.config.accessoryBatteryEnabled)
        XCTAssertEqual(restored.config.accessoryBatteryThresholdPercent, 15)
        try await render(
            AlertsSettingsView().environmentObject(restored).frame(height: 536),
            width: 480, appearance: .aqua, name: "accessory-alert-settings", scrollToBottom: true)
    }

    func testMinuteLimitSurvivesRepeatedRefreshAndTabReopening() async {
        var now = 100.0
        let reader = Reader([[mouse], [mouse]])
        let model = AccessoryBatteryModel(reader: reader, uptime: { now })
        defer { model.stop() }
        await completedRead(model) { model.start() }
        XCTAssertEqual(reader.count, 1)

        model.refresh()
        now = 159.999
        model.stop()
        model.start()
        model.refresh()
        XCTAssertEqual(reader.count, 1)

        now = 160
        await completedRead(model) { model.refresh() }
        XCTAssertEqual(reader.count, 2)
        XCTAssertEqual(model.status, .ready)
    }

    func testFailuresKeepLastReportedDataAndUseTheSameRetryLimit() async {
        var now = 0.0
        let reader = Reader([[mouse], nil, []])
        let model = AccessoryBatteryModel(reader: reader, uptime: { now })
        defer { model.stop() }
        await completedRead(model) { model.start() }
        let checkedAt = model.checkedAt

        now = 60
        await completedRead(model) { model.refresh() }
        XCTAssertEqual(model.status, .unavailable)
        XCTAssertEqual(model.devices, [mouse])
        XCTAssertEqual(model.checkedAt, checkedAt)

        now = 119
        model.stop()
        model.start()
        model.refresh()
        XCTAssertEqual(reader.count, 2)

        now = 120
        await completedRead(model) { model.refresh() }
        XCTAssertEqual(reader.count, 3)
        XCTAssertEqual(model.status, .ready)
        XCTAssertTrue(model.devices.isEmpty)
    }

    func testUnavailableFirstReadDoesNotInventBatteries() async {
        let model = AccessoryBatteryModel(reader: Reader([nil]))
        defer { model.stop() }
        await completedRead(model) { model.start() }
        XCTAssertEqual(model.status, .unavailable)
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertNil(model.checkedAt)
    }

    func testStoppedAndOverlappingReadsDoNotStartAnotherCommand() async {
        var now = 0.0
        let began = expectation(description: "The background reader starts")
        let gate = DispatchSemaphore(value: 0)
        let reader = Reader([[mouse]]) {
            began.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        }
        let model = AccessoryBatteryModel(reader: reader, uptime: { now })
        defer { model.stop() }
        model.refresh()
        XCTAssertEqual(reader.count, 0)

        model.start()
        await fulfillment(of: [began], timeout: 5)
        now = 60
        model.refresh()
        now = 120
        model.stop()
        model.start()
        model.refresh()
        await completedRead(model) { gate.signal() }
        XCTAssertEqual(reader.count, 1)

        model.stop()
        now = 180
        model.refresh()
        XCTAssertEqual(reader.count, 1)
    }

    func testNativePanelFitsNarrowRailsAndFailureStates() async throws {
        _ = NSApplication.shared
        var now = 0.0
        let headphones = AccessoryBattery(
            id: "headphones", name: "AirPods Pro", kind: .headphones,
            parts: [
                .init(component: .left, percent: 79, isCharging: true),
                .init(component: .right, percent: 80, isCharging: false),
                .init(component: .chargingCase, percent: 100, isCharging: false),
            ])
        let keyboard = AccessoryBattery(
            id: "keyboard", name: "A wireless keyboard with a longer device name", kind: .keyboard,
            parts: [.init(component: .battery, percent: nil, isCharging: nil)])
        let model = AccessoryBatteryModel(
            reader: Reader([[mouse, headphones, keyboard], nil, []]), uptime: { now })
        defer { model.stop() }
        await completedRead(model) { model.start() }
        try await render(model, width: 260, appearance: .darkAqua, name: "accessories-dark")
        try await render(model, width: 240, appearance: .aqua, name: "accessories-narrow")

        now = 60
        await completedRead(model) { model.refresh() }
        try await render(model, width: 260, appearance: .darkAqua, name: "accessories-unavailable")

        now = 120
        await completedRead(model) { model.refresh() }
        try await render(model, width: 240, appearance: .aqua, name: "accessories-empty")
    }

    private func render(
        _ model: AccessoryBatteryModel, width: CGFloat, appearance: NSAppearance.Name, name: String
    ) async throws {
        try await render(
            AccessoryBatteryPanel(model: model), width: width, appearance: appearance, name: name)
    }

    private func render<Content: View>(
        _ content: Content, width: CGFloat, appearance: NSAppearance.Name, name: String,
        scrollToBottom: Bool = false
    ) async throws {
        let appeared = expectation(description: "The accessories panel appears")
        let host = NSHostingView(
            rootView:
                content
                .padding(12)
                .frame(width: width, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: width, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await fulfillment(of: [appeared], timeout: 5)
        host.layoutSubtreeIfNeeded()
        let height = ceil(host.fittingSize.height)
        XCTAssertGreaterThan(height, 70)
        XCTAssertLessThan(height, 600)
        window.setContentSize(CGSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        if scrollToBottom, let scroll = scrollView(in: host), let document = scroll.documentView {
            scroll.contentView.scroll(
                to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        window.displayIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let bytes = try XCTUnwrap(image.bitmapData)
        let byteCount = image.bytesPerRow * image.pixelsHigh
        let colors = Set(
            stride(from: 0, to: byteCount, by: image.samplesPerPixel).map { bytes[$0] })
        XCTAssertGreaterThan(colors.count, 20, "The native card must contain visible content")
        if let directory = ProcessInfo.processInfo.environment["MACPERF_ACCESSORY_ARTIFACTS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent(name + ".png"))
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}
