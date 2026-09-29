import Darwin
import Foundation
import MacPerfMonitorCore

struct UsageTimelineTarget: Codable, Hashable, Identifiable {
    var pid: Int32
    var startTime: Date
    var name: String
    var bundleID: String?
    var uid: UInt32

    var id: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }
}

extension UsageTimelineTarget {
    init(sample: ProcessSample) {
        self.init(
            pid: sample.pid, startTime: sample.startTime, name: sample.displayName,
            bundleID: sample.bundleID, uid: UInt32(sample.uid))
    }
}

@MainActor
final class UsageTimelineModel: ObservableObject {
    static let windowDefaultsKey = "historyRange.usageTimeline"

    typealias HistoryLoader = (
        ProcessIdentity, HistoryWindow, Date,
        @escaping (Result<UsageTimeline.ObservedHistory, Error>) -> Void
    ) -> Void
    typealias ActivityLoader = (
        String, ClosedRange<Date>,
        @escaping (Result<[UsageTimeline.Interval], KnowledgeActivityReader.ReadError>) -> Void
    ) -> Void

    let target: UsageTimelineTarget
    @Published private(set) var window: HistoryWindow
    @Published private(set) var endDate: Date
    @Published private(set) var history: UsageTimeline.ObservedHistory?
    @Published private(set) var activity: [UsageTimeline.Interval] = []
    @Published private(set) var includesAppleActivity = false
    @Published private(set) var loadingHistory = false
    @Published private(set) var loadingActivity = false
    @Published private(set) var historyUnavailable = false
    @Published private(set) var activityError: KnowledgeActivityReader.ReadError?

    private let loadHistory: HistoryLoader
    private let loadActivity: ActivityLoader
    private let preferences: UserDefaults?
    private var generation = 0
    private static let activityQueue = DispatchQueue(
        label: "MacPerfMonitor.usageTimeline.activity", qos: .utility)

    init(
        target: UsageTimelineTarget, now: Date = Date(),
        preferences: UserDefaults? = nil,
        loadHistory: @escaping HistoryLoader, loadActivity: ActivityLoader? = nil
    ) {
        self.target = target
        self.endDate = now
        self.preferences = preferences
        let saved = preferences?.string(forKey: Self.windowDefaultsKey)
        self.window = saved.flatMap(HistoryWindow.init(rawValue:)) ?? .thirtyMinutes
        self.loadHistory = loadHistory
        self.loadActivity = loadActivity ?? Self.readActivity
    }

    var range: ClosedRange<Date> { endDate.addingTimeInterval(-window.seconds)...endDate }
    var intervals: [UsageTimeline.Interval] { (history?.intervals ?? []) + activity }
    var isLoading: Bool { loadingHistory || loadingActivity }
    var canReadAppleActivity: Bool {
        target.uid == UInt32(getuid())
            && !(target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func load(window: HistoryWindow? = nil, endingAt: Date? = nil) {
        if let window {
            self.window = window
            preferences?.set(window.rawValue, forKey: Self.windowDefaultsKey)
        }
        if let endingAt { self.endDate = min(endingAt, Date()) }
        generation &+= 1
        let request = generation
        history = nil
        activity = []
        historyUnavailable = false
        activityError = nil
        loadingHistory = true
        loadingActivity = includesAppleActivity && canReadAppleActivity
        loadHistory(target.id, self.window, endDate) { [weak self] result in
            guard let self, request == self.generation else { return }
            self.loadingHistory = false
            switch result {
            case .success(let history): self.history = history
            case .failure: self.historyUnavailable = true
            }
        }
        if loadingActivity, let bundleID = target.bundleID {
            loadActivity(bundleID, range) { [weak self] result in
                guard let self, request == self.generation else { return }
                self.loadingActivity = false
                switch result {
                case .success(let activity): self.activity = activity
                case .failure(let error): self.activityError = error
                }
            }
        }
    }

    func includeAppleActivity(_ included: Bool) {
        guard !included || canReadAppleActivity else { return }
        includesAppleActivity = included
        load()
    }

    func close() {
        generation &+= 1
        activity = []
        includesAppleActivity = false
        loadingHistory = false
        loadingActivity = false
        activityError = nil
    }

    private static func readActivity(
        bundleID: String, range: ClosedRange<Date>,
        completion:
            @escaping (Result<[UsageTimeline.Interval], KnowledgeActivityReader.ReadError>)
            -> Void
    ) {
        activityQueue.async {
            let result: Result<[UsageTimeline.Interval], KnowledgeActivityReader.ReadError>
            do {
                result = .success(
                    try KnowledgeActivityReader.read(bundleID: bundleID, within: range))
            } catch {
                result = .failure(error as? KnowledgeActivityReader.ReadError ?? .unavailable)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
