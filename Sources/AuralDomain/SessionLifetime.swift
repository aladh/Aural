import Foundation

/// The cumulative result requested while an account teardown is in flight.
/// Clearing the persisted grant is the strongest intent and always resolves to signed out,
/// regardless of whether a weaker token-revocation failure arrived first or last.
public struct SessionTeardownIntent: Equatable, Sendable {
    public let clearGrant: Bool
    public let finalPhase: PlaybackSessionPhase

    public init(clearGrant: Bool, finalPhase: PlaybackSessionPhase) {
        self.clearGrant = clearGrant
        self.finalPhase = clearGrant ? .signedOut : finalPhase
    }

    public func merging(_ other: Self) -> Self {
        if clearGrant || other.clearGrant {
            return Self(clearGrant: true, finalPhase: .signedOut)
        }

        switch (finalPhase, other.finalPhase) {
        case let (.failed(message), _), let (_, .failed(message)):
            return Self(clearGrant: false, finalPhase: .failed(message))
        default:
            return other
        }
    }
}

/// Pure single-flight state shared by the presentation and account lifecycle owners.
/// `request` returns true only for the caller that must start the underlying teardown.
public struct SessionTeardownCoalescer: Sendable {
    public private(set) var intent: SessionTeardownIntent?

    public init() {}

    public var isActive: Bool { intent != nil }

    @discardableResult
    public mutating func request(_ requested: SessionTeardownIntent) -> Bool {
        guard let intent else {
            self.intent = requested
            return true
        }
        self.intent = intent.merging(requested)
        return false
    }

    @discardableResult
    public mutating func complete() -> SessionTeardownIntent? {
        defer { intent = nil }
        return intent
    }
}

/// Identity captured by catalog work before its first suspension. Session revision distinguishes
/// ready → unavailable → ready transitions even when the Spotify account epoch is unchanged.
public struct AccountScopedRequestIdentity: Equatable, Sendable {
    public let requestID: UInt64
    public let accountEpoch: UInt64
    public let sessionRevision: UInt64

    public init(requestID: UInt64, accountEpoch: UInt64, sessionRevision: UInt64) {
        self.requestID = requestID
        self.accountEpoch = accountEpoch
        self.sessionRevision = sessionRevision
    }

    public func isCurrent(
        requestID: UInt64,
        accountEpoch: UInt64,
        sessionRevision: UInt64,
        isAvailable: Bool,
        isCancelled: Bool
    ) -> Bool {
        self.requestID == requestID
            && self.accountEpoch == accountEpoch
            && self.sessionRevision == sessionRevision
            && isAvailable
            && !isCancelled
    }
}

/// Connect queue *callback* watermark. Distinct from provenance-snapshot revisions
/// recorded on `PlaybackEventSource.engineQueue`. `engineEpoch` is only a stale-engine floor:
/// adopting that epoch elsewhere must not clear a newer callback generation.
public struct ConnectQueueCallbackWatermark: Equatable, Sendable {
    public private(set) var generation: UInt64
    public private(set) var revision: UInt64

    public init(generation: UInt64 = 0, revision: UInt64 = 0) {
        self.generation = generation
        self.revision = revision
    }

    public mutating func reset() {
        generation = 0
        revision = 0
    }

    @discardableResult
    public mutating func accept(
        generation: UInt64?,
        revision: UInt64?,
        engineEpoch: UInt64
    ) -> Bool {
        var next = self
        if let generation {
            guard generation >= max(next.generation, engineEpoch) else { return false }
            if generation > next.generation {
                next.generation = generation
                next.revision = 0
            }
        }
        if let revision {
            guard revision > next.revision else { return false }
            next.revision = revision
        }
        self = next
        return true
    }
}

/// Dependent work after `PlaybackStore.send(.commandFinished)`.
///
/// `PlaybackReducer.reconcileTransport` drops a pending *transport* command when an engine
/// snapshot already matches `expectedTransport`. The later `commandFinished` is then rejected.
/// On the same account/engine lifetime that is already-reconciled success, even if the
/// coordinator later reports failure: the backend has confirmed the optimistic transport.
/// Showing an error or calling `completion(false)` would roll back that confirmed state.
/// A known play target is confirmed only by that target's identity, not by a lagging prior
/// track that happens to already be `.playing`. Confirmation and supersession are stored per
/// command id so a later pause/resume cannot recycle the nil already-reconciled-success path.
/// An unrelated or empty track supersedes the optimistic target: rollback is cleared and a later
/// finish stays inert.
/// Seek confirmation and track-switch supersession both clear pending `.seek`, so a later
/// finish stays inert: `pendingCommandID == nil` cannot tell those cases apart, and seek
/// completions have no success side effect.
/// Account/engine invalidation, teardown, non-transport kinds, and a newer pending id stay inert.
public enum PlaybackCommandFollowUp: Equatable, Sendable {
    case reportSuccess
    case reportFailure(reconnect: Bool)
    case inert
}

public func playbackCommandFollowUp(
    finishAccepted: Bool,
    operationSucceeded: Bool,
    requiresReconnect: Bool,
    commandKind: PlaybackCommandKind,
    pendingCommandID: UUID?,
    finishedCommandID: UUID? = nil,
    transportCommandResolutions: [UUID: PlaybackTransportCommandResolution] = [:],
    capturedAccountEpoch: UInt64,
    capturedEngineEpoch: UInt64,
    currentAccountEpoch: UInt64,
    currentEngineEpoch: UInt64,
    isTearingDown: Bool
) -> PlaybackCommandFollowUp {
    if finishAccepted {
        return operationSucceeded ? .reportSuccess : .reportFailure(reconnect: requiresReconnect)
    }
    let sameLifetime =
        !isTearingDown
        && capturedAccountEpoch == currentAccountEpoch
        && capturedEngineEpoch == currentEngineEpoch
    guard sameLifetime, commandKind == .transport else { return .inert }
    if let finishedCommandID {
        switch transportCommandResolutions[finishedCommandID] {
        case .confirmed:
            return .reportSuccess
        case .superseded:
            return .inert
        case nil:
            break
        }
    }
    return pendingCommandID == nil ? .reportSuccess : .inert
