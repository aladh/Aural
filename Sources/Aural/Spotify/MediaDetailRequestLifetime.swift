//
//  MediaDetailRequestLifetime.swift
//  Aural
//
//  Shared account- and selection-scoped request lifetime for album and artist detail.
//

import AuralDomain
import Foundation

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

    private let session: CatalogSessionAvailability
    private var requestID: UInt64 = 0
    private var task: Task<Void, Never>?
    private var inFlightURI: String?
    private var inFlightSession: CatalogSessionSnapshot?
    private var loadedURI: String?
    private var loadedSession: CatalogSessionSnapshot?

    init(session: CatalogSessionAvailability) {
        self.session = session
    }

    func reset() {
        requestID &+= 1
        task?.cancel()
        task = nil
        inFlightURI = nil
        inFlightSession = nil
        loadedURI = nil
        loadedSession = nil
    }

    func admit(uri: String) -> Admission {
        let currentSession = session.snapshot
        guard currentSession.isAvailable else { return .skip }
        if loadedURI == uri, loadedSession == currentSession {
            return .skip
        }
        // A cancelled owner (SwiftUI `.task` teardown) must not be joined: the view can
        // remount the same URI/session before `complete` runs.
        if let task, !task.isCancelled, inFlightURI == uri, inFlightSession == currentSession {
            return .join(task)
        }

        requestID &+= 1
        let identity = session.requestIdentity(requestID: requestID)
        task?.cancel()
        task = nil
        loadedURI = nil
        loadedSession = nil
        inFlightURI = uri
        inFlightSession = currentSession
        return .start(
            Handle(identity: identity, sessionSnapshot: currentSession, uri: uri)
        )
    }

    func run(_ handle: Handle, operation: @escaping @MainActor () async -> Void) async {
        let newTask = Task { [weak self] in
            await operation()
            self?.complete(handle)
        }
        task = newTask
        await withTaskCancellationHandler {
            await newTask.value
        } onCancel: {
            newTask.cancel()
        }
    }

    func abandonUnstarted(_ handle: Handle) {
        guard owns(handle) else { return }
        inFlightURI = nil
        inFlightSession = nil
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
        task = nil
        inFlightURI = nil
        inFlightSession = nil
    }
}
