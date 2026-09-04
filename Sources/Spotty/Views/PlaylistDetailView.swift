import SpottyDomain
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
            MediaDetailHeader(
                item: item,
                description: store.description,
                detail: playlistMetadataText ?? "",
                style: .playlist
            )

            PlaylistDetailActionStrip(canPlay: playback.canStartPlayback) {
                playback.playPlaylist(item)
            }

            CatalogTableDivider()

            playlistContent
        }
        .task(
            id: PlaylistLoadIdentity(
                uri: item.uri,
                accountEpoch: playback.accountEpoch,
                isConnected: playback.isConnected
            )
        ) {
            guard playback.isConnected else { return }
            await store.load(item)
        }
        .navigationTitle(item.title)
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
            VStack(spacing: 0) {
                if store.error != nil {
                    staleRefreshWarning
                    CatalogTableDivider()
                }
                TrackTable(
                    tracks: store.trackCollection,
                    metadata: metadata,
                    playback: playback,
                    variant: .playlist,
                    playlistActions: playlistActions
                )
                .id(item.uri)
            }
        }
    }

    private var staleRefreshWarning: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Couldn't refresh this playlist. The songs shown may be out of date.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                Task { await store.load(item, force: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.isLoading)
            .accessibilityHint("Reload the playlist without repeating the last change.")
        }
        .padding(.horizontal, CatalogLayout.contentPadding)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private var showsPlaylistMetadata: Bool {
        store.loadedURI == item.uri
            && !store.isLoading
            && store.error == nil
    }

    private var songCountText: String {
        let count = store.tracks.count
        return "\(count) \(count == 1 ? "song" : "songs")"
    }

    private var totalDuration: TimeInterval {
        store.tracks.reduce(0) { total, track in
            total + TimeInterval(roundedCatalogDurationSeconds(track.duration))
        }
    }

    private var playlistMetadataText: String? {
        guard showsPlaylistMetadata else { return nil }
        return [songCountText, formatPlaylistDuration(totalDuration)].joined(separator: " · ")
    }

}

private struct PlaylistDetailActionStrip: View {
    let canPlay: Bool
    let play: () -> Void

    var body: some View {
        HStack {
            CircularPlayButton(action: play, isEnabled: canPlay)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CatalogLayout.contentPadding)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
        .background(SpottyPalette.catalogCanvas)
    }
}

func formatPlaylistDuration(_ interval: TimeInterval) -> String {
    let totalSeconds = roundedCatalogDurationSeconds(interval)
    let hours = totalSeconds / 3_600
    if hours > 0 {
        let minutes = (totalSeconds % 3_600) / 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    if minutes == 0 {
        return "\(seconds) sec"
    }
    if seconds == 0 {
        return "\(minutes) min"
    }
    return "\(minutes) min \(seconds) sec"
}
