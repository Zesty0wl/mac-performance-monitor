import MacPerfMonitorCore
import SwiftUI

/// The Disk tab: every disk fact the system exposes, on one page. Live
/// throughput, IOPS, service latency, and utilization ride the sampler's
/// existing tick and the v12 history columns; volumes, APFS containers,
/// hardware identity, and SMART health are pulled by `DiskDetailModel` at a
/// slow cadence while the tab is visible and stop entirely when it is not.
struct DiskUsageView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState

    @StateObject private var diskDetail = DiskDetailModel()

    @State private var range: HistoryWindow = .oneHour
    @State private var history: [SystemHistoryPoint] = []
    /// Downsampled timeline + live point, memoized like the dashboard's:
    /// recomputed only when source data changes, never inside body.
    @State private var points: [SystemHistoryPoint] = []
    @State private var loadedRange: HistoryWindow?
    @State private var topDiskConsumers: [ProcessConsumer] = []

    /// The tab's two pages. Remembered across launches: someone who came for
    /// the Disk Map keeps landing on it.
    enum SubPage: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case map = "Disk Map"
        var id: String { rawValue }
    }

    @AppStorage("diskSubPage") private var subPage: SubPage = .overview

    private var awaitingData: Bool { loadedRange != range }

    private var chartDomain: ClosedRange<Date>? {
        LiveChartGeometry.trailingDomain(latest: points.last?.date, span: range.seconds)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Page", selection: $subPage) {
                    ForEach(SubPage.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            Divider()
            switch subPage {
            case .overview: overview
            case .map: DiskMapView()
            }
        }
        .onAppear { consumeDiskMapRequest() }
        .onChange(of: appState.showDiskMap) { _, requested in
            if requested { consumeDiskMapRequest() }
        }
    }

    /// A menu command asked for the Disk Map; the same observe-then-clear
    /// idiom as the Network Scan request.
    private func consumeDiskMapRequest() {
        guard appState.showDiskMap else { return }
        subPage = .map
        appState.showDiskMap = false
    }

    /// The original Disk page. Its slow-cadence detail model runs only while
    /// this page is the one showing.
    private var overview: some View {
        ScrollView {
            MainRailLayout {
                pageHeader
                headlineCards
                throughputPanel
                activityPanel
                devicesPanel
                capacityPanel
            } rail: {
                healthPanel
                freeSpacePanel
                topProcessesPanel
            }
            .padding(20)
        }
        .onAppear {
            reload()
            diskDetail.start()
        }
        .onDisappear { diskDetail.stop() }
        .onChange(of: range) { reload() }
        .onChange(of: model.displayProcessesVersion) {
            if appState.mainWindowVisible { reload() }
        }
        .onReceive(model.liveTick) { _ in
            if appState.mainWindowVisible { rebuildPoints() }
        }
        .onChange(of: appState.mainWindowVisible) { _, visible in if visible { reload() } }
    }

    // MARK: - Header

    /// The primary (internal) disk's identity on the left, the shared range
    /// control on the right, mirroring the dashboard's page header.
    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryDiskTitle)
                    .font(.headline)
                Text(primaryDiskSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("HISTORY")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Picker("Range", selection: $range) {
                    ForEach(HistoryWindow.allCases) { r in Text(r.label).tag(r) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
                .historyRangeGate()
            }
        }
    }

    private var primaryDevice: DiskDeviceSample? {
        model.latestDisk?.devices.first
    }

    private var primaryDiskTitle: String {
        primaryDevice?.model ?? t("Disk")
    }

    private var primaryDiskSubtitle: String {
        guard let device = primaryDevice else { return t("Waiting for the first disk sample") }
        var parts: [String] = []
        if let size = device.sizeBytes { parts.append(ByteFormat.string(size)) }
        if let name = device.protocolName { parts.append(name) }
        parts.append(device.isInternal == true ? t("internal") : t("external"))
        let others = (model.latestDisk?.devices.count ?? 1) - 1
        if others > 0 {
            parts.append(
                others == 1
                    ? t("+%@ more disk", String(others))
                    : t("+%@ more disks", String(others)))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Headline cards

    private var headlineCards: some View {
        let rates = model.smoothedDiskRates
        let disk = model.latestDisk
        return MetricCardsRow(
            cards: [
                MetricCardData(
                    label: t("Read"),
                    value: rates.map { ByteFormat.rate($0.readBytesPerSec) },
                    tint: DiskStyle.read,
                    samples: points.map {
                        MetricSample(date: $0.date, value: $0.diskReadBytesPerSec)
                    },
                    help: t("Physical read throughput, smoothed over about 5 seconds.")),
                MetricCardData(
                    label: t("Write"),
                    value: rates.map { ByteFormat.rate($0.writeBytesPerSec) },
                    tint: DiskStyle.write,
                    samples: points.map {
                        MetricSample(date: $0.date, value: $0.diskWriteBytesPerSec)
                    },
                    help: t("Physical write throughput, smoothed over about 5 seconds.")),
                MetricCardData(
                    label: t("IOPS"),
                    value: disk.map {
                        "\(Int(($0.readOperationsPerSec + $0.writeOperationsPerSec).rounded()))"
                    },
                    samples: points.map {
                        MetricSample(
                            date: $0.date,
                            value: $0.diskReadOperationsPerSec + $0.diskWriteOperationsPerSec)
                    },
                    unit: .percent,
                    help: t("Read plus write operations per second across all disks.")),
                bootFreeCard,
            ],
            xDomain: chartDomain,
            gridColumns: 4,
            loading: awaitingData)
    }

    private var bootFreeCard: MetricCardData {
        let root = diskDetail.volumeSnapshot?.volumes.first(where: \.isRoot)
        // Finder-style figure (includes purgeable) when known; the sampler's
        // plain statfs figure otherwise.
        let free =
            root?.importantUsageAvailableBytes
            ?? root?.availableBytes
            ?? model.latest?.system.bootVolumeFreeBytes
        let total = root?.totalBytes ?? model.latest?.system.bootVolumeTotalBytes
        return MetricCardData(
            label: t("Free space"),
            value: free.map { ByteFormat.string($0) },
            samples: points.compactMap { point in
                point.bootFreeBytes.map { MetricSample(date: point.date, value: Double($0)) }
            },
            detail: total.map { t("of %@", ByteFormat.string($0)) },
            help: t(
                "Space the system could make available on the boot volume, "
                    + "including purgeable content."))
    }

    // MARK: - Main column panels

    private var throughputPanel: some View {
        DiskPanel("Throughput", systemImage: "internaldrive") {
            DiskChart(points: points, xDomain: chartDomain, showsTimeAxis: true)
                .frame(height: 170)
                .chartReloading(awaitingData)
            footnote(
                "Physical traffic across real internal and external disks. Disk images are excluded, and per-process attribution below may not add up to this: filesystem caching, metadata, and paging are device traffic too."
            )
        }
    }

    private var activityPanel: some View {
        DiskPanel("Operations and latency", systemImage: "waveform.path.ecg") {
            HStack(spacing: 24) {
                diskStat(
                    t("Read latency"),
                    model.latestDisk?.readLatencyMs.map { String(format: "%.2f ms", $0) },
                    DiskStyle.read)
                diskStat(
                    t("Write latency"),
                    model.latestDisk?.writeLatencyMs.map { String(format: "%.2f ms", $0) },
                    DiskStyle.write)
                utilizationStat
                Spacer(minLength: 0)
            }
            chartCaption("OPERATIONS PER SECOND")
            DiskIOPSChart(points: points, xDomain: chartDomain)
                .frame(height: 110)
                .chartReloading(awaitingData)
            chartCaption("SERVICE TIME PER OPERATION")
            DiskLatencyChart(points: points, xDomain: chartDomain, showsTimeAxis: true)
                .frame(height: 110)
                .chartReloading(awaitingData)
            footnote(
                "Service time is the device's average per completed operation; gaps mean no IO happened in that interval. Utilization is the busiest disk's share of time spent servicing IO."
            )
        }
    }

    @ViewBuilder private var utilizationStat: some View {
        let utilization = model.latestDisk?.utilizationPercent
        VStack(alignment: .leading, spacing: 2) {
            Text("UTILIZATION")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(utilization.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(DiskStyle.utilization(utilization ?? 0))
                Gauge(value: min(utilization ?? 0, 100), in: 0...100) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(DiskStyle.utilization(utilization ?? 0))
                    .frame(width: 60)
                    .accessibilityLabel("Disk utilization")
            }
        }
    }

    private var devicesPanel: some View {
        DiskPanel("Devices", systemImage: "externaldrive") {
            if let devices = model.latestDisk?.devices, !devices.isEmpty {
                ForEach(devices) { device in
                    DeviceCard(
                        device: device,
                        hardware: diskDetail.hardware[device.registryEntryID])
                }
            } else {
                Text("No physical disks visible yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var capacityPanel: some View {
        DiskPanel("Capacity and volumes", systemImage: "chart.bar.doc.horizontal") {
            if let snapshot = diskDetail.volumeSnapshot {
                let standalone = snapshot.volumes.filter { $0.containerBSDName == nil }
                ForEach(orderedContainers(snapshot)) { container in
                    CapacityBarSection(
                        title: containerTitle(container, volumes: snapshot.volumes),
                        subtitle: containerSubtitle(container),
                        slices: DiskCapacityBreakdown.slices(
                            container: container, volumes: snapshot.volumes))
                }
                ForEach(standalone) { volume in
                    CapacityBarSection(
                        title: volume.name,
                        subtitle: t("%1$@ at %2$@", volume.fsTypeName, volume.mountPoint),
                        slices: DiskCapacityBreakdown.slices(standaloneVolume: volume))
                }
                footnote(
                    "APFS volumes share their container's free pool, so a container's volumes are one bar. Purgeable space is allocated content the system can reclaim when needed."
                )
            } else {
                Text("Reading volumes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Boot container first, then the rest by name.
    private func orderedContainers(_ snapshot: VolumeSnapshot) -> [APFSContainerInfo] {
        let bootContainer = snapshot.volumes.first(where: \.isRoot)?.containerBSDName
        return snapshot.containers.sorted {
            if ($0.bsdName == bootContainer) != ($1.bsdName == bootContainer) {
                return $0.bsdName == bootContainer
            }
            return $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
        }
    }

    private func containerTitle(_ container: APFSContainerInfo, volumes: [VolumeInfo]) -> String {
        let isBoot = volumes.contains { $0.isRoot && $0.containerBSDName == container.bsdName }
        return isBoot
            ? t("Boot container (%@)", container.bsdName)
            : t("Container %@", container.bsdName)
    }

    private func containerSubtitle(_ container: APFSContainerInfo) -> String {
        var parts: [String] = []
        if let capacity = container.capacityBytes {
            parts.append(ByteFormat.string(capacity))
        }
        if !container.physicalStoreBSDNames.isEmpty {
            parts.append(t("on %@", container.physicalStoreBSDNames.joined(separator: ", ")))
        }
        parts.append(t("%@ volumes", String(container.volumeBSDNames.count)))
        return parts.joined(separator: ", ")
    }

    // MARK: - Rail panels

    private var healthPanel: some View {
        DiskPanel("Health", systemImage: "stethoscope") {
            if let (device, smart) = primarySMART {
                smartSection(device: device, smart: smart)
            } else {
                Text(
                    LocalizedStringKey(
                        "SMART data is not available for this disk. External and USB enclosures "
                            + "usually do not expose it.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            errorCountsSection
        }
    }

    private var primarySMART: (DiskDeviceSample, NVMeSMARTSnapshot)? {
        guard let devices = model.latestDisk?.devices else { return nil }
        for device in devices {
            if let smart = diskDetail.smart[device.registryEntryID] { return (device, smart) }
        }
        return nil
    }

    @ViewBuilder
    private func smartSection(device: DiskDeviceSample, smart: NVMeSMARTSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(
                systemName: smart.isHealthy
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(smart.isHealthy ? Color.green : Color.red)
            Text(smart.isHealthy ? "Verified" : "Failing")
                .font(.subheadline.weight(.semibold))
            Text(device.bsdName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            t(
                "SMART status %1$@ for %2$@",
                smart.isHealthy ? t("verified") : t("failing"), device.bsdName))

        VStack(alignment: .leading, spacing: 5) {
            if let temperature = smart.temperatureCelsius {
                infoRow("Temperature", String(format: "%.0f\u{202F}C", temperature))
            }
            wearRow(smart)
            infoRow(
                "Available spare",
                t(
                    "%1$@%% (threshold %2$@%%)",
                    String(smart.availableSparePercent), String(smart.spareThresholdPercent)))
            infoRow("Power-on time", t("%@ hours", String(smart.powerOnHours)))
            infoRow("Power cycles", "\(smart.powerCycles)")
            infoRow("Unsafe shutdowns", "\(smart.unsafeShutdowns)")
            infoRow("Media errors", "\(smart.mediaErrors)", dimZero: true)
            infoRow("Error log entries", "\(smart.errorLogEntries)", dimZero: true)
            infoRow("Lifetime reads", ByteFormat.string(smart.bytesRead))
            infoRow("Lifetime writes", ByteFormat.string(smart.bytesWritten))
        }
    }

    private func wearRow(_ smart: NVMeSMARTSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("Life used")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Gauge(value: min(Double(smart.percentageUsed), 100), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(smart.percentageUsed >= 80 ? .red : .accentColor)
                .frame(width: 70)
                .accessibilityHidden(true)
            Text("\(smart.percentageUsed)%")
                .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t("Drive life used %@ percent", String(smart.percentageUsed)))
    }

    @ViewBuilder private var errorCountsSection: some View {
        if let devices = model.latestDisk?.devices, !devices.isEmpty {
            Divider()
            chartCaption("DRIVER ERROR COUNTERS SINCE BOOT")
            VStack(alignment: .leading, spacing: 5) {
                ForEach(devices) { device in
                    infoRow(
                        LocalizedStringKey(device.bsdName),
                        [
                            t("%@ errors", String(device.readErrors + device.writeErrors)),
                            t("%@ retries", String(device.readRetries + device.writeRetries)),
                        ].joined(separator: ", "),
                        dimZero: device.readErrors + device.writeErrors
                            + device.readRetries + device.writeRetries == 0)
                }
            }
        }
    }

    private var freeSpacePanel: some View {
        DiskPanel("Free space", systemImage: "chart.line.downtrend.xyaxis") {
            FreeSpaceChart(points: points, xDomain: chartDomain, showsTimeAxis: true)
                .frame(height: 120)
                .chartReloading(awaitingData)
            purgeableSummary
            footnote(
                "Boot volume free space over the selected range, sampled once a minute. On APFS this is the container's shared pool."
            )
        }
    }

    @ViewBuilder private var purgeableSummary: some View {
        if let volumes = diskDetail.volumeSnapshot?.volumes {
            let purgeable = volumes.compactMap(\.purgeableBytes).max() ?? 0
            if purgeable > 0 {
                infoRow("Purgeable", ByteFormat.string(purgeable))
            }
        }
    }

    private var topProcessesPanel: some View {
        DiskPanel("Top disk processes", systemImage: "list.number") {
            if topDiskConsumers.isEmpty {
                Text("No attributed disk activity in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(topDiskConsumers.prefix(8)) { process in
                    HStack(spacing: 7) {
                        Image(
                            nsImage: ProcessIconProvider.shared.icon(
                                forPath: process.executablePath)
                        )
                        .resizable()
                        .frame(width: 16, height: 16)
                        Text(process.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(ByteFormat.rate(process.averageDisk))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            footnote("Kernel-attributed I/O over the selected range; read plus write.")
        }
    }

    // MARK: - Shared bits

    private func diskStat(_ label: String, _ value: String?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value ?? "--")
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    private func chartCaption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func infoRow(
        _ label: LocalizedStringKey, _ value: String, dimZero: Bool = false
    ) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(dimZero ? .tertiary : .primary)
        }
    }

    private func infoRow(_ label: String, _ value: String, dimZero: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(dimZero ? .tertiary : .primary)
        }
    }

    private static let maxChartPoints = 360

    private func rebuildPoints() {
        var pts = history
        if let system = model.liveSystem {
            let live = SystemHistoryPoint(
                date: system.timestamp,
                pressurePercent: system.pressurePercent,
                appMemory: system.appMemory,
                wired: system.wired,
                compressed: system.compressed,
                cachedFiles: system.cachedFiles,
                swapUsed: system.swapUsed,
                diskReadBytesPerSec: system.diskReadBytesPerSec,
                diskWriteBytesPerSec: system.diskWriteBytesPerSec,
                diskReadOperationsPerSec: system.diskReadOperationsPerSec,
                diskWriteOperationsPerSec: system.diskWriteOperationsPerSec,
                diskReadLatencyMs: system.diskReadLatencyMs,
                diskWriteLatencyMs: system.diskWriteLatencyMs,
                diskUtilizationPercent: system.diskUtilizationPercent,
                bootFreeBytes: system.bootVolumeFreeBytes,
                bootTotalBytes: system.bootVolumeTotalBytes
            )
            if let last = pts.last {
                if live.date > last.date { pts.append(live) }
            } else {
                pts.append(live)
            }
        }
        points = pts
    }

    private func reload() {
        let requested = range
        model.loadSystemHistory(requested, downsampledTo: Self.maxChartPoints) { pts in
            self.history = pts
            self.loadedRange = requested
            self.rebuildPoints()
        }
        model.loadTopConsumers(window: requested, metric: .averageDisk, limit: 8) { rows in
            guard self.range == requested else { return }
            self.topDiskConsumers = rows
        }
    }
}

// MARK: - Device card

/// One physical disk: identity row, hardware facts (nil rows omitted), and a
/// live activity strip. Hardware identity arrives from `DiskDetailModel` a
/// beat after first render; rows appear as they resolve.
private struct DeviceCard: View {
    let device: DiskDeviceSample
    let hardware: DiskHardwareInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: device.isInternal == true ? "internaldrive" : "externaldrive")
                    .foregroundStyle(.secondary)
                Text(device.model)
                    .font(.subheadline.weight(.semibold))
                Text(device.bsdName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if device.isRemovable {
                    badge("Removable")
                }
                badge(device.isInternal == true ? "Internal" : "External")
                Spacer()
                if let size = device.sizeBytes {
                    Text(ByteFormat.string(size))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            factGrid

            liveStrip
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.4)))
    }

    private var facts: [(String, String)] {
        var rows: [(String, String)] = []
        if let name = device.protocolName { rows.append((t("Protocol"), name)) }
        if let hardware {
            if let vendor = hardware.vendorName { rows.append((t("Vendor"), vendor)) }
            if let revision = hardware.productRevision { rows.append((t("Revision"), revision)) }
            if let firmware = hardware.firmwareRevision, firmware != hardware.productRevision {
                rows.append((t("Firmware"), firmware))
            }
            if let serial = hardware.serialNumber { rows.append((t("Serial"), serial)) }
            if let interconnect = hardware.interconnect {
                let location = hardware.interconnectLocation.map { " (\($0))" } ?? ""
                rows.append((t("Interconnect"), interconnect + location))
            }
            if let solidState = hardware.isSolidState {
                rows.append((t("Medium"), solidState ? t("Solid state") : t("Rotational")))
            }
            if let blockSize = hardware.physicalBlockSizeBytes {
                rows.append((t("Block size"), t("%@ bytes", String(blockSize))))
            }
            if let nand = hardware.nandStatus { rows.append((t("NAND status"), nand)) }
            if let revision = hardware.nvmeRevision {
                rows.append((t("NVMe revision"), revision))
            }
            if let controller = hardware.controllerClass {
                rows.append((t("Controller"), controller))
            }
        }
        return rows
    }

    private var factGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            alignment: .leading, spacing: 4
        ) {
            ForEach(facts, id: \.0) { fact in
                HStack(spacing: 4) {
                    Text(fact.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(fact.1)
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var liveStrip: some View {
        HStack(spacing: 14) {
            liveValue("R", ByteFormat.rate(device.readBytesPerSec), DiskStyle.read)
            liveValue("W", ByteFormat.rate(device.writeBytesPerSec), DiskStyle.write)
            liveValue(
                "IOPS",
                "\(Int((device.readOperationsPerSec + device.writeOperationsPerSec).rounded()))",
                .primary)
            if let readTime = device.averageReadTimeMilliseconds {
                liveValue(t("R lat"), String(format: "%.2f ms", readTime), .secondary)
            }
            if let writeTime = device.averageWriteTimeMilliseconds {
                liveValue(t("W lat"), String(format: "%.2f ms", writeTime), .secondary)
            }
            if let utilization = device.utilizationPercent {
                liveValue(
                    t("Busy"), "\(Int(utilization.rounded()))%",
                    DiskStyle.utilization(utilization))
            }
            Spacer(minLength: 0)
        }
    }

    private func liveValue(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    private func badge(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Capacity bar

/// One container (or standalone volume): a single horizontal stacked bar with
/// 2 point gaps between slices, and a legend of name, role, mount, bytes, and
/// percent rows. Colors come from `DiskStyle.capacityColor`, whose slot order
/// is the validated one; the free slice renders as a recessive track.
private struct CapacityBarSection: View {
    let title: String
    let subtitle: String
    let slices: [DiskCapacitySlice]

    private var totalBytes: UInt64 { max(slices.reduce(0) { $0 + $1.bytes }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            bar
                .frame(height: 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(t("%@ capacity", title))
                .accessibilityValue(accessibilitySummary)
            legend
        }
        .padding(.bottom, 6)
    }

    private var bar: some View {
        GeometryReader { geometry in
            let gaps = CGFloat(max(slices.count - 1, 0)) * 2
            let available = max(geometry.size.width - gaps, 1)
            HStack(spacing: 2) {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(for: slice, at: index))
                        .frame(
                            width: max(
                                available * CGFloat(slice.bytes) / CGFloat(totalBytes),
                                slice.bytes > 0 ? 3 : 0))
                }
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: slice, at: index))
                        .frame(width: 8, height: 8)
                    Text(legendLabel(slice))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let role = slice.role {
                        Text(t(role.label))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.secondary)
                    }
                    if let detail = slice.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteFormat.string(slice.bytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(percentText(slice))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    /// Named volume slices count their own index among volumes so folded and
    /// fixed-slot slices do not shift their colors.
    private func color(for slice: DiskCapacitySlice, at index: Int) -> Color {
        let namedIndex = slices.prefix(index).filter { $0.kind == .volume }.count
        return DiskStyle.capacityColor(for: slice, namedIndex: namedIndex)
    }

    private func legendLabel(_ slice: DiskCapacitySlice) -> String {
        if case .otherVolumes(let count) = slice.kind {
            return t("Other volumes (%@)", String(count))
        }
        return slice.label
    }

    private func percentText(_ slice: DiskCapacitySlice) -> String {
        let percent = Double(slice.bytes) / Double(totalBytes) * 100
        if percent > 0 && percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }

    private var accessibilitySummary: String {
        slices.map { "\(legendLabel($0)) \(ByteFormat.string($0.bytes))" }
            .joined(separator: ", ")
    }
}

// MARK: - Panel chrome

/// The page's card chrome, matching the dashboard's panel (each page keeps a
/// private copy by convention).
private struct DiskPanel<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var content: () -> Content

    init(
        _ title: LocalizedStringKey, systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
