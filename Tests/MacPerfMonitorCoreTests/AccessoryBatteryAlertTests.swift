import XCTest

@testable import MacPerfMonitorCore

final class AccessoryBatteryAlertTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func device(
        _ percent: Int?, charging: Bool? = nil, connected: Bool? = nil,
        stable: Bool = true, id: String = "mouse"
    ) -> AccessoryBattery {
        AccessoryBattery(
            id: id, name: "Mouse", kind: .mouse,
            parts: [.init(component: .battery, percent: percent, isCharging: charging)],
            hasStableIdentity: stable, isConnected: connected)
    }

    func testNeedsTwoMinuteSpacedLowReadsAndNotifiesOnlyOnce() {
        var tracker = AccessoryBatteryAlertTracker()
        XCTAssertTrue(tracker.evaluate([device(20)], now: start).isEmpty)
        XCTAssertTrue(tracker.evaluate([device(20)], now: start.addingTimeInterval(59)).isEmpty)
        XCTAssertEqual(tracker.evaluate([device(19)], now: start.addingTimeInterval(60)).count, 1)
        for seconds in [120.0, 180, 3600] {
            XCTAssertTrue(
                tracker.evaluate([device(5)], now: start.addingTimeInterval(seconds)).isEmpty)
        }
    }

    func testFailureMissingDeviceAndLongPauseInterruptConfirmation() {
        for missing: [AccessoryBattery]? in [
            nil, [], [device(nil)], [device(10, connected: false)],
        ] {
            var tracker = AccessoryBatteryAlertTracker()
            XCTAssertTrue(tracker.evaluate([device(10)], now: start).isEmpty)
            XCTAssertTrue(tracker.evaluate(missing, now: start.addingTimeInterval(60)).isEmpty)
            XCTAssertTrue(
                tracker.evaluate([device(10)], now: start.addingTimeInterval(120)).isEmpty)
            XCTAssertEqual(
                tracker.evaluate([device(10)], now: start.addingTimeInterval(180)).count, 1)
        }
        var tracker = AccessoryBatteryAlertTracker()
        _ = tracker.evaluate([device(10)], now: start)
        XCTAssertTrue(tracker.evaluate([device(10)], now: start.addingTimeInterval(3600)).isEmpty)
    }

    func testChargingUnknownLevelsAndUnstableIdentitiesCannotTrigger() {
        let ignored = [
            device(10, charging: true), device(nil, id: "unknown"), device(-1, id: "negative"),
            device(101, id: "invalid"), device(10, stable: false, id: "temporary"),
            device(10, connected: false, id: "disconnected"),
        ]
        var tracker = AccessoryBatteryAlertTracker()
        XCTAssertTrue(tracker.evaluate(ignored, now: start).isEmpty)
        XCTAssertTrue(tracker.evaluate(ignored, now: start.addingTimeInterval(60)).isEmpty)
    }

    func testGroupingRequiresTheSameComponentToBeLowTwice() {
        func headphones(left: Int, right: Int, caseCharge: Int) -> AccessoryBattery {
            AccessoryBattery(
                id: "headphones", name: "AirPods", kind: .headphones,
                parts: [
                    .init(component: .left, percent: left, isCharging: false),
                    .init(component: .right, percent: right, isCharging: false),
                    .init(component: .chargingCase, percent: caseCharge, isCharging: true),
                ])
        }
        var tracker = AccessoryBatteryAlertTracker()
        _ = tracker.evaluate([headphones(left: 10, right: 50, caseCharge: 5)], now: start)
        XCTAssertTrue(
            tracker.evaluate(
                [headphones(left: 50, right: 10, caseCharge: 5)],
                now: start.addingTimeInterval(60)
            ).isEmpty)
        let alerts = tracker.evaluate(
            [headphones(left: 10, right: 10, caseCharge: 5)], now: start.addingTimeInterval(120))
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.parts.map(\.component), [.left, .right])
    }

    func testSuppressionSurvivesRestartFailureDisconnectAndChargingUntilRecovery() throws {
        var original = AccessoryBatteryAlertTracker()
        _ = original.evaluate([device(20)], now: start)
        XCTAssertEqual(original.evaluate([device(20)], now: start.addingTimeInterval(60)).count, 1)
        var tracker = AccessoryBatteryAlertTracker(storedState: try XCTUnwrap(original.storedState))
        let states: [[AccessoryBattery]?] = [
            nil, [], [device(5, connected: false)], [device(10, charging: true)], [device(24)],
            [device(nil)], [device(10)],
        ]
        for (index, state) in states.enumerated() {
            XCTAssertTrue(
                tracker.evaluate(state, now: start.addingTimeInterval(Double(index + 2) * 60))
                    .isEmpty)
        }
        XCTAssertTrue(tracker.evaluate([device(25)], now: start.addingTimeInterval(600)).isEmpty)
        XCTAssertTrue(tracker.evaluate([device(20)], now: start.addingTimeInterval(660)).isEmpty)
        XCTAssertEqual(tracker.evaluate([device(20)], now: start.addingTimeInterval(720)).count, 1)
    }

    func testMissingPreviouslyReportedPartDoesNotRearm() {
        var headphones = device(10)
        headphones.parts = [
            .init(component: .left, percent: 10, isCharging: false),
            .init(component: .right, percent: 50, isCharging: false),
        ]
        var tracker = AccessoryBatteryAlertTracker()
        _ = tracker.evaluate([headphones], now: start)
        _ = tracker.evaluate([headphones], now: start.addingTimeInterval(60))
        var incomplete = headphones
        incomplete.parts = [.init(component: .right, percent: 100, isCharging: false)]
        _ = tracker.evaluate([incomplete], now: start.addingTimeInterval(120))
        XCTAssertTrue(tracker.evaluate([headphones], now: start.addingTimeInterval(180)).isEmpty)
        XCTAssertTrue(tracker.evaluate([headphones], now: start.addingTimeInterval(240)).isEmpty)
    }

    func testFailedDeliveryCanRetryAfterConfirmation() throws {
        var tracker = AccessoryBatteryAlertTracker()
        _ = tracker.evaluate([device(10)], now: start)
        let alert = try XCTUnwrap(
            tracker.evaluate([device(10)], now: start.addingTimeInterval(60)).first)
        tracker.notificationFailed(alert)
        XCTAssertTrue(tracker.evaluate([device(10)], now: start.addingTimeInterval(120)).isEmpty)
        let retry = try XCTUnwrap(
            tracker.evaluate([device(10)], now: start.addingTimeInterval(180)).first)
        XCTAssertNotEqual(retry.episodeID, alert.episodeID)
        tracker.notificationFailed(alert)
        XCTAssertTrue(tracker.evaluate([device(10)], now: start.addingTimeInterval(240)).isEmpty)
    }

    func testSeparateEarbudsCanRecoverAPreviouslyCombinedBatteryEpisode() {
        var combined = device(10)
        combined.kind = .headphones
        var separate = combined
        separate.parts = [
            .init(component: .left, percent: 50, isCharging: false),
            .init(component: .right, percent: 55, isCharging: false),
        ]
        var tracker = AccessoryBatteryAlertTracker()
        _ = tracker.evaluate([combined], now: start)
        XCTAssertEqual(tracker.evaluate([combined], now: start.addingTimeInterval(60)).count, 1)
        XCTAssertTrue(tracker.evaluate([separate], now: start.addingTimeInterval(120)).isEmpty)
        separate.parts[0].percent = 10
        XCTAssertTrue(tracker.evaluate([separate], now: start.addingTimeInterval(180)).isEmpty)
        XCTAssertEqual(tracker.evaluate([separate], now: start.addingTimeInterval(240)).count, 1)
    }

    func testSettingChangesAndDisableResetConfirmationButNotNotifiedEpisodes() {
        var tracker = AccessoryBatteryAlertTracker()
        _ = tracker.evaluate([device(20)], now: start)
        XCTAssertTrue(
            tracker.evaluate([device(20)], thresholdPercent: 25, now: start.addingTimeInterval(60))
                .isEmpty)
        tracker.resetConfirmation()
        XCTAssertTrue(tracker.evaluate([device(20)], now: start.addingTimeInterval(120)).isEmpty)
        XCTAssertEqual(tracker.evaluate([device(20)], now: start.addingTimeInterval(180)).count, 1)
        tracker.resetConfirmation()
        XCTAssertTrue(tracker.evaluate([device(20)], now: start.addingTimeInterval(240)).isEmpty)
    }

    func testCorruptAndUnsupportedStoredStateDoesNotCrash() {
        for data in [
            Data("broken".utf8), Data(#"{"version":2,"episodes":{}}"#.utf8),
            Data(repeating: 0, count: 524_289),
        ] {
            var tracker = AccessoryBatteryAlertTracker(storedState: data)
            XCTAssertTrue(tracker.evaluate([device(10)], now: start).isEmpty)
            XCTAssertEqual(
                tracker.evaluate([device(10)], now: start.addingTimeInterval(60)).count, 1)
        }
    }
}
