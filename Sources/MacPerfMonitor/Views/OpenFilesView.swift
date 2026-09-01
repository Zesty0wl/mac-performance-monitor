import AppKit
import MacPerfMonitorCore
import SwiftUI

/// A self-contained description of the process whose open descriptors the window
/// lists, resolved once when the window is opened (from the live sample under
/// the cursor) and carried as the window's value.
///
/// Like `InspectorTarget`, it is a plain `Codable`/`Hashable` value rather than a
/// reference to the live `SamplerModel`: the window must NOT subscribe to the
/// 2-second sample stream (that would re-execute its view tree every tick). The
/// descriptor list is read once on demand, with an explicit Refresh.
struct OpenFilesTarget: Codable, Hashable, Identifiable {
    var pid: Int32
    var startTime: Date
    var name: String
    var uid: UInt32

    var id: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }
}

/// A standalone, freely resizable window listing the descriptors a process
/// currently has open: files (with their paths), sockets (with their endpoints),
/// and pipes. Opened from a process row's context menu as a drill-down behind
/// the File-descriptor count.
///
/// It is a real `WindowGroup` scene (not a sheet), so it is movable and
/// resizable by default — the same approach as the Memory Inspector. A search
/// field and a kind filter make a long list (hundreds of entries for a busy app)
/// navigable, and the count breakdown mirrors the chart.
///
/// It observes only the helper manager, never the live sample stream, so it
/// stays still between explicit Refreshes rather than re-rendering every tick.
struct OpenFilesView: View {
    let target: OpenFilesTarget

    @EnvironmentObject private var helper: HelperManager

    @State private var state: LoadState = .loading
    @State private var search = ""
    @State private var filter: Filter = .all

    private var ownedByCurrentUser: Bool { target.uid == UInt32(getuid()) }

    private enum LoadState {
        case loading
        case failed
        case loaded([OpenFileDescriptor])
    }

    private enum Filter: String, CaseIterable, Identifiable {
        case all, files, sockets, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .files: return "Files"
            case .sockets: return "Sockets"
            case .other: return "Other"
            }
        }

        func matches(_ kind: OpenFileDescriptor.Kind) -> Bool {
            switch self {
            case .all: return true
            case .files: return kind == .file
            case .sockets: return kind == .socket
            case .other: return kind == .pipe || kind == .kqueue || kind == .other
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 380)
        .navigationTitle(t("Open Files · %@", target.name))
        .onAppear(perform: load)
    }

    private func load() {
        state = .loading
        // When elevated coverage is active the root daemon can see descriptors
        // for every process, so prefer it and the list is complete even for
        // system and other-user processes. Fall back to a user-level read if the
        // daemon is unreachable.
        if helper.canEscalate {
            helper.listOpenFiles(pid: target.pid) { result in
                if let list = result {
                    state = .loaded(list)
                    FDWatchdog.check(after: "open-files inspector")
                } else {
                    loadUserLevel()
                }
            }
        } else {
            loadUserLevel()
        }
    }

    private func loadUserLevel() {
        // Read directly off the main thread rather than through the sampler
        // model, so this window has no dependency on (and never subscribes to)
        // the live sample stream. Resolving each descriptor's path/endpoint is a
        // syscall per descriptor, hence the background queue.
        let pid = target.pid
        DispatchQueue.global(qos: .userInitiated).async {
            let fds = ProcessReader().openFileDescriptors(pid)
            DispatchQueue.main.async {
                if let fds {
                    state = .loaded(fds)
                } else {
                    state = .failed
                }
                FDWatchdog.check(after: "open-files inspector")
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Open files & sockets")
                    .font(.headline)
                Text("\(target.name) · PID \(target.pid)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let list = loadedList {
                Text(t("%@ open", String(list.count)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by path or endpoint", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            Picker("Kind", selection: $filter) {
                ForEach(Filter.allCases) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            loadingState
        case .failed:
            messageState(
                icon: "exclamationmark.triangle",
                title: "Couldn't read open files",
                message: "The process may have just exited."
            )
        case .loaded(let list):
            if list.isEmpty {
                emptyState
            } else {
                listView(rows(from: list))
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading open descriptors…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        // With elevated coverage the root daemon reads any process, so an empty
        // result genuinely means no descriptors. Without it, an empty result for
        // a process the user does not own is really "not permitted".
        let readable = ownedByCurrentUser || helper.canEscalate
        return messageState(
            icon: readable ? "tray" : "lock",
            title: readable ? "No open descriptors" : "Not readable",
            message: readable
                ? "This process has no open file descriptors right now."
                : "Open files can only be listed for processes you own. Turn on Full "
                    + "Coverage in Settings to inspect system and other-user processes as root."
        )
    }

    private func messageState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func listView(_ rows: [OpenFileDescriptor]) -> some View {
        Group {
            if rows.isEmpty {
                messageState(
                    icon: "magnifyingglass",
                    title: "No matches",
                    message: "No open descriptors match the current filter."
                )
            } else {
                List(rows) { fd in
                    FileDescriptorRow(descriptor: fd)
                        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private var footer: some View {
        HStack {
            if let list = loadedList, !list.isEmpty {
                Text(countSummary(list))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: load) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .padding(16)
    }

    // MARK: Derived

    private var loadedList: [OpenFileDescriptor]? {
        if case .loaded(let list) = state { return list }
        return nil
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    private func rows(from list: [OpenFileDescriptor]) -> [OpenFileDescriptor] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        return list.filter { fd in
            guard filter.matches(fd.kind) else { return false }
            guard !term.isEmpty else { return true }
            return fd.detail.lowercased().contains(term) || "\(fd.fd)".contains(term)
        }
    }

    private func countSummary(_ list: [OpenFileDescriptor]) -> String {
        let files = list.filter { $0.kind == .file }.count
        let sockets = list.filter { $0.kind == .socket }.count
        let other = list.count - files - sockets
        return "\(files) files · \(sockets) sockets · \(other) other"
    }
}

/// One row in the open-descriptor list: a kind glyph, the resolved path or
/// endpoint, and the descriptor number. File rows offer a Reveal in Finder
/// action; sockets, pipes, and kqueues have no on-disk location to reveal.
private struct FileDescriptorRow: View {
    let descriptor: OpenFileDescriptor

    var body: some View {
        // Only file (vnode) descriptors have a real filesystem path, so only
        // they get a context menu. The existence check that drives the disabled
        // state is a `stat`, so it lives inside the menu builder and runs only
        // when the menu is actually opened, not on every row render.
        if descriptor.kind == .file, !descriptor.detail.isEmpty {
            rowContent.contextMenu {
                Button {
                    ProcessActions.revealInFinder(path: descriptor.detail)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!FileManager.default.fileExists(atPath: descriptor.detail))
            }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.detail.isEmpty ? "(unavailable)" : descriptor.detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(descriptor.detail.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("fd \(descriptor.fd) · \(kindLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        // Make the whole row (including the trailing empty space) the hit target
        // so a right-click anywhere on the row opens the context menu, not just
        // a click directly on the icon or text.
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch descriptor.kind {
        case .file: return "doc"
        case .socket: return "network"
        case .pipe: return "arrow.left.arrow.right"
        case .kqueue: return "bell"
        case .other: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch descriptor.kind {
        case .file: return .blue
        case .socket: return .green
        case .pipe: return .orange
        case .kqueue: return .purple
        case .other: return .secondary
        }
    }

    private var kindLabel: String {
        switch descriptor.kind {
        case .file: return "file"
        case .socket: return "socket"
        case .pipe: return "pipe"
        case .kqueue: return "kqueue"
        case .other: return "other"
        }
    }
}
