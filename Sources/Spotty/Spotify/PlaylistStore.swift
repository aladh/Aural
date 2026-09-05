//
//  PlaylistStore.swift
//  Spotty
//
//  Selected-playlist detail state.
//

import SpottyDomain
import Foundation

@MainActor
@Observable
final class PlaylistStore {
    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    var description = ""
    private(set) var loadedURI: String?
    private(set) var ownerURI: String?
    var isLoading = false
    var error: String?

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private var requestScope: UInt64 = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadSessionSnapshot: CatalogSessionSnapshot?
    @ObservationIgnored private var loadedSessionSnapshot: CatalogSessionSnapshot?

    init(
        provider: any CatalogProviding,
        metadata: CatalogMetadataRepository,
        session: CatalogSessionAvailability
    ) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
    }

    func reset() {
        requestScope &+= 1
        loadTask?.cancel()
        loadTask = nil
        loadSessionSnapshot = nil
        loadedSessionSnapshot = nil
        trackCollection.replace([])
        description = ""
        loadedURI = nil
        ownerURI = nil
        isLoading = false
        error = nil
        metadata.replaceTracks([], from: .playlist)
    }

    /// Keeps `loadedURI` and `tracks` paired. Production loading still goes through `load(_:)`.
    func replaceLoadedPlaylist(uri: String, tracks: [CatalogTrack]) {
        if loadedURI != uri {
            loadedSessionSnapshot = nil
        }
        loadedURI = uri
        trackCollection.replace(tracks)
    }

    func load(_ item: CatalogItem, force: Bool = false) async {
        let currentSession = session.snapshot
        guard currentSession.isAvailable, item.kind == .playlist else { return }
        if loadedURI == item.uri,
            loadedSessionSnapshot == currentSession,
            error == nil,
            !force
        {
            return
        }
        if isLoading,
            loadedURI == item.uri,
            loadSessionSnapshot == currentSession,
            let loadTask,
            !force
        {
            await loadTask.value
            return
        }

        requestScope &+= 1
        let requestID = requestScope
        let identity = session.requestIdentity(requestID: requestID)
        loadTask?.cancel()
        loadTask = nil
        let isNewPlaylist = loadedURI != item.uri
        loadedURI = item.uri
        if isNewPlaylist {
            loadedSessionSnapshot = nil
            trackCollection.replace([])
            description = ""
            ownerURI = item.ownerURI
            metadata.replaceTracks([], from: .playlist)
            error = nil
        } else if !force {
            error = nil
        }
        // Same-playlist force reloads keep `error` until a current load succeeds so a
        // cancelled or superseded retry cannot hide stale rows.
        isLoading = true
        defer {
            if requestID == requestScope {
                isLoading = false
                loadTask = nil
                loadSessionSnapshot = nil
            }
        }

        guard let id = SpotifyURI.id(from: item.uri, kind: "playlist") else {
            error = "Spotify returned an invalid playlist address."
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(
                item,
                id: id,
                identity: identity,
                isNewPlaylist: isNewPlaylist
            )
        }
        loadTask = task
        loadSessionSnapshot = currentSession
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performLoad(
        _ item: CatalogItem,
        id: String,
        identity: AccountScopedRequestIdentity,
        isNewPlaylist: Bool
    ) async {
        do {
            let playlist = try await provider.playlist(id: id)
            guard isCurrent(identity, uri: item.uri) else { return }
            error = nil
            description = PlaylistDescription.plainText(from: playlist.description ?? "")
            ownerURI = CatalogMapping.ownerURI(from: playlist) ?? item.ownerURI
            let entries = playlist.content.flatMap(\.items) ?? []
            trackCollection.replace(entries.compactMap(CatalogMapping.playlistTrack(from:)))
            loadedSessionSnapshot = session.snapshot
            metadata.replaceTracks(tracks, from: .playlist)
            metadata.loadTrackAttributes(for: tracks)
        } catch {
            guard !isCancellation(error), isCurrent(identity, uri: item.uri) else { return }
            self.error = error.localizedDescription
        }
    }

    private func isCurrent(
        _ identity: AccountScopedRequestIdentity,
        uri: String
    ) -> Bool {
        loadedURI == uri
            && identity.isCurrent(
                requestID: requestScope,
                accountEpoch: session.accountEpoch,
                sessionRevision: session.snapshot.revision,
                isAvailable: session.isAvailable,
                isCancelled: Task.isCancelled
            )
    }
}
