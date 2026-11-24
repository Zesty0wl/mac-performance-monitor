import Combine
import Foundation
import MacPerfMonitorCore

enum MenuBarMetric: String, CaseIterable, Codable, Identifiable {
    /// The RAM read-out. Named for the pressure index it first showed; the raw
    /// value is saved in settings, so it stays. What it shows now follows
    /// `CombinedMenuBarConfiguration.memoryReadout`.
    case pressure
    case cpu
    case gpu
    case energy
    case temperature
    case network
    case disk
    /// Space left on the startup disk. Off by default; new in 2.7.
    case freeSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pressure: return t("Memory")
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .energy: return t("Energy")
        case .temperature: return t("Temperature")
        case .network: return t("Network")
        case .disk: return t("Disk")
        case .freeSpace: return t("Free Space")
        }
    }

    var shortTitle: String {
        switch self {
        case .pressure: return "RAM"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .energy: return "BAT"
        case .temperature: return "TMP"
        case .network: return "NET"
        case .disk: return "DSK"
        case .freeSpace: return "FREE"
        }
    }

    var symbolName: String {
        switch self {
        case .pressure: return "memorychip"
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .energy: return "bolt.fill"
        case .temperature: return "thermometer.medium"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .freeSpace: return "chart.pie"
        }
    }
}

/// What the RAM read-out shows, in the menu bar and in its panel.
///
/// Memory usage is the default. The pressure index only moves once macOS
/// compresses or swaps heavily, so on a Mac with plenty of RAM it read 0
/// however much was in use.
enum MemoryReadout: String, CaseIterable, Identifiable {
    /// Memory in use against installed RAM, past 100 once apps need more than
    /// the Mac has. See `MemoryUsage`.
    case usage
    /// The 0 to 100 pressure index. See docs/pressure-index.md.
    case pressure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage: return t("Memory Usage")
        case .pressure: return t("Memory Pressure")
        }
    }

    func percent(of system: SystemSample) -> Double {
        switch self {
        case .usage: return system.memoryUsagePercent
        case .pressure: return system.pressurePercent
        }
    }

    /// The figure as the read-outs print it, such as "68%". Capped at 999 so
    /// the menu bar cell keeps its width.
    func text(for system: SystemSample) -> String {
        "\(Int(min(percent(of: system), 999).rounded()))%"
    }
}

enum MenuBarPresentation: String, CaseIterable, Identifiable {
    case focus
    case strip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: return t("Focus")
        case .strip: return t("Strip")
        }
    }
}

final class CombinedMenuBarConfiguration: ObservableObject {
    static let selectionDefaultsKey = "combinedMenuBarMetrics"
    static let presentationDefaultsKey = "combinedMenuBarPresentation"
    static let focusDefaultsKey = "combinedMenuBarFocus"
    static let memoryReadoutDefaultsKey = "combinedMenuBarMemoryReadout"
    private static let legacyCPUKey = "showCPUMenuBar"
    private static let legacyGPUKey = "showGPUMenuBar"
    private static let legacyEnergyKey = "showBatteryMenuBar"
    private static let legacyNetworkKey = "showNetworkMenuBar"

    @Published private(set) var selectedMetrics: [MenuBarMetric]
    @Published var presentation: MenuBarPresentation {
        didSet { defaults.set(presentation.rawValue, forKey: Self.presentationDefaultsKey) }
    }
    @Published var focusedMetric: MenuBarMetric {
        didSet { defaults.set(focusedMetric.rawValue, forKey: Self.focusDefaultsKey) }
    }
    @Published var memoryReadout: MemoryReadout {
        didSet { defaults.set(memoryReadout.rawValue, forKey: Self.memoryReadoutDefaultsKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let loadedMetrics = Self.loadSelection(from: defaults)
        let savedFocus =
            defaults.string(forKey: Self.focusDefaultsKey)
            .flatMap(MenuBarMetric.init(rawValue:))
        self.defaults = defaults
        selectedMetrics = loadedMetrics
        presentation =
            defaults.string(forKey: Self.presentationDefaultsKey)
            .flatMap(MenuBarPresentation.init(rawValue:)) ?? .strip
        focusedMetric =
            savedFocus.flatMap { loadedMetrics.contains($0) ? $0 : nil }
            ?? loadedMetrics.first ?? .pressure
        memoryReadout =
            defaults.string(forKey: Self.memoryReadoutDefaultsKey)
            .flatMap(MemoryReadout.init(rawValue:)) ?? .usage
        persistSelection()
    }

    /// The name a read-out goes by in tooltips and VoiceOver. The RAM cell
    /// names the figure it is showing, since "Memory 0%" would not say which.
    func title(for metric: MenuBarMetric) -> String {
        metric == .pressure ? memoryReadout.title : metric.title
    }

    func setSelected(_ metric: MenuBarMetric, isSelected: Bool) {
        if isSelected {
            guard !selectedMetrics.contains(metric) else { return }
            selectedMetrics.append(metric)
        } else {
            guard selectedMetrics.count > 1 else { return }
            selectedMetrics.removeAll { $0 == metric }
            if focusedMetric == metric {
                focusedMetric = selectedMetrics.first ?? .pressure
            }
        }
        persistSelection()
    }

    func isSelected(_ metric: MenuBarMetric) -> Bool {
        selectedMetrics.contains(metric)
    }

    func move(_ metric: MenuBarMetric, by offset: Int) {
        guard let source = selectedMetrics.firstIndex(of: metric) else { return }
        let destination = source + offset
        guard selectedMetrics.indices.contains(destination) else { return }
        selectedMetrics.swapAt(source, destination)
        persistSelection()
    }

    private func persistSelection() {
        defaults.set(selectedMetrics.map(\.rawValue), forKey: Self.selectionDefaultsKey)
    }

    private static func loadSelection(from defaults: UserDefaults) -> [MenuBarMetric] {
        if let saved = defaults.stringArray(forKey: selectionDefaultsKey) {
            let metrics = saved.compactMap(MenuBarMetric.init(rawValue:))
            if !metrics.isEmpty { return metrics }
        }

        var migrated: [MenuBarMetric] = [.pressure]
        if defaults.object(forKey: legacyCPUKey) as? Bool ?? true {
            migrated.append(.cpu)
        }
        if defaults.object(forKey: legacyGPUKey) as? Bool ?? true {
            migrated.append(.gpu)
        }
        if defaults.object(forKey: legacyEnergyKey) as? Bool ?? true {
            migrated.append(.energy)
        }
        if defaults.object(forKey: legacyNetworkKey) as? Bool ?? true {
            migrated.append(.network)
        }
        // Disk did not exist before the combined-item preference. Existing users
        // keep their chosen width; new users (no legacy keys at all) get Disk.
        let hasLegacySelection = [legacyCPUKey, legacyGPUKey, legacyEnergyKey, legacyNetworkKey]
            .contains { defaults.object(forKey: $0) != nil }
        if !hasLegacySelection { migrated.append(.disk) }
        return migrated
    }
}
