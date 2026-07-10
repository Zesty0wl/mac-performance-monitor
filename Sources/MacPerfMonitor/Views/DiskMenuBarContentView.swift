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
            DiskReadWriteChart(read: model.diskReadTrail(), write: model.diskWriteTrail())
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

    private func rateColumn(_ title: String, _ rate: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rate.map { ByteFormat.rate($0) } ?? "--")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func activitySummary(_ disk: DiskSample) -> some View {
        HStack(spacing: 14) {
            Text("\(Int(disk.readOperationsPerSec.rounded())) read IOPS")
            Text("\(Int(disk.writeOperationsPerSec.rounded())) write IOPS")
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var devices: some View {
        let items = model.latestDisk?.devices ?? []
        VStack(alignment: .leading, spacing: 5) {
            Text("Physical devices")
                .font(.caption)
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("Reading storage devices...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(device.model).lineLimit(1)
                            Spacer()
                            Text(device.bsdName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Text("\(ByteFormat.rate(device.readBytesPerSec)) R")
                            Text("\(ByteFormat.rate(device.writeBytesPerSec)) W")
                            if let size = device.sizeBytes { Text(ByteFormat.string(size)) }
                            if let internalDisk = device.isInternal {
                                Text(internalDisk ? "Internal" : "External")
                            }
                            if let protocolName = device.protocolName { Text(protocolName) }
                            if let readTime = device.averageReadTimeMilliseconds {
                                Text(String(format: "%.2f ms R", readTime))
                            }
                            if let writeTime = device.averageWriteTimeMilliseconds {
                                Text(String(format: "%.2f ms W", writeTime))
                            }
                            if device.readErrors + device.writeErrors > 0 {
                                Label(
                                    "\(device.readErrors + device.writeErrors) errors",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.red)
                            }
                            let retries = device.readRetries + device.writeRetries
                            if retries > 0 {
                                Text("\(retries) retries")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
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

private struct DiskReadWriteChart: View {
    let read: [Double]
    let write: [Double]

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
                Text("\(ByteFormat.rate(peak)) peak").font(MenuChart.labelFont)
                    .foregroundColor(MenuChart.labelColor),
                at: CGPoint(x: plot.minX, y: plot.minY + 4), anchor: .topLeading)

            func points(_ values: [Double], upward: Bool) -> [CGPoint] {
                let step = values.count >= 2 ? plot.width / CGFloat(values.count - 1) : 0
                return values.enumerated().map { index, value in
                    let height = CGFloat(min(1, max(0, value / upper))) * halfHeight
                    return CGPoint(
                        x: plot.minX + CGFloat(index) * step,
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
