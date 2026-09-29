import Foundation
import MacPerfMonitorCore
import XCTest

@testable import MacPerfMonitor

final class AlertNotificationTests: XCTestCase {
    func testAccessoryNoticeIsQuietGroupedAndOpensEnergy() throws {
        let device = AccessoryBattery(
            id: "group:private-device-id", name: "AirPods Pro", kind: .headphones,
            parts: [
                .init(component: .left, percent: 10, isCharging: false),
                .init(component: .right, percent: 15, isCharging: false),
                .init(component: .chargingCase, percent: 90, isCharging: false),
            ])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var tracker = AccessoryBatteryAlertTracker()
        _ = tracker.evaluate([device], now: now)
        let alert = try XCTUnwrap(tracker.evaluate([device], now: now.addingTimeInterval(60)).first)
        let request = try XCTUnwrap(AccessoryBatteryNotification.request(for: alert))
        XCTAssertEqual(request.content.title, "Low battery: AirPods Pro")
        XCTAssertEqual(request.content.body, "macOS reports Left: 10%, Right: 15%.")
        XCTAssertNil(request.content.sound)
        XCTAssertNil(request.trigger)
        XCTAssertTrue(AlertUserInfo.opensEnergy(from: request.content.userInfo))
        XCTAssertNil(AlertUserInfo.investigation(from: request.content.userInfo))
        XCTAssertNil(AlertUserInfo.identity(from: request.content.userInfo))
        XCTAssertFalse(request.identifier.contains(device.id))
        XCTAssertEqual(
            request.identifier, AccessoryBatteryNotification.request(for: alert)?.identifier)
        XCTAssertFalse(AlertUserInfo.opensEnergy(from: [:]))
    }

    func testRelatedMemoryAlertsShareOneNoticeAndCarryTheEvidenceWindow() throws {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = ProcessIdentity(pid: 100, startTime: time.addingTimeInterval(-600))
        let rows = [
            Alert(
                kind: .swap, title: "Swap growth", body: "3 to 4 GiB", date: time,
                evidence: AlertEvidence(
                    start: time.addingTimeInterval(-300), end: time, baseline: 3, current: 4)),
            Alert(
                kind: .leak, title: "Process growth", body: "Growing", identity: identity,
                date: time),
            Alert(
                kind: .highCPU, title: "Watching", body: "Quiet", date: time, severity: .watching),
        ]
        let batches = AlertNotification.batches(rows)
        XCTAssertEqual(batches.count, 1)
        let batch = try XCTUnwrap(batches.first)
        XCTAssertFalse(batch.isCritical)
        XCTAssertEqual(batch.incidentIDs.count, 2)
        let payload = AlertUserInfo.payload(for: batch)
        let request = try XCTUnwrap(AlertUserInfo.investigation(from: payload))
        XCTAssertEqual(request.identities, [identity])
        XCTAssertEqual(request.time, time)
        XCTAssertLessThanOrEqual(request.start, time.addingTimeInterval(-300))
        XCTAssertGreaterThanOrEqual(request.end, time)
    }

    func testCriticalNoticeKeepsItsUrgencyAndLegacyProcessLinksWork() throws {
        let time = Date()
        let identity = ProcessIdentity(pid: 123, startTime: time)
        XCTAssertEqual(AlertUserInfo.identity(from: AlertUserInfo.payload(for: identity)), identity)
        let batch = try XCTUnwrap(
            AlertNotification.batches([
                Alert(
                    kind: .criticalPressure, title: "Critical", body: "Pressure", date: time,
                    severity: .critical)
            ]).first)
        XCTAssertTrue(batch.isCritical)
        XCTAssertNil(AlertUserInfo.investigation(from: [:]))
    }
}
