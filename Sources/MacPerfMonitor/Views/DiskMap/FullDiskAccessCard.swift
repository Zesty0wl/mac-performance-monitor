import SwiftUI

/// The in-context request for Full Disk Access, in the app's advisory
/// language (the Settings `WarningBanner` recipe). Shown on the Disk Map's
/// empty state before a first scan and, compactly, above a scan that ran
/// without the grant. Never a modal: the ask is made where it matters.
struct FullDiskAccessCard: View {
    @EnvironmentObject private var fullDiskAccess: FullDiskAccessManager
    /// Folders the last scan could not read because of the missing grant.
    var notPermittedCount: Int = 0
    var onScanAnyway: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if fullDiskAccess.awaitingRelaunch {
                        Button("Relaunch \(AppInfo.displayName)") { fullDiskAccess.relaunch() }
                            .buttonStyle(.borderedProminent)
                        Button("Open Privacy Settings") { fullDiskAccess.openSystemSettings() }
                    } else {
                        Button("Open Privacy Settings") { fullDiskAccess.openSystemSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let onScanAnyway {
                        Button("Scan Anyway", action: onScanAnyway)
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.28)))
    }

    private var title: LocalizedStringKey {
        if notPermittedCount == 1 {
            return "1 folder could not be read without Full Disk Access"
        }
        if notPermittedCount > 1 {
            return "\(notPermittedCount) folders could not be read without Full Disk Access"
        }
        return "Grant Full Disk Access for a complete map"
    }

    private var explanation: LocalizedStringKey {
        if fullDiskAccess.awaitingRelaunch {
            return
                "If you turned Full Disk Access on, it takes effect once \(AppInfo.displayName) relaunches. Then scan again."
        }
        return
            "Without it macOS asks about Desktop, Documents and Downloads one at a time, and Mail, Messages, Safari, Photos internals, iOS backups, Time Machine and the Trash stay hidden. The grant takes effect after \(AppInfo.displayName) relaunches."
    }
}
