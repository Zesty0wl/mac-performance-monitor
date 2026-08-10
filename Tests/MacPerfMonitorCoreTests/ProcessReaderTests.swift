import XCTest

@testable import MacPerfMonitorCore

final class ProcessReaderTests: XCTestCase {
    // MARK: - Process start time

    /// The process launch time is read from the kernel as split seconds +
    /// microseconds and must keep its sub-second precision. `ProcessIdentity`
    /// keys a reused PID apart by its start time, and the trace export encodes
    /// `startTime.timeIntervalSince1970.bitPattern`; dropping the microseconds
    /// collapses two distinct processes that reuse a PID within the same second.
    func testStartTimeKeepsMicrosecondPrecision() {
        let wholeSecond = ProcessReader.startDate(seconds: 1_700_000_000, microseconds: 0)
        let later = ProcessReader.startDate(seconds: 1_700_000_000, microseconds: 400_000)

        XCTAssertEqual(wholeSecond.timeIntervalSince1970, 1_700_000_000.0, accuracy: 1e-9)
        XCTAssertEqual(later.timeIntervalSince1970, 1_700_000_000.4, accuracy: 1e-9)
        // Same whole second, different microseconds -> distinct start times, so
        // two same-second PID reuses stay distinct identities.
        XCTAssertNotEqual(wholeSecond, later)
    }

    /// The full microsecond range rounds cleanly into the fractional second.
    func testStartTimeCarriesFullMicrosecondFraction() {
        let t = ProcessReader.startDate(seconds: 1_700_000_000, microseconds: 999_999)
        XCTAssertEqual(t.timeIntervalSince1970, 1_700_000_000.999_999, accuracy: 1e-9)
    }
}
