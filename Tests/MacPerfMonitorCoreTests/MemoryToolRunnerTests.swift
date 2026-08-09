// SPDX-License-Identifier: MIT

import XCTest

@testable import MacPerfMonitorCore

/// `MemoryToolRunner` is the one place the project execs a subprocess, so its
/// timeout/output decision is safety-relevant: a run that is killed for exceeding
/// the hard timeout must report failure even if the child managed to write some
/// stdout before it died, otherwise a wedged run is misreported as a complete,
/// successful result. The public `run` resolves a fixed Apple tool path, which
/// cannot be made to hang on cue, so these tests drive the internal `capture`
/// seam with a `/bin/sh -c` stub script: the same Process machinery, just a
/// program we control.
final class MemoryToolRunnerTests: XCTestCase {

    /// Small enough that the timeout cases finish in a couple of seconds while
    /// still exercising the real wait/kill path.
    private let timeoutSeconds: TimeInterval = 2

    private func capture(script: String) -> Result<String, MemoryToolRunner.RunError> {
        MemoryToolRunner.capture(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            label: "stub",
            pid: 99_999,
            timeout: timeoutSeconds,
            maxBytes: 8 * 1024 * 1024)
    }

    func testTimeoutWithPartialOutputIsFailureNotSuccess() {
        // Prints one line, then outlives the timeout. The child was killed for
        // timing out, so the result must be .timedOut even though it captured
        // partial stdout before it died.
        let result = capture(script: "printf 'partial output line one\\n'; sleep 30")

        switch result {
        case .failure(.timedOut):
            break
        case .failure(let error):
            XCTFail("expected .failure(.timedOut), got .failure(\(error))")
        case .success(let text):
            XCTFail("expected .failure(.timedOut), got .success(\"\(text)\")")
        }
    }

    func testFastSuccessfulRunReturnsCapturedOutput() {
        // Finishes well within the timeout, so it is a genuine success that
        // carries everything the child printed.
        let result = capture(script: "printf 'full output\\n'")

        switch result {
        case .success(let text):
            XCTAssertEqual(text, "full output\n")
        case .failure(let error):
            XCTFail("expected .success, got .failure(\(error))")
        }
    }

    func testTimeoutWithNoOutputIsFailure() {
        // Hangs without printing anything. The empty-output timeout path must
        // keep returning .timedOut (regression guard for the empty-output branch).
        let result = capture(script: "sleep 30")

        switch result {
        case .failure(.timedOut):
            break
        case .failure(let error):
            XCTFail("expected .failure(.timedOut), got .failure(\(error))")
        case .success(let text):
            XCTFail("expected .failure(.timedOut), got .success(\"\(text)\")")
        }
    }

    func testFastRunWithNoOutputIsNoOutputFailure() {
        // Exits at once without printing anything (the `:` shell builtin is a
        // no-op): a clean run that produced no output is .noOutput, distinct
        // from a timeout. Guards that the timeout-precedence change did not
        // swallow the genuine no-output failure.
        let result = capture(script: ":")

        switch result {
        case .failure(.noOutput):
            break
        case .failure(let error):
            XCTFail("expected .failure(.noOutput), got .failure(\(error))")
        case .success(let text):
            XCTFail("expected .failure(.noOutput), got .success(\"\(text)\")")
        }
    }
}
