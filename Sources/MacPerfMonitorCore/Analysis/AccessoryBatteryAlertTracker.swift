import Foundation

public struct AccessoryBatteryAlert: Identifiable, Equatable, Sendable {
    public var id: String
    public var episodeID: UUID
    public var name: String
    public var parts: [AccessoryBattery.Part]
}

public struct AccessoryBatteryAlertTracker {
    private struct Episode: Codable {
        var id: UUID
        var threshold: Int
        var components: Set<AccessoryBattery.Component>
    }

    private struct Snapshot: Codable {
        var version: Int = 1
        var episodes: [String: Episode]
    }

    private struct Confirmation {
        var date: Date
        var threshold: Int
        var components: Set<AccessoryBattery.Component>
    }

    private static let maximumDevices = 256
    private static let maximumStoredBytes = 512 * 1024
    private var episodes: [String: Episode] = [:]
    private var confirmations: [String: Confirmation] = [:]
    private var lastEvaluation: Date?

    public init(storedState: Data? = nil) {
        guard let storedState, storedState.count <= Self.maximumStoredBytes,
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: storedState),
            snapshot.version == 1, snapshot.episodes.count <= Self.maximumDevices
        else { return }
        episodes = snapshot.episodes.filter { identifier, episode in
            !identifier.isEmpty && identifier.utf8.count <= 1024
                && (5...50).contains(episode.threshold) && !episode.components.isEmpty
        }
    }

    public var storedState: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Snapshot(episodes: episodes)),
            data.count <= Self.maximumStoredBytes
        else { return nil }
        return data
    }

    public mutating func resetConfirmation() {
        confirmations.removeAll()
        lastEvaluation = nil
    }

    public mutating func notificationFailed(_ alert: AccessoryBatteryAlert) {
        guard episodes[alert.id]?.id == alert.episodeID else { return }
        episodes.removeValue(forKey: alert.id)
        confirmations.removeValue(forKey: alert.id)
    }

    public mutating func evaluate(
        _ devices: [AccessoryBattery]?, thresholdPercent: Int = 20, now: Date = Date()
    ) -> [AccessoryBatteryAlert] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        if let lastEvaluation {
            let elapsed = now.timeIntervalSince(lastEvaluation)
            guard elapsed >= 60 else { return [] }
            if elapsed > 150 { confirmations.removeAll() }
        }
        lastEvaluation = now
        guard let devices else {
            confirmations.removeAll()
            return []
        }
        let threshold = min(50, max(5, thresholdPercent))
        let eligibleDevices = devices.prefix(Self.maximumDevices).filter {
            $0.hasStableIdentity && !$0.id.isEmpty && $0.id.utf8.count <= 1024
                && $0.isConnected != false
        }
        let present = Set(eligibleDevices.map(\.id))
        confirmations = confirmations.filter { present.contains($0.key) }
        var visited: Set<String> = []
        var alerts: [AccessoryBatteryAlert] = []

        for device in eligibleDevices where visited.insert(device.id).inserted {
            let parts = device.parts.prefix(AccessoryBattery.Component.allCases.count)
            let components = Set(parts.map(\.component))
            if let episode = episodes[device.id] {
                var required = episode.components
                if device.kind == .headphones, required.contains(.battery),
                    components.contains(.left), components.contains(.right)
                {
                    required.remove(.battery)
                    required.formUnion([.left, .right])
                }
                let recovered =
                    required.isSubset(of: components)
                    && !parts.isEmpty
                    && parts.allSatisfy {
                        guard let percent = $0.percent, (0...100).contains(percent) else {
                            return false
                        }
                        return percent >= max(threshold, episode.threshold) + 5
                    }
                if recovered { episodes.removeValue(forKey: device.id) }
                confirmations.removeValue(forKey: device.id)
                continue
            }

            let low = parts.filter {
                guard $0.isCharging != true, let percent = $0.percent,
                    (0...100).contains(percent)
                else { return false }
                return percent <= threshold
            }
            guard !low.isEmpty else {
                confirmations.removeValue(forKey: device.id)
                continue
            }
            let lowComponents = Set(low.map(\.component))
            if let confirmation = confirmations[device.id],
                confirmation.threshold == threshold,
                now.timeIntervalSince(confirmation.date) <= 150,
                !lowComponents.isDisjoint(with: confirmation.components),
                episodes.count < Self.maximumDevices
            {
                let episode = Episode(id: UUID(), threshold: threshold, components: components)
                episodes[device.id] = episode
                confirmations.removeValue(forKey: device.id)
                alerts.append(
                    AccessoryBatteryAlert(
                        id: device.id, episodeID: episode.id, name: device.name, parts: Array(low)))
            } else {
                confirmations[device.id] = Confirmation(
                    date: now, threshold: threshold, components: lowComponents)
            }
        }
        return alerts
    }
}
