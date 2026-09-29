import AppKit
import MacPerfMonitorCore
import SwiftUI

/// Physical disk activity plus task-attributed I/O. The two sections are
/// deliberately labeled separately because process counters do not exactly add
/// up to block-device traffic across caching, metadata, paging, and kernel work.
struct DiskMenuBarContentView: View {
    private static let processRowCount = 8
    private static let processRowHeight: CGFloat = 22

    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var menuLists: MenuListsModel

    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            DiskReadWriteChart(
                read: model.diskReadTrail(), write: model.diskWriteTrail(),
                sampleCapacity: model.systemHistory.capacity
            )
            .frame(height: MenuChart.networkHeight)
            if let disk = model.latestDisk { activitySummary(disk) }
            Divider()
            devices
            Divider()
            topProcesses
        }
    }

    private var header: some View {
        let rates = model.smoothedDiskRates
        return HStack(spacing: 20) {
            rateColumn("Read", rates?.readBytesPerSec, tint: DiskStyle.read)
            rateColumn("Write", rates?.writeBytesPerSec, tint: DiskStyle.write)
            Spacer(minLength: 0)
        }
    }

    private func rateColumn(_ title: LocalizedStringKey, _ rate: Double?, tint: Color) -> some View
    {
        VStack(alignment: .leading, spacing: 1) {
            Text(rate.map { ByteFormat.rate($0) } ?? "--")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func activitySummary(_ disk: DiskSample) -> some View {
        HStack(spacing: 14) {
            Text(
                String(
                    format: String(localized: "%d read IOPS"),
                    Int(disk.readOperationsPerSec.rounded())))
            Text(
                String(
                    format: String(localized: "%d write IOPS"),
                    Int(disk.writeOperationsPerSec.rounded())))
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var devices: some View {
        let items = (model.latestDisk?.devices ?? []).sorted {
            if $0.bsdName == $1.bsdName { return $0.registryEntryID < $1.registryEntryID }
            return $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
        }
        VStack(alignment: .leading, spacing: 5) {
            Text("Physical devices")
                .font(.caption)
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("Reading storage devices...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: DiskMenuDeviceRow.height, alignment: .top)
            } else {
                ForEach(items) { device in
                    DiskMenuDeviceRow(device: device)
                }
            }
        }
    }

    private var topProcesses: some View {
        let rows = Array(menuLists.topDisk.prefix(Self.processRowCount))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Process-attributed I/O")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ZStack(alignment: .topLeading) {
                if rows.isEmpty {
                    Text("Sampling...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { process in processRow(process) }
                }
            }
            .frame(
                height: Self.processRowHeight * CGFloat(Self.processRowCount),
                alignment: .top
            )
            Text("Process totals may differ from physical device activity.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    private func processRow(_ process: ProcessSample) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            Text(process.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(ByteFormat.rate(process.diskReadBytesPerSec)) R")
                .foregroundStyle(DiskStyle.read)
            Text("\(ByteFormat.rate(process.diskWriteBytesPerSec)) W")
                .foregroundStyle(DiskStyle.write)
        }
        .font(.caption.monospacedDigit())
        .frame(height: Self.processRowHeight)
    }
}

struct DiskMenuDeviceRow: View {
    static let height: CGFloat = 92

    let device: DiskDeviceSample

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(device.model)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help(device.model)
                Text(device.bsdName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 56, alignment: .trailing)
            }
            .frame(height: 18)

            HStack(spacing: 6) {
                Text(metadata)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help(metadata)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 14, height: 14)
                    .opacity(hasErrors ? 1 : 0)
                    .help(
                        counterSummary(
                            "%@ errors", read: device.readErrors, write: device.writeErrors)
                    )
                    .accessibilityLabel(
                        counterSummary(
                            "%@ errors", read: device.readErrors, write: device.writeErrors)
                    )
                    .accessibilityHidden(!hasErrors)
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.orange)
                    .frame(width: 14, height: 14)
                    .opacity(hasRetries ? 1 : 0)
                    .help(
                        counterSummary(
                            "%@ retries", read: device.readRetries, write: device.writeRetries)
                    )
                    .accessibilityLabel(
                        counterSummary(
                            "%@ retries", read: device.readRetries, write: device.writeRetries)
                    )
                    .accessibilityHidden(!hasRetries)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(height: 16)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Color.clear.frame(height: 14)
                    Text("Throughput").frame(height: 14)
                    Text("Service time").frame(height: 14)
                }
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
                direction(
                    "Read", rate: device.readBytesPerSec,
                    serviceTime: device.averageReadTimeMilliseconds, tint: DiskStyle.read)
                direction(
                    "Write", rate: device.writeBytesPerSec,
                    serviceTime: device.averageWriteTimeMilliseconds, tint: DiskStyle.write)
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(height: 50)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height, alignment: .top)
        .transaction { $0.animation = nil }
    }

    private var metadata: String {
        let parts = [
            device.sizeBytes.map { ByteFormat.string($0) },
            device.isInternal.map { $0 ? t("Internal") : t("External") },
            device.protocolName,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? t("Unavailable") : parts.joined(separator: " / ")
    }

    private var hasErrors: Bool { device.readErrors > 0 || device.writeErrors > 0 }
    private var hasRetries: Bool { device.readRetries > 0 || device.writeRetries > 0 }

    private func direction(
        _ title: LocalizedStringKey, rate: Double, serviceTime: Double?, tint: Color
    ) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title).foregroundStyle(tint).frame(height: 14)
            Text(rate.isFinite && rate >= 0 ? ByteFormat.rate(rate) : "--")
                .foregroundStyle(tint)
                .frame(height: 14)
            Text(Self.serviceTimeText(serviceTime))
                .foregroundStyle(.secondary)
                .frame(height: 14)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    static func serviceTimeText(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "--" }
        return String(format: "%.2f ms", milliseconds)
    }

    private func counterSummary(_ key: String, read: UInt64, write: UInt64) -> String {
        [
            t("%1$@: %2$@", t("Read"), t(key, String(read))),
            t("%1$@: %2$@", t("Write"), t(key, String(write))),
        ].joined(separator: "\n")
    }
}

