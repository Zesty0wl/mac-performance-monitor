import AppKit
import Combine
import Foundation
import MacPerfMonitorCore
import UniformTypeIdentifiers

/// State for the Hardware tab: the inventory, the selection, the search, and
/// the refresh in flight. One shared instance, so the inventory (a few
/// seconds of `system_profiler` per refresh) survives leaving and returning
/// to the tab; nothing here runs on the sampler's tick, the page changes only
/// when the person asks for a refresh.
@MainActor
final class HardwareExplorerModel: ObservableObject {
    static let shared = HardwareExplorerModel()
    static let overviewID = "overview"

    /// Completed sections in spec order. While a refresh runs, each section is
    /// replaced as its capture lands, so the page fills in progressively.
    @Published private(set) var sections: [HardwareSection] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var completed = 0
    @Published private(set) var capturedAt: Date?
    @Published private(set) var lastCaptureSeconds: Double?
    @Published var selectedID: String? = HardwareExplorerModel.overviewID
    @Published var query = ""

    private var generation = 0

    var total: Int { HardwareInventory.specs.count }

    /// Facts layered over the captured ones, for previewing the overview with
    /// a chip this Mac is not (the snapshot harness renders an Ultra with it).
    @Published var previewFacts: HardwareFacts?

    var facts: HardwareFacts {
        var merged = HardwareFacts()
        for section in sections { merged.merge(section.facts) }
        if let previewFacts { merged.merge(previewFacts) }
        return merged
    }

    var snapshot: HardwareSnapshot? {
        guard let capturedAt else { return nil }
        return HardwareSnapshot(sections: sections, capturedAt: capturedAt)
    }

    var hits: [HardwareSearchHit] {
        HardwareSearch.results(in: sections, query: query)
    }

    func section(_ id: String) -> HardwareSection? {
        sections.first { $0.id == id }
    }

    func node(withID id: String) -> HardwareNode? {
        for section in sections {
            if let found = section.root.node(withID: id) { return found }
        }
        return nil
    }

    /// Section root first, down to the node.
    func path(to id: String) -> [HardwareNode] {
        for section in sections {
            if let path = section.root.path(to: id) { return path }
        }
        return []
    }

    func sectionContaining(_ id: String) -> HardwareSection? {
        sections.first { $0.root.node(withID: id) != nil }
    }

    func refreshIfNeeded() {
        if capturedAt == nil, !isRefreshing { refresh() }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        completed = 0
        generation += 1
        let current = generation
        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let snapshot = HardwareInventory.capture { section in
                Task { @MainActor in
                    self.merge(section, generation: current)
                }
            }
            await MainActor.run {
                self.finish(snapshot, generation: current, started: started)
            }
        }
    }

    private func merge(_ section: HardwareSection, generation: Int) {
        guard generation == self.generation else { return }
        completed += 1
        if let index = sections.firstIndex(where: { $0.id == section.id }) {
            sections[index] = section
        } else {
            sections.append(section)
            let order = HardwareInventory.specs.map(\.id)
            sections.sort {
                (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0)
            }
        }
    }

    private func finish(_ snapshot: HardwareSnapshot, generation: Int, started: Date) {
        guard generation == self.generation else { return }
        sections = snapshot.sections
        capturedAt = snapshot.capturedAt
        lastCaptureSeconds = Date().timeIntervalSince(started)
        completed = total
        isRefreshing = false
        if let selectedID, selectedID != Self.overviewID, node(withID: selectedID) == nil {
            self.selectedID = Self.overviewID
        }
    }

    // MARK: - Export

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func reportText() -> String {
        guard let snapshot else { return "" }
        return HardwareReport.text(for: snapshot)
    }

    func reportJSON() -> Data? {
        guard let snapshot else { return nil }
        return try? HardwareReport.json(for: snapshot)
    }

    /// Save the report through a panel; `json` picks the format.
    func saveReport(json: Bool) {
        let panel = NSSavePanel()
        panel.title = json ? "Save Hardware JSON" : "Save Hardware Report"
        panel.message = "Save this Mac's hardware inventory."
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let model = facts.modelIdentifier?.replacingOccurrences(of: ",", with: "-") ?? "Mac"
        panel.nameFieldStringValue =
            "Hardware \(model) \(stamp.string(from: Date())).\(json ? "json" : "txt")"
        panel.allowedContentTypes = [json ? UTType.json : UTType.plainText]
        panel.canCreateDirectories = true
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        {
            panel.directoryURL = desktop
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = json ? reportJSON() : reportText().data(using: .utf8)
        try? data?.write(to: url, options: .atomic)
    }
}
