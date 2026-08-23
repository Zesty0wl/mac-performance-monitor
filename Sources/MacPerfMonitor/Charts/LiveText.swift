import AppKit
import SwiftUI

/// A live string (and optional colour) for an AppKit label, published by the
/// owning store each tick. Labels skip the update when nothing changed, so a
/// steady figure costs nothing. Main thread only.
final class TextFeed {
    private(set) var text: String
    private(set) var color: NSColor?
    private var observers: [UUID: () -> Void] = [:]

    init(_ text: String = "--", color: NSColor? = nil) {
        self.text = text
        self.color = color
    }

    func publish(_ text: String, color: NSColor? = nil) {
        guard text != self.text || color != self.color else { return }
        self.text = text
        self.color = color
        for observer in observers.values { observer() }
    }

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

/// A read-out that updates in place from a `TextFeed`, without re-rendering
/// or re-laying-out the SwiftUI view that contains it. Its reported size is
/// constant (the font's line height), so a new figure never moves anything.
struct LiveText: NSViewRepresentable {
    let feed: TextFeed
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    var color: NSColor = .labelColor
    var alignment: NSTextAlignment = .left

    func makeNSView(context: Context) -> LiveTextField {
        let field = LiveTextField(font: font, color: color, alignment: alignment)
        field.attach(feed)
        return field
    }

    func updateNSView(_ field: LiveTextField, context: Context) {
        field.apply(font: font, color: color, alignment: alignment)
        if field.feed !== feed { field.attach(feed) }
    }

    static func dismantleNSView(_ field: LiveTextField, coordinator: ()) {
        field.detach()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: LiveTextField, context: Context
    )
        -> CGSize?
    {
        CGSize(width: proposal.width ?? 80, height: LiveTextField.lineHeight(for: font))
    }
}

final class LiveTextField: NSTextField {
    private(set) var feed: TextFeed?
    private var observation: UUID?
    private var baseColor: NSColor

    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 2
    }

    init(font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        baseColor = color
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(font: font, color: color, alignment: alignment)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { detach() }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: Self.lineHeight(for: font ?? .systemFont(ofSize: 13)))
    }

    /// `NSTextField` invalidates its intrinsic size on every `stringValue`
    /// set, and SwiftUI's representable host answers that with a full layout
    /// pass of the hosting view. In the main window that pass re-solved the
    /// window's constraints and rebuilt the toolbar bridge on every tick,
    /// about 30 ms, for a field whose size never depends on its text (fixed
    /// height, no intrinsic width). Only a font change can alter it, so only
    /// `apply` lets the invalidation through.
    private var allowsIntrinsicInvalidation = false

    override func invalidateIntrinsicContentSize() {
        guard allowsIntrinsicInvalidation else { return }
        super.invalidateIntrinsicContentSize()
    }

    func apply(font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        if self.font != font {
            self.font = font
            allowsIntrinsicInvalidation = true
            invalidateIntrinsicContentSize()
            allowsIntrinsicInvalidation = false
        }
        if self.alignment != alignment { self.alignment = alignment }
        baseColor = color
        refresh()
    }

    func attach(_ feed: TextFeed) {
        detach()
        self.feed = feed
        observation = feed.observe { [weak self] in self?.refresh() }
        refresh()
    }

    func detach() {
        if let feed, let observation { feed.stopObserving(observation) }
        observation = nil
        feed = nil
    }

    private func refresh() {
        let text = feed?.text ?? "--"
        if stringValue != text { stringValue = text }
        let color = feed?.color ?? baseColor
        if textColor != color { textColor = color }
    }
}
