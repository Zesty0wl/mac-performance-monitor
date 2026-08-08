// SPDX-License-Identifier: MIT

import XCTest

@testable import MacPerfMonitorCore

/// Tests for `MemoryToolRunner`'s captured-output resolution. The real `run`
/// spawns a signed Apple tool and cannot reproduce a timeout-with-output case
/// deterministically, so these exercise the pure decision it delegates to
/// (`resolveResult`): the rule under test is that a timeout must win over any
/// partial stdout the child managed to print before being killed.
final class MemoryToolRunnerTests: XCTestCase {

    // The reported bug: a tool run that emits some stdout and THEN exceeds the
    // hard timeout was returned as `.success` with that partial text. A timed-
    // out run is incomplete by definition, so it must be `.failure(.timedOut)`
    // regardless of what was captured.
    func testTimeoutWithPartialOutputIsFailureNotSuccess() {
        let partial = Data("Footprint: 195 MB\n[truncated, child killed]\n".utf8)
        let result = MemoryToolRunner.resolveResult(timedOut: true, data: partial)
        XCTAssertEqual(result, .failure(.timedOut))
    }

    // Control: a timeout that captured nothing is also `.failure(.timedOut)`.
    // This case already worked before the fix (the empty-output branch consulted
    // the flag); it is kept as a regression guard for the timeout path.
    func testTimeoutWithNoOutputIsFailure() {
        let result = MemoryToolRunner.resolveResult(timedOut: true, data: Data())
        XCTAssertEqual(result, .failure(.timedOut))
    }

    // Control: a run that finished in time and produced output is `.success`
    // carrying that text. Guards the happy path so the timeout fix does not
    // regress the normal success return.
    func testSuccessfulRunReturnsText() {
        let output = Data("All zones: 202503 nodes (47995927 bytes)\n".utf8)
        let result = MemoryToolRunner.resolveResult(timedOut: false, data: output)
        XCTAssertEqual(result, .success("All zones: 202503 nodes (47995927 bytes)\n"))
    }

    // Control: a run that finished in time but printed nothing is the distinct
    // `.noOutput` failure, not a timeout. Guards against the timeout check
    // shadowing the no-output case.
    func testInTimeRunWithNoOutputIsNoOutputFailure() {
        let result = MemoryToolRunner.resolveResult(timedOut: false, data: Data())
        XCTAssertEqual(result, .failure(.noOutput))
    }
}
