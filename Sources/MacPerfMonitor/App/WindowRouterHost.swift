import AppKit
import SwiftUI

/// An off-screen, always-present home for `MenuBarWindowRouter`.
///
/// SwiftUI's `openWindow` and `openSettings` actions only exist inside a mounted
/// view. They used to be carried by a one-pixel hosting view inside the status
/// item's button, which meant every window-opening path in the app depended on
/// the menu bar item existing: the reopen handler, notification clicks, a
/// `.mpmtrace` opened from Finder, the menu commands and the onboarding request
/// all queue in `WindowOpenBridge` until a router registers. That is fine while
/// the item is mandatory and fatal once it is optional, because with no item
/// there is no router, the queue never drains, and nothing can open a window
/// again for the rest of the session.
///
/// So the router moves here instead. This owns a one-pixel borderless window
/// parked far off-screen with zero alpha. It has to be ordered in, because a
/// hosting view in a window that was never ordered in does not mount and so
/// never registers, but it is invisible, ignores mouse events, stays out of the
/// Windows menu and out of window cycling, and refuses to become key or main.
/// That last part is what `NSWindow.isRealAppWindow` keys off, so presence and
/// lifetime logic can tell this apart from a window the user can see.
@MainActor
final class WindowRouterHost {
    private var window: NSWindow?

    /// Create and order in the host. Safe to call more than once.
    func start() {
        guard window == nil else { return }
        let host = RouterHostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        host.contentView = NSHostingView(rootView: MenuBarWindowRouter())
        host.alphaValue = 0
        host.ignoresMouseEvents = true
        host.isExcludedFromWindowsMenu = true
        host.isReleasedWhenClosed = false
        host.hasShadow = false
        host.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Far enough off-screen that it cannot land on a display, whatever the
        // arrangement, while still counting as ordered in.
        host.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        host.orderFrontRegardless()
        window = host
        AppLog.ui.notice("window router host installed")
    }
}

/// The router host's window. Marked as its own type so it is never mistaken for
/// a window the user opened.
final class RouterHostWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSWindow {
    /// Whether this is a window the user can see and interact with, as opposed
    /// to a status item's window, a popover, a panel, or the router host.
    ///
    /// Used to answer "does the app have a window up?", which drives the reopen
    /// handler, the activation policy, and the quit-when-idle rule. `canBecomeMain`
    /// is the discriminator: every scene window in this app can become main, and
    /// none of the infrastructure windows can.
    var isRealAppWindow: Bool {
        isVisible && canBecomeMain
    }
}
