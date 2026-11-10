import AppKit
import MacPerfMonitorCore
import SwiftUI

/// Searches every process's open files and sockets for a path, address or
/// port. Owned by `FindView`.
@MainActor
final class FindModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searching(done: Int, total: Int)
        case finished(Summary)
    }

    struct Summary: Equatable {
        /// Processes whose descriptors were read.
        var searched: Int
        /// Processes that belong to the system or another user and could not
        /// be read without Full Coverage.
        var skipped: Int
        /// True when the list stopped at `FindModel.matchLimit`.
        var truncated: Bool
    }

    /// Enough to answer any real question; past this the term is too broad
    /// and a longer list would only cost memory.
    static let matchLimit = 2000

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [DescriptorMatch] = []
    /// The term the current results are for.
    @Published private(set) var searchedTerm = ""

    private var task: Task<Void, Never>?

    var isSearching: Bool { if case .searching = phase { return true } else { return false } }

    func cancel() {
        task?.cancel()
        task = nil
        if isSearching { phase = .idle }
    }

    /// Read the descriptors of every process and keep the ones matching `term`.
    /// Results appear as each process is read. The user's own processes are
    /// read directly, four at a time; the rest go through the helper when Full
    /// Coverage is on, and are counted as skipped when it is not.
    func search(_ term: String, helper: HelperManager) {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        task?.cancel()
        results = []
        searchedTerm = term
        phase = .searching(done: 0, total: 0)
        let escalate = helper.canEscalate
        let me = getuid()

        done = 0
        truncated = false
        task = Task { @MainActor [weak self] in
            let targets = await Task.detached(priority: .userInitiated) {
                DescriptorSearch.targets()
            }.value
            let own = targets.filter { $0.uid == me }
            let others = targets.filter { $0.uid != me }
            let total = own.count + (escalate ? others.count : 0)

            await withTaskGroup(of: [DescriptorMatch].self) { group in
                var pending = own[...]
                var running = 0
                while !pending.isEmpty || running > 0 {
                    while running < 4, let target = pending.popFirst() {
                        group.addTask(priority: .userInitiated) {
                            guard !Task.isCancelled,
                                let descriptors = ProcessReader().openFileDescriptors(target.pid)
                            else { return [] }
                            return DescriptorSearch.matches(
                                in: descriptors, of: target, term: term)
                        }
                        running += 1
                    }
                    guard let matches = await group.next() else { break }
                    running -= 1
                    if self?.absorb(matches, total: total) != true {
                        group.cancelAll()
                        pending = []
                    }
                }
            }

            if escalate, self?.truncated == false {
                for target in others {
                    guard !Task.isCancelled else { break }
                    let descriptors = await withCheckedContinuation { continuation in
                        helper.listOpenFiles(pid: target.pid) { continuation.resume(returning: $0) }
                    }
                    let matches = DescriptorSearch.matches(
                        in: descriptors ?? [], of: target, term: term)
                    if self?.absorb(matches, total: total) != true { break }
                }
            }

            guard let self, !Task.isCancelled else { return }
            self.phase = .finished(
                Summary(
                    searched: self.done, skipped: escalate ? 0 : others.count,
                    truncated: self.truncated))
            FDWatchdog.check(after: "find open files")
        }
    }

    /// Progress of the search in flight.
    private var done = 0
    private var truncated = false

    /// Count one process as read and keep its matches, up to `matchLimit`.
    /// False once the search should stop: cancelled, or the list is full.
    private func absorb(_ matches: [DescriptorMatch], total: Int) -> Bool {
        guard !Task.isCancelled else { return false }
        done += 1
        if !matches.isEmpty {
            let room = Self.matchLimit - results.count
            results.append(contentsOf: matches.prefix(room))
            if matches.count > room { truncated = true }
        }
        phase = .searching(done: done, total: total)
        return !truncated
    }
}

/// A window that answers "which process has this open?": type part of a file
/// path, a host address or a port number, and it lists every matching open
/// file and socket with the process holding it.
struct FindView: View {
    /// Held as a plain reference and read only when a row is acted on, so this
    /// window never subscribes to the sample stream.
    let sampler: SamplerModel

    @EnvironmentObject private var helper: HelperManager
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = FindModel()
    @State private var term = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { fieldFocused = true }
        .onDisappear { model.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("File path, address or port", text: $term)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { model.search(term, helper: helper) }
            if model.isSearching {
                ProgressView().controlSize(.small)
                Button("Stop") { model.cancel() }
            } else {
                Button("Find") { model.search(term, helper: helper) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if model.results.isEmpty {
            switch model.phase {
            case .idle:
                message(
                    icon: "doc.text.magnifyingglass", title: t("Find what has something open"),
                    text: t(
                        "Type part of a file or folder path, a host address, or a port number "
                            + "such as 8080, to list every process with a matching file or "
                            + "socket open."))
            case .searching:
                message(icon: "hourglass", title: t("Searching\u{2026}"), text: "")
            case .finished:
                message(
                    icon: "tray", title: t("No matches"),
                    text: t(
                        "No process has an open file or socket matching \u{201C}%@\u{201D}.",
                        model.searchedTerm))
            }
        } else {
            List(model.results) { match in
                FindResultRow(match: match)
                    .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                    .contextMenu {
                        Button {
                            show(match)
                        } label: {
                            Label("Show in Processes", systemImage: "list.bullet.rectangle")
                        }
                        if match.descriptor.kind == .file {
                            Button {
                                ProcessActions.revealInFinder(path: match.descriptor.detail)
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                        }
                    }
                    .onTapGesture(count: 2) { show(match) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    /// Select the match's process in the main window's Processes tab. The
    /// process is looked up now, by pid, in the sampler's latest list; if it
    /// has gone since the search there is nothing to show.
    private func show(_ match: DescriptorMatch) {
        guard let live = sampler.latest?.processes.first(where: { $0.pid == match.pid }) else {
            NSSound.beep()
            return
        }
        ProcessRowIntent.openDetail(identity: live.id, appState: appState, bringWindowForward: true)
    }

    private func message(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(verbatim: title)
                .font(.headline)
            if !text.isEmpty {
                Text(verbatim: text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Text(verbatim: summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summary: String {
        switch model.phase {
        case .idle:
            return ""
        case .searching(let done, let total):
            return total > 0 ? t("Read %1$d of %2$d processes", done, total) : ""
        case .finished(let summary):
            var parts = [
                t("%1$d matches in %2$d processes", model.results.count, summary.searched)
            ]
            if summary.truncated {
                parts.append(
                    t("Showing the first %d. Use a longer term to narrow it.", FindModel.matchLimit)
                )
            }
            if summary.skipped > 0 {
                parts.append(
                    t(
                        "%d system and other-user processes were not searched. Turn on Full "
                            + "Coverage in Settings to include them.", summary.skipped))
            }
            return parts.joined(separator: " ")
        }
    }
}

/// One match: the path or endpoint, then the process holding it.
private struct FindResultRow: View {
    let match: DescriptorMatch

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: match.descriptor.kind == .socket ? "network" : "doc")
                .foregroundStyle(match.descriptor.kind == .socket ? Color.green : Color.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: match.descriptor.detail)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(verbatim: subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [match.processName, "PID \(match.pid)", "fd \(match.descriptor.fd)"]
        if let state = match.descriptor.tcpState { parts.append(state.label) }
        return parts.joined(separator: " · ")
    }
}
