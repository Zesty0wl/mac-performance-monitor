import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The process whose threads the window lists, resolved when the window is
/// opened and carried as the window's value (see `OpenFilesTarget`).
struct ThreadsTarget: Codable, Hashable, Identifiable {
    var pid: Int32
    var startTime: Date
    var name: String
    var uid: UInt32

    var id: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }
}

/// One thread as the table shows it.
struct ThreadRow: Identifiable, Equatable {
    var snapshot: ThreadSnapshot
    /// Position in the kernel's list, where the main thread comes first.
    var index: Int
    /// Percent of one core since the previous refresh; nil until the thread
    /// has been seen twice.
    var cpuPercent: Double?

    var id: UInt64 { snapshot.id }

    var displayName: String {
        if !snapshot.name.isEmpty { return snapshot.name }
        return index == 0 ? t("Main thread") : t("Thread %d", index + 1)
    }

    // Sort keys. A thread with no rate yet sorts below every measured one.
    var cpuSortKey: Double { cpuPercent ?? -1 }
    var cpuNanos: UInt64 { snapshot.cpuNanos }
    var stateSortKey: Int { snapshot.state.rawValue }
    var priority: Int32 { snapshot.currentPriority }

    var stateLabel: String {
        switch snapshot.state {
        case .running: return t("Running")
        case .waiting: return t("Waiting")
        case .stopped: return t("Stopped")
        case .uninterruptible: return t("Uninterruptible")
        case .halted: return t("Halted")
        case .unknown: return t("Unknown")
        }
    }

    /// "0.42 s" under a minute, then "3:07" and "1:02:45".
    static func cpuTimeText(nanos: UInt64) -> String {
        let seconds = Double(nanos) / 1_000_000_000
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        let whole = Int(seconds)
        if whole < 3600 { return String(format: "%d:%02d", whole / 60, whole % 60) }
        return String(format: "%d:%02d:%02d", whole / 3600, whole % 3600 / 60, whole % 60)
    }
}

/// Reads one process's threads every two seconds and turns successive reads
/// into per-thread CPU rates. Owned by `ThreadsView`.
@MainActor
final class ThreadsModel: ObservableObject {
    enum State: Equatable {
        case loading
        /// macOS will not let this user list the threads.
        case unreadable
        case exited
        case loaded
    }

    static let interval: TimeInterval = 2

    @Published private(set) var state: State = .loading
    @Published private(set) var rows: [ThreadRow] = []
    @Published var isPaused = false

    private var previous: [ThreadSnapshot] = []
    private var previousAt: Date?
    private var loop: Task<Void, Never>?
    private var reading = false

    /// Poll until `stop()`. `isVisible` lets the loop idle while the window is
    /// hidden behind others or minimised, so nothing is read for no one.
    func start(target: ThreadsTarget, helper: HelperManager, isVisible: @escaping () -> Bool) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.isPaused, self.state != .exited, isVisible(),
                    self.isDueForARead
                {
                    self.refresh(target: target, helper: helper)
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// False just after a read. The loop restarts when the window is found or
    /// reappears, and a second read a few milliseconds after the first would
    /// turn scheduling noise into a CPU rate.
    private var isDueForARead: Bool {
        previousAt.map { Date().timeIntervalSince($0) >= Self.interval / 2 } ?? true
    }

    func refresh(target: ThreadsTarget, helper: HelperManager) {
        guard !reading else { return }
        reading = true
        let pid = target.pid
        let startTime = target.startTime
        // Your own process reads directly, which is cheapest. Anything else
        // needs root, so it goes to the helper when Full Coverage is on.
        let viaHelper = target.uid != UInt32(getuid()) && helper.canEscalate
        DispatchQueue.global(qos: .userInitiated).async {
            // The pid may have been reused since the window opened.
            let info = ProcessReader().taskAllInfo(pid)
            let gone = info.map { abs($0.startTime.timeIntervalSince(startTime)) >= 0.001 } ?? false
            let local = gone || viaHelper ? nil : ThreadReader().threads(pid)
            let alive = kill(pid, 0) == 0 || errno == EPERM
            DispatchQueue.main.async {
                if gone || !alive {
                    self.finish(nil, exited: true)
                } else if viaHelper {
                    helper.listThreads(pid: pid) { self.finish($0, exited: false) }
                } else {
                    self.finish(local, exited: false)
                }
            }
        }
    }

    private func finish(_ threads: [ThreadSnapshot]?, exited: Bool) {
        reading = false
        if exited {
            state = .exited
            return
        }
        guard let threads else {
            // Keep the last good list on screen if a single read fails.
            if state != .loaded { state = .unreadable }
            return
        }
        let now = Date()
        let usage =
            previousAt.map {
                ThreadUsage.cpuPercent(
                    previous: previous, current: threads, elapsed: now.timeIntervalSince($0))
            } ?? [:]
        previous = threads
        previousAt = now
        rows = threads.enumerated().map { index, thread in
            ThreadRow(snapshot: thread, index: index, cpuPercent: usage[thread.id])
        }
        state = .loaded
    }
}

/// A standalone window listing a process's threads: name, the CPU each is
/// using right now, accumulated CPU time, scheduler state and priority. Opened
/// from a process row's menu to answer "which thread is busy?".
struct ThreadsView: View {
    let target: ThreadsTarget

