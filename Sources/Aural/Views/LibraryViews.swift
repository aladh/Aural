import AuralDomain
import SwiftUI

private struct SearchLoadIdentity: Equatable {
    let query: String
    let accountEpoch: UInt64
    let isConnected: Bool
}

struct SearchView: View {
    let store: SearchStore
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    @Binding var searchText: String
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        Group {
            if !playback.isConnected {
                EmptyState(
                    icon: "person.crop.circle.badge.plus",
                    title: "Connect Spotify",
                    message: "Connect your Spotify Premium account to search its track catalog.",
                    actionTitle: "Connect Spotify",
                    actionSystemImage: "link"
                ) {
                    playback.connect()
                }
                .padding(30)
            } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyState(
                    icon: "magnifyingglass",
                    title: "Search Spotify",
                    message: "Find tracks, artists, albums, and playlists."
                )
                .padding(30)
            } else if store.isSearching && store.isEmpty {
                LoadingState(label: "Searching Spotify")
                    .padding(30)
            } else if let error = store.error, store.isEmpty {
                EmptyState(
                    icon: "exclamationmark.magnifyingglass",
                    title: "Couldn't search Spotify",
                    message: error,
                    actionTitle: "Try Again",
                    actionSystemImage: "arrow.clockwise"
                ) {
                    Task { await store.search(searchText) }
                }
                .padding(30)
            } else if store.isEmpty {
                EmptyState(
                    icon: "magnifyingglass",
                    title: "No results for “\(searchText)”",
                    message: "Try another track, artist, or album."
                )
                .padding(30)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if !store.failedSections.isEmpty {
                            partialFailureBanner
                        }
                        if !store.artists.isEmpty {
                            MediaShelf(
                                section: CatalogSection(id: "search-artists", title: "Artists", items: store.artists),
                                onSelect: onSelect
                            )
                        }
                        if !store.albums.isEmpty {
                            MediaShelf(
                                section: CatalogSection(id: "search-albums", title: "Albums", items: store.albums),
                                onSelect: onSelect
                            )
                        }
                        if !store.playlists.isEmpty {
                            MediaShelf(
                                section: CatalogSection(id: "search-playlists", title: "Playlists", items: store.playlists),
                                onSelect: onSelect
                            )
                        }
                        if !store.tracks.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Tracks").font(.title2.bold())
                                TrackTable(tracks: store.tracks, metadata: metadata, playback: playback)
                                    .frame(minHeight: 280)
                            }
                        }
                    }
                    .padding(30)
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Artists, albums, playlists, and tracks")
        .navigationTitle("Search")
        .task(id: SearchLoadIdentity(
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            accountEpoch: playback.accountEpoch,
            isConnected: playback.isConnected
        )) {
            guard playback.isConnected else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await store.search(searchText)
        }
    }

    private var partialFailureBanner: some View {
        HStack(spacing: 10) {
            Label(
                "Some results couldn't load: \(failedSectionNames)",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)

            Spacer()

            Button("Try Again", systemImage: "arrow.clockwise") {
                Task { await store.search(searchText) }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var failedSectionNames: String {
        store.failedSections.map { $0.rawValue.capitalized }.joined(separator: ", ")
    }
}

struct LibraryView: View {
    let title: String
    let items: [CatalogItem]
    let isLoading: Bool
    let error: String?
    let reload: () async -> Void
    let playback: CatalogPlaybackAccess
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        ScrollView {
            if isLoading && items.isEmpty {
                LoadingState(label: "Loading \(title.lowercased())")
                    .padding(30)
            } else if items.isEmpty {
                Group {
                    if !playback.isConnected {
                        EmptyState(
                            icon: "person.crop.circle.badge.plus",
                            title: "Connect Spotify",
                            message: "Your Spotify library will appear here after you connect.",
                            actionTitle: "Connect Spotify",
                            actionSystemImage: "link"
                        ) {
                            playback.connect()
                        }
                    } else if let error {
                        EmptyState(
                            icon: "exclamationmark.triangle",
                            title: "Couldn't load \(title.lowercased())",
                            message: error,
                            actionTitle: "Try Again",
                            actionSystemImage: "arrow.clockwise"
                        ) {
                            Task { await reload() }
                        }
                    } else {
                        EmptyState(
                            icon: "tray",
                            title: "No \(title.lowercased()) found",
                            message: "This part of your Spotify library is empty."
                        )
                    }
                }
                .padding(30)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 165, maximum: 210), spacing: 20)],
                    spacing: 24
                ) {
                    ForEach(items) { item in
                        MediaCard(item: item) { onSelect(item) }
                    }
                }
                .padding(30)
            }
        }
        .navigationTitle(title)
        .task(id: playback.accountEpoch) {
            guard playback.isConnected else { return }
            await reload()
        }
    }
}

struct TrackCollectionView: View {
    let title: String
    let subtitle: String
    let tracks: [CatalogTrack]
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    var reloadError: String? = nil
    var reload: () async -> Void = {}
    var isLoading = false
    var emptyIcon = "music.note"
    var emptyTitle: String? = nil
    var emptyMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(30)

            Divider()

            if isLoading && tracks.isEmpty {
                LoadingState(label: "Loading \(title.lowercased())")
            } else if tracks.isEmpty {
                if !playback.isConnected {
                    EmptyState(
                        icon: "person.crop.circle.badge.plus",
                        title: "Connect Spotify",
                        message: "Your Spotify tracks will appear after you connect.",
                        actionTitle: "Connect Spotify",
                        actionSystemImage: "link"
                    ) {
                        playback.connect()
                    }
                } else if let error = reloadError {
                    EmptyState(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't load tracks",
                        message: error,
                        actionTitle: "Try Again",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        Task { await reload() }
                    }
                } else {
                    EmptyState(
                        icon: emptyIcon,
                        title: emptyTitle ?? "No tracks to show",
                        message: emptyMessage ?? subtitle
                    )
                }
            } else {
                TrackTable(tracks: tracks, metadata: metadata, playback: playback)
            }
        }
        .navigationTitle(title)
    }
}
