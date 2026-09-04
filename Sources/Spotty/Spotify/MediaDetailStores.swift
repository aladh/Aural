//
//  MediaDetailStores.swift
//  Spotty
//
//  Account- and selection-scoped album and artist browsing state.
//

import SpottyDomain
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
    @ObservationIgnored private let lifetime: MediaDetailRequestLifetime

    init(provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
        lifetime = MediaDetailRequestLifetime(session: session)
    }

    func reset() {
        lifetime.reset()
        item = nil
        trackCollection.replace([])
        releaseDate = ""
        isLoading = false
        error = nil
    }

    func load(_ selected: CatalogItem) async {
        guard session.isAvailable, selected.kind == .album else { return }
        switch lifetime.admit(uri: selected.uri) {
        case .skip:
            return
        case let .join(claim):
            await lifetime.awaitFlight(claim)
        case let .start(handle):
            item = selected
            trackCollection.replace([])
            releaseDate = ""
            error = nil
            isLoading = true
            guard let id = SpotifyURI.id(from: selected.uri, kind: "album") else {
                error = "Spotify returned an invalid album address."
                isLoading = false
                lifetime.abandonUnstarted(handle)
                return
            }
            await lifetime.run(handle) { [weak self] in
                guard let self else { return }
                defer {
                    if self.lifetime.owns(handle) {
                        isLoading = false
                    }
                }
                do {
                    let album = try await provider.album(id: id)
                    guard self.lifetime.isCurrent(handle, selectedURI: self.item?.uri) else { return }
                    trackCollection.replace(
                        album.tracks.compactMap { CatalogMapping.albumTrack(from: $0, album: album) }
                    )
                    releaseDate = album.date?.day ?? ""
                    self.lifetime.markLoaded(handle)
                    metadata.replaceTracks(tracks, from: .album)
                    metadata.loadTrackAttributes(for: tracks)
                } catch {
                    guard !isCancellation(error), self.lifetime.isCurrent(handle, selectedURI: self.item?.uri) else {
                        return
                    }
                    self.error = error.localizedDescription
                }
            }
        }
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
    @ObservationIgnored private let lifetime: MediaDetailRequestLifetime

    init(provider: any CatalogProviding, session: CatalogSessionAvailability) {
        self.provider = provider
        self.session = session
        lifetime = MediaDetailRequestLifetime(session: session)
    }

    func reset() {
        lifetime.reset()
        item = nil
        releases = []
        isLoading = false
        error = nil
    }

    func load(_ selected: CatalogItem) async {
        guard session.isAvailable, selected.kind == .artist else { return }
        switch lifetime.admit(uri: selected.uri) {
        case .skip:
            return
        case let .join(claim):
            await lifetime.awaitFlight(claim)
        case let .start(handle):
            item = selected
            releases = []
            error = nil
            isLoading = true
            guard let id = SpotifyURI.id(from: selected.uri, kind: "artist") else {
                error = "Spotify returned an invalid artist address."
                isLoading = false
                lifetime.abandonUnstarted(handle)
                return
            }
            await lifetime.run(handle) { [weak self] in
                guard let self else { return }
                defer {
                    if self.lifetime.owns(handle) {
                        isLoading = false
                    }
                }
                do {
                    async let overview = provider.artist(id: id)
                    async let discography = provider.artistDiscography(id: id)
                    let (profile, allReleases) = try await (overview, discography)
                    guard self.lifetime.isCurrent(handle, selectedURI: self.item?.uri) else { return }
                    let artistName = profile.profile?.name ?? selected.title
                    releases = allReleases.releases.compactMap { CatalogMapping.item(from: $0, artist: artistName) }
                    self.lifetime.markLoaded(handle)
                } catch {
                    guard !isCancellation(error), self.lifetime.isCurrent(handle, selectedURI: self.item?.uri) else {
                        return
                    }
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
