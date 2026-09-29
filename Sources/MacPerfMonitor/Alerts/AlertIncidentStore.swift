import Foundation
import MacPerfMonitorCore

final class AlertIncidentStore: @unchecked Sendable {
    struct Delivery: Codable {
        var date: Date
        var incidentIDs: [String]
        var outcome: String
    }

    enum StoreError: Error { case tooLarge }
    private let url: URL
    private let queue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.alert-state", qos: .utility)
    private static let maximumBytes = 2 * 1024 * 1024

    init(url: URL) { self.url = url }

    func load() throws -> AlertIncidentTracker.Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AlertIncidentTracker.Snapshot.self, from: read(url))
    }

    func save(
        _ snapshot: AlertIncidentTracker.Snapshot,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        queue.async {
            let result = Result { try self.write(JSONEncoder().encode(snapshot), to: self.url) }
            if case .failure(let error) = result {
                AppLog.alerts.error(
                    "could not save alert state: \(String(describing: error), privacy: .public)")
            }
            completion(result)
        }
    }

    func recordDelivery(_ ids: [String], outcome: String) {
        queue.async {
            let destination = self.url.deletingLastPathComponent().appendingPathComponent(
                "deliveries.json")
            var records =
                (try? JSONDecoder().decode([Delivery].self, from: self.read(destination))) ?? []
            records.append(
                Delivery(date: Date(), incidentIDs: Array(ids.prefix(512)), outcome: outcome))
            records = Array(records.suffix(128))
            do { try self.write(JSONEncoder().encode(records), to: destination) } catch {
                AppLog.alerts.error(
                    "could not save alert delivery outcome: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func read(_ file: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumBytes else {
            throw StoreError.tooLarge
        }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.maximumBytes else { throw StoreError.tooLarge }
        return data
    }

    private func write(_ data: Data, to file: URL) throws {
        guard data.count <= Self.maximumBytes else { throw StoreError.tooLarge }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
