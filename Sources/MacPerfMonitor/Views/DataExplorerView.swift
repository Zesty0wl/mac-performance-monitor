import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI
import UniformTypeIdentifiers

struct DataExplorerView: View {
    @ObservedObject var explorer: DataExplorerModel
    @Environment(\.samplerModel) private var sampler
    @EnvironmentObject private var monitor: MonitorSelection
    @EnvironmentObject private var appState: AppState
    let onImport: (ImportedTrace) -> Void
    var onLegacy: () -> Void = {}

    @State private var sourcePane = 0
    @State private var inspectorPane = 0
    @State private var showDate = false
    @State private var requestedTime = Date()
    @State private var requestedSeconds = 0
    @State private var showExport = false
    @State private var importError: String?
    @State private var errorTitle = t("Could not open trace")
    @State private var openingTrace = false
    @AppStorage("explorer.chartGrid") private var chartGrid = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    sidebar.frame(width: geometry.size.width >= 1100 ? 226 : 198)
                    Divider()
                    VStack(spacing: 0) {
                        timelineHeader
                        Divider()
                        chartWorkspace
                        if explorer.showsInspector, geometry.size.width < 1100 {
                            Divider()
                            inspector.frame(height: 210)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    if explorer.showsInspector, geometry.size.width >= 1100 {
                        Divider()
                        inspector.frame(width: 300)
                    }
                }
            }
            Divider()
            statusBar
        }
        .onAppear {
            sampler?.addGPUConsumer()
            sampler?.addProcessConsumer()
            explorer.start(sampler: sampler, identities: monitor.identities)
        }
        .onDisappear {
            explorer.stop()
            sampler?.removeGPUConsumer()
            sampler?.removeProcessConsumer()
        }
        .onChange(of: monitor.identities) { _, identities in explorer.setSelection(identities) }
        .onChange(of: explorer.processQuery) { _, _ in explorer.search(debounce: true) }
        .onReceive(
            sampler?.liveTick.eraseToAnyPublisher() ?? Empty<Void, Never>().eraseToAnyPublisher()
        ) { _ in
            if appState.mainWindowVisible { explorer.tick() }
        }
        .sheet(isPresented: $showExport) {
            if let sampler {
                TraceExportSheet(
                    currentView: explorer.domain, preselected: monitor.identities,
                    recorded: explorer.selectedProcesses,
                    initialResolution: explorer.sourceTier == .raw
                        ? .full : (explorer.sourceTier == .minute ? .standard : .coarse)
                )
                .environmentObject(sampler)
            }
        }
        .alert(
            errorTitle,
            isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .accessibilityIdentifier("explorer.workspace")
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label("Explorer", systemImage: "waveform.path.ecg.rectangle").font(.headline)
                navigationControls
                Spacer(minLength: 4)
                workspaceControls
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Explorer", systemImage: "waveform.path.ecg.rectangle").font(.headline)
                    Spacer()
                    workspaceControls
                }
                navigationControls
            }
        }
        .controlSize(.small)
    }

    private var navigationControls: some View {
        HStack(spacing: 5) {
            tool("Earlier", icon: "chevron.left") { explorer.pan(-0.8) }
            tool("Later", icon: "chevron.right") { explorer.pan(0.8) }
                .disabled(explorer.followsLive)
            Menu {
                ForEach(HistoryWindow.allCases) { window in
                    Button(window.label) { explorer.chooseWindow(window) }
                }
            } label: {
                Text(TrendStatistics.duration(explorer.span)).monospacedDigit().frame(minWidth: 58)
            }
            .help("Visible time window")
            tool("Go to time", icon: "calendar") {
                requestedTime = explorer.cursor.date ?? explorer.domain.upperBound
                requestedSeconds = Calendar.current.component(.second, from: requestedTime)
                showDate = true
            }
            .popover(isPresented: $showDate) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Go to time").font(.headline)
                    DatePicker(
                        "Date and time", selection: $requestedTime, in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute])
                    Stepper("Seconds: \(requestedSeconds)", value: $requestedSeconds, in: 0...59)
                    HStack {
                        Spacer()
                        Button("Go") {
                            let minute =
                                Calendar.current.dateInterval(of: .minute, for: requestedTime)?
                                .start ?? requestedTime
                            explorer.showTime(
                                min(Date(), minute.addingTimeInterval(Double(requestedSeconds))))
                            showDate = false
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding(18).frame(width: 330)
            }
            tool("Zoom in", icon: "plus.magnifyingglass") { explorer.zoom(0.5) }
            tool("Zoom out", icon: "minus.magnifyingglass") { explorer.zoom(2) }
            Button {
                explorer.toggleLive()
            } label: {
                Label(
                    explorer.followsLive ? "Live" : "Resume live",
                    systemImage: explorer.followsLive ? "pause.fill" : "play.fill"
                )
                .frame(minWidth: 78)
            }
            .tint(explorer.followsLive ? .green : .accentColor)
            .accessibilityIdentifier("explorer.live")
        }
    }

    private var workspaceControls: some View {
        HStack(spacing: 6) {
            tool("Chart layout", icon: chartGrid ? "rectangle.grid.1x2" : "square.grid.2x2") {
                chartGrid.toggle()
            }
            tool("Refresh", icon: "arrow.clockwise") { explorer.refresh() }
                .disabled(explorer.loading)
            tool("Inspector", icon: "sidebar.right") { explorer.showsInspector.toggle() }
            Menu {
                Button("Export visible data", systemImage: "tablecells") { exportCSV() }
                    .disabled(explorer.lanes.isEmpty)
                Button("Export process trace", systemImage: "square.and.arrow.up") {
                    showExport = true
                }
                .disabled(monitor.identities.isEmpty || sampler == nil)
                Button("Import trace", systemImage: "square.and.arrow.down") { importTrace() }
                    .disabled(openingTrace)
                Divider()
                Button("Process monitor", systemImage: "chart.xyaxis.line", action: onLegacy)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .help("Data and tools")
        }
    }

    private func tool(
        _ title: LocalizedStringKey, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 24, height: 22)
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Sources", selection: $sourcePane) {
                Text("Metrics").tag(0)
                Text("Processes").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            if sourcePane == 0 { metricSources } else { processSources }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var metricSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter metrics", text: $explorer.sourceQuery)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 10)
            Menu {
                Button("Overview") { explorer.preset(nil) }
                ForEach(ExplorerSourceGroup.allCases) { group in
                    Button(group.title) { explorer.preset(group) }
                }
            } label: {
                Label("Views", systemImage: "line.3.horizontal.decrease")
            }.padding(.horizontal, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ExplorerSourceGroup.allCases) { group in
                        let definitions = explorer.definitions.filter {
                            $0.group == group
                                && (explorer.sourceQuery.isEmpty
                                    || $0.title.localizedCaseInsensitiveContains(
                                        explorer.sourceQuery))
                        }
                        if !definitions.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(group.title, systemImage: group.icon)
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(definitions) { definition in
                                    Toggle(
                                        definition.title,
                                        isOn: Binding(
                                            get: { explorer.enabled.contains(definition.id) },
                                            set: { _ in explorer.toggleLane(definition.id) })
                                    )
                                    .toggleStyle(.checkbox)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("explorer.metric.\(definition.id)")
                                }
                            }
                        }
                    }
                }.padding(12)
            }
        }
    }

    private var processSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name or PID", text: $explorer.processQuery)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 10)
            Text(
                t(
                    "Compared: %1$@ of %2$@", String(monitor.identities.count),
                    String(monitor.capacity))
            )
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            if !explorer.selectedProcesses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(explorer.selectedProcesses) { process in
                        HStack(spacing: 6) {
                            Circle().fill(explorer.color(for: process.id)).frame(
                                width: 7, height: 7)
                            Text(process.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 0)
                            Button {
                                monitor.remove(process.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain).help("Remove from comparison")
                        }
                    }
                }.padding(.horizontal, 12)
                Divider()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(explorer.searchResults) { process in
                        Button {
                            monitor.toggle(process.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(
                                    systemName: monitor.contains(process.id)
                                        ? "checkmark.circle.fill" : "plus.circle"
                                )
                                .foregroundStyle(
                                    monitor.contains(process.id)
                                        ? explorer.color(for: process.id) : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(process.name).font(.callout).lineLimit(1).truncationMode(
                                        .middle)
                                    Text(t("PID %@", String(process.id.pid)))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(
                                            .secondary)
                                    Text(
                                        process.lastSeen,
                                        format: .dateTime.month(.abbreviated).day().hour().minute()
                                    )
                                    .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(monitor.isFull && !monitor.contains(process.id))
                        .help(process.executablePath ?? process.name)
                    }
                    if explorer.searchResults.isEmpty {
                        Text("No recorded processes in this window")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }
            }
        }
    }

    private var timelineHeader: some View {
        HStack(spacing: 8) {
            Text(
                TrendStatistics.intervalText(
                    start: explorer.domain.lowerBound.timeIntervalSinceReferenceDate,
                    end: explorer.domain.upperBound.timeIntervalSinceReferenceDate)
            )
            .font(.caption.monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if explorer.loading || explorer.preparing { ProgressView().controlSize(.mini) }
            if explorer.focusedLaneID != nil {
                Button("All charts") { explorer.focusedLaneID = nil }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14).frame(height: 38)
    }

    /// The lanes on screen: the focused one alone, or every enabled lane.
    private var visibleLanes: [ExplorerLane] {
        explorer.lanes.filter { explorer.focusedLaneID == nil || $0.id == explorer.focusedLaneID }
    }

    /// One or two charts stack full width and share the height rather than
    /// leaving most of the workspace empty.
    private var lanesFillHeight: Bool { (1...2).contains(visibleLanes.count) }

    private var chartWorkspace: some View {
        GeometryReader { geometry in
            ScrollView {
                if lanesFillHeight {
                    VStack(spacing: 0) {
                        errorBanner
                        ForEach(visibleLanes) { lane in
                            laneView(lane, fillsHeight: true)
                            Divider()
                        }
                    }
                    // Short windows scroll rather than squash the charts.
                    .frame(
                        height: max(
                            geometry.size.height, CGFloat(visibleLanes.count) * Self.minimumFillLane
                        ))
                } else {
                    LazyVStack(spacing: 0) {
                        errorBanner
                        if chartGrid, explorer.focusedLaneID == nil {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 370), spacing: 0)],
                                spacing: 0
                            ) {
                                ForEach(explorer.lanes) { lane in
                                    VStack(spacing: 0) {
                                        laneView(lane)
                                        Divider()
                                    }
                                }
                            }
                        } else {
                            ForEach(visibleLanes) { lane in
                                laneView(lane)
                                Divider()
                            }
                        }
                        if explorer.lanes.isEmpty {
                            ContentUnavailableView(
                                "No metrics selected", systemImage: "chart.xyaxis.line"
                            )
                            .frame(minHeight: 280)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("explorer.charts")
        .opacity(explorer.loading || explorer.preparing ? 0.45 : 1)
    }

    /// Height below which a filling lane stops shrinking and the stack scrolls.
    private static let minimumFillLane: CGFloat = 240

    @ViewBuilder private var errorBanner: some View {
        if let error = explorer.error {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                Spacer()
                Button("Retry") { explorer.refresh() }
            }.foregroundStyle(.orange).padding(16)
        }
    }

    /// Offers the other scale when the lane's axis left a spike off the top,
    /// or was switched to show it.
    @ViewBuilder private func scaleControl(_ lane: ExplorerLane) -> some View {
        if let peak = lane.feed.model.outlierPeak {
            if explorer.fullScaleLaneIDs.contains(lane.id) {
                Button {
                    explorer.toggleFullScale(lane.id)
                } label: {
                    Label("Fit scale", systemImage: "arrow.down.to.line").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Fit the axis to the rest of the data")
            } else if let top = lane.feed.model.yDomain?.upperBound, peak > top {
                Button {
                    explorer.toggleFullScale(lane.id)
                } label: {
                    Label(
                        t("Peak %@ off scale", lane.definition.unit.format(peak)),
                        systemImage: "arrow.up.to.line"
                    ).font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
                .help("Show full scale")
            }
        }
    }

    private func laneView(_ lane: ExplorerLane, fillsHeight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    explorer.selectedLaneID = lane.id
                    explorer.showsInspector = true
                    inspectorPane = 0
                } label: {
                    Label(lane.definition.title, systemImage: lane.definition.group.icon)
                        .font(.subheadline.weight(.semibold))
                }.buttonStyle(.plain)
                Spacer(minLength: 0)
                scaleControl(lane)
                Text(lane.definition.isProcess ? t("Processes") : t("Machine"))
                    .font(.caption2).foregroundStyle(.secondary)
                Button {
                    explorer.focusedLaneID = explorer.focusedLaneID == lane.id ? nil : lane.id
                    explorer.selectedLaneID = lane.id
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(
                        width: 24, height: 22)
                }.buttonStyle(.plain).help("Focus chart")
            }
            if lane.definition.isProcess, monitor.identities.isEmpty {
                HStack {
                    Text("No processes selected").font(.caption).foregroundStyle(.secondary)
                    Button("Add processes") { sourcePane = 1 }.controlSize(.small)
                }.frame(height: 70)
            } else {
                ExplorerTrendChart(
                    feed: lane.feed, cursor: explorer.cursor,
                    allowsInspection: !explorer.loading && !explorer.preparing,
                    onZoom: { factor, fraction in explorer.zoom(factor, anchorFraction: fraction) }
                ) { date in
                    explorer.selectedLaneID = lane.id
                    explorer.inspect(date)
                }
                .frame(height: fillsHeight ? nil : explorer.focusedLaneID == nil ? 165 : 350)
                .frame(minHeight: fillsHeight ? 120 : nil, maxHeight: fillsHeight ? .infinity : nil)
                .accessibilityIdentifier("explorer.chart.\(lane.id)")
                if lane.feed.model.series.allSatisfy({
                    !$0.column.values.contains(where: \.isFinite)
                }) {
                    Text("No recorded data in this window")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !lane.feed.model.series.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(lane.feed.model.series.enumerated()), id: \.offset) {
                            _, series in
                            HStack(spacing: 5) {
                                Circle().fill(series.color).frame(width: 6, height: 6)
                                Text(series.name).font(.caption2)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
        .background(explorer.selectedLaneID == lane.id ? Color.accentColor.opacity(0.035) : .clear)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorPane) {
                Text("Values").tag(0)
                Text("Processes").tag(1)
                Text("Hardware").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(10)
            if inspectorPane == 0 {
                ExplorerValueInspector(explorer: explorer, cursor: explorer.cursor)
            } else if inspectorPane == 1 {
                processInspector
            } else {
                ExplorerHardwareInspector(hardware: .shared)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    private var processInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let date = explorer.observationTime {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                        .font(.caption.monospacedDigit())
                } else {
                    Text("No time selected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    explorer.inspect(explorer.cursor.date ?? explorer.domain.upperBound)
                } label: {
                    Image(systemName: "scope").frame(width: 24, height: 22)
                }.help("Inspect processes at cursor")
            }.padding(.horizontal, 12)
            if explorer.inspecting { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(explorer.observations) { observation in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(observation.process.name).font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Button {
                                    monitor.toggle(observation.id)
                                } label: {
                                    Image(
                                        systemName: monitor.contains(observation.id)
                                            ? "checkmark.circle.fill" : "plus.circle")
                                }
                                .buttonStyle(.plain)
                                .disabled(monitor.isFull && !monitor.contains(observation.id))
                                .help("Compare process")
                            }
                            HStack {
                                Text(t("PID %@", String(observation.id.pid)))
                                Spacer()
                                Text(
                                    observation.point.values[.cpu].map(ExplorerUnit.percent.format)
                                        ?? "--")
                                Text(
                                    observation.point.values[.footprint].map(
                                        ExplorerUnit.bytes.format) ?? "--")
                            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Text(observation.point.date, format: .dateTime.hour().minute().second())
                                .font(.caption2).foregroundStyle(.tertiary)
                            DisclosureGroup("Details") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(
                                        observation.process.executablePath
                                            ?? observation.process.name
                                    )
                                    .font(.caption).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    Text(
                                        t(
                                            "Started: %@",
                                            observation.id.startTime.formatted(
                                                date: .abbreviated, time: .standard))
                                    )
                                    .font(.caption2).foregroundStyle(.secondary)
                                    ForEach(ExplorerProcessMetric.allCases, id: \.self) { metric in
                                        if let value = observation.point.values[metric] {
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(ExplorerMetrics.processTitle(metric))
                                                    .foregroundStyle(.secondary)
                                                Spacer(minLength: 8)
                                                Text(rawProcessValue(value, metric: metric))
                                                    .monospacedDigit()
                                            }.font(.caption2)
                                        }
                                    }
                                }.padding(.top, 6)
                            }.font(.caption)
                        }
                        .padding(12)
                        .help(observation.process.executablePath ?? observation.process.name)
                        Divider()
                    }
                    if explorer.observationTime != nil, !explorer.inspecting,
                        explorer.observations.isEmpty
                    {
                        Text("No recent process observations at this time")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle().fill(explorer.followsLive ? .green : .secondary).frame(width: 6, height: 6)
            Text(explorer.followsLive ? t("Following live") : t("Fixed time window"))
            Text(t("%@ charts", String(explorer.lanes.count)))
            Spacer(minLength: 8)
            if !explorer.hasHistory {
                Text("History unavailable; live samples only")
            } else if !explorer.usesRecordedHistory {
                Text("Live samples, not recorded")
            }
            if let loadedAt = explorer.loadedAt {
                Text(loadedAt, format: .dateTime.hour().minute().second())
            }
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 28)
    }

    private func importTrace() {
        errorTitle = t("Could not open trace")
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [TraceFileType.utType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openingTrace = true
        TraceFileLoader.load(url) { result in
            openingTrace = false
            switch result {
            case .success(let trace): onImport(trace)
            case .failure(let error): importError = error.localizedDescription
            }
        }
    }

    private func exportCSV() {
        errorTitle = t("Export failed")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Explorer.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let models = explorer.lanes
            .filter { explorer.focusedLaneID == nil || $0.id == explorer.focusedLaneID }
            .map { ($0.definition.title, $0.feed.model) }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ExplorerCSV.encode(models).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async { importError = error.localizedDescription }
            }
        }
    }

    private func rawProcessValue(_ value: Double, metric: ExplorerProcessMetric) -> String {
        switch metric {
        case .diskRead, .diskWrite: return ExplorerUnit.bytes.format(value)
        case .energyTotal, .cpuUser, .cpuSystem:
            return ExplorerMetrics.processUnit(metric).format(value / 1_000_000_000)
        default: return ExplorerMetrics.processUnit(metric).format(value)
        }
    }
}

private struct ExplorerValueInspector: View {
    @ObservedObject var explorer: DataExplorerModel
    let cursor: ExplorerCursor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !explorer.alertEvidence.isEmpty {
                    Text("Alert evidence").font(.subheadline.weight(.semibold))
                    ForEach(explorer.alertEvidence) { alert in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(alert.title).font(.caption.weight(.semibold))
                            Text(alert.body).font(.caption).fixedSize(
                                horizontal: false, vertical: true)
                            Text(
                                alert.evidence?.end ?? alert.date,
                                format: .dateTime.month(.abbreviated).day().hour().minute().second()
                            )
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
                ExplorerCursorValues(explorer: explorer, cursor: cursor)
                if let lane = explorer.lanes.first(where: { $0.id == explorer.selectedLaneID })
                    ?? explorer.lanes.first
                {
                    Text("Window statistics").font(.subheadline.weight(.semibold))
                    if lane.feed.model.discrete {
                        Text("State values are not averaged.").font(.caption).foregroundStyle(
                            .secondary)
                        if let note = lane.definition.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        TrendStatisticsCaption(model: lane.feed.model)
                        TrendStatisticsSummary(model: lane.feed.model)
                    }
                }
                if let record = explorer.machineRecord {
                    Divider()
                    DisclosureGroup("Recorded machine row") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.source).font(.caption.monospaced()).foregroundStyle(
                                .secondary)
                            Text(
                                record.date,
                                format: .dateTime.month(.abbreviated).day().hour().minute().second()
                            )
                            .font(.caption2).foregroundStyle(.secondary)
                            ForEach(record.fields) { field in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.name).font(.caption2.monospaced()).foregroundStyle(
                                        .secondary)
                                    Text(field.value ?? t("Not recorded"))
                                        .font(.caption.monospacedDigit()).textSelection(.enabled)
                                }
                            }
                        }.padding(.top, 8)
                    }.font(.caption)
                }
            }.padding(12)
        }
    }
}

