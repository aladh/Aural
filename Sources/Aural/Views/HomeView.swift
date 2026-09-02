import AuralDomain
import SwiftUI

struct HomeView: View {
    let store: HomeLibraryStore
    let playback: CatalogPlaybackAccess
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if store.isLoading(.home) && store.homeSections.isEmpty {
                    LoadingState(label: "Loading your Spotify home")
                } else if !playback.isConnected {
                    EmptyState(
                        icon: "music.note.house",
                        title: "Your music will appear here",
                        message: "Connect a Spotify Premium account to load Home and your library.",
                        actionTitle: "Connect Spotify",
                        actionSystemImage: "link"
                    ) {
                        playback.connect()
                    }
                } else if store.homeSections.isEmpty {
                    if let error = store.error(for: .home) {
                        EmptyState(
                            icon: "exclamationmark.triangle",
                            title: "Couldn't load Spotify Home",
                            message: error,
                            actionTitle: "Try Again",
                            actionSystemImage: "arrow.clockwise"
                        ) {
                            Task { await store.loadHome(force: true) }
                        }
                    } else {
                        EmptyState(
                            icon: "rectangle.stack",
                            title: "Spotify Home is empty",
                            message: "Spotify didn't return any recommendations."
                        )
                    }
                } else {
                    HStack {
                        Text(store.greeting)
                            .font(.system(size: 30, weight: .bold))
                        Spacer()
                        if store.isLoading(.home) {
                            ProgressView()
                                .controlSize(.small)
                                .help("Refreshing Spotify")
                        }
                    }
                    .padding(.bottom, -6)

                    ForEach(store.homeSections) { section in
                        MediaShelf(section: section, onSelect: onSelect)
                    }
                }
            }
            .padding(.horizontal, CatalogLayout.contentPadding)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
        .navigationTitle("Home")
    }
}

struct MediaShelf: View {
    let section: CatalogSection
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title3.weight(.bold))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(section.items) { item in
                        MediaCard(item: item) { onSelect(item) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct MediaCard: View {
    let item: CatalogItem
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RemoteArtwork(
                    url: item.artworkURL,
                    kind: item.kind,
                    cornerRadius: item.kind == .artist ? CatalogLayout.cardArtwork / 2 : 10,
                    pointSize: CatalogLayout.cardArtwork
                )
                .frame(width: CatalogLayout.cardArtwork, height: CatalogLayout.cardArtwork)
                .shadow(color: .black.opacity(isHovering ? 0.18 : 0.08), radius: isHovering ? 10 : 5, y: 4)

                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.subtitle.isEmpty ? item.kind.rawValue : item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: CatalogLayout.cardWidth, alignment: .leading)
            .padding(CatalogLayout.cardPadding)
            .contentShape(RoundedRectangle(cornerRadius: CatalogLayout.cardCornerRadius, style: .continuous))
            .background(
                Color.primary.opacity(isHovering ? 0.055 : 0),
                in: RoundedRectangle(cornerRadius: CatalogLayout.cardCornerRadius, style: .continuous)
            )
            .scaleEffect(isHovering && !reduceMotion ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // A card scrolled away under a resting cursor keeps no highlight.
        .onDisappear { isHovering = false }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isHovering)
        .help(item.kind == .track ? "Play \(item.title)" : "Open \(item.title)")
        .accessibilityLabel("\(item.title), \(item.subtitle.isEmpty ? item.kind.rawValue : item.subtitle)")
        .accessibilityHint(item.kind == .track ? "Starts playback" : "Opens details")
    }
}
