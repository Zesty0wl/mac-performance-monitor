import Foundation

/// Parent and child relationships within one snapshot of the process list.
public enum ProcessTree {
    /// Every process below `root` in `processes`, nearest generation first:
    /// children, then grandchildren, and so on. `root` itself is not included.
    ///
    /// The order is the one a "force quit the tree" action wants. Stopping a
    /// parent before its children means a supervisor is gone before it can
    /// notice a missing worker and start a replacement.
    ///
    /// A child is only counted when it started no earlier than its parent.
    /// Process IDs are reused, so an old process can carry a `ppid` that now
    /// belongs to a newer, unrelated process; the start times tell them apart.
    public static func descendants(
        of root: ProcessIdentity, in processes: [ProcessSample]
    ) -> [ProcessSample] {
        var childrenByParent: [Int32: [ProcessSample]] = [:]
        for process in processes where process.pid != process.ppid {
            childrenByParent[process.ppid, default: []].append(process)
        }
        var result: [ProcessSample] = []
        var seen: Set<Int32> = [root.pid]
        var generation: [(pid: Int32, startTime: Date)] = [(root.pid, root.startTime)]
        while !generation.isEmpty {
            var next: [(pid: Int32, startTime: Date)] = []
            for parent in generation {
                let children = (childrenByParent[parent.pid] ?? []).sorted { $0.pid < $1.pid }
                for child in children
                where child.startTime >= parent.startTime && seen.insert(child.pid).inserted {
                    result.append(child)
                    next.append((child.pid, child.startTime))
                }
            }
            generation = next
        }
        return result
    }
}
