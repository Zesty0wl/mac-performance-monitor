import MacPerfMonitorCore
import SwiftUI

/// Space left on the startup disk, and on any other drives that are mounted.
/// The startup figure rides the sampler (read once a minute); the other
/// volumes are enumerated only while this panel is open, as the Disk page does.
struct FreeSpaceMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @StateObject private var volumes = FreeSpaceVolumesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            startupDisk
            if !volumes.others.isEmpty {
                Divider()
                otherVolumes
            }
        }
        .onAppear { volumes.start() }
        .onDisappear { volumes.stop() }
    }

    private var isLow: Bool { model.activeAlertKinds.contains(.lowDiskSpace) }

    @ViewBuilder private var startupDisk: some View {
        let system = model.liveSystem
        VStack(alignment: .leading, spacing: 6) {
            Text("Startup disk")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let total = system?.bootVolumeTotalBytes, total > 0,
                let available = system?.bootVolumeUsableBytes
            {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(t("%@ available", ByteFormat.string(available)))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isLow ? Color.red : Color.primary)
                    if isLow {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Low on space")
                    }
                    Spacer(minLength: 0)
                    Text(
                        t(
                            "%1$@ of %2$@", ByteFormat.percent(Self.fraction(available, total)),
                            ByteFormat.string(total))
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                FreeSpaceBar(
                    usedFraction: 1 - Self.fraction(available, total),
                    tint: isLow ? .red : .accentColor)
                if let free = system?.bootVolumeFreeBytes, available > free {
                    Text(
                        t(
                            "Includes %@ of purgeable space that macOS frees when it is needed.",
                            ByteFormat.string(available - free))
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Reading the startup disk...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var otherVolumes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other volumes")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(volumes.others) { volume in
                let available = volume.importantUsageAvailableBytes ?? volume.availableBytes
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(volume.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(volume.mountPoint)
                        Text(
                            t(
                                "%1$@ of %2$@", ByteFormat.string(available),
                                ByteFormat.string(volume.totalBytes))
                        )
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                    FreeSpaceBar(
                        usedFraction: 1 - Self.fraction(available, volume.totalBytes),
                        tint: .secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    static func fraction(_ part: UInt64, _ whole: UInt64) -> Double {
        guard whole > 0 else { return 0 }
        return min(1, Double(part) / Double(whole))
    }
}

/// A thin capacity bar: the filled part is used space.
struct FreeSpaceBar: View {
    let usedFraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * max(0, min(1, usedFraction)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Mounted volumes other than the startup disk, refreshed every 30 seconds
/// while the panel is open. Enumeration touches every mount and the IORegistry,
/// so it runs off the main thread and only on demand.
@MainActor
final class FreeSpaceVolumesModel: ObservableObject {
    @Published private(set) var others: [VolumeInfo] = []

    private var timer: Timer?
    private static let queue = DispatchQueue(
        label: "MacPerfMonitor.freeSpaceVolumes", qos: .utility)

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        Self.queue.async {
            let snapshot = VolumeReader().read()
            let others = Self.otherVolumes(in: snapshot.volumes)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.others != others else { return }
                self.others = others
            }
        }
    }

    /// Writable volumes a person put there: external drives, other partitions
    /// and network shares, which macOS mounts under /Volumes. The startup disk
    /// has its own section. Everything else is noise here: the APFS support
    /// volumes (Preboot, VM, Recovery), and pseudo filesystems such as /dev
    /// and Xcode's DeviceFS that also classify as user volumes.
    nonisolated static func otherVolumes(in volumes: [VolumeInfo]) -> [VolumeInfo] {
        volumes
            .filter { $0.role == .user && !$0.isRoot && !$0.isReadOnly && $0.totalBytes > 0 }
            .filter { $0.mountPoint.hasPrefix("/Volumes/") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
