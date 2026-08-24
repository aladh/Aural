//
//  PlaylistStore.swift
//  Aural
//
//  Selected-playlist detail and sorting state.
//

import AuralDomain
import Foundation

@MainActor
@Observable
final class PlaylistStore {
    var tracks: [CatalogTrack] = []
    var dateSort: PlaylistDateSort = .playlistOrder {
        didSet {
            guard oldValue != dateSort else { return }
            resortTracks()
        }
    }
    private(set) var sortedTracks: [CatalogTrack] = []
    var description = ""
    private(set) var loadedURI: String?
    var isLoading = false
    var error: String?

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private var requestScope: UInt64 = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadSessionSnapshot: CatalogSessionSnapshot?

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
        tracks = []
        sortedTracks = []
        dateSort = .playlistOrder
        description = ""
        loadedURI = nil
        isLoading = false
        error = nil
        metadata.replaceTracks([], from: .playlist)
    }

    func load(_ item: CatalogItem) async {
        let currentSession = session.snapshot
        guard currentSession.isAvailable, item.kind == .playlist else { return }
        if loadedURI == item.uri, !tracks.isEmpty { return }
        if isLoading,
           loadedURI == item.uri,
           loadSessionSnapshot == currentSession,
           let loadTask {
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
        tracks = []
        sortedTracks = []
        description = ""
        error = nil
        isLoading = true
        metadata.replaceTracks([], from: .playlist)
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
            description = PlaylistDescription.plainText(from: playlist.description ?? "")
            if isNewPlaylist {
                dateSort = .playlistOrder
            }
            let entries = playlist.content.flatMap(\.items) ?? []
            tracks = entries.compactMap(CatalogMapping.playlistTrack(from:))
            resortTracks()
            metadata.replaceTracks(tracks, from: .playlist)
            metadata.loadTrackAttributes(for: tracks)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard isCurrent(identity, uri: item.uri) else { return }
            self.error = error.localizedDescription
        }
    }

    private func isCurrent(
        _ identity: AccountScopedRequestIdentity,
        uri: String
    ) -> Bool {
        loadedURI == uri && identity.isCurrent(
            requestID: requestScope,
            accountEpoch: session.accountEpoch,
            sessionRevision: session.snapshot.revision,
            isAvailable: session.isAvailable,
            isCancelled: Task.isCancelled
        )
    }

    private func resortTracks() {
        sortedTracks = switch dateSort {
        case .playlistOrder:
            tracks
        case .newestFirst:
            sortedByDateAdded(tracks, newestFirst: true)
        case .oldestFirst:
            sortedByDateAdded(tracks, newestFirst: false)
        }
    }
}
