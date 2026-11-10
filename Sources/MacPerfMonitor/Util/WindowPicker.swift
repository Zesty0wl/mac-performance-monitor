import AppKit
import CoreGraphics
import MacPerfMonitorCore

/// Finds the process that owns the window under a point on screen.
///
/// The window server reports each window's owner, frame and layer to any app
/// without a privacy prompt. Window titles and contents are what Screen
/// Recording permission protects, and this reads neither.
enum WindowPicker {
    /// One on-screen window, as much of it as picking needs.
    struct Window: Equatable {
        var number: Int
        var ownerPID: pid_t
        /// In the window server's coordinates: origin at the top left of the
        /// main display, y increasing downwards.
        var frame: CGRect
        /// 0 for ordinary app windows; the menu bar, Dock and overlays are higher.
        var layer: Int
        var alpha: Double
    }

    /// The windows on screen now, front to back.
    static func onScreenWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                let pid = info[kCGWindowOwnerPID as String] as? Int,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return Window(
                number: number, ownerPID: pid_t(pid), frame: frame,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// The owner of the frontmost visible window containing `point`, skipping
    /// the windows numbered in `ignoring` (the picker's own overlays).
    ///
    /// An ordinary app window wins over anything floating above it, such as a
    /// notification or an invisible full-screen overlay some utilities keep.
    /// Only when no app window is there does a higher layer count, which is
    /// how clicking the menu bar or the Dock finds their owners.
    static func ownerPID(
        at point: CGPoint, in windows: [Window], ignoring: Set<Int> = []
    ) -> pid_t? {
        let candidates = windows.filter {
            !ignoring.contains($0.number) && $0.alpha > 0 && $0.ownerPID > 0
                && $0.frame.contains(point)
        }
        return (candidates.first { $0.layer == 0 } ?? candidates.first)?.ownerPID
    }

    /// Convert a point from AppKit's screen coordinates (origin at the bottom
    /// left of the main display) to the window server's (origin at its top
    /// left). `mainHeight` is the height of the display that has the menu bar.
    static func windowServerPoint(fromAppKit point: CGPoint, mainHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainHeight - point.y)
    }
}

/// Runs one "click a window" pick: covers every display with a clear overlay
/// showing a crosshair, waits for a click or Escape, then reports the process
/// that owns the window that was under the click.
@MainActor
final class WindowPickerController {
    static let shared = WindowPickerController()

    private var overlays: [NSWindow] = []
    private var completion: ((pid_t?) -> Void)?

    var isPicking: Bool { !overlays.isEmpty }

    /// Start a pick. `completion` gets the owning pid, or nil when the user
    /// pressed Escape or clicked where no window was.
    func begin(completion: @escaping (pid_t?) -> Void) {
        guard !isPicking else { return }
        self.completion = completion
        for screen in NSScreen.screens {
            let window = PickerOverlayWindow(
                contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = PickerOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onClick = { [weak self] in self?.finish(at: NSEvent.mouseLocation) }
            view.onCancel = { [weak self] in self?.finish(at: nil) }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            overlays.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        overlays.first { $0.screen == NSScreen.main }?.makeKey()
            ?? overlays.first?.makeKey()
    }

    private func finish(at location: CGPoint?) {
        guard isPicking else { return }
        let ignoring = Set(overlays.map(\.windowNumber))
        for window in overlays { window.orderOut(nil) }
        overlays.removeAll()
        NSCursor.arrow.set()
        let completion = self.completion
        self.completion = nil
        guard let location else {
            completion?(nil)
            return
        }
        // The main display is the first screen: the one whose origin is (0, 0).
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = WindowPicker.windowServerPoint(fromAppKit: location, mainHeight: mainHeight)
        completion?(
            WindowPicker.ownerPID(
                at: point, in: WindowPicker.onScreenWindows(), ignoring: ignoring))
    }
}

/// A borderless window that can still take the keyboard, for Escape.
private final class PickerOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The overlay's content: a faint wash so it is clear the screen is in a
/// special mode, a line saying what to do, and a crosshair cursor throughout.
private final class PickerOverlayView: NSView {
    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?

    private let hint = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        hint.stringValue = t("Click a window to find its process. Press Esc to cancel.")
        hint.font = .systemFont(ofSize: 15, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        hint.layer?.cornerRadius = 8
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        let size = hint.intrinsicContentSize
        let width = size.width + 28
        let height = size.height + 14
        hint.frame = NSRect(
            x: (bounds.width - width) / 2, y: bounds.height - height - 60, width: width,
            height: height)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
