import AuralDomain
import OSLog
import SwiftUI

struct RootView: View {
    let player: PlaybackStore
    let catalog: CatalogStore

    @SceneStorage("sidebarSelection") private var selectionRawValue = SidebarSelection.destination(.home).rawValue
    @State private var selectedMedia: CatalogItem?
    @SceneStorage("selectedMediaTitle") private var restoredMediaTitle = ""
    @SceneStorage("selectedMediaSubtitle") private var restoredMediaSubtitle = ""
    @SceneStorage("selectedMediaArtworkURL") private var restoredMediaArtworkURL = ""
    @State private var searchText = ""
    @SceneStorage("showsPlaybackInspector") private var showsSidePanel = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(selection: selectionBinding, playlists: catalog.homeLibrary.playlists)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
            } detail: {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationSplitViewStyle(.balanced)
            .inspector(isPresented: $showsSidePanel) {
                SidePanelView(
                    metadata: catalog.metadata,
                    player: player,
                    onClose: { showsSidePanel = false }
                )
                .inspectorColumnWidth(min: 220, ideal: 220, max: 220)
            }

            NowPlayingBar(player: player, showsSidePanel: $showsSidePanel)
        }
        .onChange(of: player.state.accountEpoch) {
            selectedMedia = nil
            clearRestoredMedia()
            selectionRawValue = SidebarSelection.destination(.home).rawValue
        }
        .onChange(of: selectionRawValue) {
            AuralLog.ui.info("Sidebar selection changed: \(selection.diagnosticLabel, privacy: .public)")
        }
        // Window-close artwork purging lives in AuralAppDelegate, which observes
        // NSWindow.willCloseNotification; adding a purge here would only duplicate it.
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case let .destination(destination):
            destinationView(destination)
        case let .playlist(uri):
            if let item = playlistItem(for: uri) {
                PlaylistDetailView(
                    item: item,
                    store: catalog.playlistStore,
                    metadata: catalog.metadata,
                    playback: catalogPlayback
                )
            } else if catalog.homeLibrary.isLoading(.playlists) {
                LoadingState(label: "Loading playlist")
            } else if let error = catalog.homeLibrary.error(for: .playlists) {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't restore this playlist",
                    message: error,
                    actionTitle: "Try Again",
                    actionSystemImage: "arrow.clockwise"
                ) {
                    Task { await catalog.homeLibrary.loadPlaylists() }
                }
                .padding(30)
            } else {
                unavailableMedia("Playlist", destination: .playlists)
            }
        case let .album(uri):
            if let item = selectedItem(uri: uri, kind: .album) {
                AlbumDetailView(
                    item: item,
                    store: catalog.albumStore,
                    metadata: catalog.metadata,
                    playback: catalogPlayback
                )
            } else {
                unavailableMedia("Album", destination: .albums)
            }
        case let .artist(uri):
            if let item = selectedItem(uri: uri, kind: .artist) {
                ArtistDetailView(
                    item: item,
                    store: catalog.artistStore,
                    playback: catalogPlayback,
                    onSelect: select
                )
            } else {
                unavailableMedia("Artist", destination: .artists)
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: SidebarDestination) -> some View {
        switch destination {
        case .home:
            HomeView(store: catalog.homeLibrary, playback: catalogPlayback, onSelect: select)
        case .search:
            SearchView(
                store: catalog.searchStore,
                metadata: catalog.metadata,
                playback: catalogPlayback,
                searchText: $searchText,
                onSelect: select
            )
        case .liked:
            TrackCollectionView(
                title: "Liked Songs",
                subtitle: catalogPlayback.isConnected
                    ? "Saved to your Spotify library"
                    : "Connect Spotify to load your saved tracks",
                tracks: catalog.homeLibrary.likedTracks,
                metadata: catalog.metadata,
                playback: catalogPlayback,
                reloadError: catalog.homeLibrary.error(for: .likedTracks),
                reload: { await catalog.homeLibrary.loadLikedTracks(force: true) },
                isLoading: catalog.homeLibrary.isLoading(.likedTracks),
                emptyIcon: "heart",
                emptyTitle: "No liked songs",
                emptyMessage: "Songs you save on Spotify will appear here."
            )
            .task(id: catalogPlayback.accountEpoch) {
                guard catalogPlayback.isConnected else { return }
                await catalog.homeLibrary.loadLikedTracks()
            }
        case .albums:
            LibraryView(
                title: "Albums",
                items: catalog.homeLibrary.albums,
                isLoading: catalog.homeLibrary.isLoading(.albums),
                error: catalog.homeLibrary.error(for: .albums),
                reload: { await catalog.homeLibrary.loadAlbums() },
                playback: catalogPlayback,
                onSelect: select
            )
        case .artists:
            LibraryView(
                title: "Artists",
                items: catalog.homeLibrary.artists,
                isLoading: catalog.homeLibrary.isLoading(.artists),
                error: catalog.homeLibrary.error(for: .artists),
                reload: { await catalog.homeLibrary.loadArtists() },
                playback: catalogPlayback,
                onSelect: select
            )
        case .playlists:
            LibraryView(
                title: "Playlists",
                items: catalog.homeLibrary.playlists,
                isLoading: catalog.homeLibrary.isLoading(.playlists),
                error: catalog.homeLibrary.error(for: .playlists),
                reload: { await catalog.homeLibrary.loadPlaylists() },
                playback: catalogPlayback,
                onSelect: select
            )
        }
    }

    private func select(_ item: CatalogItem) {
        switch item.kind {
        case .playlist:
            remember(item)
            selectedMedia = item
            selectionRawValue = SidebarSelection.playlist(item.uri).rawValue
        case .album:
            remember(item)
            selectedMedia = item
            selectionRawValue = SidebarSelection.album(item.uri).rawValue
        case .artist:
            remember(item)
            selectedMedia = item
            selectionRawValue = SidebarSelection.artist(item.uri).rawValue
        case .track, .unknown:
            catalogPlayback.playURI(item.uri)
        }
    }

    private func selectedItem(uri: String, kind: CatalogItem.Kind) -> CatalogItem? {
        if selectedMedia?.uri == uri, selectedMedia?.kind == kind {
            return selectedMedia
        }
        return catalog.metadata.knownItem(for: uri).flatMap { $0.kind == kind ? $0 : nil }
            ?? restoredItem(uri: uri, kind: kind)
    }

    private func unavailableMedia(
        _ kind: String,
        destination: SidebarDestination
    ) -> some View {
        EmptyState(
            icon: "questionmark.square.dashed",
            title: "\(kind) unavailable",
            message: "This item is no longer available in the loaded catalog.",
            actionTitle: "Show \(destination.rawValue)",
            actionSystemImage: "arrow.left"
        ) {
            selectionRawValue = SidebarSelection.destination(destination).rawValue
        }
        .padding(30)
    }

    private func playlistItem(for uri: String) -> CatalogItem? {
        return catalog.homeLibrary.playlists.first { $0.uri == uri }
            ?? (selectedMedia?.uri == uri && selectedMedia?.kind == .playlist ? selectedMedia : nil)
            ?? catalog.metadata.knownItem(for: uri).flatMap { $0.kind == .playlist ? $0 : nil }
            ?? restoredItem(uri: uri, kind: .playlist)
    }

    private var selection: SidebarSelection {
        SidebarSelection(rawValue: selectionRawValue) ?? .destination(.home)
    }

    private var catalogPlayback: CatalogPlaybackAccess {
        CatalogPlaybackAccess(player: player)
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: {
                let next = $0 ?? .destination(.home)
                let nextMediaURI: String? = switch next {
                case .destination: nil
                case let .playlist(uri), let .album(uri), let .artist(uri): uri
                }
                if nextMediaURI == nil || selectedMedia?.uri != nextMediaURI {
                    selectedMedia = nil
                    clearRestoredMedia()
                }
                selectionRawValue = next.rawValue
            }
        )
    }

    private func remember(_ item: CatalogItem) {
        restoredMediaTitle = item.title
        restoredMediaSubtitle = item.subtitle
        restoredMediaArtworkURL = item.artworkURL?.absoluteString ?? ""
    }

    private func clearRestoredMedia() {
        restoredMediaTitle = ""
        restoredMediaSubtitle = ""
        restoredMediaArtworkURL = ""
    }

    private func restoredItem(uri: String, kind: CatalogItem.Kind) -> CatalogItem? {
        guard !restoredMediaTitle.isEmpty else { return nil }
        return CatalogItem(
            id: SpotifyURI.id(from: uri) ?? uri,
            uri: uri,
            title: restoredMediaTitle,
            subtitle: restoredMediaSubtitle,
            artworkURL: restoredMediaArtworkURL.isEmpty ? nil : URL(string: restoredMediaArtworkURL),
            kind: kind
        )
    }
}
