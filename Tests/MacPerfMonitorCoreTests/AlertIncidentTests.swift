import XCTest

@testable import MacPerfMonitorCore

final class AlertIncidentTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func condition(
        _ value: Double = 4, severity: AlertSeverity = .warning, at offset: Double = 0
    ) -> AlertCondition {
        let date = start.addingTimeInterval(offset)
        return AlertCondition(
            Alert(
                kind: .swap, title: "Swap growth", body: "Evidence", date: date,
                severity: severity,
                evidence: AlertEvidence(
                    start: start, end: date, baseline: 3, current: value, rate: 1)),
            recoveryDelay: 60, escalationDelta: 2)
    }

    func testQuietObservationsDoNotNotifyOrCountAsActive() {
        let tracker = AlertIncidentTracker()
        XCTAssertTrue(tracker.reconcile([condition(severity: .watching)], now: start).isEmpty)
        XCTAssertTrue(tracker.active.isEmpty)
        XCTAssertEqual(tracker.observations.count, 1)
    }

    func testFurtherGrowthEscalatesWithoutReturningBelowTheOriginalValue() {
        let tracker = AlertIncidentTracker()
        XCTAssertEqual(tracker.reconcile([condition()], now: start).count, 1)
        XCTAssertTrue(
            tracker.reconcile([condition(5, at: 60)], now: start.addingTimeInterval(60)).isEmpty)
        let escalated = tracker.reconcile(
            [condition(8, at: 360)], now: start.addingTimeInterval(360))
        XCTAssertEqual(escalated.count, 1)
        XCTAssertEqual(escalated.first?.previousNotification?.current, 4)
        XCTAssertEqual(escalated.first?.previousNotification?.end, start)
        XCTAssertTrue(
            tracker.reconcile([condition(8, at: 86400)], now: start.addingTimeInterval(86400))
                .isEmpty)
        XCTAssertEqual(tracker.active.first?.evidence?.current, 8)
    }

    func testSuppressedEpisodeIsRecheckedAfterCooldown() {
        let tracker = AlertIncidentTracker()
        _ = tracker.reconcile([condition()], now: start)
        _ = tracker.reconcile([], now: start.addingTimeInterval(10))
        _ = tracker.reconcile([], now: start.addingTimeInterval(70))
        XCTAssertTrue(
            tracker.reconcile([condition(at: 120)], now: start.addingTimeInterval(120)).isEmpty)
        XCTAssertEqual(
            tracker.reconcile([condition(at: 301)], now: start.addingTimeInterval(301)).count, 1)
    }

    func testUnknownIsNotRecoveryAndRestartPreservesNotificationBaseline() throws {
        let tracker = AlertIncidentTracker()
        _ = tracker.reconcile([condition()], now: start)
        _ = tracker.reconcile(
            [], unknownIDs: ["swap.threshold"], now: start.addingTimeInterval(600))
        XCTAssertEqual(tracker.observations.first?.phase, .unknown)
        let data = try JSONEncoder().encode(tracker.snapshot)
        let restored = AlertIncidentTracker(
            snapshot: try JSONDecoder().decode(AlertIncidentTracker.Snapshot.self, from: data))
        XCTAssertTrue(
            restored.reconcile([condition(at: 700)], now: start.addingTimeInterval(700)).isEmpty)
        XCTAssertEqual(restored.active.count, 1)
    }

    func testCriticalUpgradeBypassesOrdinaryBudgetButDoesNotRepeat() {
        let tracker = AlertIncidentTracker()
        _ = tracker.reconcile([condition()], now: start)
        XCTAssertEqual(
            tracker.reconcile(
                [condition(severity: .critical, at: 2)], now: start.addingTimeInterval(2)
            ).count, 1)
        XCTAssertTrue(
            tracker.reconcile(
                [condition(severity: .critical, at: 3)], now: start.addingTimeInterval(3)
            ).isEmpty)
    }

    func testSnoozeDelaysWorseningButNotAnUrgentUpgrade() {
        let tracker = AlertIncidentTracker()
        _ = tracker.reconcile([condition()], now: start)
        tracker.snooze("swap.threshold", until: start.addingTimeInterval(3600), now: start)
        XCTAssertTrue(
            tracker.reconcile([condition(8, at: 600)], now: start.addingTimeInterval(600)).isEmpty)
        XCTAssertEqual(
            tracker.reconcile(
                [condition(8, severity: .critical, at: 601)], now: start.addingTimeInterval(601)
            ).count, 1)
    }

    func testFailedDeliveryRetriesAfterCooldownWithoutNewGrowth() {
        let tracker = AlertIncidentTracker()
        _ = tracker.reconcile([condition()], now: start)
        tracker.deliveryFailed(
            ["swap.threshold"], attemptedAt: start, now: start.addingTimeInterval(1))
        XCTAssertTrue(tracker.reconcile([condition()], now: start.addingTimeInterval(100)).isEmpty)
        XCTAssertEqual(
            tracker.reconcile([condition()], now: start.addingTimeInterval(302)).count, 1)
    }

    func testExpiredCheckpointDoesNotSuppressANewEpisode() {
        let tracker = AlertIncidentTracker()
        _ = tracker.reconcile([condition()], now: start)
        XCTAssertEqual(
            tracker.reconcile([condition(at: 8 * 86400)], now: start.addingTimeInterval(8 * 86400))
                .count, 1)
    }
}
