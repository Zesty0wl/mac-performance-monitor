import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

/// Owns the battery menubar item as an AppKit `NSStatusItem` with a SwiftUI panel
/// hosted in an `NSPopover`, mirroring `CPUStatusItemController`.
///
/// AppKit rather than a third SwiftUI `MenuBarExtra` for the same reason as the
/// CPU item: the toolchain can't type-check a conditional `MenuBarExtra`, and
/// this item is user-toggleable. On a laptop the button image is a rasterised
/// charge percentage (refreshed only when the rounded percentage, charging
/// state, or level changes); on a desktop with no battery it's a bolt glyph and
/// the panel ranks the top energy users. The dropdown is
/// `BatteryMenuBarContentView`.
@MainActor
final class BatteryStatusItemController: NSObject {
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
        // The dropdown ranks the top energy users, so it needs the per-process scan
        // — but only while it is open, and at the full 1 Hz so the list stays live
        // regardless of the global table cadence. Register/unregister the demand with it.
        onActiveChange: { [model] active in
            if active {
                model.addPopoverProcessConsumer(.energy)
            } else {
                model.removePopoverProcessConsumer(.energy)
            }
        })

    /// What the button currently shows, so an unchanged tick is a no-op.
    private var shownSignature: String?

    /// UserDefaults key shared with the Settings toggle (`@AppStorage`).
    static let visibilityDefaultsKey = "showBatteryMenuBar"

    init(
        model: SamplerModel, appState: AppState,
        updateController: UpdateController
    ) {
        self.model = model
        self.appState = appState
        self.updateController = updateController
        super.init()
    }

    /// Begin managing the item: install it (when enabled and a battery exists),
    /// and keep its image and visibility in sync with the sampler and the setting.
    func start() {
        model.menuBarTick
            .sink { [weak self] _ in
                self?.update()
                self?.reconcileMenuClock()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        update()
    }

    // MARK: - Visibility

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.visibilityDefaultsKey) as? Bool ?? true
    }

    /// Install or remove the item to match the setting, then refresh its image.
    /// Shown on every Mac when enabled: a laptop gets the charge read-out, a
    /// desktop gets a bolt glyph (its panel still ranks the top energy users).
    /// Idempotent, so it's safe to call on every tick.
    private func update() {
        if isEnabled {
            installItem()
            refreshImage()
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

        guard let battery = model.latestBattery, battery.isPresent else {
            // Desktop (no internal battery), or before the first sample lands.
            // There's no charge to read out, so show the measured whole-machine
            // power draw in watts when we have it, and a plain bolt glyph
            // otherwise. The panel still ranks the top energy users.
            let watts = model.latestBattery?.systemPowerWatts ?? 0
            if watts > 0 {
                let isDark = button.effectiveAppearance.isDarkMenuBar
                let signature = "energy-\(Int(watts.rounded()))-\(isDark ? "dk" : "lt")"
                guard signature != shownSignature else { return }
                button.image = EnergyWattsMenuBarImage.image(watts: watts, isDark: isDark)
                button.toolTip = "Energy · \(BatteryFormat.watts(watts)) system power"
                shownSignature = signature
            } else if shownSignature != "energy-bolt" {
                button.image = NSImage(
                    systemSymbolName: "bolt.fill", accessibilityDescription: "Energy")
                button.image?.isTemplate = true
                button.toolTip = "Energy"
                shownSignature = "energy-bolt"
            }
            return
        }
        let percent = Int(battery.chargePercent.rounded())
        let level = BatteryLevel(percent: battery.chargePercent)
        // Track the bar's light/dark appearance so the caption re-renders legibly
        // when the user (or a wallpaper) flips it. Picked up on the next live tick.
        let isDark = button.effectiveAppearance.isDarkMenuBar
        let signature =
            "\(percent)-\(battery.isCharging ? "c" : "d")-\(level.rawValue)-\(isDark ? "dk" : "lt")"
        guard signature != shownSignature else { return }
        button.image = BatteryMenuBarImage.image(percent: percent, level: level, isDark: isDark)
        button.toolTip = "Battery \(percent)%" + (battery.isCharging ? " · charging" : "")
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
        let content = BatteryMenuBarContentView(dismiss: { [weak self] in
            self?.popover?.performClose(nil)
        })
        .environmentObject(model)
        .environmentObject(model.menuLists)
        .environmentObject(appState)
        .environmentObject(updateController)
        .environmentObject(menuClock)
        let hosting = NSHostingController(rootView: content)
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

extension BatteryStatusItemController: NSPopoverDelegate {
    // Refcount the menu clock so the dropdown refreshes at 1 Hz only while shown.
    // The menu clock's open/close is driven by the content view's onAppear/
    // onDisappear — these status-item popover delegate callbacks do not fire
    // reliably, which is what froze the dropdown at the global refresh rate.
    func popoverDidShow(_ notification: Notification) {}
    func popoverDidClose(_ notification: Notification) {}
}
