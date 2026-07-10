import Darwin
import Foundation
import os.log

/// Securely executes one of the allow-listed Apple memory tools against a target
/// PID and returns its combined stdout/stderr text. Shared by the app (for the
/// user's own processes) and the root helper (for system / other-user processes
/// the app cannot examine unprivileged).
///
/// Security posture — this is the one place the project execs a subprocess, and
/// in the helper it runs as root, so it is deliberately constrained:
///   * The executable is a FIXED absolute path chosen by `MemoryInspection.Tool`
///     (`/usr/bin/footprint|heap|leaks`), never assembled from caller input, so
///     a caller can pick only *which* sanctioned tool to run, not *what* to run.
///   * The only variable is the PID, validated `> 1` and passed as its own
///     argument (never interpolated into a shell line), so it cannot inject
///     further flags or commands. No shell is involved at all.
///   * Output is capped and the child is killed on a hard timeout, so a wedged
///     or pathological target cannot exhaust memory or hang the daemon.
public enum MemoryToolRunner {
    public enum RunError: Error, Equatable {
        case invalidPID
        case launchFailed(String)
        case timedOut
        case noOutput
    }

    private static let log = Logger(
        subsystem: "uk.co.bzwrd.macperfmonitor", category: "memtool")

    /// Run `tool` against `pid`, returning the captured text.
    ///
    /// - Parameters:
    ///   - timeout: hard wall-clock limit; the child is terminated if exceeded.
    ///   - maxBytes: cap on captured output; the child is stopped once reached.
    public static func run(
        _ tool: MemoryInspection.Tool,
        pid: Int32,
        timeout: TimeInterval = 30,
        maxBytes: Int = 8 * 1024 * 1024
    ) -> Result<String, RunError> {
        guard pid > 1 else { return .failure(.invalidPID) }

        // Spawn inside an autoreleasepool so the Process/Pipe/FileHandle file
        // descriptors are reclaimed when this returns rather than at the calling
        // context's next pool drain — the same descriptor-leak guard the per-tick
        // spawners use (see NetworkProcessReader.runOneShot). Belt-and-braces here
        // (this is user-action only, not a hot loop), but keeps the pattern uniform.
        return autoreleasepool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool.executablePath)
            process.arguments = tool.arguments(pid: pid)

            // Combine stdout and stderr: the tools print their data to stdout and
            // their privilege/usage errors to stderr, and the caller wants to see
            // both (so "cannot examine ... try as root" can become real guidance).
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }

            do {
                try process.run()
            } catch {
                log.error(
                    "launch \(tool.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                return .failure(.launchFailed(error.localizedDescription))
            }

            // Drain only after launch succeeds. Starting this reader first makes
            // a launch failure retain the Process through the closure while the
            // pipe waits forever for EOF from its still-open writer handle.
            let bufferLock = NSLock()
            var buffer = Data()
            var hitCap = false
            let readDone = DispatchSemaphore(value: 0)
            let readHandle = pipe.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let chunk = autoreleasepool { readHandle.availableData }
                    if chunk.isEmpty { break }  // EOF: write end closed
                    bufferLock.lock()
                    let room = maxBytes - buffer.count
                    if room > 0 { buffer.append(chunk.prefix(room)) }
                    let full = buffer.count >= maxBytes
                    let firstCapHit = full && !hitCap
                    if full { hitCap = true }
                    bufferLock.unlock()
                    if firstCapHit {
                        // Keep draining after asking the child to stop. Breaking
                        // here leaves the pipe full, which can block the child
                        // and turn a bounded run into the full timeout.
                        terminateHard(process)
                    }
                }
                readDone.signal()
            }

            var timedOut = false
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                log.error(
                    "\(tool.label, privacy: .public) on pid \(pid, privacy: .public) timed out after \(timeout, privacy: .public)s"
                )
                terminateHard(process)
            }

            // Let the reader finish draining to EOF after the child exits. If a
            // resistant child survived either the cap or timeout termination,
            // make sure it is gone.
            _ = readDone.wait(timeout: .now() + 5)
            if process.isRunning { terminateHard(process) }

            bufferLock.lock()
            let data = buffer
            let capped = hitCap
            bufferLock.unlock()

            if capped {
                log.notice(
                    "\(tool.label, privacy: .public) on pid \(pid, privacy: .public) output capped at \(maxBytes, privacy: .public) bytes"
                )
            }

            let text = String(decoding: data, as: UTF8.self)
            if text.isEmpty {
                return timedOut ? .failure(.timedOut) : .failure(.noOutput)
            }
            return .success(text)
        }
    }

    /// Stop a runaway child: ask politely, then force-kill if it lingers.
    private static func terminateHard(_ process: Process) {
        process.terminate()  // SIGTERM
        let pid = process.processIdentifier
        // Give it a brief grace period, then SIGKILL if still alive.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
