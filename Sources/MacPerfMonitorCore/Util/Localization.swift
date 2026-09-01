import Foundation

/// Look up `key` in the interface language the user chose in Settings.
///
/// SwiftUI already resolves every string *literal* it is handed: `Text("Free")`,
/// `Label("General", systemImage:)` and friends take a `LocalizedStringKey`, and
/// the environment locale that `AppLanguageManager` installs picks the `.lproj`
/// for them. Nothing here is needed for those.
///
/// This exists for the strings SwiftUI never sees as keys: values that reach the
/// screen as a plain `String`, from a model enum's `label`, a lookup table of
/// field names, or a template assembled before it is displayed. `Text(someString)`
/// binds to the `StringProtocol` overload, which renders verbatim and never
/// consults the table, so those stayed in English however complete the
/// translation looked. Routing them through `t(_:)` is what closes that gap:
///
///   * `HardwareLabel.label(forKey:)`, one call for ~370 property names
///   * `HardwareProperty.init`, one call for every field label in the inventory
///   * `CheckCatalog.template`, translating before it substitutes so the
///     `{probe}` tokens survive
///   * the model enums: `PressureLevel`, `ThermalPressureState`,
///     `TaxonomyCategory`, `GPUWorkloadCategory`, `HistoryWindow`, `ConsumerMetric`
///
/// A missing entry returns the key, which IS the English original, so an
/// untranslated string shows in English rather than blank. Outside an app bundle
/// (the CLI, the privileged helper, the test runner) there is no `.lproj` to
/// find, so everything degrades to English by the same path.
///
/// Not for anything that is stored, exported or compared: see the note on
/// `Architecture.label`, which must stay English because it is serialised into
/// `.mpmtrace` files that move between machines.
public func t(_ key: String) -> String {
    LocalizationTable.current.localizedString(forKey: key, value: key, table: nil)
}

/// Translate a `String(format:)` template and fill it in.
///
/// The key keeps its `%@` placeholders so a translation can reorder them with
/// `%1$@` / `%2$@`, which Chinese frequently must. Anything that inflects has to
/// live inside the key rather than arrive as an argument: splicing an English
/// fragment (" is" / "es are") into a sentence cannot survive translation.
public func t(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: t(key), arguments: arguments)
}

/// The `.lproj` bundle `t(_:)` reads, cached until the language changes.
///
/// Resolved from the same `UserDefaults` key `AppLanguageManager` writes, so the
/// Settings picker drives this without the two needing to know about each other.
/// `Bundle.main` is the fallback, and is also the right answer for "Follow
/// System": it already honours the Mac's preferred-language list, and after the
/// launch preflight re-executes with `-AppleLanguages` it resolves to the chosen
/// language on its own.
private enum LocalizationTable {
    private static let lock = NSLock()
    private static var cached: (language: String, bundle: Bundle)?

    static var current: Bundle {
        let choice = UserDefaults.standard.string(forKey: appLanguageDefaultsKey) ?? "system"
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.language == choice { return cached.bundle }
        let resolved = bundle(for: choice)
        cached = (choice, resolved)
        return resolved
    }

    private static func bundle(for choice: String) -> Bundle {
        guard choice != "system",
            let path = Bundle.main.path(forResource: choice, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return Bundle.main }
        return bundle
    }
}

/// The defaults key `AppLanguageManager` stores the chosen language under.
///
/// Duplicated as a literal rather than imported: `AppLanguageManager` lives in
/// the app target, which depends on this one, so Core cannot refer to it. The
/// app target's `appLanguageDefaultsKey` is the same string, and a test pins
/// them together.
let appLanguageDefaultsKey = "uk.co.bzwrd.macperfmonitor.language"
