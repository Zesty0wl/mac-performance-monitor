import CoreFoundation
import Foundation

public struct AccessoryBattery: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case mouse, keyboard, trackpad, headphones, speaker, gameController, other
    }

    public enum Component: String, CaseIterable, Codable, Sendable {
        case battery, left, right, chargingCase
    }

    public struct Part: Identifiable, Equatable, Sendable {
        public var component: Component
        public var percent: Int?
        public var isCharging: Bool?
        public var id: Component { component }

        public init(component: Component, percent: Int?, isCharging: Bool?) {
            self.component = component
            self.percent = percent
            self.isCharging = isCharging
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var parts: [Part]
    public var hasStableIdentity: Bool
    public var isConnected: Bool?

    public init(
        id: String, name: String, kind: Kind, parts: [Part],
        hasStableIdentity: Bool = true, isConnected: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parts = parts
        self.hasStableIdentity = hasStableIdentity
        self.isConnected = isConnected
    }
}

public protocol AccessoryBatteryReading: Sendable {
    func read() -> [AccessoryBattery]?
}

public struct AccessoryBatteryReader: AccessoryBatteryReading {
    static let maximumReportBytes = 1_048_576
    private static let maximumRecords = 128

    public init() {}

    public func read() -> [AccessoryBattery]? {
        let result = MemoryToolRunner.capture(
            executablePath: "/usr/bin/pmset", arguments: ["-g", "accps", "-xml"],
            label: "Accessories", pid: ProcessInfo.processInfo.processIdentifier,
            timeout: 5, maxBytes: Self.maximumReportBytes + 1)
        guard case .success(let report) = result else { return nil }
        return Self.parse(report)
    }

    static func parse(_ report: String) -> [AccessoryBattery]? {
        guard report.utf8.count <= maximumReportBytes else { return nil }
        let frames = report.components(separatedBy: "<?xml")
        guard frames.count > 1, frames.count <= maximumRecords + 1,
            frames[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var records: [[String: Any]] = []
        for frame in frames.dropFirst() {
            guard
                let record = try? PropertyListSerialization.propertyList(
                    from: Data(("<?xml" + frame).utf8), format: nil) as? [String: Any]
            else { return nil }
            records.append(record)
        }

        var devices: [String: AccessoryBattery] = [:]
        var namedFromCase: Set<String> = []
        for (index, record) in records.enumerated() {
            guard record["Type"] as? String == "Accessory Source",
                boolean(record["Is Present"]) != false,
                let name = text(record["Name"])
            else { continue }
            let identifier: String
            if let group = text(record["Group Identifier"]) {
                identifier = "group:\(group)"
            } else if let accessory = text(record["Accessory Identifier"]) {
                identifier = "accessory:\(accessory)"
            } else {
                identifier = "record:\(index)"
            }
            let part = component(record["Part Identifier"])
            let category = record["Accessory Category"] as? String ?? ""
            let isCase = part == .chargingCase || category == "Audio Battery Case"
            var device =
                devices[identifier]
                ?? AccessoryBattery(
                    id: identifier, name: name, kind: kind(category), parts: [],
                    hasStableIdentity: !identifier.hasPrefix("record:"),
                    isConnected: boolean(record["Is Connected"]))
            if devices[identifier] == nil, isCase { namedFromCase.insert(identifier) }
            if namedFromCase.contains(identifier), !isCase {
                device.name = name
                device.kind = kind(category)
                namedFromCase.remove(identifier)
            }

            let children = (record["Combined Parts"] as? [Any] ?? []).prefix(16)
                .compactMap { $0 as? [String: Any] }
                .filter { boolean($0["Is Present"]) != false }
            let parts =
                children.isEmpty
                ? [reading(record, component: isCase ? .chargingCase : part)]
                : children.map { reading($0, component: component($0["Part Identifier"])) }
            for reading in parts {
                if let position = device.parts.firstIndex(where: { $0.id == reading.id }) {
                    device.parts[position] = reading
                } else {
                    device.parts.append(reading)
                }
            }
            devices[identifier] = device
        }

        return devices.values.map { device in
            var device = device
            if device.parts.contains(where: { $0.component == .left || $0.component == .right }) {
                device.parts.removeAll { $0.component == .battery }
            }
            device.parts = AccessoryBattery.Component.allCases.compactMap { component in
                device.parts.first { $0.component == component }
            }
            return device
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return nil }
        return trimmed
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }

    private static func reading(
        _ record: [String: Any], component: AccessoryBattery.Component
    ) -> AccessoryBattery.Part {
        var percent: Int?
        if let current = number(record["Current Capacity"]),
            let maximum = number(record["Max Capacity"]), maximum > 0,
            current >= 0, current <= maximum
        {
            percent = Int((current / maximum * 100).rounded())
        }
        return AccessoryBattery.Part(
            component: component, percent: percent, isCharging: boolean(record["Is Charging"]))
    }

    private static func component(_ value: Any?) -> AccessoryBattery.Component {
        switch value as? String {
        case "Left": return .left
        case "Right": return .right
        case "Case": return .chargingCase
        default: return .battery
        }
    }

    private static func kind(_ category: String) -> AccessoryBattery.Kind {
        switch category {
        case "Mouse": return .mouse
        case "Keyboard": return .keyboard
        case "Trackpad": return .trackpad
        case "Headphone", "Headset", "Audio Battery Case", "HearingAid": return .headphones
        case "Speaker": return .speaker
        case "Game Controller": return .gameController
        default: return .other
        }
    }
}
