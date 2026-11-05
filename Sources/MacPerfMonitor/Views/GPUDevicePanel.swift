import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The pages of the GPU tab's Device panel. Five short pages behind one
/// picker instead of one long list, so the rail stays level with the history
/// chart beside it.
enum GPUDevicePage: String, CaseIterable, Identifiable {
    case clock, limits, work, memory, health

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .clock: return "Clock"
        case .limits: return "Limits"
        case .work: return "Work"
        case .memory: return "Memory"
        case .health: return "Health"
        }
    }

    var info: LocalizedStringKey {
        switch self {
        case .clock:
            return
                "The GPU's mean clock while awake. It weights each clock state's time by that state's frequency from the chip's own frequency table. On a chip without a table, the helper's powermetrics reading supplies the clock."
        case .limits:
            return
                "What set the clock. The power controller follows demand most of the time; its limit states mean heat or power, not the workload, held the GPU back. Lost performance is the firmware's own record of time a GPU block was limited."
        case .work:
            return
                "Work the GPU firmware queued per second on each engine. AI runtimes such as MLX, llama.cpp and PyTorch run on Compute; drawing uses Fragment and Geometry. Context switches are the GPU moving between apps; slow ones show contention."
        case .memory:
            return
                "GPU memory is ordinary RAM wired for the GPU. The limit is how much macOS lets the GPU wire, which caps the size of a model a GPU runtime can load. macOS sets a default; raising the iogpu.wired_limit_mb setting allows larger models, and the limit then reads as custom."
        case .health:
            return
                "Fault counters since the Mac started. Every one should stay at zero. Recoveries and restarts mean the GPU hung and was reset; killed work is work the driver stopped, usually after a timeout."
        }
    }
}

/// The rail beside the history chart: one panel, five pages.
struct GPUDevicePanel: View {
    @ObservedObject var timeline: GPUTimelineStore
    @AppStorage("gpu.devicePage") private var page: GPUDevicePage = .clock

    var body: some View {
        GPUPanel("Device", systemImage: "cpu", info: page.info) {
            VStack(alignment: .leading, spacing: 12) {
                GPUPageSelector(selection: $page)
                // Every page is laid out and the transparent ones keep their
                // space, so switching pages never changes the row's height.
                // Their surfaces only repaint when a value changes.
                ZStack(alignment: .topLeading) {
                    ForEach(GPUDevicePage.allCases) { candidate in
                        content(for: candidate)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .opacity(candidate == page ? 1 : 0)
                            .allowsHitTesting(candidate == page)
                            .accessibilityHidden(candidate != page)
                    }
                }
            }
        }
    }

