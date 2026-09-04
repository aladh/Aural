/// Pure circular-buffer index arithmetic used by the real-time audio renderer. Storage and
/// synchronization stay in the platform adapter; this value makes wrap/reset invariants testable.
public struct PCMBufferCursor: Equatable, Sendable {
    public let capacity: Int
    public private(set) var readIndex: Int
    public private(set) var writeIndex: Int

    public init(capacity: Int, readIndex: Int = 0, writeIndex: Int = 0) {
        precondition(capacity > 1)
        self.capacity = capacity
        self.readIndex = Self.normalizedIndex(readIndex, capacity: capacity)
        self.writeIndex = Self.normalizedIndex(writeIndex, capacity: capacity)
    }

    public var available: Int {
        writeIndex >= readIndex
            ? writeIndex - readIndex
            : capacity - readIndex + writeIndex
    }

    public var free: Int { capacity - 1 - available }

    public mutating func advanceWrite(by count: Int) {
        precondition(count >= 0 && count <= free)
        writeIndex = (writeIndex + count) % capacity
    }

    public mutating func advanceRead(by count: Int) {
        precondition(count >= 0 && count <= available)
        readIndex = (readIndex + count) % capacity
    }

    public mutating func reset() {
        readIndex = 0
        writeIndex = 0
    }

    private static func normalizedIndex(_ index: Int, capacity: Int) -> Int {
        let remainder = index % capacity
        return remainder >= 0 ? remainder : remainder + capacity
    }
}
