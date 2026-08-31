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
@MainActor
final class AppLanguageManager: ObservableObject {
    static let languageDefaultsKey = "uk.co.bzwrd.macperfmonitor.language"

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