    @ViewBuilder private func content(for page: GPUDevicePage) -> some View {
        let device = timeline.device
        switch page {
        case .clock:
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    LiveText(
                        feed: device.clockText,
                        font: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold))
                    LiveText(
                        feed: device.clockDetailText,
                        font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
                }
                GPUDetailGrid {
                    GPUDetailRow("Chip", timeline.chipText)
                    GPUDetailRow("Cores", timeline.coresText)
                    GPUDetailRow("Clock source", device.clockSourceText)
                }
                GPUClockStatesSection(feed: timeline.statesFeed)
            }
        case .limits:
            VStack(alignment: .leading, spacing: 12) {
                GPUDetailGrid {
                    GPUDetailRow("Thermal limit", timeline.throttleText)
                    GPUDetailRow("Power cap", timeline.capText)
                    GPUDetailRow("Limited time", device.limitedText)
                    GPUDetailRow("Die temperature", timeline.temperatureText)
                    GPUDetailRow("Fan", timeline.fanText)
                }
                GPUSectionLabel("POWER CONTROLLER")
                GPUBarListSurface(feed: device.controllerFeed)
                GPUSectionLabel("LOST PERFORMANCE")
                GPUBarListSurface(feed: device.lostFeed)
            }
        case .work:
            VStack(alignment: .leading, spacing: 12) {
                GPUSectionLabel("SUBMISSIONS")
                GPUBarListSurface(feed: device.engineFeed)
                GPUDetailGrid {
                    GPUDetailRow("Wake-ups", device.wakeupsText)
                    GPUDetailRow("Busy period", device.busyText)
                    GPUDetailRow("Idle gap", device.idleText)
                }
                GPUSectionLabel("CONTEXT SWITCHES")
                GPUBarListSurface(feed: device.switchFeed)
            }
        case .memory:
            VStack(alignment: .leading, spacing: 12) {
                GPUBarListSurface(feed: device.memoryShareFeed)
                GPUDetailGrid {
                    GPUDetailRow("In use", timeline.memoryText)
                    GPUDetailRow("Allocated", timeline.allocatedText)
                    GPUDetailRow("GPU limit", device.limitText)
                    GPUDetailRow("Headroom", device.headroomText)
                    GPUDetailRow("Installed RAM", device.ramText)
                }
            }
        case .health:
            VStack(alignment: .leading, spacing: 12) {
                LiveText(
                    feed: device.healthSummaryText, font: .systemFont(ofSize: 13, weight: .medium))
                GPUDetailGrid {
                    GPUDetailRow("GPU recoveries", timeline.recoveryText)
                    GPUDetailRow("Firmware restarts", device.restartsText)
                    GPUDetailRow("Killed compute work", device.killedComputeText)
                    GPUDetailRow("Killed fragment work", device.killedFragmentText)
                    GPUDetailRow("Killed geometry work", device.killedGeometryText)
                    GPUDetailRow("Failed render passes", device.memorylessText)
                    GPUDetailRow("Under-voltage warnings", device.undervoltageText)
                    GPUDetailRow("Thermal activations", device.thermalText)
                }
            }
        }
    }
}

/// The Device panel's page switcher. A segmented `Picker` with five
/// segments needs about 276 pt at small size, more in German and Russian,
/// against the rail's 268: SwiftUI squeezed it, and AppKit sized the control
/// back to its natural width on every selection change, so the panel spilled
/// over the chart beside it and then snapped back. This selector is laid out
/// by `GPUSegmentLayout`, which can never exceed the width it is offered, and
/// one font weight serves every state so selecting a page cannot change a
/// segment's width.
struct GPUPageSelector: View {
    @Binding var selection: GPUDevicePage

    var body: some View {
        GPUSegmentLayout(spacing: 2) {
            ForEach(GPUDevicePage.allCases) { page in
                let selected = page == selection
                Button {
                    selection = page
                } label: {
                    Text(page.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Color.primary.opacity(0.16) : Color.clear)
                )
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Device page")
    }
}

/// Lays segments out in a row that fills the offered width: each segment gets
/// its label's natural width plus an equal share of any room left over (the
/// padding around the label), and when the labels do not fit they are scaled
/// down together and shrink through their minimum scale factor. The row is
/// never wider than the proposal, so Russian, the widest catalog, still fits.
struct GPUSegmentLayout: Layout {
    var spacing: CGFloat

    private func widths(for width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let natural = subviews.map { $0.sizeThatFits(.unspecified).width }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let room = max(0, width - gaps)
        let total = natural.reduce(0, +)
        guard total > 0, !natural.isEmpty else { return natural }
        if total <= room {
            let extra = (room - total) / CGFloat(natural.count)
            return natural.map { $0 + extra }
        }
        return natural.map { $0 * room / total }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let width = proposal.width ?? (natural.reduce(0) { $0 + $1.width } + gaps)
        let height = natural.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// A two-column grid of labels and live values.
struct GPUDetailGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            content()
        }
    }
}

struct GPUDetailRow: View {
    let label: LocalizedStringKey
    let feed: TextFeed

    init(_ label: LocalizedStringKey, _ feed: TextFeed) {
        self.label = label
        self.feed = feed
    }

