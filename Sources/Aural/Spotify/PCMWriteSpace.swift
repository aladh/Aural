import Foundation

/// Sticky wake-up used when the PCM writer parks on a full ring.
///
/// Control always signals, including the case where `stop` / `flush` run before `wait` is entered.
/// The pull side should signal only while a writer is actually waiting so normal consume does not
/// turn the next wait into a spin.
nonisolated final class PCMWriteSpace: @unchecked Sendable {
    private let condition = NSCondition()
    private var generation: UInt64 = 0
    private var observedGeneration: UInt64 = 0

    /// Returns `true` when a signal arrived, `false` on timeout.
    @discardableResult
    func wait(timeoutMilliseconds: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if generation != observedGeneration {
            observedGeneration = generation
            return true
        }
        let deadline = Date().addingTimeInterval(Double(max(timeoutMilliseconds, 0)) / 1000)
        while generation == observedGeneration {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        observedGeneration = generation
        return true
    }

    func signal() {
        condition.lock()
        generation &+= 1
        condition.broadcast()
        condition.unlock()
    }
}
