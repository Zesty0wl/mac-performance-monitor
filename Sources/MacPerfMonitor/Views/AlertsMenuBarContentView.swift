import AppKit
import MacPerfMonitorCore
import SwiftUI

struct MenuBarAlertGroup: Identifiable {
    let identity: ProcessIdentity?
    let name: String
    let executablePath: String?
    let alerts: [MacPerfMonitorCore.Alert]
    var id: ProcessIdentity? { identity }

    static func groups(
        alerts: [MacPerfMonitorCore.Alert], processes: [ProcessSample]
    ) -> [MenuBarAlertGroup] {
        let samples = Dictionary(
            processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: alerts) { alert -> ProcessIdentity? in
            switch alert.kind {
            case .processCeiling, .leak: return alert.identity
            default: return nil
            }
        }
        return grouped.map { identity, alerts in
            let process = identity.flatMap { samples[$0] }
            let recorded = identity == nil ? nil : alerts.first(where: { $0.processName != nil })
            return MenuBarAlertGroup(
                identity: identity,
                name: process?.displayName ?? recorded?.processName ?? identity.map {
                    t("PID %@", String($0.pid))
                } ?? t("This Mac"),
                executablePath: process?.executablePath ?? recorded?.executablePath,
                alerts: alerts.sorted { first, second in
                    first.date == second.date ? first.id < second.id : first.date > second.date
                })
        }.sorted { first, second in
            if first.identity == nil { return second.identity != nil }
            if second.identity == nil { return false }
            if first.name != second.name {
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
            return first.alerts[0].id < second.alerts[0].id
        }
    }
}

struct AlertsMenuBarContentView: View {
    let alerts: [MacPerfMonitorCore.Alert]
    let processes: [ProcessSample]
    var observations: [AlertIncident] = []
    var inspectAlert: ((MacPerfMonitorCore.Alert) -> Void)?
    var snooze: ((String, TimeInterval) -> Void)?
    let openProcess: (ProcessIdentity) -> Void

    var body: some View {
        let groups = MenuBarAlertGroup.groups(alerts: alerts, processes: processes)
        Group {
            if groups.isEmpty, observations.isEmpty {
                ContentUnavailableView("No active alerts", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if groups.isEmpty {
                            Text("No active alerts").font(.caption).foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                if let identity = group.identity {
                                    Button {
                                        openProcess(identity)
                                    } label: {
                                        heading(group)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open Processes")
                                } else {
                                    heading(group)
                                }
                                ForEach(group.alerts) { alert in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .top, spacing: 8) {
                                            Button {
                                                inspectAlert?(alert)
                                            } label: {
                                                Label(
                                                    alert.title,
                                                    systemImage: "exclamationmark.triangle"
                                                )
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.red)
                                                .fixedSize(horizontal: false, vertical: true)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Inspect alert evidence")
                                            .disabled(inspectAlert == nil)
                                            Spacer(minLength: 0)
                                            if let snooze, alert.severity != .critical {
                                                let muted =
                                                    alert.snoozedUntil.map { $0 > Date() } ?? false
                                                Button {
                                                    snooze(alert.id, muted ? 0 : 3600)
                                                } label: {
                                                    Image(systemName: muted ? "bell" : "bell.slash")
                                                        .frame(width: 20, height: 20)
                                                }.buttonStyle(.plain)
                                                    .help(
                                                        muted
                                                            ? "Resume notifications"
                                                            : "Snooze for 1 hour")
                                            }
                                        }
                                        Text(alert.body)
                                            .font(.caption)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(
                                            t(
                                                "Detected: %@",
                                                alert.date.formatted(
                                                    date: .abbreviated, time: .shortened))
                                        )
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        if let evidence = alert.evidence {
                                            Text(
                                                t(
                                                    "Last reading: %@",
                                                    evidence.end.formatted(
                                                        date: .omitted, time: .standard))
                                            )
                                            .font(.caption2.monospacedDigit()).foregroundStyle(
                                                .secondary)
                                        }
                                        if let until = alert.snoozedUntil, until > Date() {
                                            Text(
                                                t(
                                                    "Notifications snoozed until %@",
                                                    until.formatted(
                                                        date: .omitted, time: .shortened))
                                            )
                                            .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 4)
                            Divider()
                        }
                        if !observations.isEmpty {
                            Text("Observations").font(.caption.weight(.semibold)).padding(
                                .vertical, 10)
                            ForEach(observations) { incident in
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(
                                        phaseTitle(incident.phase),
                                        systemImage: incident.phase == .unknown
                                            ? "questionmark.circle" : "eye"
                                    )
                                    .font(.caption2).foregroundStyle(.secondary)
                                    Text(
                                        incident.condition.alert.processName
                                            ?? incident.condition.alert.title
                                    )
                                    .font(.caption.weight(.semibold))
                                    if incident.phase == .watching {
                                        Text(incident.condition.alert.body).font(.caption)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Text(
                                        t(
                                            "Last reading: %@",
                                            (incident.condition.alert.evidence?.end
                                                ?? incident.observedAt)
                                                .formatted(date: .abbreviated, time: .shortened))
                                    )
                                    .font(.caption2).foregroundStyle(.secondary)
                                }.padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 320)
        .accessibilityIdentifier("menubar.alerts.list")
    }

    private func phaseTitle(_ phase: AlertIncident.Phase) -> String {
        switch phase {
        case .unknown: return t("Waiting for fresh data")
        case .recovering: return t("Settling")
        default: return t("Watching")
        }
    }

    private func heading(_ group: MenuBarAlertGroup) -> some View {
        HStack(spacing: 8) {
            if group.identity != nil {
                Image(nsImage: ProcessIconProvider.shared.icon(forPath: group.executablePath))
                    .resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "desktopcomputer").frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.callout.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                if let identity = group.identity {
                    Text(t("PID %@", String(identity.pid)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if group.identity != nil {
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
