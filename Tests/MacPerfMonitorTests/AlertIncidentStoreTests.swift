import Foundation
import MacPerfMonitorCore
import XCTest

@testable import MacPerfMonitor

final class AlertIncidentStoreTests: XCTestCase {
    func testCheckpointRoundTripPreservesNotificationBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AlertIncidentStore(
            url: directory.appendingPathComponent("alerts/incidents.json"))
        XCTAssertNil(try store.load())
        let now = Date()
        let tracker = AlertIncidentTracker()
        let condition = AlertCondition(
            MacPerfMonitorCore.Alert(kind: .swap, title: "Growth", body: "Evidence", date: now))
        _ = tracker.reconcile([condition], now: now)
        let saved = expectation(description: "checkpoint saved")
        store.save(tracker.snapshot) { result in
            if case .failure(let error) = result { XCTFail(String(describing: error)) }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        let restored = AlertIncidentTracker(snapshot: try XCTUnwrap(store.load()))
        XCTAssertTrue(restored.reconcile([condition], now: now.addingTimeInterval(600)).isEmpty)
        XCTAssertEqual(restored.active.count, 1)
    }
}