private struct ExplorerCursorValues: View {
    let explorer: DataExplorerModel
    @ObservedObject var cursor: ExplorerCursor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    cursor.pinned ? "Pinned time" : "At cursor",
                    systemImage: cursor.pinned ? "pin.fill" : "scope"
                )
                .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    explorer.stepCursor(-1)
                } label: {
                    Image(systemName: "backward.end")
                }
                .buttonStyle(.plain).help("Previous sample")
                Button {
                    explorer.stepCursor(1)
                } label: {
                    Image(systemName: "forward.end")
                }
                .buttonStyle(.plain).help("Next sample")
                Button {
                    explorer.unpinTime()
                } label: {
                    Image(systemName: "pin.slash")
                }
                .buttonStyle(.plain).help("Unpin time")
            }
            let date = cursor.date ?? explorer.domain.upperBound
            Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                .font(.callout.monospacedDigit()).textSelection(.enabled)
            if let lane = explorer.lanes.first(where: { $0.id == explorer.selectedLaneID })
                ?? explorer.lanes.first
            {
                Text(lane.definition.title).font(.headline)
                ForEach(Array(lane.feed.model.series.enumerated()), id: \.offset) { _, series in
                    let reading = DataExplorerModel.reading(
                        series, at: date,
                        freshness: lane.feed.model.gapThreshold ?? 15)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Circle().fill(series.color).frame(width: 7, height: 7)
                            Text(series.name).font(.callout.weight(.semibold))
                        }
                        Text(
                            reading.sourceDuration > 0 ? "Source interval value" : "Recorded value"
                        )
                        .font(.caption2).foregroundStyle(.secondary)
                        Text(reading.value.map(lane.definition.unit.format) ?? t("Unavailable"))
                            .font(.title3.monospacedDigit())
                        if let observed = reading.observedAt {
                            if reading.sourceDuration > 0 {
                                Text(
                                    TrendStatistics.intervalText(
                                        start: observed.timeIntervalSinceReferenceDate,
                                        end: observed.addingTimeInterval(reading.sourceDuration)
                                            .timeIntervalSinceReferenceDate)
                                )
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Text(
                                    t(
                                        "Source resolution: %@",
                                        TrendStatistics.duration(reading.sourceDuration))
                                )
                                .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text(observed, format: .dateTime.hour().minute().second())
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            valueRow("Minimum", reading.minimum, unit: lane.definition.unit)
                            valueRow("Maximum", reading.maximum, unit: lane.definition.unit)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private func valueRow(
        _ title: LocalizedStringKey, _ value: Double?, unit: ExplorerUnit
    ) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value.map(unit.format) ?? t("Not recorded")).monospacedDigit()
        }.font(.caption)
    }
}

