import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The Hardware tab: this Mac's inventory as a searchable, browsable tree
/// with a visual overview. Every fact the system reports about the machine
/// (the chip and its cores, memory, displays, storage, battery, every bus and
/// the devices on it, the radios, the security state, the running kernel)
/// lives in one place. Nothing here follows the sampler's tick: the page is
/// read once when first opened and again only when Refresh is pressed.
struct HardwareView: View {
    @ObservedObject private var model = HardwareExplorerModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            HSplitView {
                HardwareSidebar(model: model)
                    .frame(minWidth: 220, idealWidth: 270, maxWidth: 340)
                HardwareDetail(model: model)
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.refreshIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Hardware")
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            searchField
            status
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .help("Read the inventory again (Command-R)")
            Menu {
                Button("Copy as Text") { model.copyToPasteboard(model.reportText()) }
                Button("Save Report\u{2026}") { model.saveReport(json: false) }
                Button("Save JSON\u{2026}") { model.saveReport(json: true) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.capturedAt == nil)
        }
    }

    private var subtitle: String {
        let facts = model.facts
        var parts: [String] = []
        if let name = facts.productName { parts.append(name) }
        if let chip = facts.chipName { parts.append(chip) }
        if let memory = facts.memoryBytes {
            parts.append(ByteFormat.string(memory, fractionDigits: 0))
        }
        if parts.isEmpty {
            return model.isRefreshing ? "Reading this Mac\u{2026}" : "This Mac"
        }
        return parts.joined(separator: ", ")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search hardware", text: $model.query)
                .textFieldStyle(.plain)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .frame(width: 260)
    }

