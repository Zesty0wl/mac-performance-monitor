import Foundation

/// Tells which processes have exited between two successive process lists.
///
/// A process is reported once, on the first list it is missing from, with the
/// last sample taken of it. Lists more than `maximumGap` apart are not
/// compared: after the table was closed or sampling paused, "missing" says
/// nothing about when a process went.
///
/// Children of `ignoredParent` are never reported. The app passes its own pid:
/// it runs short-lived tools (nettop every few seconds, among others) whose
/// exits are routine, not something to show.
public struct ProcessExitTracker: Sendable {
    public var maximumGap: TimeInterval
    public var ignoredParent: Int32?

    private var previous: [ProcessSample] = []
    private var previousAt: Date?

    public init(maximumGap: TimeInterval = 10, ignoringChildrenOf ignoredParent: Int32? = nil) {
        self.maximumGap = maximumGap
        self.ignoredParent = ignoredParent
    }

    /// Record `live` as the current list and return the processes that were in
    /// the previous one and are gone from this one.
    public mutating func exits(in live: [ProcessSample], now: Date) -> [ProcessSample] {
        defer {
            previous = live
            previousAt = now
        }
        guard let previousAt, !previous.isEmpty else { return [] }
        let gap = now.timeIntervalSince(previousAt)
        guard gap >= 0, gap <= maximumGap else { return [] }
        let liveIDs = Set(live.map(\.id))
        return previous.filter { !liveIDs.contains($0.id) && $0.ppid != ignoredParent }
    }

    /// Forget the previous list, so the next one starts a new comparison.
    public mutating func reset() {
        previous = []
        previousAt = nil
    }
}
