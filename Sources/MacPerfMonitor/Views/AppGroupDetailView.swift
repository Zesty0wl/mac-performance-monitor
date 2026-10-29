import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The Processes tab's inspector for an app row in the Apps layout: the app's
/// totals and every process working for it, largest first. Picking a process
/// selects its own row and opens its full detail.
///
/// Rebuilt from `displayProcesses` on the table cadence, like the table's own
/// rows; the group is found by its identity, so it follows the app as members
/// come and go.
struct AppGroupDetailView: View {
    let identity: ProcessIdentity
    @Binding var selection: ProcessIdentity?
    @EnvironmentObject private var model: SamplerModel

    var body: some View {
        let group = Self.group(identity, in: model.displayProcesses)
        ScrollView {
            if let group {
                content(group)
                    .padding(16)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView(
                    "App no longer running", systemImage: "app.dashed",
                    description: Text("Select a process to see its history and details."))
            }
        }
    }

    static func group(_ identity: ProcessIdentity, in samples: [ProcessSample]) -> AppGroup? {
        var coalition: UInt64?
        let members = samples.filter { sample in
            guard let id = sample.coalitionID, ProcessIdentity.appGroup(coalitionID: id) == identity
            else { return false }
            coalition = id
            return true
        }
        guard let coalition, !members.isEmpty else { return nil }
        return AppGrouping.makeGroup(coalitionID: coalition, members: members)
    }

    private func content(_ group: AppGroup) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(group)
            Text(
                "Added up across the app and every process working for it, including services macOS started on its behalf."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            totals(group.total)
            members(group)
        }
    }

    private func header(_ group: AppGroup) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: group.leader.executablePath))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.total.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    t(
                        group.members.count == 1 ? "%@ process" : "%@ processes",
                        String(group.members.count))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let app = AppGroupActions.runningApp(for: group.leader) {
                Button("Quit App") { app.terminate() }
                    .controlSize(.small)
                    .help("Quit the app the normal way, as Quit in its menu does.")
            }
        }
    }

    private func totals(_ total: ProcessSample) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                metric(
                    "Memory",
                    total.footprintReadable
                        ? ByteFormat.string(total.physFootprint) : t("Not readable"))
                metric("CPU", String(format: "%.1f%%", total.cpuPercent))
            }
            GridRow {
                metric("Threads", "\(total.threadCount)")
                metric("FDs", "\(total.fdTotal)")
            }
        }
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
        }
    }

    private func members(_ group: AppGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Processes")
                .font(.headline)
            ForEach(
                group.members.sorted { $0.physFootprint > $1.physFootprint }, id: \.id
            ) { member in
                Button {
                    selection = member.id
                } label: {
                    HStack(spacing: 6) {
                        Image(
                            nsImage: ProcessIconProvider.shared.rowIcon(
                                forPath: member.executablePath))
                        Text(member.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(
                            member.footprintReadable
                                ? ByteFormat.string(member.physFootprint) : t("Not readable")
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t("PID %@", String(member.pid)))
            }
        }
    }
}

/// Actions on an app as a whole.
enum AppGroupActions {
    /// The running app to quit for a group's leader: only a regular app (one
    /// with a Dock icon and a Quit command), never a daemon or a helper, and
    /// only while the leader is still the same process.
    static func runningApp(for leader: ProcessSample) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: leader.pid),
            app.activationPolicy == .regular, !app.isTerminated
        else { return nil }
        if let launched = app.launchDate, abs(launched.timeIntervalSince(leader.startTime)) > 5 {
            return nil
        }
        return app
    }
}
