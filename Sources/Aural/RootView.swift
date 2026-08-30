import AuralDomain
import OSLog
import SwiftUI

struct RootView: View {
    let player: PlaybackStore
    let catalog: CatalogStore
    let feedback: TransientFeedbackPresenter

    @SceneStorage("sidebarSelection") private var mediaSelectionRawValue = MediaSelectionModel().rawValue
    @SceneStorage("selectedMediaTitle") private var legacyMediaTitle = ""
    @SceneStorage("selectedMediaSubtitle") private var legacyMediaSubtitle = ""
    @SceneStorage("selectedMediaArtworkURL") private var legacyMediaArtworkURL = ""
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
            .overlay(alignment: .bottom) {
                TransientFeedbackBanner(feedback: feedback)
            }

            NowPlayingBar(player: player, showsSidePanel: $showsSidePanel)
        }
        .onChange(of: player.state.accountEpoch) {
            resetMediaSelection()
        }
        .onAppear(perform: migrateLegacyMediaSelection)
        .onChange(of: mediaSelectionRawValue) {
            AuralLog.ui.info("Sidebar selection changed: \(mediaSelection.diagnosticLabel, privacy: .public)")
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
                    playback: catalogPlayback,
                    playlistActions: playlistActions(removingFrom: item)
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
                    playback: catalogPlayback,
                    playlistActions: playlistActions()
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
                onSelect: select,
                playlistActions: playlistActions()
            )
        case .liked:
            TrackCollectionView(
                title: "Liked Songs",
                subtitle: catalogPlayback.isConnected
                    ? "Saved to your Spotify library"
                    : "Connect Spotify to load your saved tracks",
                tracks: catalog.homeLibrary.likedTrackCollection,
                metadata: catalog.metadata,
                playback: catalogPlayback,
                reloadError: catalog.homeLibrary.error(for: .likedTracks),
                reload: { await catalog.homeLibrary.loadLikedTracks(force: true) },
                isLoading: catalog.homeLibrary.isLoading(.likedTracks),
                emptyIcon: "heart",
                emptyTitle: "No liked songs",
                emptyMessage: "Songs you save on Spotify will appear here.",
                playlistActions: playlistActions()
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
        var model = mediaSelection
        switch model.select(item) {
        case .navigate:
            mediaSelectionRawValue = model.rawValue
        case let .play(uri):
            catalogPlayback.playURI(uri)
        }
    }

    private func selectedItem(uri: String, kind: CatalogItem.Kind) -> CatalogItem? {
        mediaSelection.item(
            uri: uri,
            kind: kind,
            metadataItem: catalog.metadata.knownItem(for: uri)
        )
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
            updateMediaSelection { $0.updateSelection(.destination(destination)) }
        }
        .padding(30)
    }

    private func playlistItem(for uri: String) -> CatalogItem? {
        mediaSelection.item(
            uri: uri,
            kind: .playlist,
            playlists: catalog.homeLibrary.playlists,
            metadataItem: catalog.metadata.knownItem(for: uri)
        )
    }

    private var selection: SidebarSelection {
        mediaSelection.selection
    }

    private var mediaSelection: MediaSelectionModel {
        MediaSelectionModel(rawValue: mediaSelectionRawValue) ?? MediaSelectionModel()
    }

    private var catalogPlayback: CatalogPlaybackAccess {
        CatalogPlaybackAccess(player: player)
    }

    private func playlistActions(removingFrom openPlaylist: CatalogItem? = nil) -> TrackPlaylistActions {
        TrackPlaylistActions(
            editablePlaylists: catalog.playlistMutations.editableLibraryPlaylists,
            canRemoveOccurrences: openPlaylist.map { catalog.playlistMutations.isOpenPlaylistEditable($0) } ?? false,
            addToPlaylist: { playlist, tracks in
                catalog.playlistMutations.addTracks(tracks, to: playlist)
            },
            removeOccurrences: { ids in
                guard let openPlaylist else { return }
                catalog.playlistMutations.removeOccurrences(selectedIDs: Set(ids), from: openPlaylist)
            }
        )
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { selection in
                updateMediaSelection { $0.updateSelection(selection) }
            }
        )
    }

    private func updateMediaSelection(_ update: (inout MediaSelectionModel) -> Void) {
        var model = mediaSelection
        update(&model)
        mediaSelectionRawValue = model.rawValue
    }

    private func migrateLegacyMediaSelection() {
        var model = mediaSelection
        guard
            model.migrateLegacyMetadata(
                title: legacyMediaTitle,
                subtitle: legacyMediaSubtitle,
                artworkURL: legacyMediaArtworkURL
            )
        else { return }
        mediaSelectionRawValue = model.rawValue
        legacyMediaTitle = ""
        legacyMediaSubtitle = ""
        legacyMediaArtworkURL = ""
    }

    private func resetMediaSelection() {
        updateMediaSelection { $0.reset() }
        legacyMediaTitle = ""
        legacyMediaSubtitle = ""
        legacyMediaArtworkURL = ""
    }
}
