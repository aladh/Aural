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
            MediaDetailHeader(item: item, detail: store.releaseDate, playback: playback)
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
                    tracks: store.tracks,
                    metadata: metadata,
                    playback: playback,
                    playlistActions: playlistActions
                )
            }
        }
        .background { CatalogCanvasBackground() }
        .navigationTitle(item.title)
        .task(id: MediaDetailLoadIdentity(
            uri: item.uri,
            accountEpoch: playback.accountEpoch,
            isConnected: playback.isConnected
        )) {
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
            MediaDetailHeader(item: item, detail: "", playback: playback)
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
                EmptyState(icon: "person.wave.2", title: "No releases", message: "Spotify returned no releases for this artist.")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 165, maximum: 210), spacing: 20)],
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
        .background { CatalogCanvasBackground() }
        .navigationTitle(item.title)
        .task(id: MediaDetailLoadIdentity(
            uri: item.uri,
            accountEpoch: playback.accountEpoch,
            isConnected: playback.isConnected
        )) {
            guard playback.isConnected else { return }
            await store.load(item)
        }
    }
}

private struct MediaDetailHeader: View {
    let item: CatalogItem
    let detail: String
    let playback: CatalogPlaybackAccess

    var body: some View {
        HStack(alignment: .bottom, spacing: 26) {
            RemoteArtwork(
                url: item.artworkURL,
                kind: item.kind,
                cornerRadius: item.kind == .artist ? 92 : 10,
                pointSize: 184
            )
            .frame(width: 184, height: 184)
            .shadow(color: .black.opacity(0.26), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(item.kind.rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Text(item.title)
                    .font(.system(size: 42, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                let supportingText = [item.subtitle, detail].filter {
                    !$0.isEmpty && $0.caseInsensitiveCompare(item.kind.rawValue) != .orderedSame
                }.joined(separator: " · ")
                if !supportingText.isEmpty {
                    Text(supportingText)
                        .foregroundStyle(.secondary)
                }
                CircularPlayButton {
                    playback.playURI(item.uri)
                }
                .disabled(!playback.canStartPlayback)
                .accessibilityHint("Starts this \(item.kind.rawValue.lowercased())")
            }
            .padding(.bottom, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }
}
