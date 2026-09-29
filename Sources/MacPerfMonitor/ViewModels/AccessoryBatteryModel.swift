import AppKit
import Combine
import MacPerfMonitorCore

@MainActor
final class AccessoryBatteryModel: ObservableObject {
    enum Status {
        case loading, ready, unavailable
    }

    static let shared = AccessoryBatteryModel(defaults: .standard)
    static let minimumInterval: TimeInterval = 60
    private static let alertStateKey = "accessoryBatteryAlertState"

    @Published private(set) var devices: [AccessoryBattery] = []
    @Published private(set) var status: Status = .loading
    @Published private(set) var checkedAt: Date?

    private static let queue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.accessory-batteries", qos: .utility)

    private let reader: any AccessoryBatteryReading
    private let uptime: () -> TimeInterval
    private let date: () -> Date
    private let defaults: UserDefaults?
    private var alertTracker: AccessoryBatteryAlertTracker
    private var savedAlertState: Data?
    private var panelVisible = false
    private var alertsEnabled = false
    private var alertThreshold = 20
    private var alertRevision: UInt64 = 0
    private var lastAttempt: TimeInterval?
    private var active = false
    private var readInFlight = false
    private var timer: AnyCancellable?
    private var wakeObservation: AnyCancellable?

    var onLowBatteryAlert: (AccessoryBatteryAlert, @escaping @Sendable (Bool) -> Void) -> Void = {
        _, completion in completion(false)
    }

    init(
        reader: any AccessoryBatteryReading = AccessoryBatteryReader(),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        date: @escaping () -> Date = { Date() }, defaults: UserDefaults? = nil
    ) {
        self.reader = reader
        self.uptime = uptime
        self.date = date
        self.defaults = defaults
        savedAlertState = defaults?.data(forKey: Self.alertStateKey)
        alertTracker = AccessoryBatteryAlertTracker(storedState: savedAlertState)
    }

    func start() {
        panelVisible = true
        updatePolling()
    }

    func stop() {
        panelVisible = false
        updatePolling()
    }

    func configureAlerts(_ config: AlertConfig) {
        let threshold = min(50, max(5, config.accessoryBatteryThresholdPercent))
        if config.accessoryBatteryEnabled != alertsEnabled || threshold != alertThreshold {
            alertRevision &+= 1
            alertTracker.resetConfirmation()
        }
        alertsEnabled = config.accessoryBatteryEnabled
        alertThreshold = threshold
        updatePolling()
    }

    private func updatePolling() {
        guard panelVisible || alertsEnabled else {
            active = false
            timer = nil
            wakeObservation = nil
            return
        }
        guard !active else { return }
        active = true
        refresh()
        timer = Timer.publish(every: Self.minimumInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
        wakeObservation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard active, !readInFlight else { return }
        let now = uptime()
        guard now.isFinite,
            lastAttempt.map({ now - $0 >= Self.minimumInterval }) ?? true
        else { return }
        lastAttempt = now
        readInFlight = true
        let revision = alertRevision
        Self.queue.async { [reader] in
            let result = reader.read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readInFlight = false
                if self.alertsEnabled, revision == self.alertRevision {
                    self.evaluateAlerts(result)
                }
                if let result {
                    self.devices = result
                    self.checkedAt = self.date()
                    self.status = .ready
                } else {
                    self.status = .unavailable
                }
            }
        }
    }

    private func evaluateAlerts(_ devices: [AccessoryBattery]?) {
        let alerts = alertTracker.evaluate(devices, thresholdPercent: alertThreshold, now: date())
        saveAlertState()
        for alert in alerts {
            onLowBatteryAlert(alert) { [weak self] scheduled in
                guard !scheduled else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.alertTracker.notificationFailed(alert)
                    self.saveAlertState()
                }
            }
        }
    }

    private func saveAlertState() {
        guard let state = alertTracker.storedState, state != savedAlertState else { return }
        defaults?.set(state, forKey: Self.alertStateKey)
        savedAlertState = state
    }
}
