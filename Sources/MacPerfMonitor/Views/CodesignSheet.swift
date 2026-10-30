import AppKit
import SwiftUI

/// What the codesign sheet inspects: captured at the moment the menu item is
/// chosen, so the sheet keeps working even if the process exits while it is open.
struct CodesignTarget: Identifiable, Equatable {
    let id = UUID()
    var path: String
    var name: String
    var pid: Int32
    var bundleID: String?
}

/// A resizable sheet showing a binary's code signature: the human-readable
/// picture (authorities, validity, flags, Designated Requirement) and — front and
/// centre — the exact fields needed to author an `app.settings` MDM binary rule
/// (CDHash, TeamID, SigningID, PathPrefix, SigningState), each copyable, plus a
/// one-click "copy the whole rule as JSON".
struct CodesignSheet: View {
    let target: CodesignTarget

    @Environment(\.dismiss) private var dismiss
    @State private var pathText: String
    @State private var info: CodeSignInfo?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var ruleCopied = false

    init(target: CodesignTarget) {
        self.target = target
        _pathText = State(initialValue: target.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if isLoading {
                    ProgressView("Reading signature…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    placeholder("exclamationmark.magnifyingglass", loadError)
                } else if let info {
                    content(info)
                } else {
                    placeholder("magnifyingglass", "Enter a path and press Inspect.")
                }
            }
            Divider()
            footer
        }
        .frame(
            minWidth: 560, idealWidth: 700, maxWidth: 1100,
            minHeight: 480, idealHeight: 680, maxHeight: 1400
        )
        .background(ResizableSheetConfigurator(minSize: NSSize(width: 560, height: 480)))
        .task { inspect() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: pathText))
                    .resizable().frame(width: 36, height: 36)
                Text(displayTitle).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let info, loadError == nil { signingStateBadge(info) }
            }
            HStack(spacing: 8) {
                TextField("Path to a binary or .app", text: $pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit(inspect)
                Button("Browse…", action: browse)
                Button("Inspect", action: inspect)
                    .buttonStyle(.borderedProminent)
                    .disabled(pathText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    /// The filename (or `.app` bundle name) of the path currently in the field.
    private var displayTitle: String {
        let p = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return "Code Signature" }
        let base: String
        if let r = p.range(of: ".app/") {
            base = String(p[..<r.lowerBound]) + ".app"
        } else {
            base = p
        }
        return (base as NSString).lastPathComponent
    }

    /// Inspect whatever path is in the field. Validates existence first (so a typo
    /// gets a clear message rather than an "unsigned" result), then reads the
    /// signature off the main thread.
    private func inspect() {
        let path = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        pathText = path
        guard !path.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            isLoading = false
            info = nil
            loadError = "No file exists at \u{201C}\(path)\u{201D}."
            return
        }
        loadError = nil
        info = nil
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CodeSignInfo.inspect(path: path)
            }.value
            isLoading = false
            info = result
        }
    }

    /// Pick a binary or app with the open panel (an `.app` is chosen as one unit).
    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Inspect"
        panel.message = "Choose a binary or app to inspect."
        if panel.runModal() == .OK, let url = panel.url {
            pathText = url.path
            inspect()
        }
    }

    private func placeholder(_ symbol: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func signingStateBadge(_ info: CodeSignInfo) -> some View {
        let color: Color =
            switch info.validity {
            case .valid: info.signingState == .apple ? .blue : .green
            case .unsigned: .secondary
            case .invalid: .red
            }
        return Text(info.signingState.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Content

    private func content(_ info: CodeSignInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("app.settings binary rule") {
                    CopyableRow(label: "CDHash", value: info.cdHash)
                    CopyableRow(label: "TeamID", value: info.appSettingsTeamID)
                    CopyableRow(label: "SigningID", value: info.signingID)
                    CopyableRow(label: "PathPrefix", value: info.pathPrefixCandidate)
                    CopyableRow(
                        label: "SigningState",
                        value: info.signingState.rawValue,
                        note: info.signingState.isAppSettingsValue
                            ? nil : "not an app.settings value")
                }

                section("Signature") {
                    LabeledContent("Status") { validityLabel(info.validity) }
                    if let format = info.format { LabeledContent("Format", value: format) }
                    if info.isAdHoc { LabeledContent("Ad-hoc", value: "yes") }
                    if let flags = info.flagsDescription {
                        LabeledContent("Flags") {
                            Text(flags).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if let ts = info.signedTimestamp {
                        LabeledContent(
                            "Signed", value: ts.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if !info.authorities.isEmpty {
                    section("Authority") {
                        ForEach(Array(info.authorities.enumerated()), id: \.offset) { idx, name in
                            HStack(spacing: 6) {
                                Image(
                                    systemName: idx == 0
                                        ? "checkmark.seal" : "arrow.turn.down.right"
                                )
                                .foregroundStyle(.secondary).font(.caption)
                                Text(name).font(.callout).textSelection(.enabled)
                            }
                            .padding(.leading, CGFloat(idx) * 14)
                        }
                    }
                }

                if info.cdHashes.count > 1 {
                    section("All code-directory hashes") {
                        ForEach(info.cdHashes) { hash in
                            CopyableRow(label: hash.label, value: hash.hex, mono: true)
                        }
                    }
                }

                if let dr = info.designatedRequirement {
                    section("Designated Requirement") {
                        Text(dr)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func validityLabel(_ validity: CodeSignInfo.Validity) -> some View {
        switch validity {
        case .valid:
            Label("Valid on disk", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .unsigned:
            Label("Unsigned", systemImage: "xmark.seal").foregroundStyle(.secondary)
        case .invalid(let why):
            Label("Invalid — \(why)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let info {
                Button {
                    Pasteboard.copy(Self.appSettingsRuleJSON(info))
                    withAnimation(.easeInOut(duration: 0.15)) { ruleCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation(.easeInOut(duration: 0.2)) { ruleCopied = false }
                    }
                } label: {
                    Label(
                        ruleCopied ? "Copied" : "Copy app.settings Rule",
                        systemImage: ruleCopied ? "checkmark.circle.fill" : "doc.on.clipboard"
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .tint(ruleCopied ? .green : nil)
                .help(
                    "Copy a JSON binary rule (CDHash / TeamID / SigningID / PathPrefix / SigningState) for an app.settings declaration."
                )
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    /// A JSON object using the available app.settings binary-rule fields. The user
    /// can drop it into AllowedBinaries / DeniedBinaries and trim what they don't
    /// want (those arrays require at least CDHash or TeamID).
    ///
    /// Encoded rather than interpolated: the signing identifier and path are
    /// whatever the inspected binary's author chose, and a quote in either
    /// must not add a key (a `"TeamID" : "*APPLE*"`) to a rule an admin pastes.
    static func appSettingsRuleJSON(_ info: CodeSignInfo) -> String {
        var fields: [String: String] = [:]
        fields["CDHash"] = info.cdHash
        fields["TeamID"] = info.appSettingsTeamID
        fields["SigningID"] = info.signingID
        fields["PathPrefix"] = info.pathPrefixCandidate
        if info.signingState.isAppSettingsValue {
            fields["SigningState"] = info.signingState.rawValue
        }
        let data = try? JSONSerialization.data(
            withJSONObject: fields, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// A label + monospaced value with a hover-free copy button; shows "—" when the
/// value is absent.
private struct CopyableRow: View {
    let label: String
    let value: String?
    var note: String? = nil
    var mono = true
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            if let value, !value.isEmpty {
                Text(value)
                    .font(mono ? .system(.callout, design: .monospaced) : .callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Pasteboard.copy(value)
                    flashCopied()
                } label: {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .help(copied ? "Copied" : "Copy \(label)")
            } else {
                Text("—").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func flashCopied() {
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.2)) { copied = false }
        }
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Makes the hosting sheet window user-resizable. A macOS SwiftUI `.sheet` is not
/// resizable from a flexible content frame alone — the sheet window has to carry
/// the `.resizable` style mask — so this reaches the window once it is attached
/// and adds it (plus a sensible minimum).
private struct ResizableSheetConfigurator: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.styleMask.insert(.resizable)
            window.minSize = minSize
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
