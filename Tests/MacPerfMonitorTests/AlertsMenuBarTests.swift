import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class AlertsMenuBarTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_950_400)

    func testBadgeOpensAlertsEvenWhenNoDisplayedMetricIsAlarmed() {
        let readouts = [CombinedMenuBarReadout(metric: .cpu, value: "15%", isAlarm: false)]
        for presentation in MenuBarPresentation.allCases {
            XCTAssertEqual(
                CombinedStatusItemController.panel(
                    at: NSPoint(x: 118, y: 11),
                    imageRect: NSRect(x: 4, y: 0, width: 100, height: 22),
                    alertRect: NSRect(x: 110, y: 0, width: 24, height: 22),
                    readouts: readouts, presentation: presentation), .alerts)
            XCTAssertEqual(
                CombinedStatusItemController.panel(
                    at: NSPoint(x: 30, y: 11),
                    imageRect: NSRect(x: 4, y: 0, width: 100, height: 22),
                    alertRect: NSRect(x: 110, y: 0, width: 24, height: 22),
                    readouts: readouts, presentation: presentation), .metric(.cpu))
        }
    }

    func testAlertGroupsKeepProcessIdentitiesAndMachineConditionsSeparate() {
        let first = ProcessIdentity(pid: 100, startTime: date)
        let reused = ProcessIdentity(pid: 100, startTime: date.addingTimeInterval(60))
        let alerts = [
            Alert(kind: .leak, title: "Leak", body: "Growing", identity: first, date: date),
            Alert(
                kind: .processCeiling, title: "Ceiling", body: "Above limit", identity: first,
                date: date),
            Alert(kind: .leak, title: "Leak", body: "Growing", identity: reused, date: date),
            Alert(kind: .criticalPressure, title: "Pressure", body: "Critical", date: date),
            Alert(
                kind: .thermalThrottle, title: "Thermal", body: "Top CPU is context",
                identity: first, date: date),
        ]
        let groups = MenuBarAlertGroup.groups(alerts: alerts, processes: [])
        XCTAssertEqual(groups.count, 3)
        XCTAssertNil(groups[0].identity)
        XCTAssertEqual(Set(groups[0].alerts.map(\.kind)), [.criticalPressure, .thermalThrottle])
        XCTAssertEqual(groups.first(where: { $0.identity == first })?.alerts.count, 2)
        XCTAssertEqual(groups.first(where: { $0.identity == reused })?.alerts.count, 1)
        XCTAssertEqual(groups.flatMap(\.alerts).count, alerts.count)
        XCTAssertTrue(MenuBarAlertGroup.groups(alerts: [], processes: []).isEmpty)
    }

    func testHighGPUConditionMarksTheGPUReadout() {
        XCTAssertTrue(MenuBarMetric.gpu.isAlarm(in: [.highGPU]))
        XCTAssertFalse(MenuBarMetric.gpu.isAlarm(in: [.highCPU]))
    }

    func testMenuUsesTheRecordedProcessNameWithoutACurrentSample() {
        let identity = ProcessIdentity(pid: 100, startTime: date)
        let alert = Alert(
            kind: .leak, title: "Possible memory leak", body: "Growing steadily",
            identity: identity, processName: "Build service", executablePath: "/tmp/build-service",
            date: date)
        let group = MenuBarAlertGroup.groups(alerts: [alert], processes: []).first
        XCTAssertEqual(group?.name, "Build service")
        XCTAssertEqual(group?.identity, identity)
        XCTAssertEqual(group?.executablePath, "/tmp/build-service")
    }

    func testAlertsPanelKeepsABoundedHeightWithManyAlerts() throws {
        _ = NSApplication.shared
        let alerts = (0..<30).map { index in
            Alert(
                kind: .leak, title: "Possible memory leak",
                body: "A process has been growing steadily and may be leaking memory.",
                identity: ProcessIdentity(pid: Int32(100 + index), startTime: date),
                processName: "Build service with a long process name \(index + 1)", date: date)
        }
        let machine = Alert(
            kind: .criticalPressure, title: "Memory pressure is critical",
            body:
                "Your Mac is under heavy memory pressure. Closing a few large apps will give it room.",
            date: date)
        for (name, rows, appearance) in [
            ("alerts-light", [machine] + alerts, NSAppearance.Name.aqua),
            ("alerts-dark", [machine] + alerts, .darkAqua),
            ("alerts-empty", [], .aqua),
        ] {
            let host = NSHostingView(
                rootView: AlertsMenuBarContentView(
                    alerts: rows, processes: [], openProcess: { _ in }
                )
                .frame(width: 380).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 380, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, 320, accuracy: 1)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            if let directory = ProcessInfo.processInfo.environment["MACPERF_ALERT_ARTIFACTS"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: root.appendingPathComponent("\(name).png"))
            }
        }
    }

    func testObservationAndSnoozeStatesHaveTheSameBoundedLayout() throws {
        _ = NSApplication.shared
        let tracker = AlertIncidentTracker()
        let start = Date(timeIntervalSince1970: 1_788_950_400)
        var active = Alert(
            kind: .swap, title: "Swap is growing rapidly",
            body: "Usage grew from 21 GB to 26 GB in five minutes and is still rising.",
            date: start,
            evidence: AlertEvidence(
                start: start.addingTimeInterval(-300), end: start, baseline: 21, current: 26))
        active.snoozedUntil = Date().addingTimeInterval(3600)
        let watched = Alert(
            kind: .leak, title: "Sustained memory growth", body: "Modest growth under observation.",
            identity: ProcessIdentity(pid: 100, startTime: start), processName: "Build service",
            date: start, severity: .watching)
        _ = tracker.reconcile([AlertCondition(watched)], now: start)
        let stale = Alert(kind: .highGPU, title: "GPU activity", body: "Unavailable", date: start)
        _ = tracker.reconcile([AlertCondition(watched), AlertCondition(stale)], now: start)
        _ = tracker.reconcile(
            [AlertCondition(watched)], unknownIDs: [stale.id], now: start.addingTimeInterval(1))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(
                rootView: AlertsMenuBarContentView(
                    alerts: [active], processes: [],
                    observations: tracker.observations, inspectAlert: { _ in }, snooze: { _, _ in },
                    openProcess: { _ in }
                )
                .frame(width: 380).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 380, height: 320),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 380, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, 320, accuracy: 1)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["MACPERF_ALERT_ARTIFACTS"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: root.appendingPathComponent("adaptive-\(appearance.rawValue).png"))
            }
        }
    }
}
