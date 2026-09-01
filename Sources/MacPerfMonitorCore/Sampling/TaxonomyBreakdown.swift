import Foundation

/// A single slice of the physical-RAM taxonomy bar shown on the dashboard.
/// The slices for one `SystemSample` always sum to `total_ram` exactly (see
/// `TaxonomyBreakdown.compute`), so the stacked visualisation is honest.
public struct TaxonomySlice: Sendable, Identifiable, Equatable {
    public var category: TaxonomyCategory
    public var bytes: UInt64

    public var id: TaxonomyCategory { category }
    public var name: String { category.name }
    public var explanation: String { category.explanation }

    public init(category: TaxonomyCategory, bytes: UInt64) {
        self.category = category
        self.bytes = bytes
    }
}

/// The five user-facing RAM categories (PRD section 7). Swap is intentionally
/// excluded here because it lives on disk, not in RAM, and is charted
/// separately. The plain-language explanations are the hover/tap copy.
public enum TaxonomyCategory: String, Sendable, CaseIterable, Codable {
    case wired
    case appMemory
    case compressed
    case cachedFiles
    case free

    public var name: String {
        switch self {
        case .wired: return t("Wired")
        case .appMemory: return t("App Memory")
        case .compressed: return t("Compressed")
        case .cachedFiles: return t("Cached Files")
        case .free: return t("Free & available")
        }
    }

    public var explanation: String {
        switch self {
        case .wired:
            return t("Memory that can't be moved or compressed. The system needs it where it is.")
        case .appMemory:
            return t("Memory your apps are actively using that isn't a reclaimable file cache.")
        case .compressed:
            return t(
                "Memory the compressor has squeezed to fit more in RAM. A little is normal; a lot, and rising, is an early sign of pressure."
            )
        case .cachedFiles:
            return t(
                "macOS is using free RAM to keep recently used files handy. This is not a problem and is released the moment anything needs the space."
            )
        case .free:
            return t("RAM not currently in use and immediately available.")
        }
    }
}

/// Builds the physical-RAM taxonomy breakdown for one system sample.
///
/// The four measured categories (wired, app memory, compressed, cached files)
/// come straight from the derived counters; "Free & available" is the remainder
/// so the slices reconcile to `total_ram` exactly. See docs/memory-taxonomy.md
/// for the formulas and the tolerance against Activity Monitor.
public enum TaxonomyBreakdown {
    /// Ordered slices that sum to `system.totalRAM` exactly.
    public static func compute(_ system: SystemSample) -> [TaxonomySlice] {
        let total = system.totalRAM
        let wired = system.wired
        let app = system.appMemory
        let compressed = system.compressed
        let cached = system.cachedFiles

        let measured = wired &+ app &+ compressed &+ cached

        if measured <= total {
            let free = total - measured
            return [
                TaxonomySlice(category: .wired, bytes: wired),
                TaxonomySlice(category: .appMemory, bytes: app),
                TaxonomySlice(category: .compressed, bytes: compressed),
                TaxonomySlice(category: .cachedFiles, bytes: cached),
                TaxonomySlice(category: .free, bytes: free),
            ]
        }

        // Rare counter-overlap case: scale the four measured categories
        // proportionally to fill total RAM so the bar still sums to total.
        // Any rounding shortfall is added to the largest slice so the sum is
        // exact to the byte.
        guard measured > 0 else {
            return [TaxonomySlice(category: .free, bytes: total)]
        }
        let scale = Double(total) / Double(measured)
        var scaled: [(TaxonomyCategory, UInt64)] = [
            (.wired, UInt64((Double(wired) * scale).rounded(.down))),
            (.appMemory, UInt64((Double(app) * scale).rounded(.down))),
            (.compressed, UInt64((Double(compressed) * scale).rounded(.down))),
            (.cachedFiles, UInt64((Double(cached) * scale).rounded(.down))),
        ]
        let assigned = scaled.reduce(UInt64(0)) { $0 &+ $1.1 }
        if assigned < total, let maxIndex = scaled.indices.max(by: { scaled[$0].1 < scaled[$1].1 })
        {
            scaled[maxIndex].1 &+= (total - assigned)
        }
        return scaled.map { TaxonomySlice(category: $0.0, bytes: $0.1) }
    }
}
