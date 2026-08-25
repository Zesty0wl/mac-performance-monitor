import Foundation

/// One fact about the hardware as the explorer shows it: a label, a value,
/// and the group it sits under (a nested record such as "Physical drive" or
/// "AC Power", flattened into its parent so it stays searchable and readable
/// without another level in the tree).
public struct HardwareProperty: Hashable, Sendable, Codable {
    public var label: String
    public var value: String
    public var group: String?

    public init(_ label: String, _ value: String, group: String? = nil) {
        self.label = label
        self.value = value
        self.group = group
    }
}

/// A device, bus, volume, controller, or any other thing the inventory knows
/// about, with its properties and the things attached to it. Ids are paths
/// ("usb/SPUSBHostDataType/2/0"), stable across refreshes while the topology
/// is, so a selection survives a refresh.
public struct HardwareNode: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var systemImage: String
    public var properties: [HardwareProperty]
    public var children: [HardwareNode]

    public init(
        id: String, title: String, subtitle: String? = nil, systemImage: String,
        properties: [HardwareProperty] = [], children: [HardwareNode] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.properties = properties
        self.children = children
    }

    /// nil for a leaf, which is what `OutlineGroup` wants.
    public var childrenOrNil: [HardwareNode]? { children.isEmpty ? nil : children }

    /// Every node below this one.
    public var descendantCount: Int {
        children.reduce(0) { $0 + 1 + $1.descendantCount }
    }

    /// The property groups in first-seen order, nil first (the node's own
    /// properties come before its nested records).
    public var propertyGroups: [String?] {
        var seen: [String?] = []
        for property in properties where !seen.contains(property.group) {
            seen.append(property.group)
        }
        return seen
    }

    public func properties(in group: String?) -> [HardwareProperty] {
        properties.filter { $0.group == group }
    }

    public func node(withID id: String) -> HardwareNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.node(withID: id) { return found }
        }
        return nil
    }

    /// The chain from this node down to `id`, inclusive, or nil when it is not
    /// in this subtree.
    public func path(to id: String) -> [HardwareNode]? {
        if self.id == id { return [self] }
        for child in children {
            if let rest = child.path(to: id) { return [self] + rest }
        }
        return nil
    }

    /// This node and everything below it, depth first.
    public func flattened() -> [HardwareNode] {
        [self] + children.flatMap { $0.flattened() }
    }

    /// Whether the query appears in the title, subtitle, or any property.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(needle) { return true }
        if let subtitle, subtitle.localizedCaseInsensitiveContains(needle) { return true }
        return properties.contains { $0.matches(needle) }
    }
}

extension HardwareProperty {
    public func matches(_ needle: String) -> Bool {
        label.localizedCaseInsensitiveContains(needle)
            || value.localizedCaseInsensitiveContains(needle)
            || (group?.localizedCaseInsensitiveContains(needle) ?? false)
    }
}

/// Typed figures the overview page draws from (core counts for the chip
/// diagram, capacities for the bars, battery health for the ring). Each
/// section fills in what it knows; the model merges them.
public struct HardwareFacts: Hashable, Sendable, Codable {
    public struct Volume: Hashable, Sendable, Codable {
        public var name: String
        public var mountPoint: String?
        public var capacityBytes: UInt64
        public var freeBytes: UInt64?
        public var isInternal: Bool?
        public init(
            name: String, mountPoint: String?, capacityBytes: UInt64, freeBytes: UInt64?,
            isInternal: Bool?
        ) {
            self.name = name
            self.mountPoint = mountPoint
            self.capacityBytes = capacityBytes
            self.freeBytes = freeBytes
            self.isInternal = isInternal
        }
    }

    public struct Display: Hashable, Sendable, Codable {
        public var name: String
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var resolution: String?
        public var isMain: Bool
        public var isBuiltIn: Bool
        public init(
            name: String, pixelWidth: Int, pixelHeight: Int, resolution: String?, isMain: Bool,
            isBuiltIn: Bool
        ) {
            self.name = name
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.resolution = resolution
            self.isMain = isMain
            self.isBuiltIn = isBuiltIn
        }
    }

