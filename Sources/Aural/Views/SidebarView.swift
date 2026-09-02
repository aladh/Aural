import AuralDomain
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    let playlists: [CatalogItem]
    @State private var sidebarWidth: CGFloat = 0

    var body: some View {
        List(selection: $selection) {
            Section {
                sidebarDestination("Home", systemImage: "house.fill", destination: .home)
                    .tag(SidebarSelection.destination(.home))
                sidebarDestination("Search", systemImage: "magnifyingglass", destination: .search)
                    .tag(SidebarSelection.destination(.search))
            }

            Section("Your Library") {
                sidebarDestination("Liked Songs", systemImage: "heart.fill", destination: .liked)
                    .tag(SidebarSelection.destination(.liked))
                sidebarDestination("Albums", systemImage: "square.stack.fill", destination: .albums)
                    .tag(SidebarSelection.destination(.albums))
                sidebarDestination("Artists", systemImage: "music.mic", destination: .artists)
                    .tag(SidebarSelection.destination(.artists))
                sidebarDestination("Playlists", systemImage: "music.note.list", destination: .playlists)
                    .tag(SidebarSelection.destination(.playlists))
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists.prefix(3)) { playlist in
                        playlistRow(
                            playlist,
                            showsSubtitle: sidebarWidth >= CatalogLayout.sidebarCompactSubtitleThreshold
                        )
                        .tag(SidebarSelection.playlist(playlist.uri))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
        .environment(\.defaultMinListRowHeight, 34)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            guard newWidth > 0 else { return }
            sidebarWidth = newWidth
        }
    }

    private func sidebarDestination(
        _ title: String,
        systemImage: String,
        destination: SidebarDestination
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.body.weight(selection == .destination(destination) ? .semibold : .regular))
            .accessibilityAddTraits(selection == .destination(destination) ? .isSelected : [])
    }

    private func playlistRow(_ playlist: CatalogItem, showsSubtitle: Bool) -> some View {
        HStack(spacing: 10) {
            RemoteArtwork(
                url: playlist.artworkURL,
                kind: .playlist,
                cornerRadius: 5,
                pointSize: 34
            )
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.title)
                    .font(.body.weight(selection == .playlist(playlist.uri) ? .semibold : .regular))
                    .lineLimit(1)

                if showsSubtitle {
                    Text(playlist.subtitle.isEmpty ? "Playlist" : playlist.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection == .playlist(playlist.uri) ? .isSelected : [])
        .accessibilityLabel(playlist.title)
        .accessibilityValue(
            showsSubtitle ? (playlist.subtitle.isEmpty ? "Playlist" : playlist.subtitle) : ""
        )
    }
}
