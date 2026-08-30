import AuralDomain
import SwiftUI

private struct PlaylistLoadIdentity: Equatable {
    let uri: String
    let accountEpoch: UInt64
    let isConnected: Bool
}

struct PlaylistDetailView: View {
    let item: CatalogItem
    let store: PlaylistStore
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    let playlistActions: TrackPlaylistActions

    var body: some View {
        VStack(spacing: 0) {
            hero
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 16)
                .padding(.bottom, 24)

            Divider()

            playlistContent
        }
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
        HStack(alignment: .bottom, spacing: 24) {
            RemoteArtwork(url: item.artworkURL, kind: .playlist, cornerRadius: 16, pointSize: 184)
                .frame(width: 184, height: 184)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 9) {
                Text("PLAYLIST")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(item.title)
                    .font(.largeTitle.bold())
                    .lineLimit(2)

                if !store.description.isEmpty {
                    Text(store.description)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
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

                Button {
                    playback.playPlaylist(item)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .controlSize(.large)
                .disabled(!playback.canStartPlayback)
            }
            .padding(.bottom, 3)
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
                tracks: store.trackCollection,
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