    var body: some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
            LiveText(
                feed: feed, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                alignment: .right
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct GPUSectionLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Feeds

/// The live figures behind the Device panel, published from
/// `GPUTimelineStore.publish` on every tick. Each feed skips unchanged values,
/// so a quiet GPU repaints nothing.
@MainActor
final class GPUDeviceFeeds {
    let clockText = TextFeed()
    let clockDetailText = TextFeed("")
    let clockSourceText = TextFeed()
    let limitedText = TextFeed()
    let controllerFeed = GPUBarListFeed(rowCount: 4, emptyText: t("Reading the GPU\u{2026}"))
    let lostFeed = GPUBarListFeed(rowCount: 3, emptyText: t("Not reported"))
    let engineFeed = GPUBarListFeed(rowCount: 3, emptyText: t("Not reported"))
    let switchFeed = GPUBarListFeed(
        rowCount: 3, emptyText: t("Not reported"), showsBars: false, labelWidth: 70)
    let wakeupsText = TextFeed()
    let busyText = TextFeed()
    let idleText = TextFeed()
    let memoryShareFeed = GPUBarListFeed(rowCount: 1, emptyText: t("Not reported"))
    let limitText = TextFeed()
    let headroomText = TextFeed()
    let ramText = TextFeed()
    let healthSummaryText = TextFeed("")
    let restartsText = TextFeed()
    let killedComputeText = TextFeed()
    let killedFragmentText = TextFeed()
    let killedGeometryText = TextFeed()
    let memorylessText = TextFeed()
    let undervoltageText = TextFeed()
    let thermalText = TextFeed()

    func publish(_ gpu: GPUSample?) {
        typealias P = GPUDevicePresentation
        clockText.publish(gpu?.clockMHz.map(P.megahertz) ?? (gpu == nil ? "--" : t("GPU off")))
        clockDetailText.publish(P.clockDetail(gpu))
        clockSourceText.publish(P.clockSource(gpu?.clockSource))

        let diagnostics = gpu?.diagnostics
        if let limited = diagnostics?.limitedResidency {
            limitedText.publish(
                MetricUnit.percent.format(limited), color: limited >= 1 ? .systemOrange : nil)
        } else {
            limitedText.publish("--")
        }
        controllerFeed.publish(P.controllerRows(diagnostics))
        lostFeed.publish(
            P.lostRows(diagnostics),
            emptyText: diagnostics?.lostPerformanceKnown == true ? t("None") : t("Not reported"))
        engineFeed.publish(P.engineRows(diagnostics))
        switchFeed.publish(P.switchRows(diagnostics), emptyText: t("None"))
        wakeupsText.publish(P.wakeups(diagnostics, awake: gpu?.activeResidency))
        busyText.publish(P.milliseconds(diagnostics?.meanBusyMilliseconds))
        idleText.publish(P.milliseconds(diagnostics?.meanIdleMilliseconds))

        memoryShareFeed.publish(P.memoryRows(gpu))
        let limit = gpu?.memoryLimit
        limitText.publish(
            limit.map {
                $0.isCustom
                    ? t("%@ · custom", ByteFormat.string($0.bytes))
                    : t("%@ · default", ByteFormat.string($0.bytes))
            } ?? "--")
        headroomText.publish(P.headroom(gpu).map { ByteFormat.string($0) } ?? "--")
        ramText.publish(ByteFormat.string(ProcessInfo.processInfo.physicalMemory))

        let health = gpu?.health
        let summary = P.healthSummary(health, recoveries: gpu?.recoveryCount)
        healthSummaryText.publish(summary.text, color: summary.color)
        func count(_ value: Int64?) -> String { value.map { String($0) } ?? "--" }
        restartsText.publish(count(health?.restarts))
        killedComputeText.publish(count(health?.killedWork[.compute]))
        killedFragmentText.publish(count(health?.killedWork[.fragment]))
        killedGeometryText.publish(count(health?.killedWork[.geometry]))
        memorylessText.publish(count(health?.memorylessRenderFailures))
        undervoltageText.publish(count(health?.undervoltageWarnings))
        thermalText.publish(count(health?.thermalActivations))
    }
}

/// The text and rows the Device panel shows, kept apart from the views so
/// tests can check them without drawing.
enum GPUDevicePresentation {
    static func megahertz(_ value: Double) -> String {
        t("%@ MHz", value.formatted(.number.precision(.fractionLength(0))))
    }

    static func clockDetail(_ gpu: GPUSample?) -> String {
        guard let maximum = gpu?.maximumClockMHz, maximum > 0 else { return "" }
        guard let clock = gpu?.clockMHz else { return t("Maximum %@", megahertz(maximum)) }
        let share = (clock / maximum * 100).formatted(.number.precision(.fractionLength(0)))
        return t("%1$@%% of the %2$@ maximum", share, megahertz(maximum))
    }

    static func clockSource(_ source: GPUClockSource?) -> String {
        switch source {
        case .frequencyTable: return t("Frequency table")
        case .powermetrics: return t("powermetrics (helper)")
        case nil: return "--"
        }
    }

    /// "14" or, with the cluster split, "14 · 2 × 7" / "18 · 10 + 8".
    static func cores(count: Int?, clusters: [Int]?) -> String {
        guard let count else { return "--" }
        guard let clusters, clusters.count > 1 else { return String(count) }
        let split =
            Set(clusters).count == 1
            ? "\(clusters.count) × \(clusters[0])"
            : clusters.map(String.init).joined(separator: " + ")
        return "\(count) · \(split)"
    }

    static func controllerLabel(_ name: String) -> String {
        switch name.uppercased() {
        case "IDLE_OFF": return t("Idle, powered off")
        case "STANDBY": return t("Standby")
        case "PERF": return t("Following demand")
        case "AVGPERF": return t("Average demand")
        case "DEADLINE": return t("Frame deadline")
        case "DEADAWAR": return t("Deadline aware")
        case "PRFBOOST": return t("Boost")
        case "CLTMLIMI": return t("Thermal limit")
        case "POWER": return t("Power limit")
        case "PWR_ZONE": return t("Power zone")
        case "PPMLIMIT": return t("Peak power limit")
        case "PPMTARGE": return t("Peak power target")
        case "PRFLIMIT": return t("Performance limit")
        default: return name
        }
    }

    static func controllerColor(_ kind: GPUControllerState.Kind) -> NSColor {
        switch kind {
        case .idle: return .secondaryLabelColor
        case .demand: return .controlAccentColor
        case .deadline: return .systemTeal
        case .boost: return .systemPurple
        case .thermal: return .systemOrange
        case .power: return .systemRed
        case .performanceLimit: return .systemYellow
        case .other: return .systemGray
        }
    }

    static func controllerRows(_ diagnostics: GPUDiagnostics?) -> [GPUBarRow] {
        (diagnostics?.controllerStates ?? []).prefix(4).map {
            let state = GPUControllerState($0.name)
            return GPUBarRow(
                label: controllerLabel($0.name), fraction: $0.residency / 100,
                value: MetricUnit.percent.format($0.residency),
                color: controllerColor(state.kind))
        }
    }

    static func lostRows(_ diagnostics: GPUDiagnostics?) -> [GPUBarRow] {
        (diagnostics?.lostPerformance ?? []).prefix(3).map {
            let reason = GPULostPerformanceReason($0.name)
            let label: String
            switch reason.limit {
            case .thermal: label = t("%@ thermal", reason.block)
            case .electrical: label = t("%@ electrical", reason.block)
            case .other: label = $0.name
            }
            return GPUBarRow(
                label: label, fraction: $0.residency / 100,
                value: MetricUnit.percent.format($0.residency),
                color: reason.limit == .thermal ? .systemOrange : .systemRed)
        }
    }

    static func engineName(_ engine: GPUEngine) -> String {
        switch engine {
        case .compute: return t("Compute")
        case .fragment: return t("Fragment")
        case .geometry: return t("Geometry")
        }
    }

    static func engineColor(_ engine: GPUEngine) -> NSColor {
        switch engine {
        case .compute: return .systemPurple
        case .fragment: return .systemBlue
        case .geometry: return .systemTeal
        }
    }

    static func rate(_ value: Double) -> String {
        let digits = value < 10 ? 0...1 : 0...0
        return t("%@/s", value.formatted(.number.precision(.fractionLength(digits))))
    }

    /// One row per engine: its submissions per second, the bar its share of
    /// all submissions.
    static func engineRows(_ diagnostics: GPUDiagnostics?) -> [GPUBarRow] {
        guard let engines = diagnostics?.engines else { return [] }
        let rates = GPUEngine.allCases.compactMap { engine in
            engines[engine]?.submissionsPerSecond.map { (engine, $0) }
        }
        guard !rates.isEmpty else { return [] }
        let total = rates.reduce(0) { $0 + $1.1 }
        return rates.map { engine, value in
            GPUBarRow(
                label: engineName(engine), fraction: total > 0 ? value / total : 0,
                value: rate(value), color: engineColor(engine))
        }
    }

    static func switchRows(_ diagnostics: GPUDiagnostics?) -> [GPUBarRow] {
        guard let engines = diagnostics?.engines else { return [] }
        return GPUEngine.allCases.compactMap { engine -> GPUBarRow? in
            guard let activity = engines[engine], let switches = activity.contextSwitches,
                let perSecond = activity.contextSwitchesPerSecond
            else { return nil }
            let value: String
            if let bound = switches.percentile95Microseconds {
                if bound.isFinite {
                    value = t(
                        "%1$@ · 95%% under %2$@ µs", rate(perSecond),
                        bound.formatted(.number.precision(.fractionLength(0))))
                } else {
                    value = t("%@ · some over 40 ms", rate(perSecond))
                }
            } else {
                value = t("None")
            }
            return GPUBarRow(
                label: engineName(engine), fraction: 0, value: value,
                color: engineColor(engine))
        }
    }

    static func wakeups(_ diagnostics: GPUDiagnostics?, awake: Double?) -> String {
        guard let perSecond = diagnostics?.wakeupsPerSecond else { return "--" }
        if perSecond == 0 {
            if let awake, awake >= 99 { return t("Busy throughout") }
            if let awake, awake <= 1 { return t("GPU off") }
        }
        return rate(perSecond)
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        let digits = value < 10 ? 1...1 : 0...0
        return t("%@ ms", value.formatted(.number.precision(.fractionLength(digits))))
    }

    static func headroom(_ gpu: GPUSample?) -> UInt64? {
        guard let limit = gpu?.memoryLimit?.bytes, let used = gpu?.inUseMemoryBytes else {
            return nil
        }
        return limit > used ? limit - used : 0
    }

    static func memoryRows(_ gpu: GPUSample?) -> [GPUBarRow] {
        guard let limit = gpu?.memoryLimit?.bytes, limit > 0, let used = gpu?.inUseMemoryBytes
        else { return [] }
        let fraction = Double(used) / Double(limit)
        return [
            GPUBarRow(
                label: t("Of the GPU limit"), fraction: fraction,
                value: MetricUnit.percent.format(fraction * 100),
                color: fraction >= 0.9 ? .systemOrange : .systemTeal)
        ]
    }

    static func healthSummary(
        _ health: GPUHealthCounters?, recoveries: Int?
    ) -> (
        text: String, color: NSColor?
    ) {
        guard let health else {
            return recoveries.map {
                $0 == 0
                    ? (t("No GPU recoveries since the Mac started"), NSColor.systemGreen)
                    : (t("The GPU has recovered from a hang"), NSColor.systemOrange)
            } ?? ("", nil)
        }
        if health.isClean, (recoveries ?? 0) == 0 {
            return (t("No GPU faults since the Mac started"), .systemGreen)
        }
        return (t("GPU faults since the Mac started"), .systemOrange)
    }
}

// MARK: - Bar list surface

/// One row of a bar list: a label, a bar filled to `fraction`, and a value.
struct GPUBarRow: Equatable {
    var label: String
    /// 0...1.
    var fraction: Double
    var value: String
    var color: NSColor
}

/// Rows for a `GPUBarListSurfaceView`. The row count is fixed when the feed
/// is made, so the surface's height never changes on a tick.
final class GPUBarListFeed {
    let rowCount: Int
    let showsBars: Bool
    let labelWidth: CGFloat
    private(set) var rows: [GPUBarRow] = []
    private(set) var emptyText: String
    private var observers: [UUID: () -> Void] = [:]

    init(rowCount: Int, emptyText: String, showsBars: Bool = true, labelWidth: CGFloat = 116) {
        self.rowCount = rowCount
        self.emptyText = emptyText
        self.showsBars = showsBars
        self.labelWidth = labelWidth
    }

    func publish(_ rows: [GPUBarRow], emptyText: String? = nil) {
        let rows = Array(rows.prefix(rowCount))
        let empty = emptyText ?? self.emptyText
        guard rows != self.rows || empty != self.emptyText else { return }
        self.rows = rows
        self.emptyText = empty
        for observer in observers.values { observer() }
    }

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ id: UUID) { observers.removeValue(forKey: id) }
}

struct GPUBarListSurface: NSViewRepresentable {
    let feed: GPUBarListFeed

