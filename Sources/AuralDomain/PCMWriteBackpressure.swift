import Foundation

/// How the push-side PCM writer should proceed for the samples still in this call.
public enum PCMWriteAdmission: Equatable, Sendable {
    /// Copy this many samples into free ring slots, then continue with any remainder.
    case write(Int)
    /// Park until the pull side or a control operation creates space. Recheck after the wait.
    case waitForSpace
    /// Discard the rest of this write. Used when rendering has stopped or the wait budget is spent.
    case dropRemaining
}

/// Bounded backpressure for the librespot player thread.
///
/// A full ring must not wait forever: `stop` / `flush` run on that same thread after `write`
/// returns, and they are the operations that clear `isRendering` or reset the cursor. The wait
/// budget is one full buffer of 500 ms slices; after that the write drops instead of wedging.
public struct PCMWriteBackpressure: Equatable, Sendable {
    public static let waitTimeoutMilliseconds = 500
    public static let maxConsecutiveFullWaits = 4

    public private(set) var consecutiveFullWaits = 0

    public init() {}

    public mutating func resetWaitBudget() {
        consecutiveFullWaits = 0
    }

    public mutating func admit(freeSpace: Int, remaining: Int, isRendering: Bool) -> PCMWriteAdmission {
        precondition(freeSpace >= 0)
        precondition(remaining >= 0)
        guard remaining > 0 else { return .dropRemaining }
        if freeSpace > 0 {
            consecutiveFullWaits = 0
            return .write(min(freeSpace, remaining))
        }
        guard isRendering else {
            consecutiveFullWaits = 0
            return .dropRemaining
        }
        guard consecutiveFullWaits < Self.maxConsecutiveFullWaits else {
            return .dropRemaining
        }
        consecutiveFullWaits += 1
        return .waitForSpace
    }
}

/// Sticky wake-up used when the writer parks on a full ring.
///
/// Control always signals, including the case where `stop` / `flush` run before `wait` is entered.
/// The pull side should signal only while a writer is actually waiting so normal consume does not
/// turn the next wait into a spin.
public final class PCMWriteSpace: @unchecked Sendable {
    private let condition = NSCondition()
    private var generation: UInt64 = 0
    private var observedGeneration: UInt64 = 0

    public init() {}

    /// Returns `true` when a signal arrived, `false` on timeout.
    @discardableResult
    public func wait(timeoutMilliseconds: Int) -> Bool {
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

    public func signal() {
        condition.lock()
        generation &+= 1
        condition.broadcast()
        condition.unlock()
    }
}
