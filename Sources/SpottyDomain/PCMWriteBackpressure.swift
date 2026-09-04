/// How the push-side PCM writer should proceed for the samples still in this call.
public enum PCMWriteAdmission: Equatable, Sendable {
    /// Copy this many samples into free ring slots, then continue with any remainder.
    case write(Int)
    /// Park until the pull side or a control operation creates space. Recheck after the wait.
    case waitForSpace
    /// Discard the rest of this write. Used when rendering has stopped or the wait budget is spent.
    case dropRemaining
}

/// Bounded backpressure for one `writeAudioData` call.
///
/// A full ring must not wait forever: `stop` / `flush` run on that same thread after `write`
/// returns. The budget is a single 500 ms wait for the whole call. Partial writes that see a
/// little free space do not renew it, so a trickle of consumer releases cannot stack parks.
/// Reset at the next write-call boundary (`beginWrite`) or when the ring is reset.
public struct PCMWriteBackpressure: Equatable, Sendable {
    public static let waitTimeoutMilliseconds = 500

    public private(set) var hasSpentWait = false

    public init() {}

    public mutating func beginWrite() {
        hasSpentWait = false
    }

    public mutating func resetWaitBudget() {
        hasSpentWait = false
    }

    public mutating func admit(freeSpace: Int, remaining: Int, isRendering: Bool) -> PCMWriteAdmission {
        precondition(freeSpace >= 0)
        precondition(remaining >= 0)
        guard remaining > 0 else { return .dropRemaining }
        if freeSpace > 0 {
            return .write(min(freeSpace, remaining))
        }
        guard isRendering else { return .dropRemaining }
        guard !hasSpentWait else { return .dropRemaining }
        hasSpentWait = true
        return .waitForSpace
    }
}

/// Serializes start/stop so a superseded stop cannot tear down a later start.
///
/// `beginStop` clears rendering on the caller thread (so a parked writer can drop) and returns
/// the generation that the serialized AV teardown must still match. `beginStart` bumps the
/// generation so an in-flight stop becomes a no-op.
public struct AudioOutputControlEpoch: Equatable, Sendable {
    public private(set) var isRendering = false
    public private(set) var generation: UInt64 = 0

    public init() {}

    public mutating func beginStart() {
        isRendering = true
        generation &+= 1
    }

    public mutating func beginStop() -> UInt64? {
        guard isRendering else { return nil }
        isRendering = false
        return generation
    }

    public func shouldApplyStop(_ captured: UInt64) -> Bool {
        !isRendering && generation == captured
    }
}
