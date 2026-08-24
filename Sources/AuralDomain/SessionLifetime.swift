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
