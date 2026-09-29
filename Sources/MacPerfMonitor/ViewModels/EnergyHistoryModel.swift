import Combine
import Foundation
import MacPerfMonitorCore

@MainActor
final class EnergyHistoryModel: ObservableObject {
    @Published private(set) var history: [BatteryHistoryPoint] = []
    @Published private(set) var daily: [BatteryDailyPoint] = []
    @Published private(set) var historyUnavailable = false
    @Published private(set) var dailyUnavailable = false

    private var range: HistoryWindow = .oneHour
    private var batteryID: String?
    private var lastLoad: Date?
    private var lastDailyLoad: Date?
    private var generation = 0

    init(history: [BatteryHistoryPoint] = [], daily: [BatteryDailyPoint] = []) {
        self.history = history
        self.daily = daily
        batteryID = history.last?.batteryID
    }

    func reload(
        _ model: SamplerModel, range requested: HistoryWindow, battery: BatterySample?,
        now: Date = Date()
    ) {
        selectBattery(battery)
        let changed = range != requested
        if changed { history = [] }
        range = requested
        if changed || lastLoad == nil || now.timeIntervalSince(lastLoad ?? now) >= 30 {
            generation += 1
            let request = generation
            lastLoad = now
            model.loadBatteryHistory(requested, now: now) { [weak self, weak model] result in
                guard let self, request == self.generation else { return }
                switch result {
                case .success(let points):
                    let last = points.last?.date ?? .distantPast
                    let liveTail = self.history.filter { $0.date > last }
                    self.history = points + liveTail
                    self.historyUnavailable = false
                    self.append(model?.latestBattery, range: requested)
                case .failure:
                    self.historyUnavailable = true
                }
            }
        }
        if let identifier = batteryID,
            lastDailyLoad == nil || now.timeIntervalSince(lastDailyLoad ?? now) >= 60
        {
            lastDailyLoad = now
            model.loadBatteryDailyHistory(for: identifier) { [weak self] result in
                guard let self, self.batteryID == identifier else { return }
                switch result {
                case .success(let points):
                    self.daily = points
                    self.dailyUnavailable = false
                case .failure:
                    self.dailyUnavailable = true
                }
            }
        }
        append(battery, range: requested)
    }

    func append(_ battery: BatterySample?, range: HistoryWindow) {
        guard let battery, battery.timestamp.timeIntervalSince1970.isFinite else { return }
        selectBattery(battery)
        guard history.last.map({ $0.date < battery.timestamp }) ?? true else { return }
        history.append(BatteryHistoryPoint(sample: battery))
        let cutoff = battery.timestamp.addingTimeInterval(-range.seconds)
        history.removeAll { $0.date.addingTimeInterval($0.duration) < cutoff }
        if history.count > 14_400 { history.removeFirst(history.count - 14_400) }
    }

    private func selectBattery(_ battery: BatterySample?) {
        guard let battery else { return }
        let identifier = BatteryIdentity.identifier(for: battery.serialNumber)
        guard batteryID != identifier else { return }
        batteryID = identifier
        history = []
        daily = []
        lastLoad = nil
        lastDailyLoad = nil
        historyUnavailable = false
        dailyUnavailable = false
        generation += 1
    }
}
