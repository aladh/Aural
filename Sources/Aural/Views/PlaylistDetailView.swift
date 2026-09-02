import AuralDomain
import SwiftUI

private struct PlaylistLoadIdentity: Equatable {
    let uri: String
    let accountEpoch: UInt64
    let isConnected: Bool
}

struct PlaylistDetailView: View {
    let item: CatalogItem
    @Bindable var store: PlaylistStore
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    let playlistActions: TrackPlaylistActions

    var body: some View {
        VStack(spacing: 0) {
            hero
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 28)
                .padding(.bottom, 22)

            Divider()

            playlistContent
        }
        .background { CatalogCanvasBackground() }
        .task(id: PlaylistLoadIdentity(
            uri: item.uri,
            accountEpoch: playback.accountEpoch,
            isConnected: playback.isConnected
        )) {
            guard playback.isConnected else { return }
            await store.load(item)
        }
        .navigationTitle(item.title)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 26) {
                RemoteArtwork(url: item.artworkURL, kind: .playlist, cornerRadius: 10, pointSize: 220)
                    .frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

                VStack(alignment: .leading, spacing: 10) {
                    Text("PLAYLIST")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)

                    Text(item.title)
                        .font(.system(size: 42, weight: .bold, design: .default))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    if !store.description.isEmpty {
                        Text(store.description)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        Text(item.subtitle)
                            .fontWeight(.medium)

                        if showsSongCount {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(songCountText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
                .padding(.bottom, 6)
            }

            CircularPlayButton {
                playback.playPlaylist(item)
            }
            .disabled(!playback.canStartPlayback)
        }
    }

    @ViewBuilder
    private var playlistContent: some View {
        if !playback.isConnected && store.tracks.isEmpty {
            VStack(spacing: 14) {
                ContentUnavailableView(
                    "Reconnect to load this playlist",
                    systemImage: "wifi.exclamationmark",
                    description: Text(playback.statusText)
                )
                Button("Reconnect") { playback.connect() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if store.isLoading && store.tracks.isEmpty {
            LoadingState(label: "Loading \(item.title)")
        } else if let error = store.error, store.tracks.isEmpty {
            EmptyState(
                icon: "exclamationmark.triangle",
                title: "Couldn't load this playlist",
                message: error,
                actionTitle: "Try Again",
                actionSystemImage: "arrow.clockwise"
            ) {
                Task { await store.load(item) }
            }
        } else if store.tracks.isEmpty {
            EmptyState(
                icon: "music.note.list",
                title: "This playlist is empty",
                message: "Spotify returned no playable tracks."
            )
        } else {
            TrackTable(
                tracks: store.tracks,
                metadata: metadata,
                playback: playback,
                showsDateAdded: true,
                playlistActions: playlistActions
            )
        }
    }

    private var showsSongCount: Bool {
        store.loadedURI == item.uri
            && !store.isLoading
            && store.error == nil
    }

    private var songCountText: String {
        let count = store.tracks.count
        return "\(count) \(count == 1 ? "song" : "songs")"
    }
}
