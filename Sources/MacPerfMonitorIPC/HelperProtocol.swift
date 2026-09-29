import Foundation

/// Stable identifiers shared by the app and the privileged helper. Centralised
/// here so the LaunchDaemon plist, the Mach service, the SMAppService
/// registration, and the code-signing checks can never drift apart.
public enum HelperConstants {
    /// Reverse-DNS label used for the LaunchDaemon, its Mach service name, and
    /// (with the `.plist` suffix) the SMAppService registration plist.
    public static let machServiceName = "uk.co.bzwrd.macperfmonitor.helper"

    /// File name of the LaunchDaemon property list bundled under
    /// `Contents/Library/LaunchDaemons/`, passed to `SMAppService.daemon`.
    public static let daemonPlistName = "uk.co.bzwrd.macperfmonitor.helper.plist"

    /// Bundle identifier of the app, pinned by the helper when it validates a
    /// connecting client.
    public static let appBundleIdentifier = "uk.co.bzwrd.macperfmonitor"

    /// Build the code-signing requirement used to pin the *peer* of an XPC
    /// connection. The peer must carry the given code `identifier`, be anchored
    /// to Apple (`anchor apple generic`), and belong to the **same Apple
    /// Developer team as this running process** — the team is read from our own
    /// signature at runtime (`ownTeamIdentifier`) rather than hardcoded, so a
    /// clone signed with any developer's certificate works unchanged. The app
    /// and helper are always co-signed, so their teams match.
    ///
    /// Returns nil when the running code has no team identifier — an ad-hoc or
    /// unsigned local build. Callers treat nil as "do not pin", so a locally
    /// built app and helper still connect for development on any machine. This
    /// is safe in practice: a distributed build is always Developer ID signed
    /// and therefore always has a team, so the pin is always enforced in
    /// release; only a deliberately ad-hoc dev build, on the developer's own
    /// machine, runs the root helper unpinned.
    public static func peerRequirement(forIdentifier identifier: String) -> String? {
        guard let team = ownTeamIdentifier() else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }
}

/// The XPC interface the root helper exposes to the app. It is deliberately
/// small and every connection is pinned to the genuine app's code signature
/// (`peerRequirement(forIdentifier:)`) before any request is served, so no other
/// process can drive the root daemon.
///
/// Most methods only *read* process data. The one mutating method,
/// `terminateProcess`, is tightly constrained: it accepts only `SIGTERM` and
/// `SIGKILL`, refuses pid <= 1, and signals exactly one process (never a process
/// group), so even though it runs as root it cannot be turned into a
/// general-purpose signal-injection tool.
///
/// `runMemoryTool` lets the caller pick only *which* of a fixed set of
/// Apple-signed tools to run (by enum raw value), never the path or arguments,
/// and the sole variable — the PID — is validated and passed as its own
/// argument with no shell, so it cannot be turned into arbitrary code execution.
/// `readANEPower` uses a fixed powermetrics command with no caller arguments.
/// Each client holds a short lease; the shared subprocess stops when leases end.
///
/// PIDs are boxed as `NSNumber` for the Objective-C XPC bridge, and reads reply
/// with JSON-encoded value types (`[RawProcessRead]`, `[OpenFileDescriptor]`,
/// both encoded in `MacPerfMonitorCore`) so the custom types never need
/// NSSecureCoding plumbing.
@objc public protocol MacPerfMonitorHelperProtocol {
    /// Read whatever root can for the given PIDs, replying with JSON-encoded
    /// `[RawProcessRead]`, or `nil` if encoding failed.
    func readProcesses(_ pids: [NSNumber], reply: @escaping (Data?) -> Void)

    /// List a process's open file descriptors as root, replying with
    /// JSON-encoded `[OpenFileDescriptor]` (possibly empty), or `nil` if
    /// encoding failed. Lets the app inspect descriptors for system and
    /// other-user processes the unprivileged reader cannot see.
    func listFileDescriptors(_ pid: NSNumber, reply: @escaping (Data?) -> Void)

    /// Send a termination signal to a process as root. `signal` must be
    /// `SIGTERM` or `SIGKILL`; any other value, or pid <= 1, is rejected. The
    /// reply is `0` on success or the POSIX `errno` (for example `ESRCH` if the
    /// process had already exited). Lets the app force-quit system and
    /// other-user processes the user cannot signal directly.
    func terminateProcess(_ pid: NSNumber, signal: NSNumber, reply: @escaping (Int32) -> Void)

    /// Run one of the allow-listed Apple memory tools (`footprint`, `heap`,
    /// `leaks`) against a PID as root, replying with its combined stdout/stderr
    /// as UTF-8 `Data`, or `nil` on failure. `tool` is a `MemoryInspection.Tool`
    /// raw value; the helper rejects any value outside that enum and any pid <= 1,
    /// then runs only the fixed absolute binary path that enum maps to — it never
    /// trusts a caller-supplied command string. Lets the app's memory inspector
    /// examine system and other-user processes it cannot read unprivileged
    /// (the tools carry the `com.apple.system-task-ports` entitlement, so as root
    /// they can attach where a direct read is denied).
    func runMemoryTool(_ tool: NSNumber, pid: NSNumber, reply: @escaping (Data?) -> Void)

    func readANEPower(reply: @escaping @Sendable (Data?) -> Void)
    func stopANEPower(reply: @escaping () -> Void)

    /// Liveness and version probe.
    func ping(reply: @escaping (String) -> Void)

    /// Ask the root daemon to exit so an app update can replace its binary
    /// cleanly. Sparkle (and `install.sh`) only know about the app bundle, not
    /// this LaunchDaemon, so the app calls this just before an update installs —
    /// mirroring the pkg installer's `preinstall`. The reply is sent immediately
    /// before the daemon exits; the new helper binary is demand-launched on the
    /// next connection. The SMAppService registration and the user's approval are
    /// untouched.
    func terminateForUpdate(reply: @escaping () -> Void)
}
