// SPDX-License-Identifier: MIT

import Foundation

/// Holds the latest interaction value without publishing it to SwiftUI, then
/// commits at most once per display frame. Trackpad and drag callbacks can fire
/// much faster than the display; publishing every intermediate domain makes all
/// chart marks lay out repeatedly for frames that can never be shown.
@MainActor
final class FrameCoalescedValue<Value> {
    private struct Pending {
        let value: Value
    }

    private var pending: Pending?
    private var workItem: DispatchWorkItem?

    func current(or committed: @autoclosure () -> Value) -> Value {
        if let pending { return pending.value }
        return committed()
    }

    func submit(_ value: Value, apply: @escaping (Value) -> Void) {
        pending = Pending(value: value)
        guard workItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.workItem = nil
            guard let pending = self.pending else { return }
            self.pending = nil
            apply(pending.value)
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
        pending = nil
    }
}

/// Pure zoom/pan math over a fixed time window, used by the imported-trace
/// viewer. The live `PerformanceMonitorView` keeps its own inline zoom because
/// its full window slides with real time and it re-reads finer detail from the
/// database; a trace is a fixed in-memory dataset, so this value type is all the
/// viewer needs. It owns only the visible sub-window and the clamping rules
/// (minimum span, staying inside the full window, snapping back to "no zoom").
struct ChartZoomState {
    /// The whole covered window; the zoom can never escape it.
    var fullDomain: ClosedRange<Date>
    /// Tightest allowed visible span, matched to the charts' minimum zoom.
    var minSpan: TimeInterval
    /// The current visible sub-window, or nil for the full window.
    private(set) var zoom: ClosedRange<Date>?

    init(fullDomain: ClosedRange<Date>, minSpan: TimeInterval = 20) {
        self.fullDomain = fullDomain
        self.minSpan = minSpan
        self.zoom = nil
    }

    /// The window the charts should draw.
    var visibleDomain: ClosedRange<Date> { zoom ?? fullDomain }

    var isZoomed: Bool { zoom != nil }

    var visibleMidpoint: Date {
        let d = visibleDomain
        return d.lowerBound.addingTimeInterval(
            d.upperBound.timeIntervalSince(d.lowerBound) / 2)
    }

    /// Keep the full window fixed but drop any zoom (e.g. after the backing data
    /// changed). Reclamps the current zoom into the (possibly new) full window.
    mutating func reclamp() {
        guard let z = zoom else { return }
        let span = z.upperBound.timeIntervalSince(z.lowerBound)
        setZoom(lower: z.lowerBound, span: span)
    }

    /// Zoom about `anchor`, keeping it fixed on screen. `factor` > 1 zooms in.
    mutating func applyZoom(anchor: Date, factor: Double) {
        guard factor > 0, factor.isFinite else { return }
        let current = visibleDomain
        let currentSpan = current.upperBound.timeIntervalSince(current.lowerBound)
        let newSpan = min(max(currentSpan / factor, minSpan), fullSpan)
        let pinned = min(max(anchor, current.lowerBound), current.upperBound)
        let fraction =
            currentSpan > 0 ? pinned.timeIntervalSince(current.lowerBound) / currentSpan : 0.5
        setZoom(lower: pinned.addingTimeInterval(-fraction * newSpan), span: newSpan)
    }

    /// Shift the visible window; positive moves it later in time. No-op at full view.
    mutating func applyPan(deltaSeconds: TimeInterval) {
        guard let current = zoom else { return }
        let currentSpan = current.upperBound.timeIntervalSince(current.lowerBound)
        setZoom(lower: current.lowerBound.addingTimeInterval(deltaSeconds), span: currentSpan)
    }

    /// Zoom to exactly a selected range (rubber-band).
    mutating func applySelect(_ range: ClosedRange<Date>) {
        let s = max(range.upperBound.timeIntervalSince(range.lowerBound), minSpan)
        setZoom(lower: range.lowerBound, span: s)
    }

    /// Set the visible window from the timeline scrubber.
    mutating func setVisibleWindow(_ range: ClosedRange<Date>) {
        let s = max(range.upperBound.timeIntervalSince(range.lowerBound), minSpan)
        setZoom(lower: range.lowerBound, span: s)
    }

    /// Back to the whole window.
    mutating func reset() { zoom = nil }

    private var fullSpan: TimeInterval {
        fullDomain.upperBound.timeIntervalSince(fullDomain.lowerBound)
    }

    /// Clamp a requested window into the full domain; snap back to "no zoom" once
    /// it covers the whole span.
    private mutating func setZoom(lower: Date, span newSpan: TimeInterval) {
        if newSpan >= fullSpan - 0.5 {
            zoom = nil
            return
        }
        var lo = lower
        if lo < fullDomain.lowerBound { lo = fullDomain.lowerBound }
        if lo.addingTimeInterval(newSpan) > fullDomain.upperBound {
            lo = fullDomain.upperBound.addingTimeInterval(-newSpan)
        }
        zoom = lo...lo.addingTimeInterval(newSpan)
    }
}