    @EnvironmentObject private var helper: HelperManager
    @StateObject private var model: ThreadsModel
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ThreadRow.cpuSortKey, order: .reverse)]
    @State private var window: NSWindow?

    /// `model` and `isVisible` are parameters so a test can watch what the
    /// window loads and stand in for a window that is really on screen.
    @MainActor
    init(target: ThreadsTarget, model: ThreadsModel? = nil, isVisible: (() -> Bool)? = nil) {
        self.target = target
        self.visibilityOverride = isVisible
        _model = StateObject(wrappedValue: model ?? ThreadsModel())
    }

    private let visibilityOverride: (() -> Bool)?

    /// (Re)start polling, idling whenever `window` is hidden or minimised.
    private func startPolling(in window: NSWindow?) {
        model.stop()
        let visible =
            visibilityOverride ?? { [weak window] in
                window?.occlusionState.contains(.visible) ?? true
            }
        model.start(target: target, helper: helper, isVisible: visible)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle(t("Threads · %@", target.name))
        .background(WindowReader(window: $window))
        .onAppear { startPolling(in: window) }
        // The window is not known on first appearance; restart once it is, so
        // the visibility check has something to ask.
        .onChange(of: window) { _, new in startPolling(in: new) }
        .onDisappear { model.stop() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.indent")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Threads")
                    .font(.headline)
                Text(verbatim: "\(target.name) · PID \(target.pid)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by name", text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading threads\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreadable:
            message(
                icon: "lock", title: t("Not readable"),
                text: helper.canEscalate
                    ? t("macOS would not list this process's threads, even as root.")
                    : t(
                        "Threads can only be listed for processes you own. Turn on Full "
                            + "Coverage in Settings to inspect system and other-user "
                            + "processes as root."))
        case .exited where model.rows.isEmpty:
            message(
                icon: "xmark.circle", title: t("Process exited"),
                text: t("This process is no longer running."))
        case .loaded, .exited:
            table
        }
    }

    private var visibleRows: [ThreadRow] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows =
            term.isEmpty
            ? model.rows : model.rows.filter { $0.displayName.lowercased().contains(term) }
        return rows.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(visibleRows, sortOrder: $sortOrder) {
            TableColumn("Thread", value: \.index) { row in
                Text(verbatim: row.displayName)
                    .foregroundStyle(row.snapshot.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.displayName)
            }
            .width(min: 140, ideal: 240)
            TableColumn("CPU %", value: \.cpuSortKey) { row in
                Text(verbatim: row.cpuPercent.map { String(format: "%.1f", $0) } ?? "\u{2026}")
                    .monospacedDigit()
                    .foregroundStyle((row.cpuPercent ?? 0) >= 0.05 ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60, max: 80)
            TableColumn("CPU Time", value: \.cpuNanos) { row in
                Text(verbatim: ThreadRow.cpuTimeText(nanos: row.cpuNanos))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80, max: 110)
            TableColumn("State", value: \.stateSortKey) { row in
                Text(verbatim: row.stateLabel)
                    .foregroundStyle(row.snapshot.state == .running ? .primary : .secondary)
            }
            .width(min: 70, ideal: 90, max: 130)
            TableColumn("Priority", value: \.priority) { row in
                Text(verbatim: "\(row.snapshot.currentPriority)")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(t("Base priority %d", Int(row.snapshot.basePriority)))
            }
            .width(min: 50, ideal: 60, max: 80)
        }
    }

    private func message(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(verbatim: title)
                .font(.headline)
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Text(verbatim: summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                model.isPaused.toggle()
            } label: {
                Label(
                    model.isPaused ? "Resume" : "Pause",
                    systemImage: model.isPaused ? "play.fill" : "pause.fill")
            }
            .disabled(model.state != .loaded)
            .help("CPU is measured between refreshes, every 2 seconds.")
        }
        .padding(16)
    }

    private var summary: String {
        switch model.state {
        case .loading, .unreadable: return ""
        case .exited: return t("The process has exited. Showing its last reading.")
        case .loaded:
            let running = model.rows.filter { $0.snapshot.state == .running }.count
            let total = model.rows.compactMap(\.cpuPercent).reduce(0, +)
            return t(
                "%1$d threads · %2$d running · %3$@%% CPU", model.rows.count, running,
                String(format: "%.1f", total))
        }
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view, so the view can ask whether
/// it is actually on screen.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if window !== view.window { window = view.window } }
    }
}
