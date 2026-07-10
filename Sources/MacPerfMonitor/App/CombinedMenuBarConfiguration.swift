import Combine
import Foundation

enum MenuBarMetric: String, CaseIterable, Codable, Identifiable {
    case pressure
    case cpu
    case gpu
    case energy
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pressure: return "Memory Pressure"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .energy: return "Energy"
        case .network: return "Network"
        }
    }

    var shortTitle: String {
        switch self {
        case .pressure: return "RAM"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .energy: return "BAT"
        case .network: return "NET"
        }
    }

    var symbolName: String {
        switch self {
        case .pressure: return "memorychip"
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .energy: return "bolt.fill"
        case .network: return "network"
        }
    }
}

enum MenuBarPresentation: String, CaseIterable, Identifiable {
    case focus
    case strip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .strip: return "Strip"
        }
    }
}

final class CombinedMenuBarConfiguration: ObservableObject {
    static let selectionDefaultsKey = "combinedMenuBarMetrics"
    static let presentationDefaultsKey = "combinedMenuBarPresentation"
    static let focusDefaultsKey = "combinedMenuBarFocus"
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
            ?? loadedMetrics[0]
        persistSelection()
    }

    func setSelected(_ metric: MenuBarMetric, isSelected: Bool) {
        if isSelected {
            guard !selectedMetrics.contains(metric) else { return }
            selectedMetrics.append(metric)
        } else {
            guard selectedMetrics.count > 1 else { return }
            selectedMetrics.removeAll { $0 == metric }
            if focusedMetric == metric {
                focusedMetric = selectedMetrics[0]
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
        return migrated
    }
}