    public struct Battery: Hashable, Sendable, Codable {
        public var cycleCount: Int?
        public var healthPercent: Double?
        public var designCapacitymAh: Int?
        public var maxCapacitymAh: Int?
        public var condition: String?
        public var chargePercent: Double?
        public init(
            cycleCount: Int?, healthPercent: Double?, designCapacitymAh: Int?,
            maxCapacitymAh: Int?, condition: String?, chargePercent: Double?
        ) {
            self.cycleCount = cycleCount
            self.healthPercent = healthPercent
            self.designCapacitymAh = designCapacitymAh
            self.maxCapacitymAh = maxCapacitymAh
            self.condition = condition
            self.chargePercent = chargePercent
        }
    }

    /// One temperature domain for the overview's heat grid: the group name and
    /// its raw readings in Celsius, hottest first.
    public struct SensorGroup: Hashable, Sendable, Codable {
        public var name: String
        public var readings: [Double]
        public init(name: String, readings: [Double]) {
            self.name = name
            self.readings = readings
        }
    }

    public var productName: String?
    public var modelIdentifier: String?
    public var serialNumber: String?
    public var chipName: String?
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var gpuCores: Int?
    public var neuralEngineCores: Int?
    public var metalSupport: String?
    public var isaFeatureCount: Int?
    public var memoryBytes: UInt64?
    public var memoryType: String?
    public var volumes: [Volume]?
    public var displays: [Display]?
    public var battery: Battery?
    public var osVersion: String?
    public var kernelVersion: String?
    public var bootTime: Date?
    public var wifiSummary: String?
    public var bluetoothSummary: String?
    public var usbDeviceCount: Int?
    public var thunderboltPortCount: Int?
    public var secureBoot: String?
    /// Empty (not nil) when the SMC was read and found nothing, so the
    /// overview can say so instead of spinning forever.
    public var sensorGroups: [SensorGroup]?
    public var fanRPMs: [Int]?

    public init() {}

    /// Take every field `other` has a value for.
    public mutating func merge(_ other: HardwareFacts) {
        if let v = other.productName { productName = v }
        if let v = other.modelIdentifier { modelIdentifier = v }
        if let v = other.serialNumber { serialNumber = v }
        if let v = other.chipName { chipName = v }
        if let v = other.performanceCores { performanceCores = v }
        if let v = other.efficiencyCores { efficiencyCores = v }
        if let v = other.gpuCores { gpuCores = v }
        if let v = other.neuralEngineCores { neuralEngineCores = v }
        if let v = other.metalSupport { metalSupport = v }
        if let v = other.isaFeatureCount { isaFeatureCount = v }
        if let v = other.memoryBytes { memoryBytes = v }
        if let v = other.memoryType { memoryType = v }
        if let v = other.volumes { volumes = v }
        if let v = other.displays { displays = v }
        if let v = other.battery { battery = v }
        if let v = other.osVersion { osVersion = v }
        if let v = other.kernelVersion { kernelVersion = v }
        if let v = other.bootTime { bootTime = v }
        if let v = other.wifiSummary { wifiSummary = v }
        if let v = other.bluetoothSummary { bluetoothSummary = v }
        if let v = other.usbDeviceCount { usbDeviceCount = v }
        if let v = other.thunderboltPortCount { thunderboltPortCount = v }
        if let v = other.secureBoot { secureBoot = v }
        if let v = other.sensorGroups { sensorGroups = v }
        if let v = other.fanRPMs { fanRPMs = v }
    }
}

/// One top-level area of the explorer (Processor, Storage, USB, ...): its
/// root node holds the items, plus a note when a source came back empty or
/// failed so an empty list is explained rather than silent.
public struct HardwareSection: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var root: HardwareNode
    public var note: String?
    public var facts: HardwareFacts
    public var captureSeconds: Double

    public init(
        id: String, title: String, systemImage: String, root: HardwareNode, note: String? = nil,
        facts: HardwareFacts = HardwareFacts(), captureSeconds: Double = 0
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.root = root
        self.note = note
        self.facts = facts
        self.captureSeconds = captureSeconds
    }

    public var isEmpty: Bool { root.children.isEmpty && root.properties.isEmpty }
}

/// A complete inventory, taken on demand.
public struct HardwareSnapshot: Hashable, Sendable, Codable {
    public var sections: [HardwareSection]
    public var capturedAt: Date

    public init(sections: [HardwareSection], capturedAt: Date) {
        self.sections = sections
        self.capturedAt = capturedAt
    }

