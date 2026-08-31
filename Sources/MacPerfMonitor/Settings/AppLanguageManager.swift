import Combine
import Foundation
import SwiftUI

/// The user's chosen display language.
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case en = "en"
    case zhHans = "zh-Hans"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "Follow System"
        case .en: return "English"
        case .zhHans: return "简体中文"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            return Locale.autoupdatingCurrent
        case .en:
            return Locale(identifier: "en")
        case .zhHans:
            return Locale(identifier: "zh-Hans")
        }
    }
}

/// Manages application-wide display language preference.
/// The UserDefaults key holding the chosen display language. Top level so the
/// non-isolated launch preflight below can read it without touching the
/// MainActor-bound manager.
let appLanguageDefaultsKey = "uk.co.bzwrd.macperfmonitor.language"

/// Re-executes the app with `-AppleLanguages` when the stored language choice
/// is not what the main bundle resolved. Writing `AppleLanguages` to the app's
/// preferences steers `Locale` but, on current macOS, not the main bundle's
/// string-table selection, so a plain relaunch after switching language in
/// Settings would come up part-translated. The launch-argument domain is
/// honored everywhere, so `main()` calls this once before the SwiftUI
/// lifecycle starts whenever a specific language is stored; the guard against
/// an existing `-AppleLanguages` argument makes a loop impossible. Detecting
/// whether the re-exec is needed is deliberately not attempted:
/// `preferredLocalizations` reports the preference-derived answer even when
/// string lookup is serving the development language, so the only reliable
/// signal is the argument itself.
enum AppLanguagePreflight {
    static func run() {
        guard !CommandLine.arguments.contains("-AppleLanguages"),
            let raw = UserDefaults.standard.string(forKey: appLanguageDefaultsKey),
            let language = AppLanguage(rawValue: raw), language != .system,
            let binary = Bundle.main.executablePath
        else { return }
        var arguments = CommandLine.arguments
        arguments.append(contentsOf: ["-AppleLanguages", "(\(language.rawValue))"])
        let argv = arguments.map { strdup($0) } + [nil]
        execv(binary, argv)
        // execv only returns on failure; continue with the mixed launch.
        argv.forEach { free($0) }
    }
}

@MainActor
final class AppLanguageManager: ObservableObject {
    static let languageDefaultsKey = appLanguageDefaultsKey

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageDefaultsKey)
            updateAppleLanguages()
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.languageDefaultsKey)
        self.language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var currentLocale: Locale {
        language.locale
    }

    private func updateAppleLanguages() {
        switch language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .en:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .zhHans:
            UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }
}

/// Injects the active application locale into a view subtree dynamically.
struct LocaleRootView<Content: View>: View {
    @ObservedObject var languageManager: AppLanguageManager
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.locale, languageManager.currentLocale)
            .environmentObject(languageManager)
    }
}
