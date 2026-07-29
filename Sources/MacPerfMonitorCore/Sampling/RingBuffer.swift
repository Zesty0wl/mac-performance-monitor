import Foundation

/// A fixed-capacity circular buffer that keeps the most recent `capacity`
/// elements. Used for the live, in-memory history that the UI reads on the hot
/// path without touching the database. See the data flow in the PRD (section 5).
///
/// Not thread-safe on its own; callers serialise access (the sampler model
/// mutates it on the main actor after each tick).
public struct RingBuffer<Element> {
    private var storage: [Element] = []
    private var head = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    /// Number of elements currently held (<= capacity).
    public var count: Int { storage.count }

    public var isEmpty: Bool { storage.isEmpty }

    /// The most recently appended element, if any.
    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        let index = (head - 1 + storage.count) % storage.count
        return storage[index]
    }

    /// Append an element, evicting the oldest once at capacity.
    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
            head = storage.count % capacity
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Chronological view (oldest first, newest last) over the buffer.
    ///
    /// Shares the underlying storage via Array CoW; does not allocate a
    /// reordered `[Element]` copy. Callers that only need a mapped series
    /// (e.g. chart trails) can `.map` this view directly.
    public func elements() -> Elements {
        Elements(storage: storage, head: head, wrapped: storage.count == capacity)
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

extension RingBuffer {
    /// Random-access chronological projection of a `RingBuffer`.
    public struct Elements: RandomAccessCollection {
        public typealias Index = Int

        private let storage: [Element]
        private let head: Int
        private let wrapped: Bool

        fileprivate init(storage: [Element], head: Int, wrapped: Bool) {
            self.storage = storage
            self.head = head
            self.wrapped = wrapped
        }

        public var startIndex: Int { 0 }
        public var endIndex: Int { storage.count }

        public subscript(position: Int) -> Element {
            if wrapped {
                return storage[(head + position) % storage.count]
            }
            return storage[position]
        }
    }
}
