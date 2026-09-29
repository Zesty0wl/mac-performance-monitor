import Foundation

struct SwapActivityTracker {
    struct Reading {
        var pagesIn: UInt64
        var pagesOut: UInt64
        var pageSize: UInt64
        var elapsed: TimeInterval
        var rateIn: Double { Double(pagesIn) * Double(pageSize) / elapsed }
        var rateOut: Double { Double(pagesOut) * Double(pageSize) / elapsed }
    }

    private var previous: (date: Date, pagesIn: UInt64, pagesOut: UInt64, pageSize: UInt64)?

    mutating func sample(
        at date: Date, pagesIn: UInt64, pagesOut: UInt64, pageSize: UInt64
    ) -> Reading? {
        let last = previous
        previous = (date, pagesIn, pagesOut, pageSize)
        guard let last, pageSize > 0, last.pageSize == pageSize,
            pagesIn >= last.pagesIn, pagesOut >= last.pagesOut
        else { return nil }
        let elapsed = date.timeIntervalSince(last.date)
        guard elapsed > 0, elapsed <= 120 else { return nil }
        return Reading(
            pagesIn: pagesIn - last.pagesIn, pagesOut: pagesOut - last.pagesOut,
            pageSize: pageSize, elapsed: elapsed)
    }

    mutating func reset() { previous = nil }
}