    public var facts: HardwareFacts {
        var merged = HardwareFacts()
        for section in sections { merged.merge(section.facts) }
        return merged
    }

    public func node(withID id: String) -> HardwareNode? {
        for section in sections {
            if let found = section.root.node(withID: id) { return found }
        }
        return nil
    }

    public func section(containing id: String) -> HardwareSection? {
        sections.first { $0.root.node(withID: id) != nil }
    }
}

// MARK: - Search

/// A search match: the node, where it lives, and which of its properties hit.
public struct HardwareSearchHit: Identifiable, Hashable, Sendable {
    public var node: HardwareNode
    public var sectionID: String
    public var sectionTitle: String
    /// Titles from the section down to the node's parent.
    public var path: [String]
    public var matchedProperties: [HardwareProperty]
    public var score: Int

    public var id: String { node.id }
}

public enum HardwareSearch {
    /// Every node whose title, subtitle, or properties contain `query`, best
    /// matches first: a title hit beats a subtitle hit beats a property hit,
    /// and among property hits a label hit beats a value hit.
    public static func results(
        in sections: [HardwareSection], query: String, limit: Int = 300
    ) -> [HardwareSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var hits: [HardwareSearchHit] = []
        for section in sections {
            walk(section.root, path: [], section: section, needle: needle, into: &hits)
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.node.title.localizedCaseInsensitiveCompare(rhs.node.title)
                == .orderedAscending
        }
        return Array(hits.prefix(limit))
    }

    private static func walk(
        _ node: HardwareNode, path: [String], section: HardwareSection, needle: String,
        into hits: inout [HardwareSearchHit]
    ) {
        let matched = node.properties.filter { $0.matches(needle) }
        var score = 0
        if node.title.localizedCaseInsensitiveContains(needle) {
            score = node.title.lowercased().hasPrefix(needle.lowercased()) ? 100 : 80
        } else if node.subtitle?.localizedCaseInsensitiveContains(needle) == true {
            score = 60
        } else if matched.contains(where: { $0.label.localizedCaseInsensitiveContains(needle) }) {
            score = 40
        } else if !matched.isEmpty {
            score = 20
        }
        // The section root is a container, not a thing; only list it on a
        // title match so "usb" still finds the USB section.
        let isRoot = node.id == section.id
        if score > 0, !isRoot || score >= 80 {
            hits.append(
                HardwareSearchHit(
                    node: node, sectionID: section.id, sectionTitle: section.title, path: path,
                    matchedProperties: matched, score: score))
        }
        let childPath = isRoot ? [section.title] : path + [node.title]
        for child in node.children {
            walk(child, path: childPath, section: section, needle: needle, into: &hits)
        }
    }
}

// MARK: - Report

/// Plain-text and JSON renderings of an inventory, for the clipboard and for
/// saving a report.
public enum HardwareReport {
    public static func text(for snapshot: HardwareSnapshot) -> String {
        var lines: [String] = []
        let stamp = ISO8601DateFormatter().string(from: snapshot.capturedAt)
        lines.append("Hardware report, captured \(stamp)")
        for section in snapshot.sections {
            lines.append("")
            lines.append("== \(section.title) ==")
            if let note = section.note { lines.append("(\(note))") }
            appendText(for: section.root, indent: 0, includeTitle: false, into: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func text(for node: HardwareNode) -> String {
        var lines: [String] = []
        appendText(for: node, indent: 0, includeTitle: true, into: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func json(for snapshot: HardwareSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    private static func appendText(
        for node: HardwareNode, indent: Int, includeTitle: Bool, into lines: inout [String]
    ) {
        let pad = String(repeating: "  ", count: indent)
        var childIndent = indent
        if includeTitle {
            var heading = node.title
            if let subtitle = node.subtitle, !subtitle.isEmpty { heading += " (\(subtitle))" }
            lines.append("\(pad)\(heading)")
            childIndent += 1
        }
        let propertyPad = String(repeating: "  ", count: childIndent)
        var currentGroup: String?
        for property in node.properties {
            if property.group != currentGroup {
                currentGroup = property.group
                if let group = currentGroup { lines.append("\(propertyPad)[\(group)]") }
            }
            lines.append("\(propertyPad)\(property.label): \(property.value)")
        }
        for child in node.children {
            appendText(for: child, indent: childIndent, includeTitle: true, into: &lines)
        }
    }
}
