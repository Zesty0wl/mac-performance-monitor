import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class LeakBoardTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    private let startTime = Date(timeIntervalSince1970: 1_000_000)
    private let mb: UInt64 = 1024 * 1024

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-leakboard-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private func insertTick(_ timestamp: Date, _ processes: [ProcessSample]) throws {
        try store.insert(
            Sampler.Snapshot(
                system: Make.system(timestamp: timestamp),
                processes: processes,
                unreadableProcessCount: 0))
    }

    /// A deliberately leaky process must be flagged while a stable one and a
    /// too-short-lived one are not. This is the M6 acceptance criterion.
    func testLeakBoardFlagsLeakyProcessOnly() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spacing = 20.0
        let count = 70  // 70 samples over 1380 s (23 min) — past the 20-minute duration floor

        for i in 0..<count {
            let ts = base.addingTimeInterval(Double(i) * spacing)
            // Leaky: +4 MB every step (≈200 KB/s), perfectly linear.
            let leaky = Make.process(
                timestamp: ts, pid: 1000, startTime: startTime,
                name: "Leaky", footprint: (100 + UInt64(i) * 4) * mb)
            // Stable: flat, never flagged.
            let stable = Make.process(
                timestamp: ts, pid: 2000, startTime: startTime,
                name: "Stable", footprint: 100 * mb)
            var processes = [leaky, stable]
            // Short-lived fast riser: present for only the first 5 ticks, so it
            // never reaches the minimum sample count / duration.
            if i < 5 {
                processes.append(
                    Make.process(
                        timestamp: ts, pid: 4000, startTime: startTime,
                        name: "Brief", footprint: (200 + UInt64(i) * 10) * mb))
            }
            try insertTick(ts, processes)
        }

        let now = base.addingTimeInterval(Double(count - 1) * spacing)
        let board = try store.leakBoard(now: now)

        XCTAssertEqual(board.count, 1, "only the leaky process should be flagged")
        let flagged = try XCTUnwrap(board.first)
        XCTAssertEqual(flagged.identity.pid, 1000)
        XCTAssertEqual(flagged.name, "Leaky")
        XCTAssertFalse(
            board.contains { $0.identity.pid == 2000 }, "stable process must not be flagged")
        XCTAssertFalse(
            board.contains { $0.identity.pid == 4000 }, "short-lived process must not be flagged")

        // The finding should reflect the synthetic ~200 KB/s slope and high fit.
        XCTAssertGreaterThan(flagged.finding.slopeBytesPerSecond, 8 * 1024)
        XCTAssertEqual(
            flagged.finding.slopeBytesPerSecond, 4 * Double(mb) / spacing, accuracy: 5_000)
        XCTAssertGreaterThan(flagged.finding.rSquared, 0.99)
        XCTAssertGreaterThan(flagged.finding.confidence, 0)
        XCTAssertEqual(flagged.latestFootprint, (100 + UInt64(count - 1) * 4) * mb)
    }

    func testLeakBoardSortsMostConfidentFirst() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spacing = 20.0
        let count = 70  // ~23 min span — past the 20-minute duration floor

        for i in 0..<count {
            let ts = base.addingTimeInterval(Double(i) * spacing)
            // Clean linear leak (high R²).
            let clean = Make.process(
                timestamp: ts, pid: 1000, startTime: startTime,
                name: "Clean", footprint: (100 + UInt64(i) * 4) * mb)
            // Noisy leak: same trend with a small alternating wobble (lower R²).
            let wobble: UInt64 = (i % 2 == 0) ? 0 : 6
            let noisy = Make.process(
                timestamp: ts, pid: 3000, startTime: startTime,
                name: "Noisy", footprint: (100 + UInt64(i) * 4 + wobble) * mb)
            try insertTick(ts, [clean, noisy])
        }

        let now = base.addingTimeInterval(Double(count - 1) * spacing)
        let board = try store.leakBoard(now: now)

        XCTAssertEqual(board.count, 2)
        XCTAssertEqual(board.first?.identity.pid, 1000, "the cleaner trend should rank first")
        XCTAssertGreaterThanOrEqual(board[0].finding.confidence, board[1].finding.confidence)
    }

    func testLeakBoardEmptyWithoutData() throws {
        let board = try store.leakBoard(now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(board.isEmpty)
    }

    /// An established slow leak must be flagged from the minute aggregates:
    /// the growth here ended 20 minutes before "now", outside the raw fast
    /// path's window, so only the minute tier can see it.
    func testLeakBoardDoesNotFlagAnEstablishedTrendWithoutFreshEvidence() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spacing = 60.0
        let count = 80  // 80 minutes of +2 MB/min growth, ~35 KB/s

        for i in 0..<count {
            let ts = base.addingTimeInterval(Double(i) * spacing)
            try insertTick(
                ts,
                [
                    Make.process(
                        timestamp: ts, pid: 1000, startTime: startTime,
                        name: "SlowLeak", footprint: (100 + UInt64(i) * 2) * mb)
                ])
        }

        let now = base.addingTimeInterval(100 * 60)
        try Retention.run(store.databasePool, now: now)

        let board = try store.leakBoard(now: now)
        XCTAssertTrue(board.isEmpty)
    }
}
