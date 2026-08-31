import AppKit
import Darwin
import Foundation

enum FullDiskAccessStatus: Equatable {
    case granted
    case notGranted
    /// Neither probe path exists on this account; assume nothing and never nag.
    case unknown
}

/// Tracks whether the app holds Full Disk Access, the one grant the Disk Map
/// needs for a complete scan. FDA is a TCC decision made out of process in
/// System Settings, keyed to the code signature, and it applies to a running
/// app only after it relaunches; this manager probes without ever prompting,
/// re-probes on activation like `HelperManager`, and remembers that the user
/// was sent to Settings so the page can offer a relaunch.
///
/// Main-thread only (SwiftUI actions and app delegate callbacks), the same
/// convention as `HelperManager`.
final class FullDiskAccessManager: ObservableObject {
    @Published private(set) var status: FullDiskAccessStatus = .unknown
    /// True after the user opened Settings and the grant has not shown up in
    /// this process yet, which is what a fresh grant looks like until relaunch.
    @Published private(set) var awaitingRelaunch = false

    private var openedSettingsAt: Date?
    private static let relaunchWindow: TimeInterval = 30 * 60

    init() {
        refresh()
    }

    var isGranted: Bool { status == .granted }

    /// Re-probe. Called at launch, on activation, and after Settings opens.
    func refresh() {
        let probed = Self.probe()
        status = probed
        if probed == .granted {
            awaitingRelaunch = false
            openedSettingsAt = nil
        } else if let openedSettingsAt,
            Date().timeIntervalSince(openedSettingsAt) < Self.relaunchWindow
        {
            awaitingRelaunch = true
        }
    }

    /// The Privacy and Security pane, Full Disk Access list.
    func openSystemSettings() {
        openedSettingsAt = Date()
        awaitingRelaunch = status != .granted
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        AppLog.ui.notice("Full Disk Access settings opened")
    }

    /// The Files and Folders list, for a Desktop / Documents / Downloads
    /// prompt the user declined earlier.
    func openFilesAndFoldersSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    /// Quit and reopen so a fresh grant applies. `open` runs after a short
    /// delay from a detached shell so the new instance starts once this one
    /// has exited (`LSMultipleInstancesProhibited` refuses a second copy while
    /// the first is still up). The bundle path is passed as an argument, not
    /// interpolated, so a space in `/Applications/Mac Performance Monitor.app`
    /// cannot break the command.
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try process.run()
            AppLog.ui.notice("relaunching for Full Disk Access")
            NSApp.terminate(nil)
        } catch {
            AppLog.ui.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The standard probe: TCC's own database is readable only with the grant
    /// (EPERM without it). If it is missing on this account, Safari's folder is
    /// the second-best signal. Neither call can trigger a prompt.
    static func probe() -> FullDiskAccessStatus {
        let home = NSHomeDirectory()
        let tcc = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = Darwin.open(tcc, O_RDONLY | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        if errno == EPERM { return .notGranted }
        if let dir = opendir(home + "/Library/Safari") {
            closedir(dir)
            return .granted
        }
        return errno == EPERM ? .notGranted : .unknown
    }
}
