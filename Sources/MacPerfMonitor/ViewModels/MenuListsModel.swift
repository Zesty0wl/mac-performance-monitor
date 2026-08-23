import Foundation
import MacPerfMonitorCore

/// Which top-process list a surface consumes. Each menu-bar popover registers
/// the one kind it shows, so the 1 Hz refresh while it is open computes only
/// that list instead of all four.
enum MenuListKind: CaseIterable {
    case footprint
    case cpu
    case energy
    case network
    case disk
    case gpu
}

/// The top-process lists for the menu-bar popovers (and the Network tab's
/// top-apps card), split out of `SamplerModel` on purpose: while a popover is
/// open these refresh at 1 Hz, and as `@Published` properties of the main model
/// every one of those refreshes fired `SamplerModel.objectWillChange` — which
/// re-evaluated every mounted main-window view at 1 Hz, overriding the global
/// refresh dial whenever a popover and the window were open together. As their
/// own object, only the views that actually read a list observe it.
///
/// Written from the main thread by `SamplerModel.refreshMenuLists`; read by
/// SwiftUI. Views receive it via `.environmentObject(model.menuLists)`.
final class MenuListsModel: ObservableObject {
    /// Top processes by memory footprint, for the pressure item's dropdown.
    @Published private(set) var topFootprint: [ProcessSample] = []
    /// Top processes by ~5 s smoothed CPU, for the CPU dropdown.
    @Published private(set) var topCPU: [ProcessSample] = []
    /// Top processes by current energy impact, for the battery dropdown.
    @Published private(set) var topEnergy: [ProcessSample] = []
    /// Top processes by network throughput, for the network dropdown and the
    /// Network tab. Empty unless per-app network tracking is enabled.
    @Published private(set) var topNetwork: [ProcessSample] = []
    /// Top processes by kernel-attributed read + write throughput.
    @Published private(set) var topDisk: [ProcessSample] = []
    @Published private(set) var topGPU: [ProcessSample] = []
    /// Whether a scan has ranked the GPU list since it was last cleared. An
    /// empty list after a scan means nothing is drawing (every app that ever
    /// touched Metal keeps a context, so the list holds only active users),
    /// not that nothing has been sampled yet.
    @Published private(set) var gpuListScanned = false

    func update(_ kind: MenuListKind, with rows: [ProcessSample]) {
        // Skip no-op publishes: an unchanged list (e.g. the always-empty
        // network list while per-app tracking is off) would still fire
        // `objectWillChange` and re-render every observer.
        switch kind {
        case .footprint: if rows != topFootprint { topFootprint = rows }
        case .cpu: if rows != topCPU { topCPU = rows }
        case .energy: if rows != topEnergy { topEnergy = rows }
        case .network: if rows != topNetwork { topNetwork = rows }
        case .disk: if rows != topDisk { topDisk = rows }
        case .gpu:
            if rows != topGPU { topGPU = rows }
            if !gpuListScanned { gpuListScanned = true }
        }
    }

    /// Drop a list too old to trust (a popover reopened after a long gap) so
    /// its panel shows "Sampling" until the next scan lands.
    func clear(_ kind: MenuListKind) {
        update(kind, with: [])
        if kind == .gpu, gpuListScanned { gpuListScanned = false }
    }
}
