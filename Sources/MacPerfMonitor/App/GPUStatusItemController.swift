import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

/// Owns the GPU menubar item as an AppKit `NSStatusItem` with a SwiftUI panel in
/// an `NSPopover`, mirroring `CPUStatusItemController`. The button shows a
/// "GPU NN%" read-out; the dropdown is `GPUMenuBarContentView`.
///
/// User-toggleable, like the CPU/energy/network items. Crucially the GPU is only
/// sampled while this item is shown: install/remove flip `setGPUSamplingEnabled`,
/// so a Mac with the GPU item off never walks the IOAccelerator registry and pays
/// no extra CPU.
@MainActor
final class GPUStatusItemController: NSObject {
    private let model: SamplerModel
    private let appState: AppState
    private let updateController: UpdateController

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    /// Drives the dropdown's refresh at the dial rate, but only while it is
    /// open. The dropdown ranks the top GPU processes, so while it shows it
    /// registers for the per-process scan (at the popover cadence, whatever the
    /// table cadence) and as a live GPU surface, which reads the device every
    /// tick rather than once a second.
    private lazy var menuClock = MenuClock(
        source: model.liveTick.eraseToAnyPublisher(),
        onOpen: { [model] in model.requestImmediateTick() },
        onActiveChange: { [model] active in
            if active {
                model.addPopoverProcessConsumer(.gpu)
                model.addGPUConsumer()
            } else {
                model.removePopoverProcessConsumer(.gpu)
                model.removeGPUConsumer()
            }
        })

    /// What the button currently shows, so an unchanged tick is a no-op.
    private var shownSignature: String?

    /// UserDefaults key shared with the Settings toggle (`@AppStorage`).
    static let visibilityDefaultsKey = "showGPUMenuBar"

    init(
        model: SamplerModel, appState: AppState,
        updateController: UpdateController
    ) {
        self.model = model
        self.appState = appState
        self.updateController = updateController
        super.init()
    }

    func start() {
        model.menuBarTick
            .sink { [weak self] _ in self?.refreshImage() }
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
            model.setGPUSamplingEnabled(true)
        } else {
            removeItem()
            model.setGPUSamplingEnabled(false)
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
    func tearDownForQuit() {
        removeItem()
        model.setGPUSamplingEnabled(false)
    }

    // MARK: - Button image

    private func refreshImage() {
        guard let button = statusItem?.button else { return }

        // Use the smoothed utilization so the figure settles rather than jumping.
        let util = model.smoothedGPUUtilization
        let percent = util.map { Int($0.rounded()) }
        let level = CPULevel(fraction: (util ?? 0) / 100)
        let isDark = button.effectiveAppearance.isDarkMenuBar
        let signature = "\(percent.map(String.init) ?? "–")-\(level.rawValue)-\(isDark ? "d" : "l")"
        guard signature != shownSignature else { return }
        button.image = GPUMenuBarImage.image(percent: percent, level: level, isDark: isDark)
        button.toolTip = percent.map { "GPU \($0)%" } ?? "GPU"
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
        let content = GPUMenuBarContentView(dismiss: { [weak self] in
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

extension GPUStatusItemController: NSPopoverDelegate {
    // The menu clock's open/close is driven by the content view's onAppear/
    // onDisappear; these delegate callbacks do not fire reliably for a status-item
    // popover, which is what froze the other dropdowns at the global refresh rate.
    func popoverDidShow(_ notification: Notification) {}
    func popoverDidClose(_ notification: Notification) {}
}
