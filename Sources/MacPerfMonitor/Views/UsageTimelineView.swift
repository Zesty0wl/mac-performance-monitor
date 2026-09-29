import AppKit
import Charts
import MacPerfMonitorCore
import SwiftUI

struct UsageTimelineView: View {
    @StateObject private var model: UsageTimelineModel
    @EnvironmentObject private var fullDiskAccess: FullDiskAccessManager

    init(model: UsageTimelineModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    UsageTimelineChart(intervals: model.intervals, range: model.range)
                    summaries
                    Text(
                        "Filled running buckets contain a sample, not proof of continuous execution. Gaps mean no retained observations."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if model.historyUnavailable {
                        Label(
                            "Process history is unavailable.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    } else if !model.loadingHistory, model.history?.intervals.isEmpty == true {
                        Text("No running observations in this timeframe.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    activityControls
                }
                .padding(16)
            }
            Divider()
            HStack(spacing: 8) {
                Text(
                    t(
                        "Process started %@",
                        model.target.startTime.formatted(date: .abbreviated, time: .standard))
                )
                .lineLimit(1)
                Spacer(minLength: 8)
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading activity")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(t("Usage Timeline - %@", model.target.name))
        .onAppear { model.load() }
        .onDisappear { model.close() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "timeline.selection")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Usage Timeline").font(.headline)
                Text(verbatim: model.target.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.target.name)
            }
            Spacer(minLength: 12)
            Text(t("PID %@", String(model.target.pid)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker(
                    "Timeframe",
                    selection: Binding(
                        get: { model.window },
                        set: { window in
                            DispatchQueue.main.async {
                                if window != model.window { model.load(window: window) }
                            }
                        })
                ) {
                    ForEach([HistoryWindow.thirtyMinutes, .oneHour, .sixHours, .oneDay, .sevenDays])
                    { window in
                        Text(window.label).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer(minLength: 12)
                Button {
                    model.load(endingAt: model.endDate.addingTimeInterval(-model.window.seconds))
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous timeframe")
                .accessibilityLabel("Previous timeframe")
                Button {
                    model.load(endingAt: model.endDate.addingTimeInterval(model.window.seconds))
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(model.endDate >= Date().addingTimeInterval(-1))
                .help("Next timeframe")
                .accessibilityLabel("Next timeframe")
                Button {
                    model.load(endingAt: Date())
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .help("Refresh to now")
                .accessibilityLabel("Refresh to now")
                .keyboardShortcut("r", modifiers: .command)
            }
            DatePicker(
                "Ending",
                selection: Binding(
                    get: { model.endDate },
                    set: { date in
                        DispatchQueue.main.async {
                            if date != model.endDate { model.load(endingAt: date) }
                        }
                    }),
                in: ...Date(), displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.field)
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summaries: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(UsageTimeline.Kind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(kind.label)
                    } icon: {
                        Image(systemName: "square.fill").foregroundStyle(kind.tint)
                    }
                    .font(.caption)
                    Text(summary(for: kind))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func summary(for kind: UsageTimeline.Kind) -> String {
        if kind == .observedRunning {
            guard let history = model.history else { return t("Not recorded") }
            return t("%@ buckets", Self.duration(history.bucketSeconds))
        }
        guard model.includesAppleActivity else { return t("Not loaded") }
        guard !model.loadingActivity, model.activityError == nil else { return t("Unavailable") }
        let intervals = model.activity.filter { $0.kind == kind }
        guard !intervals.isEmpty else { return t("Not recorded") }
        return Self.duration(intervals.reduce(0) { $0 + $1.duration })
    }

    private var activityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Include Apple app activity",
                isOn: Binding(
                    get: { model.includesAppleActivity }, set: { model.includeAppleActivity($0) })
            )
            .toggleStyle(.checkbox)
            .disabled(!model.canReadAppleActivity)
            if model.canReadAppleActivity {
                Text(
                    "Only this app's usage and media intervals are read into memory. Source device and foreground state are unverified."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let bundleID = model.target.bundleID {
                    Text(t("App scope: %@", bundleID))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(bundleID)
                }
            } else {
                Text("No current-user app bundle is available for this process.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.activityError {
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if error == .permissionDenied {
                    HStack {
                        Button("Open System Settings") { fullDiskAccess.openSystemSettings() }
                        if fullDiskAccess.awaitingRelaunch {
                            Button("Relaunch App") { fullDiskAccess.relaunch() }
                        }
                    }
                }
            } else if model.includesAppleActivity, !model.loadingActivity, model.activity.isEmpty {
                Text("No Apple app activity was recorded for this timeframe.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .units(
                allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated,
                maximumUnitCount: 2))
    }
}

extension UsageTimeline.Kind {
    var label: String {
        switch self {
        case .observedRunning: return t("Sampled running")
        case .appUsage: return t("App usage")
        case .mediaUsage: return t("Media usage")
        }
    }

    var tint: Color {
        switch self {
        case .observedRunning: return .blue
        case .appUsage: return .green
        case .mediaUsage: return .orange
        }
    }
}

struct UsageTimelineChart: View {
    let intervals: [UsageTimeline.Interval]
    let range: ClosedRange<Date>
    @State private var hovered: UsageTimeline.Interval?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(UsageTimeline.Kind.allCases, id: \.self) { kind in
                    RuleMark(y: .value("Activity", kind.label))
                        .foregroundStyle(.secondary.opacity(0.15))
                }
                ForEach(intervals) { interval in
                    RectangleMark(
                        xStart: .value("Start", interval.start),
                        xEnd: .value("End", interval.end),
                        y: .value("Activity", interval.kind.label), height: .fixed(20)
                    )
                    .foregroundStyle(interval.kind.tint)
                    .accessibilityLabel(interval.kind.label)
                    .accessibilityValue(intervalDates(interval))
                }
            }
            .chartXScale(domain: range)
            .chartYScale(domain: UsageTimeline.Kind.allCases.map(\.label))
            .chartLegend(.hidden)
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisTick()
                    AxisValueLabel(
                        format: range.upperBound.timeIntervalSince(range.lowerBound) > 86400
                            ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute(),
                        anchor: timeLabelAnchor(value.as(Date.self)))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let location) = phase, let plot = proxy.plotFrame
                            else {
                                hovered = nil
                                return
                            }
                            let frame = geometry[plot]
                            guard frame.contains(location),
                                let date: Date = proxy.value(atX: location.x - frame.minX),
                                let lane: String = proxy.value(atY: location.y - frame.minY)
                            else {
                                hovered = nil
                                return
                            }
                            hovered = intervals.first {
                                $0.kind.label == lane && $0.start <= date && date < $0.end
                            }
                        }
                }
            }
            .frame(height: 210)
            .accessibilityIdentifier("usage-timeline-chart")
            HStack(alignment: .top, spacing: 12) {
                if let hovered {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hovered.kind.label).foregroundStyle(hovered.kind.tint)
                        Text(intervalDates(hovered)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if hovered.kind != .observedRunning {
                        Text(UsageTimelineView.duration(hovered.duration))
                            .monospacedDigit()
                    }
                } else {
                    Text("No interval selected").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .font(.caption)
            .frame(height: 44, alignment: .top)
        }
        .onChange(of: range) { _, _ in hovered = nil }
        .onChange(of: intervals) { _, _ in hovered = nil }
    }

    private func timeLabelAnchor(_ date: Date?) -> UnitPoint {
        guard let date else { return .top }
        let fraction =
            date.timeIntervalSince(range.lowerBound)
            / range.upperBound.timeIntervalSince(range.lowerBound)
        if fraction < 0.1 { return .topLeading }
        if fraction > 0.9 { return .topTrailing }
        return .top
    }

    private func intervalDates(_ interval: UsageTimeline.Interval) -> String {
        t(
            "%1$@ to %2$@",
            interval.start.formatted(date: .abbreviated, time: .standard),
            interval.end.formatted(date: .abbreviated, time: .standard))
    }
}
