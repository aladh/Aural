//
//  MediaDetailRequestLifetime.swift
//  Aural
//
//  Shared account- and selection-scoped request lifetime for album and artist detail.
//

import AuralDomain
import Foundation
import os

/// Internal single-flight owner for one media-detail selection. Presentation state stays on
/// `AlbumDetailStore` and `ArtistDetailStore`; this type does not publish UI.
@MainActor
final class MediaDetailRequestLifetime {
    struct Handle {
        let identity: AccountScopedRequestIdentity
        let sessionSnapshot: CatalogSessionSnapshot
        let uri: String
    }

    /// Opaque waiter token. `awaitFlight` releases this claim on cancel or return.
    struct WaiterClaim: Sendable {
        fileprivate let flightID: UInt64
        fileprivate let claimID: UInt64
        fileprivate let task: Task<Void, Never>
    }

    enum Admission {
        case skip
        case join(WaiterClaim)
        case start(Handle)
    }

    private struct JoinFlight: Sendable {
        let flightID: UInt64
        let task: Task<Void, Never>
        let uri: String
        let session: CatalogSessionSnapshot
        var liveClaims: Set<UInt64>
    }

    private struct JoinState: Sendable {
        var flight: JoinFlight?
    }

    private let session: CatalogSessionAvailability
    private var requestID: UInt64 = 0
    private var nextFlightID: UInt64 = 0
    private var nextClaimID: UInt64 = 0
    private let joinState = OSAllocatedUnfairLock(initialState: JoinState())
    private var loadedURI: String?
    private var loadedSession: CatalogSessionSnapshot?

    init(session: CatalogSessionAvailability) {
        self.session = session
    }

    func reset() {
        requestID &+= 1
        invalidateJoinFlight()
        loadedURI = nil
        loadedSession = nil
    }

    func admit(uri: String) -> Admission {
        let currentSession = session.snapshot
        guard currentSession.isAvailable else { return .skip }
        if loadedURI == uri, loadedSession == currentSession {
            return .skip
        }

        nextClaimID &+= 1
        let claimID = nextClaimID
        let joined = joinState.withLock { state -> WaiterClaim? in
            guard var flight = state.flight,
                  flight.uri == uri,
                  flight.session == currentSession,
                  !flight.task.isCancelled,
                  !flight.liveClaims.isEmpty
            else {
                return nil
            }
            flight.liveClaims.insert(claimID)
            state.flight = flight
            return WaiterClaim(flightID: flight.flightID, claimID: claimID, task: flight.task)
        }
        if let joined {
            return .join(joined)
        }

        requestID &+= 1
        let identity = session.requestIdentity(requestID: requestID)
        invalidateJoinFlight()
        loadedURI = nil
        loadedSession = nil
        return .start(
            Handle(identity: identity, sessionSnapshot: currentSession, uri: uri)
        )
    }

    func awaitFlight(_ claim: WaiterClaim) async {
        await withTaskCancellationHandler {
            await claim.task.value
        } onCancel: { [joinState] in
            Self.releaseClaim(claim, joinState: joinState)
        }
        Self.releaseClaim(claim, joinState: joinState)
    }

    func run(_ handle: Handle, operation: @escaping @MainActor () async -> Void) async {
        nextFlightID &+= 1
        let flightID = nextFlightID
        nextClaimID &+= 1
        let ownerClaimID = nextClaimID
        let newTask = Task { [weak self] in
            await operation()
            self?.complete(handle, flightID: flightID)
        }
        joinState.withLock { state in
            state.flight = JoinFlight(
                flightID: flightID,
                task: newTask,
                uri: handle.uri,
                session: handle.sessionSnapshot,
                liveClaims: [ownerClaimID]
            )
        }
        let ownerClaim = WaiterClaim(flightID: flightID, claimID: ownerClaimID, task: newTask)
        await withTaskCancellationHandler {
            await newTask.value
        } onCancel: { [joinState] in
            Self.releaseClaim(ownerClaim, joinState: joinState)
        }
        Self.releaseClaim(ownerClaim, joinState: joinState)
    }

    func abandonUnstarted(_ handle: Handle) {
        guard owns(handle) else { return }
        invalidateJoinFlight()
    }

    func isCurrent(_ handle: Handle, selectedURI: String?) -> Bool {
        selectedURI == handle.uri && handle.identity.isCurrent(
            requestID: requestID,
            accountEpoch: session.accountEpoch,
            sessionRevision: session.snapshot.revision,
            isAvailable: session.isAvailable,
            isCancelled: Task.isCancelled
        )
    }

    func owns(_ handle: Handle) -> Bool {
        handle.identity.requestID == requestID
    }

    func markLoaded(_ handle: Handle) {
        guard owns(handle) else { return }
        loadedURI = handle.uri
        loadedSession = handle.sessionSnapshot
    }

    private func complete(_ handle: Handle, flightID: UInt64) {
        guard owns(handle) else { return }
        joinState.withLock { state in
            guard state.flight?.flightID == flightID else { return }
            state.flight = nil
        }
    }

    private func invalidateJoinFlight() {
        let stale = joinState.withLock { state -> Task<Void, Never>? in
            let task = state.flight?.task
            state.flight = nil
            return task
        }
        stale?.cancel()
    }

    /// Releases one waiter. Cancels the underlying task only when the last live claim
    /// for that exact flight leaves. A stale claim is a no-op.
    private static func releaseClaim(
        _ claim: WaiterClaim,
        joinState: OSAllocatedUnfairLock<JoinState>
    ) {
        let stale = joinState.withLock { state -> Task<Void, Never>? in
            guard var flight = state.flight, flight.flightID == claim.flightID else {
                return nil
            }
            guard flight.liveClaims.remove(claim.claimID) != nil else {
                return nil
            }
            if flight.liveClaims.isEmpty {
                state.flight = nil
                return flight.task
            }
            state.flight = flight
            return nil
        }
        stale?.cancel()
    }
}
