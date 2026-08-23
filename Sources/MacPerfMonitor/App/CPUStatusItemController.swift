import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

/// Owns the second, CPU-focused menubar item as an AppKit `NSStatusItem` with a
/// SwiftUI panel hosted in an `NSPopover`.
///
/// Why not a second SwiftUI `MenuBarExtra`? A user-toggleable item needs the
/// scene to be conditionally present, and the current Swift toolchain fails to
/// type-check a conditional `MenuBarExtra` inside a `SceneBuilder` (it crashes
/// with "failed to produce diagnostic"). Driving the item from AppKit sidesteps
/// that entirely and gives a clean live show/hide: the button image is the same
/// rasterised "CPU NN%" read-out as the pressure label, refreshed only when the
/// rounded percentage or level changes, and the dropdown is the shared
/// `CPUMenuBarContentView`.
@MainActor
final class CPUStatusItemController: NSObject {
    private let model: SamplerModel
    private let appState: AppState
    private let updateController: UpdateController

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    /// Drives the dropdown's 1 Hz refresh, but only while it is open.
    private lazy var menuClock = MenuClock(
        source: model.liveTick.eraseToAnyPublisher(),
        onOpen: { [model] in model.requestImmediateTick() },
        // The dropdown ranks top processes, so it needs the per-process scan — but
        // only while it is open, and at the full 1 Hz so the list stays live
        // regardless of the global table cadence. Register/unregister with the popover.
        onActiveChange: { [model] active in
            if active {
                model.addPopoverProcessConsumer(.cpu)
            } else {
                model.removePopoverProcessConsumer(.cpu)
            }
        })

    /// What the button currently shows, so an unchanged tick is a no-op.
    private var shownSignature: String?

    /// UserDefaults key shared with the Settings toggle (`@AppStorage`).
    static let visibilityDefaultsKey = "showCPUMenuBar"

    init(
        model: SamplerModel, appState: AppState,
        updateController: UpdateController
    ) {
        self.model = model
        self.appState = appState
        self.updateController = updateController
        super.init()
    }

    /// Begin managing the item: install it (if enabled), then keep its image and
    /// its visibility in sync with the sampler and the setting.
    func start() {
        // The menu-bar icon refreshes on the full-rate heartbeat (reading the
        // live `smoothedCPU`), so it stays live even though the heavy `latest`
        // snapshot now publishes only on the slower heavy cadence.
        model.menuBarTick
            .sink { [weak self] _ in
                self?.refreshImage()
                self?.reconcileMenuClock()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyVisibility() }
            .store(in: &cancellables)
        applyVisibility()
    }

    // MARK: - Visibility

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.visibilityDefaultsKey) as? Bool ?? true
    }

    private func applyVisibility() {
        if isEnabled {
            installItem()
        } else {
            removeItem()
        }
    }

    private func installItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageOnly
        statusItem = item
        shownSignature = nil
        refreshImage()
    }

    private func removeItem() {
        popover?.performClose(nil)
        popover = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    /// Remove the menubar item immediately. Called on app quit so macOS 26/27's
    /// `MenuBarAgent` records a deliberate removal rather than demand-relaunching
    /// the app to restore a persisted status item.
    func tearDownForQuit() { removeItem() }

    // MARK: - Button image

    private func refreshImage() {
        guard let button = statusItem?.button else { return }

        // Use the smoothed total so the menubar figure settles rather than
        // flicking between values (and digit counts) on every 0.5 s tick.
        let usage = model.smoothedCPU?.totalUsage
        let percent = usage.map { Int(($0 * 100).rounded()) }
        let level = CPULevel(fraction: usage ?? 0)
        // Track the bar's light/dark appearance so the caption re-renders legibly
        // when the user (or a wallpaper) flips it. Picked up on the next live tick.
        let isDark = button.effectiveAppearance.isDarkMenuBar
        let signature = "\(percent.map(String.init) ?? "–")-\(level.rawValue)-\(isDark ? "d" : "l")"
        guard signature != shownSignature else { return }
        button.image = CPUMenuBarImage.image(percent: percent, level: level, isDark: isDark)
        button.toolTip = percent.map { "CPU \($0)%" } ?? "CPU"
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
        let content = CPUMenuBarContentView(dismiss: { [weak self] in
            self?.popover?.performClose(nil)
        })
        .environmentObject(model)
        .environmentObject(model.menuLists)
        .environmentObject(appState)
        .environmentObject(updateController)
        .environmentObject(menuClock)
        let hosting = NSHostingController(rootView: content)
        // Size the popover to the SwiftUI content (which sets its own width and
        // grows vertically with the core grid and process list).
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

extension CPUStatusItemController: NSPopoverDelegate {
    // Refcount the menu clock so the dropdown refreshes at 1 Hz only while shown.
    // The menu clock's open/close is driven by the content view's onAppear/
    // onDisappear — these status-item popover delegate callbacks do not fire
    // reliably, which is what froze the dropdown at the global refresh rate.
    func popoverDidShow(_ notification: Notification) {}
    func popoverDidClose(_ notification: Notification) {}
}