    func makeNSView(context: Context) -> GPUBarListSurfaceView {
        let view = GPUBarListSurfaceView()
        view.attach(feed)
        return view
    }

    func updateNSView(_ view: GPUBarListSurfaceView, context: Context) {
        if view.feed !== feed { view.attach(feed) }
    }

    static func dismantleNSView(_ view: GPUBarListSurfaceView, coordinator: ()) { view.detach() }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: GPUBarListSurfaceView, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? 268, height: GPUBarListSurfaceView.height(rows: feed.rowCount))
    }
}

final class GPUBarListSurfaceView: LiveSurfaceView {
    private(set) var feed: GPUBarListFeed?
    private var observation: UUID?
    private let labels = ChartLabelCache()
    static let rowHeight: CGFloat = 17
    static let valueWidth: CGFloat = 52

    static func height(rows: Int) -> CGFloat { CGFloat(max(1, rows)) * rowHeight }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { detach() }

    func attach(_ feed: GPUBarListFeed) {
        detach()
        self.feed = feed
        observation = feed.observe { [weak self] in self?.feedDidPublish() }
        feedDidPublish()
    }

    func detach() {
        if let feed, let observation { feed.stopObserving(observation) }
        observation = nil
        feed = nil
    }

    /// What the rows read as, for VoiceOver and tests.
    var displayedText: String {
        guard let feed else { return "" }
        if feed.rows.isEmpty { return feed.emptyText }
        return feed.rows.map { "\($0.label): \($0.value)" }.joined(separator: ", ")
    }

