import AppKit
import Combine
import SwiftUI

@MainActor
final class CombinedStatusItemController: NSObject {
    private static let panelDefaultsKey = "combinedMenuBarPanel"

    private let model: SamplerModel
    private let appState: AppState
    private let helperManager: HelperManager
    private let updateController: UpdateController
    private let appModeManager: AppModeManager
    private let configuration: CombinedMenuBarConfiguration

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var router: NSHostingView<MenuBarWindowRouter>?
    private var cancellables = Set<AnyCancellable>()
    private var shownSignature: String?
    private var activeConsumer: MenuListKind?
    private var gpuSamplingActive = false
    private var currentPanel: MenuBarMetric
    private lazy var panelSelection = CombinedMenuBarPanelSelection(metric: currentPanel)

    private lazy var menuClock = MenuClock(
        source: model.liveTick.eraseToAnyPublisher(),
        onOpen: { [model] in model.requestImmediateTick() },
        onActiveChange: { [weak self] active in self?.popoverActivityChanged(active) })

    init(
        model: SamplerModel, appState: AppState, helperManager: HelperManager,
        updateController: UpdateController, appModeManager: AppModeManager,
        configuration: CombinedMenuBarConfiguration
    ) {
        self.model = model
        self.appState = appState
        self.helperManager = helperManager
        self.updateController = updateController
        self.appModeManager = appModeManager
        self.configuration = configuration
        currentPanel =
            UserDefaults.standard.string(forKey: Self.panelDefaultsKey)
            .flatMap(MenuBarMetric.init(rawValue:)) ?? configuration.focusedMetric
        super.init()
    }

