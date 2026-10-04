import AppKit

/// Evidence for "the main window will not drag from its title bar". It
/// happens now and then with plenty of empty toolbar under the pointer, and has
/// always recovered by the time anyone looks (2026-09-30, twice: the app was
/// responsive, nothing covered the bar, and a synthetic drag then worked).
///
/// Watches presses in the main window's title bar and, when one is dragged
/// well past the drag threshold without the window moving, logs what AppKit
/// hit and the window's state. Read it with
/// `log show --last 1h --predicate 'subsystem == "uk.co.bzwrd.macperfmonitor" AND eventMessage CONTAINS "title bar drag"'`.
/// Costs nothing outside title-bar presses.
@MainActor
enum TitlebarDragProbe {
    private struct Press {
        weak var window: NSWindow?
        var origin: NSPoint
        var start: NSPoint
        var distance: CGFloat = 0
        var point: NSPoint
        var hit: String
        /// Every toolbar item container at the press, as "class x..x", in
        /// window points: which one reached into the empty toolbar.
        var items: String
    }

    private static var press: Press?
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { event in
            MainActor.assumeIsolated { observe(event) }
            return event
        }
    }

    private static func observe(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            press = nil
            guard let window = event.window,
                window.identifier?.rawValue.hasPrefix(WindowID.main) == true,
                event.locationInWindow.y >= window.contentLayoutRect.maxY
            else { return }
            press = Press(
                window: window, origin: window.frame.origin, start: NSEvent.mouseLocation,
                point: event.locationInWindow, hit: hitChain(window, at: event.locationInWindow),
                items: toolbarItems(window))
        case .leftMouseDragged:
            guard var current = press else { return }
            let now = NSEvent.mouseLocation
            current.distance = max(
                current.distance, hypot(now.x - current.start.x, now.y - current.start.y))
            press = current
        case .leftMouseUp:
            defer { press = nil }
            guard let current = press, let window = current.window, current.distance >= 10,
                window.frame.origin == current.origin
            else { return }
            AppLog.ui.error(
                """
                title bar drag did not move the window: dragged \(Int(current.distance), privacy: .public) pt, \
                pressed at x \(Int(current.point.x), privacy: .public) of \(Int(window.frame.width), privacy: .public), \
                hit \(current.hit, privacy: .public), \
                items \(current.items, privacy: .public), movable \(window.isMovable, privacy: .public), \
                key \(window.isKeyWindow, privacy: .public), active \(NSApp.isActive, privacy: .public), \
                sheet \(window.attachedSheet != nil, privacy: .public), \
                modal \(NSApp.modalWindow != nil, privacy: .public), \
                frame \(NSStringFromRect(window.frame), privacy: .public), \
                screen \(window.screen?.localizedName ?? "none", privacy: .public)
                """)
        default:
            break
        }
    }

    /// The view AppKit delivers the press to, and its ancestors, by class,
    /// each with its horizontal extent in window points.
    private static func hitChain(_ window: NSWindow, at point: NSPoint) -> String {
        guard let frameView = window.contentView?.superview else { return "no frame view" }
        var view = frameView.hitTest(frameView.convert(point, from: nil))
        var names: [String] = []
        while let current = view, names.count < 6 {
            names.append("\(type(of: current)) \(span(current))")
            view = current.superview
        }
        return names.isEmpty ? "nothing" : names.joined(separator: " < ")
    }

    /// The toolbar's item containers (AppKit's item viewers), found by walking
    /// the title bar's public view tree, with what each holds.
    private static func toolbarItems(_ window: NSWindow) -> String {
        guard let frameView = window.contentView?.superview else { return "none" }
        var found: [String] = []
        func walk(_ view: NSView, depth: Int) {
            guard depth < 12, found.count < 12 else { return }
            let name = String(describing: type(of: view))
            if name.contains("ToolbarItemViewer") {
                let inside = view.subviews.map { String(describing: type(of: $0)) }.prefix(2)
                found.append("\(span(view)) [\(inside.joined(separator: ","))]")
                return
            }
            for child in view.subviews { walk(child, depth: depth + 1) }
        }
        for child in frameView.subviews
        where String(describing: type(of: child)).contains("Titlebar") {
            walk(child, depth: 0)
        }
        return found.isEmpty ? "none" : found.joined(separator: "; ")
    }

    private static func span(_ view: NSView) -> String {
        let frame = view.convert(view.bounds, to: nil)
        return "x \(Int(frame.minX))..\(Int(frame.maxX))"
    }
}
