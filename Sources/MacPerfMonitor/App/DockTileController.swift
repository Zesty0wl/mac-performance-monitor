// SPDX-License-Identifier: MIT
import AppKit
import Combine
import MacPerfMonitorCore

/// Keeps the Dock icon showing the chosen metric's trend.
///
/// It redraws only when the picture can change: when a time slot of the chosen
/// range completes (see `DockTileBuckets`), and when the metric, the range or
/// the app's Dock presence changes. A sample arriving inside a slot does not
/// redraw, so a fifteen-minute trend costs the Dock one redraw every few
/// seconds rather than one a second.
@MainActor
final class DockTileController: NSObject {
    private let model: SamplerModel
    private let defaults: UserDefaults
    private let bitmap = ChartBitmap()
    private let imageView = NSImageView()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    private struct Drawn: Equatable {
        var metric: DockTileMetric
        var range: DockTileRange
        var text: DockTileText
        var size: DockTileSize
        var slot: Int
    }

    private var drawn: Drawn?
    private var configured: (metric: DockTileMetric, range: DockTileRange)?
    private var reportedVisible: Bool?
    /// Whether this controller holds one of the sampler's GPU consumers. GPU
    /// figures are only read while something shows them.
    private var holdsGPUConsumer = false

    init(model: SamplerModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        super.init()
        imageView.imageScaling = .scaleProportionallyUpOrDown
    }

    func start() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        update()
    }

    /// The activation policy changed: the Dock icon appeared or went away.
    /// LaunchServices learns of the change a moment after AppKit does, and a
    /// tile drawn before the Dock has caught up can be dropped, so draw again
    /// once it has (the same half second `PresenceController` waits to verify).
    func presenceChanged() {
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.drawn = nil
            self?.update()
        }
    }

    private var isInDock: Bool {
        NSApp.activationPolicy() == .regular
    }

    /// How long after a slot ends before it is drawn, so the sample that
    /// closes it has landed in the history. Every redraw reads the time
    /// through this lag, so a redraw for any reason just after a boundary
    /// still waits for that sample rather than drawing the slot short.
    static let settle: TimeInterval = 0.2

    private var clock: Date { Date().addingTimeInterval(-Self.settle) }

    private func update() {
        // Any change to the Dock mode, from Settings, onboarding or the
        // Keep in Dock button, also updates the old switch older versions read.
        DockPresenceMode.mirror(defaults)
        let metric = DockTileMetric.current(defaults)
        let range = DockTileRange.current(defaults)
        let visible = metric.showsTrend && isInDock
        if visible != reportedVisible {
            reportedVisible = visible
            // The sampler skips its per-tick publish when nothing is watching.
            // A Dock trend is watching, or its line would have holes in it.
            model.setDockTileVisible(visible)
        }
        let wantsGPU = visible && metric == .gpu
        if wantsGPU != holdsGPUConsumer {
            holdsGPUConsumer = wantsGPU
            if wantsGPU { model.addGPUConsumer() } else { model.removeGPUConsumer() }
        }

        if !metric.showsTrend, drawn != nil || NSApp.dockTile.contentView != nil {
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.display()
        }
        // Off the Dock, or on the app icon, there is nothing to keep drawing:
        // stop the timer so the main thread is not woken every slot for
        // nothing. Coming back to the Dock calls `presenceChanged`.
        guard visible else {
            timer?.invalidate()
            timer = nil
            configured = nil
            drawn = nil
            return
        }
        if configured?.metric != metric || configured?.range != range {
            configured = (metric, range)
            scheduleTimer(range: range)
        }
        redrawIfNeeded(metric: metric, range: range)
    }

    /// Fire when the current slot has ended and settled, then after each one.
    private func scheduleTimer(range: DockTileRange) {
        timer?.invalidate()
        let fire = DockTileBuckets.nextBoundary(after: clock, range: range)
            .addingTimeInterval(Self.settle)
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let configured = self.configured else { return }
                self.redrawIfNeeded(metric: configured.metric, range: configured.range)
                self.scheduleTimer(range: configured.range)
            }
        }
        timer.tolerance = DockTileBuckets.width(for: range) * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func redrawIfNeeded(metric: DockTileMetric, range: DockTileRange) {
        guard isInDock else {
            drawn = nil
            return
        }
        let now = clock
        let slot = DockTileBuckets.index(of: now, width: DockTileBuckets.width(for: range))
        let text = DockTileText.current(defaults)
        let size = DockTileSize.current(defaults)
        let next = Drawn(metric: metric, range: range, text: text, size: size, slot: slot)
        guard next != drawn else { return }
        guard
            let content = DockTileContent.make(
                metric: metric,
                samples: DockTileContent.recent(
                    model.systemHistory.elements(), now: now, range: range),
                now: now, range: range, text: text),
            let image = DockTileRenderer.image(content, size: size, bitmap: bitmap)
        else { return }
        drawn = next
        imageView.image = image
        if NSApp.dockTile.contentView !== imageView {
            NSApp.dockTile.contentView = imageView
        }
        NSApp.dockTile.display()
    }

    // MARK: - Dock menu

    /// The "Dock Icon" submenu for the Dock's context menu: the same choices
    /// as Settings, so the icon can be switched where it is seen.
    func dockMenuItem() -> NSMenuItem {
        let metric = DockTileMetric.current(defaults)
        let range = DockTileRange.current(defaults)
        let submenu = NSMenu()
        for option in DockTileMetric.allCases {
            let item = NSMenuItem(
                title: option.title, action: #selector(chooseMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == metric ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        for option in DockTileRange.allCases {
            let item = NSMenuItem(
                title: option.title, action: #selector(chooseRange(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == range ? .on : .off
            item.isEnabled = metric.showsTrend
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let size = DockTileSize.current(defaults)
        for option in DockTileSize.allCases {
            let item = NSMenuItem(
                title: option.title, action: #selector(chooseSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == size ? .on : .off
            item.isEnabled = metric.showsTrend
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let text = DockTileText.current(defaults)
        for (title, key, isOn) in [
            (t("Show Label"), DockTileText.labelKey, text.label),
            (t("Show Value"), DockTileText.valueKey, text.value),
        ] {
            let item = NSMenuItem(
                title: title, action: #selector(toggleText(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = isOn ? .on : .off
            item.isEnabled = metric.showsTrend
            submenu.addItem(item)
        }
        // Ranges and the text switches do nothing on the app icon.
        submenu.autoenablesItems = false

        let item = NSMenuItem(title: t("Dock Icon"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func chooseMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: DockTileMetric.defaultsKey)
    }

    @objc private func chooseRange(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        defaults.set(minutes, forKey: DockTileRange.defaultsKey)
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: DockTileSize.defaultsKey)
    }

    @objc private func toggleText(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(sender.state != .on, forKey: key)
    }
}
