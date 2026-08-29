import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

/// Owns the primary, memory-pressure menubar item as an AppKit `NSStatusItem`
/// with a SwiftUI panel hosted in an `NSPopover`.
///
/// This was a SwiftUI `MenuBarExtra`. On macOS 26/27 the system `MenuBarAgent`
/// persists menu-bar status items and demand-relaunches a quit menu-bar app to
/// restore them ("No server elements for status item" -> "launch job demand"),
/// so the app comes straight back and can't be quit. The cure is to remove the
/// item on quit so the removal reads as deliberate — but a `MenuBarExtra` can't
/// be retracted at quit: touching its `isInserted` spins SwiftUI's scene
/// reconciliation into an infinite loop and the app never exits (confirmed on
/// 27.0 26A5353q). Driving the item from AppKit, like the CPU/Battery/Network
/// items, makes `removeStatusItem` on quit a clean synchronous deregistration, so
/// the app actually quits and stays quit. Always installed (the primary item).
@MainActor
final class MemoryStatusItemController: NSObject {
    private let model: SamplerModel
    private let appState: AppState
    private let helperManager: HelperManager
    private let updateController: UpdateController
    private let appModeManager: AppModeManager
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// Invisible host for the window-opening plumbing — see `MenuBarWindowRouter`.
    private var router: NSHostingView<MenuBarWindowRouter>?
    private var cancellables = Set<AnyCancellable>()
    /// Drives the dropdown's 1 Hz refresh, but only while it is open.
    private lazy var menuClock = MenuClock(
        source: model.liveTick.eraseToAnyPublisher(),
        onOpen: { [model] in model.requestImmediateTick() },
        // The dropdown lists the top processes by footprint, so it needs the
        // per-process scan — but only while it is open, and at the full 1 Hz so the
        // list stays live regardless of the global table cadence. Register/unregister
        // with it.
        onActiveChange: { [model] active in
            if active {
                model.addPopoverProcessConsumer(.footprint)
            } else {
                model.removePopoverProcessConsumer(.footprint)
            }
        })

    /// What the button currently shows, so an unchanged tick is a no-op.
    private var shownSignature: String?

    init(
        model: SamplerModel, appState: AppState, helperManager: HelperManager,
        updateController: UpdateController,
        appModeManager: AppModeManager
    ) {
        self.model = model
        self.appState = appState
        self.helperManager = helperManager
        self.updateController = updateController
        self.appModeManager = appModeManager
        super.init()
    }

    /// Install the item and keep its image in sync with the sampler. Unlike the
    /// CPU/Battery/Network items this one is not user-toggleable — it is the app's
    /// primary menubar presence — so it installs once and stays.
    func start() {
        model.menuBarTick
            .sink { [weak self] _ in
                self?.refreshImage()
                self?.reconcileMenuClock()
            }
            .store(in: &cancellables)
        installItem()
    }

    private func installItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageOnly
        // Carry the window-opening plumbing in an invisible SwiftUI view hosted
        // inside the always-present status item button (its window is live, so the
        // view's `onReceive`/`openWindow` stay active). Without the old MenuBarExtra
        // label there is otherwise no always-mounted view to open the main window /
        // settings in response to the notifications the popovers and process actions
        // post.
        if let button = item.button {
            let host = NSHostingView(rootView: MenuBarWindowRouter())
            host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            button.addSubview(host)
            router = host
        }
        statusItem = item
        shownSignature = nil
        refreshImage()
    }

    /// Remove the menubar item immediately. Called on app quit so macOS 26/27's
    /// `MenuBarAgent` records a deliberate removal rather than demand-relaunching
    /// the app to restore a persisted status item.
    func tearDownForQuit() {
        popover?.performClose(nil)
        popover = nil
        router?.removeFromSuperview()
        router = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Button image

    private func refreshImage() {
        guard let button = statusItem?.button else { return }

        let system = model.liveSystem
        let level = system?.pressureLevel ?? .normal
        let percent = system.map { Int($0.pressurePercent.rounded()) }
        let isDark = button.effectiveAppearance.isDarkMenuBar
        let signature = "\(percent.map(String.init) ?? "–")-\(level)-\(isDark ? "d" : "l")"
        guard signature != shownSignature else { return }
        button.image = MemoryMenuBarImage.image(percent: percent, level: level, isDark: isDark)
        button.toolTip = percent.map { "Memory pressure \($0)%" } ?? "Memory"
        shownSignature = signature
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let popover = popover ?? makePopover()
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let content = MenuBarContentView()
            .environmentObject(model)
            .environmentObject(model.menuLists)
            .environmentObject(appState)
            .environmentObject(helperManager)
            .environmentObject(updateController)
            .environmentObject(menuClock)
            .environmentObject(appModeManager)
        let hosting = PopoverHostingController(rootView: content)
        // Size the popover to the SwiftUI content (which sets its own width and
        // grows vertically with the summary and process list).
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        return popover
    }
    /// Keep the menu clock's per-process consumer tied to the popover's ACTUAL
    /// visibility. A SwiftUI `onDisappear` can be dropped for NSPopover-hosted
    /// content, which leaves the dropdown's 1 Hz per-process consumer registered
    /// after it closed — re-rendering the whole main window at 1 Hz regardless of
    /// the refresh interval. Reconciling against the authoritative `isShown` on
    /// the 1 Hz heartbeat releases it within a tick of a real close, and never
    /// closes while the popover is genuinely shown (so the live dropdown is not
    /// frozen). Both calls are idempotent.
    private func reconcileMenuClock() {
        guard let popover else { return }
        if popover.isShown {
            menuClock.open()
        } else {
            menuClock.close()
            // Release the closed popover with its SwiftUI content: a retained
            // hosting controller kept observing the menu lists and re-rendered
            // the hidden panel on every table tick. The next open rebuilds it.
            self.popover = nil
        }
    }
}

extension MemoryStatusItemController: NSPopoverDelegate {
    // Refcount the menu clock so the dropdown refreshes at 1 Hz only while shown,
    // mirroring the other status item controllers.
    func popoverDidShow(_ notification: Notification) {}
    func popoverDidClose(_ notification: Notification) {}
}
