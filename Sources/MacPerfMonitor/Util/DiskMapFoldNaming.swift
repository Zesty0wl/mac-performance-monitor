import Foundation
import MacPerfMonitorCore

/// The display name of a small-files fold ("1,234 small images"), localized.
/// Kind labels are localization keys, so the label is resolved through the
/// strings table before being dropped into the sentence.
enum DiskMapFoldNaming {
    static func name(count: UInt32, kind: FileKind) -> String {
        let formatted = count.formatted()
        guard kind != .other else {
            return String(format: String(localized: "%@ small items"), formatted)
        }
        let label = String(localized: String.LocalizationValue(kind.label)).localizedLowercase
        return String(format: String(localized: "%1$@ small %2$@"), formatted, label)
    }
}
