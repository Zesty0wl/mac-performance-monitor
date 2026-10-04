import AppIntents
import Foundation
import MacPerfMonitorCore

/// Whether Ask is offered: macOS 27 or later, and not turned off in Settings.
enum AskAvailability {
    static let enabledKey = "askEnabled"

    static var systemSupports: Bool {
        if #available(macOS 27.0, *) { return true }
        return false
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: true])
    }

    static func isOffered(enabled: Bool) -> Bool { systemSupports && enabled }
}

/// Siri and Shortcuts can open Ask. They receive nothing from it: no readings,
/// summaries or answers.
struct OpenAskIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask About This Mac"
    static var description = IntentDescription(
        "Open Ask About This Mac to find out how your Mac is doing in plain words.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WindowOpenBridge.shared.open(id: WindowID.ask)
        return .result()
    }
}

struct AskShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenAskIntent(),
            phrases: [
                "Ask \(.applicationName)", "Check my Mac with \(.applicationName)",
                "How is my Mac doing in \(.applicationName)",
            ],
            shortTitle: "Ask About This Mac", systemImageName: "sparkles")
    }
}