    @ViewBuilder
    private var status: some View {
        if model.isRefreshing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading \(model.completed) of \(model.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if let capturedAt = model.capturedAt {
            VStack(alignment: .trailing, spacing: 1) {
                Text("Updated \(capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let seconds = model.lastCaptureSeconds {
                    Text(String(format: "%.1f s", seconds))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Sidebar

private struct HardwareSidebar: View {
    @ObservedObject var model: HardwareExplorerModel

    var body: some View {
        List(selection: $model.selectedID) {
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                tree
            } else {
                results
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var tree: some View {
        Label("Overview", systemImage: "rectangle.3.group")
            .tag(HardwareExplorerModel.overviewID)
        ForEach(HardwareInventory.specs) { spec in
            if let section = model.section(spec.id) {
                OutlineGroup([section.root], id: \.id, children: \.childrenOrNil) { node in
                    HardwareSidebarRow(node: node, isSection: node.id == section.id)
                        .tag(node.id)
                }
            } else {
                HStack {
                    Label(spec.title, systemImage: spec.systemImage)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        let hits = model.hits
        if hits.isEmpty {
            Text(model.isRefreshing ? "Still reading\u{2026}" : "No matches")
                .foregroundStyle(.secondary)
        } else {
            Section("\(hits.count) \(hits.count == 1 ? "match" : "matches")") {
                ForEach(hits) { hit in
                    HardwareHitRow(hit: hit)
                        .tag(hit.node.id)
                }
            }
        }
    }
}

private struct HardwareSidebarRow: View {
    let node: HardwareNode
    let isSection: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title)
                        .fontWeight(isSection ? .semibold : .regular)
                        .lineLimit(1)
                    if !isSection, let subtitle = node.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: node.systemImage)
            }
            Spacer(minLength: 4)
            if !node.children.isEmpty {
                Text("\(node.children.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
    }
}

private struct HardwareHitRow: View {
    let hit: HardwareSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(hit.node.title, systemImage: hit.node.systemImage)
                .lineLimit(1)
            Text(([hit.sectionTitle] + hit.path.dropFirst()).joined(separator: " \u{203A} "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let first = hit.matchedProperties.first {
                Text("\(first.label): \(first.value)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

private struct HardwareDetail: View {
    @ObservedObject var model: HardwareExplorerModel

    var body: some View {
        Group {
            if model.selectedID == HardwareExplorerModel.overviewID || model.selectedID == nil {
                HardwareOverviewView(model: model)
            } else if let id = model.selectedID, let node = model.node(withID: id) {
                HardwareNodeDetail(
                    node: node, path: model.path(to: id), section: model.sectionContaining(id),
                    query: model.query, model: model)
            } else if model.isRefreshing {
                placeholder("Reading\u{2026}")
            } else {
                placeholder("Select an item")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HardwareNodeDetail: View {
    let node: HardwareNode
    let path: [HardwareNode]
    let section: HardwareSection?
    let query: String
    @ObservedObject var model: HardwareExplorerModel

    private var isSectionRoot: Bool { node.id == section?.id }
    private var isFeatureList: Bool { node.id.hasSuffix("/native/features") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                breadcrumb
                heading
                if let note = section?.note, isSectionRoot {
                    noteBanner(note)
                }
                if isFeatureList {
                    HardwarePanel("Features", systemImage: "checklist") {
                        HardwareFeatureCloud(properties: node.properties, query: query)
                    }
                } else if !node.properties.isEmpty {
                    HardwarePanel("Properties", systemImage: "list.bullet.rectangle") {
                        HardwarePropertyTable(node: node, query: query, model: model)
                    }
                }
                if !node.children.isEmpty {
                    HardwarePanel(
                        isSectionRoot ? "Items" : "Attached",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    ) {
                        HardwareChildList(children: node.children, model: model)
                    }
                }
                if node.properties.isEmpty, node.children.isEmpty {
                    Text(
                        isSectionRoot
                            ? "Nothing reported for this section." : "No details reported."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(path.enumerated()), id: \.element.id) { index, crumb in
                if index > 0 {
                    Text("\u{203A}")
                        .foregroundStyle(.tertiary)
                }
                Button(crumb.title) { model.selectedID = crumb.id }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == path.count - 1 ? Color.primary : Color.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: node.systemImage)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text(node.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                if let subtitle = node.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                model.copyToPasteboard(HardwareReport.text(for: node))
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy this item and everything under it as text")
        }
    }

    private var summary: String {
        var parts: [String] = []
        let count = node.properties.count
        if count > 0 { parts.append("\(count) \(count == 1 ? "property" : "properties")") }
        let below = node.descendantCount
        if below > 0 { parts.append("\(below) \(below == 1 ? "item" : "items") below") }
        if let section, isSectionRoot {
            parts.append(String(format: "read in %.1f s", section.captureSeconds))
        }
        return parts.joined(separator: ", ")
    }

    private func noteBanner(_ note: String) -> some View {
        Label(note, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.yellow.opacity(0.12)))
    }
}

/// Label/value rows grouped by nested record, with click-to-copy and the
/// search term highlighted.
private struct HardwarePropertyTable: View {
    let node: HardwareNode
    let query: String
    @ObservedObject var model: HardwareExplorerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(node.propertyGroups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 4) {
                    if let group {
                        Text(group.uppercased())
                            .font(.caption2.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                    ForEach(Array(node.properties(in: group).enumerated()), id: \.offset) {
                        _, property in
                        HardwarePropertyRow(property: property, query: query, model: model)
                    }
                }
            }
        }
    }
}

private struct HardwarePropertyRow: View {
    let property: HardwareProperty
    let query: String
    @ObservedObject var model: HardwareExplorerModel
    @State private var hovering = false

    private var highlighted: Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return !needle.isEmpty && property.matches(needle)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(property.label)
                .foregroundStyle(.secondary)
                .frame(width: 220, alignment: .trailing)
                .lineLimit(2)
            Text(property.value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.copyToPasteboard(property.value)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Copy value")
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    highlighted
                        ? Color.yellow.opacity(0.22)
                        : (hovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Value") { model.copyToPasteboard(property.value) }
            Button("Copy \u{201C}\(property.label): \(property.value)\u{201D}") {
                model.copyToPasteboard("\(property.label): \(property.value)")
            }
        }
    }
}

/// Supported features as tags, unsupported ones listed quietly below.
private struct HardwareFeatureCloud: View {
    let properties: [HardwareProperty]
    let query: String

    var body: some View {
        let supported = properties.filter { $0.value == "Supported" }
        let missing = properties.filter { $0.value != "Supported" }
        VStack(alignment: .leading, spacing: 12) {
            Text("\(supported.count) supported")
                .font(.caption)
                .foregroundStyle(.secondary)
            HardwareFlowLayout(spacing: 6) {
                ForEach(supported, id: \.label) { feature in
                    Text(feature.label)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                isHit(feature)
                                    ? Color.yellow.opacity(0.35) : Color.accentColor.opacity(0.12))
                        )
                        .textSelection(.enabled)
                }
            }
            if !missing.isEmpty {
                Text("Not supported: " + missing.map(\.label).joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private func isHit(_ property: HardwareProperty) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return !needle.isEmpty && property.label.localizedCaseInsensitiveContains(needle)
    }
}

private struct HardwareChildList: View {
    let children: [HardwareNode]
    @ObservedObject var model: HardwareExplorerModel

    var body: some View {
        VStack(spacing: 2) {
            ForEach(children) { child in
                HardwareChildRow(node: child) { model.selectedID = child.id }
            }
        }
    }
}

private struct HardwareChildRow: View {
    let node: HardwareNode
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: node.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title)
                        .lineLimit(1)
                    if let subtitle = node.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !node.children.isEmpty {
                    Text("\(node.children.count) inside")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Shared chrome

/// The panel card every Hardware page uses, matching the other tabs.
struct HardwarePanel<Content: View>: View {
    let title: String
    let systemImage: String
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    init(
        _ title: String, systemImage: String, action: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
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
                if let action {
                    Button(action: action) {
                        Label("Details", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// Wraps its children onto as many lines as they need.
struct HardwareFlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Give every item in a row the row's height, so a row of blocks lines
    /// up along the bottom as well as the top. Items must accept the extra
    /// height (a `maxHeight: .infinity` frame) for it to show.
    var equalHeights = false

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    /// Wrap into rows at `width`; unconstrained (an ideal-size probe, as
    /// `ViewThatFits` makes) means the narrowest layout that fits the widest
    /// item, so a row of cards can still sit beside this one and the real
    /// proposal decides the wrap.
    private func rows(for subviews: Subviews, width: CGFloat?, sizes: [CGSize]) -> [Row] {
        let limit = width ?? sizes.map(\.width).max() ?? 0
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if x + size.width > limit, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
                x = 0
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(for: subviews, width: proposal.width, sizes: sizes)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = proposal.width ?? sizes.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width, sizes: sizes) {
            var x = bounds.minX
            for index in row.indices {
                let size = sizes[index]
                let height = equalHeights ? row.height : size.height
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: size.width, height: height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
}