    func start() {
        model.liveTick
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshImage()
                self?.reconcileMenuClock()
            }
            .store(in: &cancellables)
        model.$activeAlertKinds
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshImage() }
            .store(in: &cancellables)
        configuration.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.configurationChanged()
                }
            }
            .store(in: &cancellables)
        installItem()
        reconcileGPUSampling()
    }

    private func installItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageOnly
        if let button = item.button {
            let host = NSHostingView(rootView: MenuBarWindowRouter())
            host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            button.addSubview(host)
            router = host
        }
        statusItem = item
        refreshImage()
    }

    func tearDownForQuit() {
        menuClock.close()
        popover?.performClose(nil)
        popover = nil
        router?.removeFromSuperview()
        router = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        model.setGPUSamplingEnabled(false)
        gpuSamplingActive = false
    }

    private func configurationChanged() {
        if !configuration.selectedMetrics.contains(configuration.focusedMetric) {
            configuration.focusedMetric = configuration.selectedMetrics[0]
        }
        shownSignature = nil
        refreshImage()
        reconcileGPUSampling()
    }

    private func refreshImage() {
        guard let button = statusItem?.button else { return }
        let metrics =
            configuration.presentation == .focus
            ? [configuration.focusedMetric] : configuration.selectedMetrics
        let readouts = CombinedMenuBarReadouts.current(for: metrics, model: model)
        let alarmCount = model.activeAlertKinds.count
        let isDark = button.effectiveAppearance.isDarkMenuBar
        let signature =
            "\(configuration.presentation.rawValue)|\(isDark)|\(alarmCount)|"
            + readouts.map {
                "\($0.metric.rawValue):\($0.value):\($0.secondaryValue ?? ""):\($0.isAlarm)"
            }.joined(separator: "|")
        guard signature != shownSignature else { return }
        button.image = CombinedMenuBarImage.image(
            readouts: readouts, presentation: configuration.presentation,
            alarmCount: alarmCount, isDark: isDark)
        let summary = readouts.map {
            [$0.metric.title, $0.value, $0.secondaryValue].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: ", ")
        let alarmSuffix =
            alarmCount > 0 ? ", \(alarmCount) active alarm\(alarmCount == 1 ? "" : "s")" : ""
        button.toolTip = summary + alarmSuffix
        button.setAccessibilityLabel("\(AppInfo.displayName), \(summary)\(alarmSuffix)")
        shownSignature = signature
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let metric = clickedMetric(in: button)
        if let popover, popover.isShown {
            if let metric, metric != currentPanel {
                panelSelection.metric = metric
                selectPanel(metric)
                popover.contentViewController?.view.window?.makeKey()
                return
            }
            popover.performClose(sender)
            return
        }
        if let metric {
            panelSelection.metric = metric
            selectPanel(metric)
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
        let content = CombinedMenuBarContentView(
            selection: panelSelection,
            selectionChanged: { [weak self] metric in self?.selectPanel(metric) },
            dismiss: { [weak popover] in popover?.performClose(nil) }
        )
        .environmentObject(model)
        .environmentObject(model.menuLists)
        .environmentObject(appState)
        .environmentObject(helperManager)
        .environmentObject(updateController)
        .environmentObject(menuClock)
        .environmentObject(appModeManager)
        .environmentObject(configuration)
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        return popover
    }

    private func clickedMetric(in button: NSStatusBarButton) -> MenuBarMetric? {
        let metrics =
            configuration.presentation == .focus
            ? [configuration.focusedMetric] : configuration.selectedMetrics
        guard !metrics.isEmpty else { return nil }
        let local: NSPoint
        if let event = NSApp.currentEvent,
            (event.type == .leftMouseDown || event.type == .leftMouseUp),
            event.window === button.window
        {
            local = button.convert(event.locationInWindow, from: nil)
        } else if let window = button.window {
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            local = button.convert(windowPoint, from: nil)
        } else {
            return configuration.presentation == .focus ? metrics[0] : nil
        }

        let imageRect =
            (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds)
            ?? NSRect(
                x: (button.bounds.width - (button.image?.size.width ?? 0)) / 2,
                y: 0, width: button.image?.size.width ?? button.bounds.width,
                height: button.bounds.height)
        let imageX = min(max(local.x - imageRect.minX, 0), imageRect.width)
        let readouts = CombinedMenuBarReadouts.current(for: metrics, model: model)
        return CombinedMenuBarImage.metric(
            at: imageX, readouts: readouts, presentation: configuration.presentation,
            alarmCount: model.activeAlertKinds.count,
            isDark: button.effectiveAppearance.isDarkMenuBar)
    }

    private func selectPanel(_ metric: MenuBarMetric) {
        guard metric != currentPanel else {
            reconcileGPUSampling()
            return
        }
        currentPanel = metric
        UserDefaults.standard.set(metric.rawValue, forKey: Self.panelDefaultsKey)
        if popover?.isShown == true {
            replaceActiveConsumer(with: consumerKind(for: metric))
            model.requestImmediateTick()
        }
        reconcileGPUSampling()
    }

    private func popoverActivityChanged(_ active: Bool) {
        if active {
            replaceActiveConsumer(with: consumerKind(for: currentPanel))
        } else {
            replaceActiveConsumer(with: nil)
        }
        reconcileGPUSampling()
    }

    private func replaceActiveConsumer(with kind: MenuListKind?) {
        if let activeConsumer { model.removePopoverProcessConsumer(activeConsumer) }
        activeConsumer = kind
        if let kind { model.addPopoverProcessConsumer(kind) }
    }

    private func consumerKind(for metric: MenuBarMetric) -> MenuListKind? {
        switch metric {
        case .pressure: return .footprint
        case .cpu: return .cpu
        case .energy: return .energy
        case .network: return .network
        case .gpu: return nil
        }
    }

    private func reconcileGPUSampling() {
        let shouldSample =
            configuration.selectedMetrics.contains(.gpu)
            || (popover?.isShown == true && currentPanel == .gpu)
        guard shouldSample != gpuSamplingActive else { return }
        gpuSamplingActive = shouldSample
        model.setGPUSamplingEnabled(shouldSample)
    }

    private func reconcileMenuClock() {
        guard let popover else { return }
        if popover.isShown { menuClock.open() } else { menuClock.close() }
        reconcileGPUSampling()
    }
}
