import AppKit
import SwiftUI

/// The hosting controller used by every status-item popover. It hardens the
/// `sizingOptions = [.preferredContentSize]` resize path against a macOS 26
/// layout feedback loop that can blow the main thread's stack.
///
/// The loop: the popover window finishes a layout pass, the hosting view's
/// `windowDidLayout()` responds by setting the window frame, the frame change
/// synchronously lays out again, and when the size SwiftUI asks for can never
/// be satisfied exactly (fractional heights from glass-material resolution
/// versus a pixel-aligned window frame) the cycle recurses inside one run-loop
/// callout until the stack guard page is hit. A crash report shows 6,554
/// nested layout passes through `NSPerformVisuallyAtomicChange` ending in
/// `SwiftUICore Color.Resolved.init` under `DesignLibrary` material frames.
///
/// Intercepting `preferredContentSize` does not work: the property is
/// computed on demand from the SwiftUI ideal size, so machine-driven sizing
/// never calls the setter and never emits KVO (verified empirically; the
/// value changes with no notification of any kind). The defense therefore
/// sits where the sizes are born, at the root of the SwiftUI layout:
/// - `IntegralIdealSize` rounds the content's reported size up to whole
///   points, so every consumer, the animated window-resize target included,
///   chases a size the window frame can actually reach and the resize
///   converges instead of pursuing a fraction forever.
/// - Sub-point hysteresis on the ideal-size query keeps jitter (for example
///   400.99 versus 401.01 across passes) from straddling an integer boundary
///   and turning into a one-point oscillation of the rounded result.
///
/// The `preferredContentSize` getter also rounds, purely as a last guard for
/// direct readers (NSPopover sizes the window from it at show time) in case
/// a future OS path computes a size outside the root layout.
final class PopoverHostingController: NSHostingController<AnyView> {
    init(rootView: some View) {
        super.init(rootView: AnyView(IntegralIdealSize { rootView }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PopoverHostingController does not support NSCoder")
    }

    override var preferredContentSize: NSSize {
        get {
            let size = super.preferredContentSize
            return NSSize(
                width: size.width.rounded(.up),
                height: size.height.rounded(.up))
        }
        set { super.preferredContentSize = newValue }
    }
}

/// Single-child layout that reports the child's size rounded up to whole
/// points. On the ideal-size query (no proposed dimensions), raw sizes within
/// a point of the previous answer keep the previous answer, so a sub-point
/// wobble in the content's ideal size cannot flip the rounded result back and
/// forth across an integer boundary. Real growth (a point or more) passes
/// through immediately.
struct IntegralIdealSize: Layout {
    struct Cache {
        var lastRawIdeal: CGSize?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    // The default implementation rebuilds the cache whenever the content
    // changes, which is exactly when the remembered ideal size is needed.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) -> CGSize {
        guard let child = subviews.first else { return .zero }
        var raw = child.sizeThatFits(proposal)
        if proposal.width == nil, proposal.height == nil {
            if let last = cache.lastRawIdeal,
                abs(raw.width - last.width) < 1,
                abs(raw.height - last.height) < 1
            {
                raw = last
            } else {
                cache.lastRawIdeal = raw
            }
        }
        return CGSize(
            width: raw.width.isFinite ? raw.width.rounded(.up) : raw.width,
            height: raw.height.isFinite ? raw.height.rounded(.up) : raw.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout Cache
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
            proposal: ProposedViewSize(bounds.size))
    }
}
