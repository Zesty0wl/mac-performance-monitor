// SPDX-License-Identifier: MIT
import XCTest

@testable import MacPerfMonitorCore

final class LowDiskSpaceAlertTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let gb: UInt64 = 1024 * 1024 * 1024
    private var tick = 0

    /// Only the low-space rule, so other default-on alerts cannot interfere.
    private let config = AlertConfig(
        criticalPressureEnabled: false, leakEnabled: false, sustainedProcessCPUEnabled: false,
        lowDiskSpaceEnabled: true, lowDiskSpaceThresholdPercent: 10)

    /// A 200 GB startup disk with `freePercent` strictly free and, when given,
    /// `availablePercent` available once purgeable space is counted.
    private func system(
        freePercent: Double?, availablePercent: Double? = nil, total: UInt64? = nil
    ) -> SystemSample {
        tick += 1
        var sample = Make.system(timestamp: start.addingTimeInterval(Double(tick) * 2))
        let capacity = total ?? 200 * gb
        sample.bootVolumeTotalBytes = freePercent == nil ? nil : capacity
        sample.bootVolumeFreeBytes = freePercent.map { UInt64(Double(capacity) * $0 / 100) }
        sample.bootVolumeAvailableBytes = availablePercent.map {
            UInt64(Double(capacity) * $0 / 100)
        }
        return sample
    }

    private func evaluate(_ engine: AlertEngine, _ sample: SystemSample) -> [Alert] {
        engine.evaluate(system: sample, processes: [], config: config)
    }

    func testFiresOnceBelowThresholdAndClearsOnlyPastTheMargin() {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        XCTAssertTrue(evaluate(engine, system(freePercent: 15)).isEmpty)

        let fired = evaluate(engine, system(freePercent: 9))
        XCTAssertEqual(fired.map(\.kind), [.lowDiskSpace])
        XCTAssertEqual(fired.first?.severity, .warning)
        XCTAssertEqual(fired.first?.id, "disk.low")
        XCTAssertEqual(fired.first?.evidence?.unit, "percent")
        XCTAssertEqual(fired.first?.evidence?.current ?? 0, 9, accuracy: 0.01)

        // Staying low does not repeat the notification.
        XCTAssertTrue(evaluate(engine, system(freePercent: 8.5)).isEmpty)
        XCTAssertTrue(engine.activeKinds.contains(.lowDiskSpace))

        // Back above 10% but inside the 2-point margin: still open, so a disk
        // hovering at the line does not alert over and over.
        _ = evaluate(engine, system(freePercent: 11))
        XCTAssertTrue(engine.activeKinds.contains(.lowDiskSpace))
        XCTAssertTrue(evaluate(engine, system(freePercent: 9.5)).isEmpty)

        // Clear of the margin: resolved, and a later drop alerts again.
        _ = evaluate(engine, system(freePercent: 12.5))
        XCTAssertFalse(engine.activeKinds.contains(.lowDiskSpace))
        XCTAssertEqual(evaluate(engine, system(freePercent: 9)).map(\.kind), [.lowDiskSpace])
    }

    func testBecomesCriticalBelowHalfTheThresholdAndNotifiesAgain() {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        XCTAssertEqual(evaluate(engine, system(freePercent: 8)).first?.severity, .warning)
        let critical = evaluate(engine, system(freePercent: 4))
        XCTAssertEqual(critical.map(\.kind), [.lowDiskSpace])
        XCTAssertEqual(critical.first?.severity, .critical)
        XCTAssertEqual(critical.first?.title, "Startup disk is almost full")
    }

    func testPurgeableSpaceCountsAsAvailable() {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        // statfs says 5% free, but Finder's Available (with purgeable caches
        // and snapshots) says 20%: no alert, as Finder would not worry either.
        XCTAssertTrue(evaluate(engine, system(freePercent: 5, availablePercent: 20)).isEmpty)
        XCTAssertFalse(engine.activeKinds.contains(.lowDiskSpace))
        XCTAssertEqual(
            evaluate(engine, system(freePercent: 5, availablePercent: 7)).map(\.kind),
            [.lowDiskSpace])
    }

    func testMissingReadingNeitherFiresNorClearsAnOpenAlert() {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        XCTAssertTrue(evaluate(engine, system(freePercent: nil)).isEmpty)
        XCTAssertFalse(engine.activeKinds.contains(.lowDiskSpace))

        _ = evaluate(engine, system(freePercent: 6))
        _ = evaluate(engine, system(freePercent: nil))
        XCTAssertEqual(
            engine.incidentSnapshot.incidents["disk.low"]?.phase, .unknown,
            "an unreadable disk is unknown, not recovered")
    }

    func testDisabledNeverFires() {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        var off = config
        off.lowDiskSpaceEnabled = false
        XCTAssertTrue(
            engine.evaluate(system: system(freePercent: 1), processes: [], config: off).isEmpty)
        XCTAssertFalse(off.anyEnabled)
    }

    func testThresholdFollowsTheSetting() {
        let engine = AlertEngine(refireCooldown: 0, notificationSpacing: 0)
        var twenty = config
        twenty.lowDiskSpaceThresholdPercent = 20
        XCTAssertEqual(
            engine.evaluate(system: system(freePercent: 15), processes: [], config: twenty)
                .map(\.kind), [.lowDiskSpace])
    }

    func testDefaultsAndSettingsSavedByOlderVersions() throws {
        XCTAssertTrue(AlertConfig.default.lowDiskSpaceEnabled)
        XCTAssertEqual(AlertConfig.default.lowDiskSpaceThresholdPercent, 10)
        XCTAssertEqual(AlertIncidentTracker.family(.lowDiskSpace), "disk")

        // Saved before this alert existed, with the default alerts on: on.
        let upgraded = try JSONDecoder().decode(
            AlertConfig.self, from: Data(#"{"criticalPressureEnabled":true}"#.utf8))
        XCTAssertTrue(upgraded.lowDiskSpaceEnabled)
        XCTAssertEqual(upgraded.lowDiskSpaceThresholdPercent, 10)

        // Someone who had turned every default alert off keeps a quiet app.
        let quiet = try JSONDecoder().decode(
            AlertConfig.self,
            from: Data(#"{"criticalPressureEnabled":false,"leakEnabled":false}"#.utf8))
        XCTAssertFalse(quiet.lowDiskSpaceEnabled)

        for (saved, expected) in [(1, 5), (90, 25), (15, 15)] {
            let data = try JSONSerialization.data(
                withJSONObject: ["lowDiskSpaceThresholdPercent": saved])
            XCTAssertEqual(
                try JSONDecoder().decode(AlertConfig.self, from: data)
                    .lowDiskSpaceThresholdPercent, expected)
        }

        var configured = config
        configured.lowDiskSpaceThresholdPercent = 20
        XCTAssertEqual(
            try JSONDecoder().decode(AlertConfig.self, from: JSONEncoder().encode(configured)),
            configured)
    }

    func testBootVolumeUsableSpacePrefersFindersFigure() {
        var capacity = BootVolumeReader.Capacity(totalBytes: 100, freeBytes: 10)
        XCTAssertEqual(capacity.usableBytes, 10)
        capacity.availableBytes = 30
        XCTAssertEqual(capacity.usableBytes, 30)
    }

    func testLiveBootVolumeAvailableIsAtLeastFree() throws {
        let capacity = try XCTUnwrap(BootVolumeReader().read(now: Date()))
        let available = try XCTUnwrap(
            capacity.availableBytes, "the startup volume reports Finder's Available figure")
        XCTAssertGreaterThanOrEqual(available, capacity.freeBytes)
        XCTAssertLessThanOrEqual(available, capacity.totalBytes)
    }
}
