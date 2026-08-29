import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

/// Owns the network menubar item as an AppKit `NSStatusItem` with a SwiftUI panel
/// in an `NSPopover`, mirroring `CPUStatusItemController`/`BatteryStatusItemController`.
///
/// AppKit rather than a fourth SwiftUI `MenuBarExtra` for the same reason as the
/// CPU and energy items: the toolchain can't type-check a conditional
/// `MenuBarExtra`, and this item is user-toggleable. The button image is the
/// stacked ↓/↑ throughput read-out (refreshed only when the rounded rates or the
/// bar appearance change); the dropdown is `NetworkMenuBarContentView`.
@MainActor
final class NetworkStatusItemController: NSObject {
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
        // The dropdown shows the top network apps, which come from the per-process
        // scan; register the demand while open like the other dropdowns. (This
        // controller previously never registered, which left its list riding on
        // whatever cadence other consumers happened to force.)
        onActiveChange: { [model] active in
            if active {
                model.addPopoverProcessConsumer(.network)
            } else {
                model.removePopoverProcessConsumer(.network)
            }
        })

    /// What the button currently shows, so an unchanged tick is a no-op.
    private var shownSignature: String?

    // --- Activity LEDs (opt-in old-school HDD-light flicker; replaces the arrows) ---
    /// 2×2 pre-rendered composites indexed [downOn][upOn] for the current read-out,
    /// so the fast flicker timer only SWAPS a cached image — it never draws.
    private var ledVariants: [[NSImage]] = []
    private var currentDownRate = 0.0
    private var currentUpRate = 0.0
    /// Fast timer that flickers the LEDs; runs ONLY while traffic is flowing, so a
    /// quiet Mac costs nothing — the overhead is paid only during active transfers.
    private var flickerTimer: Timer?
    private let flickerHz = 12.0
    /// Below this (bytes/sec) a direction counts as idle — no flicker, no timer.
    private let activeThreshold = 2048.0
    /// Last-seen LED setting, so flipping it re-renders without disturbing the
    /// flicker on every unrelated defaults change.
    private var lastUseLEDs = false

    /// UserDefaults key shared with the Settings toggle (`@AppStorage`).
    static let visibilityDefaultsKey = "showNetworkMenuBar"
    /// When true the item blinks activity LEDs instead of the ↓/↑ arrows. Off by
    /// default — the flicker costs extra CPU while traffic flows.
    static let activityLEDsDefaultsKey = "networkActivityLEDs"

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
        // The icon refreshes on the full-rate heartbeat (reading the live
        // smoothed network rates), staying live even though the heavy `latest`
        // snapshot publishes only on the slower heavy cadence.
        model.menuBarTick
            .sink { [weak self] _ in self?.refreshImage() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.defaultsDidChange() }
            .store(in: &cancellables)
        lastUseLEDs = useLEDs
        applyVisibility()
    }

    /// Apply a Settings change: show/hide the item, and if the LED ↔ arrows toggle
    /// flipped, drop the flicker and force a re-render in the new style.
    private func defaultsDidChange() {
        applyVisibility()
        if useLEDs != lastUseLEDs {
            lastUseLEDs = useLEDs
            stopFlicker()
            shownSignature = nil
            refreshImage()
        }
    }

    // MARK: - Visibility

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.visibilityDefaultsKey) as? Bool ?? true
    }

    /// Blinking activity LEDs instead of the arrows (off by default).
    private var useLEDs: Bool {
        UserDefaults.standard.bool(forKey: Self.activityLEDsDefaultsKey)
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
        stopFlicker()
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

        guard let rates = model.smoothedNetworkRates else {
            // Before the first interface read: a plain glyph rather than zeros.
            stopFlicker()
            if shownSignature != "network-glyph" {
                button.image = NSImage(
                    systemSymbolName: "network", accessibilityDescription: "Network")
                button.image?.isTemplate = true
                button.toolTip = "Network"
                shownSignature = "network-glyph"
            }
            return
        }

        let downText = ByteFormat.rateCompact(rates.inBytesPerSec)
        let upText = ByteFormat.rateCompact(rates.outBytesPerSec)
        let isDark = button.effectiveAppearance.isDarkMenuBar
        let tooltip =
            "Network · \(ByteFormat.rate(rates.inBytesPerSec)) down · "
            + "\(ByteFormat.rate(rates.outBytesPerSec)) up"

        if useLEDs {
            // Re-render the figures and rebuild the LED composites only when the
            // read-out text or bar appearance changes (≤ 1 Hz); the fast timer then
            // just swaps a cached composite.
            let signature = "led|\(downText)|\(upText)|\(isDark ? "d" : "l")"
            if signature != shownSignature {
                let text = MenuBarReadoutImage.networkFigures(
                    down: downText, up: upText,
                    color: MenuBarReadoutImage.figureColor(isDark: isDark), widthSample: "999M")
                rebuildVariants(text: text)
                button.toolTip = tooltip
                shownSignature = signature
            }
            currentDownRate = rates.inBytesPerSec
            currentUpRate = rates.outBytesPerSec
            updateFlicker()
        } else {
            stopFlicker()
            let signature = "arrow|\(downText)|\(upText)|\(isDark ? "d" : "l")"
            guard signature != shownSignature else { return }
            button.image = NetworkMenuBarImage.image(
                downText: downText, upText: upText, isDark: isDark)
            button.toolTip = tooltip
            shownSignature = signature
        }
    }

    // MARK: - Activity LEDs

    /// Pre-render the 2×2 [downOn][upOn] composites for the current read-out. Done
    /// only when the read-out text or bar appearance changes (≤ 1 Hz), so the fast
    /// flicker timer never draws — it just swaps one of these cached images.
    private func rebuildVariants(text: NSImage) {
        ledVariants = [
            [compose(text, false, false), compose(text, false, true)],
            [compose(text, true, false), compose(text, true, true)],
        ]
    }

    private func compose(_ text: NSImage, _ downOn: Bool, _ upOn: Bool) -> NSImage {
        let ledW: CGFloat = 9
        let size = NSSize(width: text.size.width + ledW, height: max(text.size.height, 12))
        let img = NSImage(size: size)
        img.lockFocus()
        text.draw(
            at: NSPoint(x: ledW, y: (size.height - text.size.height) / 2), from: .zero,
            operation: .sourceOver, fraction: 1)
        let r: CGFloat = 3.0
        let cx = ledW / 2
        func dot(_ cy: CGFloat, _ color: NSColor, _ on: Bool) {
            if on {  // soft glow under the lit core
                color.withAlphaComponent(0.30).setFill()
                NSBezierPath(
                    ovalIn: NSRect(
                        x: cx - r - 1.2, y: cy - r - 1.2, width: 2 * (r + 1.2),
                        height: 2 * (r + 1.2))
                ).fill()
            }
            (on ? color : color.withAlphaComponent(0.16)).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
        }
        dot(size.height * 0.70, .systemGreen, downOn)  // download — top
        dot(size.height * 0.30, .systemRed, upOn)  // upload — bottom
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private func setFrame(downOn: Bool, upOn: Bool) {
        guard let button = statusItem?.button, ledVariants.count == 2 else { return }
        button.image = ledVariants[downOn ? 1 : 0][upOn ? 1 : 0]
    }

    /// Run the fast flicker only while traffic flows; when both directions go idle,
    /// stop the timer and leave the LEDs unlit — so a quiet Mac costs nothing.
    private func updateFlicker() {
        let active = currentDownRate > activeThreshold || currentUpRate > activeThreshold
        if active {
            if flickerTimer == nil {
                let timer = Timer(timeInterval: 1.0 / flickerHz, repeats: true) { [weak self] _ in
                    // Added to RunLoop.main, so this fires on the main thread.
                    MainActor.assumeIsolated { self?.tickFlicker() }
                }
                RunLoop.main.add(timer, forMode: .common)
                flickerTimer = timer
            }
        } else {
            stopFlicker()
            setFrame(downOn: false, upOn: false)
        }
    }

    private func tickFlicker() {
        let downOn =
            currentDownRate > activeThreshold
            && Double.random(in: 0..<1) < intensity(currentDownRate)
        let upOn =
            currentUpRate > activeThreshold
            && Double.random(in: 0..<1) < intensity(currentUpRate)
        setFrame(downOn: downOn, upOn: upOn)
    }

    private func stopFlicker() {
        flickerTimer?.invalidate()
        flickerTimer = nil
    }

    /// Map a byte rate to a flicker density (≈0.35 just-active … 0.9 busy) on a log
    /// scale — a denser, livelier blink the more data moves, like a real HDD light.
    private func intensity(_ rate: Double) -> Double {
        let lo = activeThreshold, hi = 4_000_000.0
        let t = (log10(max(rate, lo)) - log10(lo)) / (log10(hi) - log10(lo))
        return min(0.9, 0.35 + 0.55 * max(0, min(1, t)))
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
        let content = NetworkMenuBarContentView(dismiss: { [weak self] in
            self?.popover?.performClose(nil)
        })
        .environmentObject(model)
        .environmentObject(model.menuLists)
        .environmentObject(appState)
        .environmentObject(updateController)
        .environmentObject(menuClock)
        let hosting = PopoverHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        return popover
    }
}

extension NetworkStatusItemController: NSPopoverDelegate {
    // Refcount the menu clock so the dropdown refreshes at 1 Hz only while shown.
    // The menu clock's open/close is driven by the content view's onAppear/
    // onDisappear — these status-item popover delegate callbacks do not fire
    // reliably, which is what froze the dropdown at the global refresh rate.
    func popoverDidShow(_ notification: Notification) {}
    func popoverDidClose(_ notification: Notification) {}
}