private struct ExplorerHardwareInspector: View {
    @ObservedObject var hardware: HardwareExplorerModel
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current inventory, not historical")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                TextField("Filter hardware", text: $query).textFieldStyle(.roundedBorder)
                Button {
                    hardware.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh hardware").disabled(hardware.isRefreshing)
            }
            if let capturedAt = hardware.capturedAt {
                Text(capturedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if hardware.isRefreshing { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(
                        hardware.sections.flatMap { $0.root.flattened() }.filter {
                            $0.matches(query)
                        }
                    ) { node in
                        if !node.properties.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(node.title, systemImage: node.systemImage).font(
                                    .callout.weight(.semibold))
                                ForEach(Array(node.properties.enumerated()), id: \.offset) {
                                    _, property in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(property.label).font(.caption2).foregroundStyle(
                                            .secondary)
                                        Text(property.value).font(.caption).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(12)
        .onAppear { hardware.refreshIfNeeded() }
    }
}

enum ExplorerCSV {
    static func encode(_ charts: [(String, TrendModel)]) -> String {
        var rows = ["Metric,Series,Unit,Timestamp,Value,Minimum,Maximum,SourceSeconds"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func quoted(_ text: String) -> String {
            let safe =
                ["=", "+", "-", "@", "\t", "\r"].contains(where: { text.hasPrefix($0) })
                ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        for (title, model) in charts {
            for series in model.series {
                let column = series.column
                for index in 0..<column.count {
                    let date = Date(
                        timeIntervalSinceReferenceDate: column.times[
                            column.times.startIndex + index])
                    let duration = column.durations.map { $0[$0.startIndex + index] } ?? 0
                    if let domain = model.xDomain {
                        guard date <= domain.upperBound,
                            date >= domain.lowerBound
                                || date.addingTimeInterval(duration) > domain.lowerBound
                        else { continue }
                    }
                    func number(_ values: ArraySlice<Double>?) -> String {
                        guard let values else { return "" }
                        let value = values[values.startIndex + index] * series.scale
                        return value.isFinite ? String(value) : ""
                    }
                    rows.append(
                        [
                            quoted(title), quoted(series.name), quoted(model.valueUnit ?? ""),
                            formatter.string(from: date),
                            number(column.values), number(column.lows), number(column.highs),
                            String(duration),
                        ].joined(separator: ","))
                }
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
