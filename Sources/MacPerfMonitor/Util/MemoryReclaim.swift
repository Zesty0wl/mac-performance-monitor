import Darwin
import Foundation

/// Called after the last live consumer has closed and its views have torn down.
@MainActor
enum MemoryReclaim {
    static func runNow() {
        ProcessIconProvider.shared.purge()
        DispatchQueue.global(qos: .utility).async {
            let released = malloc_zone_pressure_relief(nil, 0)
            AppLog.ui.notice("idle UI caches cleared; allocator released \(released) bytes")
        }
    }
}
