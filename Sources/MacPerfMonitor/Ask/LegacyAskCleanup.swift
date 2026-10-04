import Foundation
import MacPerfMonitorCore

/// Removes what the Ask preview left behind: the optional Qwen and DeepAnalyze
/// downloads (several gigabytes under the app's support folder) and its
/// preference keys. The redesigned Ask uses only Apple's on-device model, so
/// nothing reads these any more. Runs once per Mac, off the main thread.
enum LegacyAskCleanup {
    static let doneKey = "ask.legacyCleanupDone"

    /// Keys the preview wrote. Listed rather than prefix-matched so an
    /// unrelated future key can never be caught by accident.
    static let legacyKeys = [
        "askPreviewEnabled", "askPreviewOnDeviceAI", "askPreviewSiriSharing",
        "askPreviewBackend", "askPreviewExplanationsConsent",
    ]

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        supportDirectory: URL = MacPerfMonitorDatabase.defaultURL().deletingLastPathComponent()
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        for key in legacyKeys { defaults.removeObject(forKey: key) }
        let models = supportDirectory.appendingPathComponent("models", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.fileExists(atPath: models.path) else { return }
            do {
                try FileManager.default.removeItem(at: models)
                AppLog.ui.notice("removed the Ask preview's downloaded models")
            } catch {
                AppLog.ui.error(
                    "could not remove the Ask preview's models: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