    private func feedDidPublish() {
        setAccessibilityValue(displayedText)
        invalidateContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        labels.invalidate()
        invalidateContent()
    }

    override func paint(in context: CGContext, dirty: CGRect) {
        guard let feed else { return }
        guard !feed.rows.isEmpty else {
            labels.label(feed.emptyText, style: .legendName).draw(
                at: CGPoint(x: 0, y: 1), in: context)
            return
        }
        let width = bounds.width
        for (index, row) in feed.rows.enumerated() {
            let y = CGFloat(index) * Self.rowHeight
            let name = labels.label(row.label, style: .legendName)
            if feed.showsBars {
                context.saveGState()
                context.clip(
                    to: CGRect(x: 0, y: y, width: feed.labelWidth - 6, height: Self.rowHeight))
                name.draw(at: CGPoint(x: 0, y: y + 1), in: context)
                context.restoreGState()
                let trackWidth = max(1, width - feed.labelWidth - Self.valueWidth - 6)
                let track = CGRect(x: feed.labelWidth, y: y + 5, width: trackWidth, height: 7)
                context.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.15).cgColor)
                context.addPath(
                    CGPath(roundedRect: track, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
                context.fillPath()
                let filled = track.width * CGFloat(min(1, max(0, row.fraction)))
                if filled > 0.5 {
                    context.setFillColor(row.color.cgColor)
                    context.addPath(
                        CGPath(
                            roundedRect: CGRect(
                                x: track.minX, y: track.minY, width: max(filled, 3),
                                height: track.height),
                            cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
                    context.fillPath()
                }
            } else {
                context.setFillColor(row.color.cgColor)
                context.addPath(
                    CGPath(
                        roundedRect: CGRect(x: 0, y: y + 5, width: 7, height: 7), cornerWidth: 2,
                        cornerHeight: 2, transform: nil))
                context.fillPath()
                name.draw(at: CGPoint(x: 12, y: y + 1), in: context)
            }
            let value = labels.label(row.value, style: .legend)
            value.draw(at: CGPoint(x: width - value.size.width, y: y + 2), in: context)
        }
    }
}
