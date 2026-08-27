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
/// returns, and they are the operations that clear `isRendering` or reset the cursor.
///
/// The budget is a single 500 ms wait. That is long enough for the pull side to resume after a
/// short `renderQueue` gap, and short enough that pause/stop on the player thread cannot sit
/// behind a multi-second hang. A stalled consumer is dropped rather than waited out; extra
/// slices would only delay control. Worst-case same-thread stall is
/// `maxWriterStallMilliseconds`.
public struct PCMWriteBackpressure: Equatable, Sendable {
    public static let waitTimeoutMilliseconds = 500
    public static let maxConsecutiveFullWaits = 1
    public static let maxWriterStallMilliseconds =
        waitTimeoutMilliseconds * maxConsecutiveFullWaits

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
