import AuralDomain
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    let playlists: [CatalogItem]

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "house.fill")
                    .tag(SidebarSelection.destination(.home))
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarSelection.destination(.search))
            }

            Section("Your Library") {
                Label("Liked Songs", systemImage: "heart.fill")
                    .tag(SidebarSelection.destination(.liked))
                Label("Albums", systemImage: "square.stack.fill")
                    .tag(SidebarSelection.destination(.albums))
                Label("Artists", systemImage: "music.mic")
                    .tag(SidebarSelection.destination(.artists))
                Label("Playlists", systemImage: "music.note.list")
                    .tag(SidebarSelection.destination(.playlists))
            }

            if !playlists.isEmpty {
                Section("Shortcuts") {
                    ForEach(playlists.prefix(3)) { playlist in
                        Text(playlist.title)
                            .lineLimit(1)
                            .tag(SidebarSelection.playlist(playlist.uri))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
