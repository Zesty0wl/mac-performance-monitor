import Combine
import Foundation
import MacPerfMonitorCore

/// The Disk tab's slow-moving data: mounted volumes with capacities, per-disk
/// hardware identity, and SMART health. All of it is view-pulled: the tab's
/// `TabGate` unmounts this model's owner when the tab is inactive, `stop()`
/// cancels the poll, and nothing here ever touches the 1 Hz sampler. Reads run
/// on a background queue; published state flips on the main actor.
@MainActor
final class DiskDetailModel: ObservableObject {
    @Published private(set) var volumeSnapshot: VolumeSnapshot?
    @Published private(set) var hardware: [UInt64: DiskHardwareInfo] = [:]
    @Published private(set) var smart: [UInt64: NVMeSMARTSnapshot] = [:]

    /// Volumes refresh every poll; hardware identity and SMART wear figures
    /// move on the scale of hours, so they refresh at most once a minute.
    private static let pollInterval: TimeInterval = 30
    private static let slowInterval: TimeInterval = 60

    /// The three readers boxed together so the poll can carry them into its
    /// background hop. Every access happens on `DiskDetailModel.queue`;
    /// `@unchecked Sendable` records that confinement contract (the readers
    /// keep per-device caches, so they are stateful but single-queue, like the
    /// sampler's readers on the sampling queue).
    private final class Readers: @unchecked Sendable {
        let volumes = VolumeReader()
        let info = DiskInfoReader()
        let smart = NVMeSMARTReader()
    }

    private let readers = Readers()
    private static let queue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.diskdetail", qos: .utility)

    private var timer: AnyCancellable?
    private var lastSlowRefresh: Date?
    private var refreshInFlight = false

    func start() {
        refresh()
        timer = Timer.publish(every: Self.pollInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer = nil
    }

    func refresh(now: Date = Date()) {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let refreshSlow =
            lastSlowRefresh.map { now.timeIntervalSince($0) >= Self.slowInterval } ?? true
        if refreshSlow { lastSlowRefresh = now }

        Task { [readers] in
            let result: (VolumeSnapshot, [UInt64: DiskHardwareInfo]?, [UInt64: NVMeSMARTSnapshot]?)
            result = await withCheckedContinuation { continuation in
                Self.queue.async {
                    let volumes = readers.volumes.read(now: now)
                    guard refreshSlow else {
                        continuation.resume(returning: (volumes, nil, nil))
                        return
                    }
                    let hardware = readers.info.read()
                    var smart: [UInt64: NVMeSMARTSnapshot] = [:]
                    for (id, info) in hardware where !info.smartCandidateIDs.isEmpty {
                        smart[id] = readers.smart.read(
                            candidateRegistryEntryIDs: info.smartCandidateIDs)
                    }
                    continuation.resume(returning: (volumes, hardware, smart))
                }
            }
            self.volumeSnapshot = result.0
            if let hardware = result.1 { self.hardware = hardware }
            if let smart = result.2 { self.smart = smart }
            self.refreshInFlight = false
        }
    }
}
