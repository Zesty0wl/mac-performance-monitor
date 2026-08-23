import SwiftUI

/// The sampler model as a plain environment value, for views that need to call
/// it (load history, read the live sample on a tick) without observing it.
///
/// `@EnvironmentObject` always subscribes the view to `objectWillChange`, which
/// for `SamplerModel` fires on every table tick and re-evaluates the whole
/// page body. A page that delegates its live parts to small observing leaves
/// reads the model through this key instead, so the page itself only
/// re-renders for its own state (a range change, a visibility flip).
private struct SamplerModelKey: EnvironmentKey {
    static let defaultValue: SamplerModel? = nil
}

extension EnvironmentValues {
    /// The app's `SamplerModel`, unobserved. Set alongside `.environmentObject`
    /// at the main window's root; nil outside it.
    var samplerModel: SamplerModel? {
        get { self[SamplerModelKey.self] }
        set { self[SamplerModelKey.self] = newValue }
    }
}
