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

    enum Admission {
        case skip
        case join(Task<Void, Never>)
        case start(Handle)
    }

    private struct JoinFlight: Sendable {
        let task: Task<Void, Never>
        let uri: String
        let session: CatalogSessionSnapshot
    }

    private let session: CatalogSessionAvailability
    private var requestID: UInt64 = 0
    private let joinFlight = OSAllocatedUnfairLock<JoinFlight?>(initialState: nil)
    private var loadedURI: String?
    private var loadedSession: CatalogSessionSnapshot?

    init(session: CatalogSessionAvailability) {
        self.session = session
    }

    func reset() {
        requestID &+= 1
        cancelJoinFlight()
        loadedURI = nil
        loadedSession = nil
    }

    func admit(uri: String) -> Admission {
        let currentSession = session.snapshot
        guard currentSession.isAvailable else { return .skip }
        if loadedURI == uri, loadedSession == currentSession {
            return .skip
        }
        // Join only while the lock still holds a live flight. Cancellation clears that
        // box before `Task.cancel()`, so admit cannot join a flight already tearing down.
        let joined = joinFlight.withLock { current -> Task<Void, Never>? in
            guard let current,
                  current.uri == uri,
                  current.session == currentSession,
                  !current.task.isCancelled
            else {
                return nil
            }
            return current.task
        }
        if let joined {
            return .join(joined)
        }

        requestID &+= 1
        let identity = session.requestIdentity(requestID: requestID)
        cancelJoinFlight()
        loadedURI = nil
        loadedSession = nil
        return .start(
            Handle(identity: identity, sessionSnapshot: currentSession, uri: uri)
        )
    }

    func run(_ handle: Handle, operation: @escaping @MainActor () async -> Void) async {
        let newTask = Task { [weak self] in
            await operation()
            self?.complete(handle)
        }
        joinFlight.withLock {
            $0 = JoinFlight(task: newTask, uri: handle.uri, session: handle.sessionSnapshot)
        }
        await withTaskCancellationHandler {
            await newTask.value
        } onCancel: { [joinFlight] in
            joinFlight.withLock { current in
                if current?.task == newTask {
                    current = nil
                }
            }
            newTask.cancel()
        }
    }

    func abandonUnstarted(_ handle: Handle) {
        guard owns(handle) else { return }
        joinFlight.withLock { current in
            if current?.uri == handle.uri, current?.session == handle.sessionSnapshot {
                current = nil
            }
        }
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

    private func complete(_ handle: Handle) {
        guard owns(handle) else { return }
        joinFlight.withLock { current in
            if current?.uri == handle.uri, current?.session == handle.sessionSnapshot {
                current = nil
            }
        }
    }

    private func cancelJoinFlight() {
        let stale = joinFlight.withLock { current -> Task<Void, Never>? in
            let task = current?.task
            current = nil
            return task
        }
        stale?.cancel()
    }
}
