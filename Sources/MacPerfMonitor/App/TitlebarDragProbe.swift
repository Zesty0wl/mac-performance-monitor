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
        var hit: String
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
                hit: hitChain(window, at: event.locationInWindow))
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
                hit \(current.hit, privacy: .public), movable \(window.isMovable, privacy: .public), \
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

    /// The view AppKit delivers the press to, and its ancestors, by class.
    private static func hitChain(_ window: NSWindow, at point: NSPoint) -> String {
        guard let frameView = window.contentView?.superview else { return "no frame view" }
        var view = frameView.hitTest(frameView.convert(point, from: nil))
        var names: [String] = []
        while let current = view, names.count < 6 {
            names.append(String(describing: type(of: current)))
            view = current.superview
        }
        return names.isEmpty ? "nothing" : names.joined(separator: " < ")
    }
}