private struct DiskReadWriteChart: View {
    let read: [Double]
    let write: [Double]
    var sampleCapacity: Int? = nil

    var body: some View {
        Canvas { context, size in
            let plot = MenuChart.plotRect(in: size, reserveGutter: false)
            let mid = plot.midY
            let halfHeight = plot.height / 2
            let peak = max(read.max() ?? 0, write.max() ?? 0, 1)
            let upper = peak * 1.2

            var centre = Path()
            centre.move(to: CGPoint(x: plot.minX, y: mid))
            centre.addLine(to: CGPoint(x: plot.maxX, y: mid))
            context.stroke(centre, with: .color(MenuChart.gridColor), lineWidth: 0.5)
            context.draw(
                Text(t("%@ peak", ByteFormat.rate(peak))).font(MenuChart.labelFont)
                    .foregroundColor(MenuChart.labelColor),
                at: CGPoint(x: plot.minX, y: plot.minY + 4), anchor: .topLeading)

            func points(_ values: [Double], upward: Bool) -> [CGPoint] {
                return values.enumerated().map { index, value in
                    let height = CGFloat(min(1, max(0, value / upper))) * halfHeight
                    let x: CGFloat
                    if let sampleCapacity, sampleCapacity > 0 {
                        let fraction = LiveChartGeometry.normalizedSlot(
                            index: index, count: values.count, capacity: sampleCapacity)
                        x = plot.minX + CGFloat(fraction) * plot.width
                    } else {
                        let step = values.count >= 2 ? plot.width / CGFloat(values.count - 1) : 0
                        x = plot.minX + CGFloat(index) * step
                    }
                    return CGPoint(
                        x: x,
                        y: upward ? mid - height : mid + height)
                }
            }
            if !read.isEmpty {
                MenuChart.drawTrend(
                    context, points: points(read, upward: true), baselineY: mid,
                    color: DiskStyle.read, gradientTop: plot.minY, gradientBottom: mid)
            }
            if !write.isEmpty {
                MenuChart.drawTrend(
                    context, points: points(write, upward: false), baselineY: mid,
                    color: DiskStyle.write, gradientTop: plot.maxY, gradientBottom: mid)
            }
        }
        .accessibilityHidden(true)
    }
}
