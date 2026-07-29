import XCTest

@testable import MacPerfMonitorCore

final class RingBufferTests: XCTestCase {
    func testAppendUnderCapacityKeepsOrder() {
        var buffer = RingBuffer<Int>(capacity: 4)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(Array(buffer.elements()), [1, 2, 3])
        XCTAssertEqual(buffer.last, 3)
    }

    func testWrapEvictsOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        XCTAssertEqual(buffer.count, 3)
        // Oldest two evicted; chronological order preserved.
        XCTAssertEqual(Array(buffer.elements()), [3, 4, 5])
        XCTAssertEqual(buffer.last, 5)
    }

    func testExactlyCapacityThenOneMore() {
        var buffer = RingBuffer<Int>(capacity: 2)
        buffer.append(10)
        buffer.append(20)
        XCTAssertEqual(Array(buffer.elements()), [10, 20])
        buffer.append(30)
        XCTAssertEqual(Array(buffer.elements()), [20, 30])
    }

    func testRemoveAll() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.last)
        buffer.append(9)
        XCTAssertEqual(Array(buffer.elements()), [9])
    }

    /// `elements()` is a RandomAccessCollection view: callers can map without
    /// first materialising a chronological `[Element]` copy.
    func testElementsIsRandomAccessCollection() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        let view = buffer.elements()
        XCTAssertEqual(view.count, 3)
        XCTAssertEqual(view[view.startIndex], 3)
        XCTAssertEqual(view[view.index(view.startIndex, offsetBy: 2)], 5)
        XCTAssertEqual(view.map { $0 * 10 }, [30, 40, 50])
    }

    func testElementsViewMatchesOrderAtExactCapacity() {
        var buffer = RingBuffer<Int>(capacity: 4)
        for value in 1...4 { buffer.append(value) }
        XCTAssertEqual(Array(buffer.elements()), [1, 2, 3, 4])
        XCTAssertEqual(buffer.elements().map { $0 }, [1, 2, 3, 4])
    }
}
