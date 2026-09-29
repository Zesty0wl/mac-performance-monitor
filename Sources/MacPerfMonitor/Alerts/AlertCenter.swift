import CryptoKit
import Foundation
import MacPerfMonitorCore
import UserNotifications

/// Encodes and decodes the process identity carried in a notification's
/// `userInfo`, so clicking a per-process alert can reveal that exact process.
enum AlertUserInfo {
    private static let pidKey = "uk.co.bzwrd.macperfmonitor.alert.pid"
    private static let startKey = "uk.co.bzwrd.macperfmonitor.alert.start"
    private static let preciseStartKey = "uk.co.bzwrd.macperfmonitor.alert.startReference"
    private static let investigationKey = "uk.co.bzwrd.macperfmonitor.alert.investigation"
    private static let destinationKey = "uk.co.bzwrd.macperfmonitor.alert.destination"

    static var accessoryBatteryPayload: [String: Any] { [destinationKey: "energy"] }

    static func opensEnergy(from userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[destinationKey] as? String == "energy"
    }

    /// The userInfo payload for an alert, identifying its process when it has
    /// one. System-wide alerts (pressure, swap) carry no identity.
    static func payload(for identity: ProcessIdentity?) -> [String: Any] {
        guard let identity else { return [:] }
        return [
            pidKey: Int(identity.pid),
            startKey: identity.startTime.timeIntervalSince1970,
            preciseStartKey: identity.startTime.timeIntervalSinceReferenceDate,
        ]
    }

    /// The process identity in a notification payload, if it carried one.
    static func identity(from userInfo: [AnyHashable: Any]) -> ProcessIdentity? {
        guard let pid = userInfo[pidKey] as? Int,
            pid >= 0, pid <= Int(Int32.max)
        else { return nil }
        if let reference = userInfo[preciseStartKey] as? Double {
            guard reference.isFinite else { return nil }
            return ProcessIdentity(
                pid: Int32(pid), startTime: Date(timeIntervalSinceReferenceDate: reference))
        }
        guard let start = userInfo[startKey] as? Double, start.isFinite else { return nil }
        return ProcessIdentity(pid: Int32(pid), startTime: Date(timeIntervalSince1970: start))
    }

    static func payload(for notification: AlertNotification) -> [String: Any] {
        var result = payload(for: notification.identity)
        var request = notification.investigation
        if let data = try? JSONEncoder().encode(request), data.count <= 16384 {
            result[investigationKey] = data
        } else {
            request.records = nil
            result[investigationKey] = try? JSONEncoder().encode(request)
        }
        return result
    }

    static func investigation(from userInfo: [AnyHashable: Any]) -> AlertInvestigation? {
        guard let data = userInfo[investigationKey] as? Data, data.count <= 16384,
            let request = try? JSONDecoder().decode(AlertInvestigation.self, from: data),
            request.isValid
        else { return nil }
        return request
    }
}

enum AccessoryBatteryNotification {
    static func request(for alert: AccessoryBatteryAlert) -> UNNotificationRequest? {
        let readings = alert.parts.compactMap { part -> String? in
            guard let percent = part.percent, (0...100).contains(percent) else { return nil }
            let label: String
            switch part.component {
            case .battery: label = t("Charge")
            case .left: label = t("Left")
            case .right: label = t("Right")
            case .chargingCase: label = t("Case")
            }
            return label + ": " + BatteryFormat.percent(Double(percent))
        }
        guard !readings.isEmpty else { return nil }
        let content = UNMutableNotificationContent()
        content.title = t("Low battery: %@", String(alert.name.prefix(128)))
        content.body = t("macOS reports %@.", readings.joined(separator: ", "))
        content.sound = nil
        content.threadIdentifier = "accessory-batteries"
        content.userInfo = AlertUserInfo.accessoryBatteryPayload
        let identifier = SHA256.hash(data: Data(alert.id.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return UNNotificationRequest(
            identifier: "uk.co.bzwrd.macperfmonitor.accessory.\(identifier)",
            content: content, trigger: nil)
    }
}

/// Delivers `Alert`s as user notifications (PRD section 8.7). Every fired alert
/// is also logged at `.notice` so a forced-pressure test can prove, from the
/// unified log alone, that the alert path fired — independent of whether the
/// system chose to present the banner.
///
/// Guards against running unbundled (`swift run`), where `UNUserNotificationCenter`
/// has no bundle to attach to: in that case it logs but does not attempt to
/// schedule, so the core app still runs.
final class AlertCenter {
    var onDeliveryOutcome: ([String], String, Date) -> Void = { _, _, _ in }
    private let isBundled = Bundle.main.bundleURL.pathExtension == "app"
    private lazy var center: UNUserNotificationCenter? = isBundled ? .current() : nil

    /// Route notification interactions (clicks, foreground presentation) to the
    /// given delegate. No-op when unbundled, where there is no notification
    /// center to attach to. Set this once at launch, before authorization.
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        center?.delegate = delegate
    }

    /// Ask the user for permission to post notifications. Safe to call once at
    /// launch; the system only prompts the first time.
    func requestAuthorization() {
        guard let center else {
            AppLog.alerts.notice(
                "notifications unavailable (running unbundled); alerts will log only")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.alerts.error(
                    "notification authorization error: \(String(describing: error), privacy: .public)"
                )
            } else {
                AppLog.alerts.notice(
                    "notification authorization granted=\(granted, privacy: .public)")
            }
        }
    }

    func deliver(_ alerts: [Alert]) {
        for batch in AlertNotification.batches(alerts) { deliver(batch) }
    }

    func deliver(_ alert: Alert) {
        deliver([alert])
    }

    func deliverAccessoryBattery(
        _ alert: AccessoryBatteryAlert, completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let center, let request = AccessoryBatteryNotification.request(for: alert) else {
            completion(false)
            return
        }
        center.getNotificationSettings { settings in
            guard
                settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            else {
                completion(false)
                return
            }
            center.add(request) { error in
                completion(error == nil)
                if let error {
                    AppLog.alerts.error(
                        "accessory notification failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    private func deliver(_ batch: AlertNotification) {
        let attemptedAt = Date()
        let ids = batch.incidentIDs.joined(separator: ",")
        AppLog.alerts.notice(
            "alert notification: ids=\(ids, privacy: .public), critical=\(batch.isCritical, privacy: .public), evidence=\(batch.investigation.start, privacy: .public) to \(batch.investigation.time, privacy: .public)"
        )
        guard let center else {
            onDeliveryOutcome(batch.incidentIDs, "unbundled", attemptedAt)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = batch.title
        content.body = batch.body
        content.sound = batch.isCritical ? .default : nil
        content.threadIdentifier = batch.family
        content.userInfo = AlertUserInfo.payload(for: batch)
        let request = UNNotificationRequest(
            identifier: batch.identifier, content: content, trigger: nil)
        center.add(request) { error in
            self.onDeliveryOutcome(
                batch.incidentIDs, error == nil ? "scheduled" : "failed", attemptedAt)
            if let error {
                AppLog.alerts.error(
                    "notification delivery failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
