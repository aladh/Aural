import AuralDomain
import SwiftUI

private struct MediaDetailLoadIdentity: Equatable {
    let uri: String
    let accountEpoch: UInt64
    let isConnected: Bool
}

struct AlbumDetailView: View {
    let item: CatalogItem
    let store: AlbumDetailStore
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    var playlistActions: TrackPlaylistActions? = nil

    var body: some View {
        VStack(spacing: 0) {
            MediaDetailHeader(
                item: item,
                detail: store.releaseDate,
                canPlay: playback.canStartPlayback
            ) {
                playback.playURI(item.uri)
            }
            Divider()
            if store.isLoading && store.tracks.isEmpty {
                LoadingState(label: "Loading album")
            } else if let error = store.error, store.tracks.isEmpty {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't load album",
                    message: error,
                    actionTitle: "Try Again",
                    actionSystemImage: "arrow.clockwise"
                ) { Task { await store.load(item) } }
            } else if store.tracks.isEmpty {
                EmptyState(icon: "square.stack", title: "No tracks", message: "Spotify returned an empty album.")
            } else {
                TrackTable(
                    tracks: store.trackCollection,
                    metadata: metadata,
                    playback: playback,
                    playlistActions: playlistActions
                )
            }
        }
        .navigationTitle(item.title)
        .task(
            id: MediaDetailLoadIdentity(
                uri: item.uri,
                accountEpoch: playback.accountEpoch,
                isConnected: playback.isConnected
            )
        ) {
            guard playback.isConnected else { return }
            await store.load(item)
        }
    }
}

struct ArtistDetailView: View {
    let item: CatalogItem
    let store: ArtistDetailStore
    let playback: CatalogPlaybackAccess
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            MediaDetailHeader(item: item, canPlay: playback.canStartPlayback) {
                playback.playURI(item.uri)
            }
            Divider()
            if store.isLoading && store.releases.isEmpty {
                LoadingState(label: "Loading artist")
            } else if let error = store.error, store.releases.isEmpty {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't load artist",
                    message: error,
                    actionTitle: "Try Again",
                    actionSystemImage: "arrow.clockwise"
                ) { Task { await store.load(item) } }
            } else if store.releases.isEmpty {
                EmptyState(
                    icon: "person.wave.2", title: "No releases",
                    message: "Spotify returned no releases for this artist.")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: MediaGridLayout.columns,
                        alignment: .leading,
                        spacing: 24
                    ) {
                        ForEach(store.releases) { release in
                            MediaCard(item: release) { onSelect(release) }
                        }
                    }
                    .padding(30)
                }
            }
        }
        .navigationTitle(item.title)
        .task(
            id: MediaDetailLoadIdentity(
                uri: item.uri,
                accountEpoch: playback.accountEpoch,
                isConnected: playback.isConnected
            )
        ) {
            guard playback.isConnected else { return }
            await store.load(item)
        }
    }
}
