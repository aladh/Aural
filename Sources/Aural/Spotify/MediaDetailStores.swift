//
//  MediaDetailStores.swift
//  Aural
//
//  Account- and selection-scoped album and artist browsing state.
//

import AuralDomain
import Foundation

@MainActor
@Observable
final class AlbumDetailStore {
    private(set) var item: CatalogItem?
    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    private(set) var releaseDate = ""
    private(set) var isLoading = false
    private(set) var error: String?

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private var requestID: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadedSession: CatalogSessionSnapshot?

    init(provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
    }

    func reset() {
        requestID &+= 1
        task?.cancel()
        task = nil
        loadedSession = nil
        item = nil
        trackCollection.replace([])
        releaseDate = ""
        isLoading = false
        error = nil
    }

    func load(_ selected: CatalogItem) async {
        guard session.isAvailable, selected.kind == .album else { return }
        let currentSession = session.snapshot
        if item?.uri == selected.uri, loadedSession == currentSession { return }
        requestID &+= 1
        let currentID = requestID
        let identity = session.requestIdentity(requestID: currentID)
        task?.cancel()
        task = nil
        loadedSession = nil
        item = selected
        trackCollection.replace([])
        releaseDate = ""
        error = nil
        isLoading = true
        guard let id = SpotifyURI.id(from: selected.uri, kind: "album") else {
            error = "Spotify returned an invalid album address."
            isLoading = false
            return
        }
        let newTask = Task { [weak self] in
            guard let self else { return }
            do {
                let album = try await provider.album(id: id)
                guard self.isCurrent(identity, uri: selected.uri) else { return }
                trackCollection.replace(
                    album.tracks.compactMap { CatalogMapping.albumTrack(from: $0, album: album) }
                )
                releaseDate = album.date?.day ?? ""
                loadedSession = currentSession
                metadata.replaceTracks(tracks, from: .album)
                metadata.loadTrackAttributes(for: tracks)
            } catch {
                guard !isCancellation(error), self.isCurrent(identity, uri: selected.uri) else { return }
                self.error = error.localizedDescription
            }
            if currentID == requestID {
                isLoading = false
                task = nil
            }
        }
        task = newTask
        await withTaskCancellationHandler {
            await newTask.value
        } onCancel: {
            newTask.cancel()
        }
    }

    private func isCurrent(_ identity: AccountScopedRequestIdentity, uri: String) -> Bool {
        item?.uri == uri && identity.isCurrent(
            requestID: requestID,
            accountEpoch: session.accountEpoch,
            sessionRevision: session.snapshot.revision,
            isAvailable: session.isAvailable,
            isCancelled: Task.isCancelled
        )
    }
}

@MainActor
@Observable
final class ArtistDetailStore {
    private(set) var item: CatalogItem?
    private(set) var releases: [CatalogItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private var requestID: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadedSession: CatalogSessionSnapshot?

    init(provider: any CatalogProviding, session: CatalogSessionAvailability) {
        self.provider = provider
        self.session = session
    }

    func reset() {
        requestID &+= 1
        task?.cancel()
        task = nil
        loadedSession = nil
        item = nil
        releases = []
        isLoading = false
        error = nil
    }

    func load(_ selected: CatalogItem) async {
        guard session.isAvailable, selected.kind == .artist else { return }
        let currentSession = session.snapshot
        if item?.uri == selected.uri, loadedSession == currentSession { return }
        requestID &+= 1
        let currentID = requestID
        let identity = session.requestIdentity(requestID: currentID)
        task?.cancel()
        task = nil
        loadedSession = nil
        item = selected
        releases = []
        error = nil
        isLoading = true
        guard let id = SpotifyURI.id(from: selected.uri, kind: "artist") else {
            error = "Spotify returned an invalid artist address."
            isLoading = false
            return
        }
        let newTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let overview = provider.artist(id: id)
                async let discography = provider.artistDiscography(id: id)
                let (profile, allReleases) = try await (overview, discography)
                guard self.isCurrent(identity, uri: selected.uri) else { return }
                let artistName = profile.profile?.name ?? selected.title
                releases = allReleases.releases.compactMap { CatalogMapping.item(from: $0, artist: artistName) }
                loadedSession = currentSession
            } catch {
                guard !isCancellation(error), self.isCurrent(identity, uri: selected.uri) else { return }
                self.error = error.localizedDescription
            }
            if currentID == requestID {
                isLoading = false
                task = nil
            }
        }
        task = newTask
        await withTaskCancellationHandler {
            await newTask.value
        } onCancel: {
            newTask.cancel()
        }
    }

    private func isCurrent(_ identity: AccountScopedRequestIdentity, uri: String) -> Bool {
        item?.uri == uri && identity.isCurrent(
            requestID: requestID,
            accountEpoch: session.accountEpoch,
            sessionRevision: session.snapshot.revision,
            isAvailable: session.isAvailable,
            isCancelled: Task.isCancelled
        )
    }
}
