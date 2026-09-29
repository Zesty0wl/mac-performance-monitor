import Foundation
import MacPerfMonitorCore

struct AlertInvestigation: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    var time: Date
    var identities: [ProcessIdentity]
    var kinds: Set<Alert.Kind>
    var records: [Alert]? = nil

    init?(alerts: [Alert]) {
        guard let latest = alerts.map({ $0.evidence?.end ?? $0.date }).max(),
            let earliest = alerts.map({ $0.evidence?.start ?? $0.date }).min()
        else { return nil }
        let span = min(86400, max(300, latest.timeIntervalSince(earliest)))
        let padding = min(60, span / 10)
        start = latest.addingTimeInterval(-span - padding)
        end = latest.addingTimeInterval(padding)
        time = latest
        identities = Array(Set(alerts.compactMap(\.identity))).sorted { first, second in
            first.pid == second.pid ? first.startTime < second.startTime : first.pid < second.pid
        }
        identities = Array(identities.prefix(8))
        kinds = Set(alerts.map(\.kind))
        records = alerts.prefix(8).map { original in
            var alert = original
            alert.executablePath = nil
            alert.body = String(alert.body.prefix(512))
            alert.title = String(alert.title.prefix(256))
            return alert
        }
    }

    var isValid: Bool {
        [start, end, time].allSatisfy {
            $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0
        }
            && end > start && end.timeIntervalSince(start) <= 90 * 86400
            && (start...end).contains(time)
            && identities.count <= 8
            && identities.allSatisfy { $0.pid >= 0 && $0.startTime.timeIntervalSince1970.isFinite }
            && time <= Date().addingTimeInterval(60) && (records?.count ?? 0) <= 8
    }
}

struct AlertNotification: Sendable {
    var family: String
    var title: String
    var body: String
    var isCritical: Bool
    var incidentIDs: [String]
    var investigation: AlertInvestigation
    var identity: ProcessIdentity?

    var identifier: String { "uk.co.bzwrd.macperfmonitor.alert.\(family)" }

    static func batches(_ alerts: [Alert]) -> [AlertNotification] {
        let groups = Dictionary(grouping: alerts.filter { $0.severity > .watching }) {
            AlertIncidentTracker.family($0.kind)
        }
        return groups.compactMap { family, rows in
            let rows = rows.sorted { first, second in
                first.severity == second.severity
                    ? first.id < second.id : first.severity > second.severity
            }
            guard let first = rows.first, let investigation = AlertInvestigation(alerts: rows),
                investigation.isValid
            else { return nil }
            var body =
                rows.count == 1
                ? message(first)
                : rows.prefix(3).map { "\($0.title): \(message($0))" }.joined(separator: "\n")
            if rows.count > 3 { body += "\n" + t("%@ more active alerts.", String(rows.count - 3)) }
            return AlertNotification(
                family: family,
                title: rows.count > 1
                    ? t("Memory needs attention")
                    : (first.previousNotification == nil
                        ? first.title : t("Worsening: %@", first.title)),
                body: String(body.prefix(1800)),
                isCritical: rows.contains { $0.severity == .critical },
                incidentIDs: rows.map(\.id), investigation: investigation,
                identity: rows.count == 1 ? first.identity : nil)
        }.sorted { $0.family < $1.family }
    }

    private static func message(_ alert: Alert) -> String {
        guard let previous = alert.previousNotification else { return alert.body }
        let value: String
        if previous.unit == "bytes", previous.current.isFinite {
            value = ByteFormat.string(
                UInt64(min(max(0, previous.current), Double(UInt64.max).nextDown)))
        } else {
            value = previous.current.formatted() + (previous.unit == "percent" ? "%" : "")
        }
        return alert.body + "\n"
            + t(
                "Previous notification at %1$@: %2$@.",
                previous.end.formatted(date: .omitted, time: .shortened), value)
    }
}
