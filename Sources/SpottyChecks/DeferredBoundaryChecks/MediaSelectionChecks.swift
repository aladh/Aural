import SpottyDomain
import Foundation
@testable import SpottyCore

@MainActor
func runMediaSelectionChecks(_ runner: CheckRunner) {
    runner.suite("Media selection restoration") {
        let uri = "spotify:playlist:remembered-private-id"
        let remembered = item(uri: uri, title: "Remembered", kind: .playlist)
        var model = MediaSelectionModel()

        runner.equal("playlist selection navigates", model.select(remembered), .navigate)
        runner.equal("playlist selection is retained", model.selection, .playlist(uri))

        let restored = MediaSelectionModel(rawValue: model.rawValue)
        runner.equal("persisted selection round-trips", restored?.selection, .playlist(uri))
        runner.equal(
            "remembered metadata round-trips",
            restored?.item(uri: uri, kind: .playlist, metadataItem: nil),
            remembered
        )

        let metadata = item(uri: uri, title: "Metadata", kind: .playlist)
        runner.equal(
            "metadata supersedes remembered fallback",
            restored?.item(uri: uri, kind: .playlist, metadataItem: metadata),
            metadata
        )

        let library = item(uri: uri, title: "Library", kind: .playlist)
        runner.equal(
            "library playlist has first precedence",
            restored?.item(
                uri: uri,
                kind: .playlist,
                playlists: [library],
                metadataItem: metadata
            ),
            library
        )

        var sameSelection = restored ?? MediaSelectionModel()
        sameSelection.updateSelection(.playlist(uri))
        runner.equal(
            "same selection preserves remembered fallback",
            sameSelection.item(uri: uri, kind: .playlist, metadataItem: nil),
            remembered
        )

        sameSelection.updateSelection(.album("spotify:album:different"))
        runner.nil_(
            "different selection clears remembered fallback",
            sameSelection.item(uri: uri, kind: .playlist, metadataItem: nil)
        )

        var resetModel = restored ?? MediaSelectionModel()
        resetModel.reset()
        runner.equal("account reset returns home", resetModel.selection, .destination(.home))
        runner.nil_(
            "account reset clears remembered fallback",
            resetModel.item(uri: uri, kind: .playlist, metadataItem: nil)
        )

        let malformed = MediaSelectionModel(rawValue: "not persisted selection state")
        runner.equal("malformed persistence falls back home", malformed?.selection, .destination(.home))

        let legacyURI = "spotify:artist:legacy"
        var legacy = MediaSelectionModel(rawValue: SidebarSelection.artist(legacyURI).rawValue)
        runner.equal(
            "legacy scene selection remains restorable",
            legacy?.selection,
            .artist(legacyURI)
        )
        runner.check(
            "legacy sibling metadata migrates once",
            legacy?.migrateLegacyMetadata(
                title: "Legacy artist",
                subtitle: "Legacy subtitle",
                artworkURL: "https://example.invalid/legacy.jpg"
            ) == true
        )
        let migratedLegacyItem = item(uri: legacyURI, title: "Legacy artist", kind: .artist)
        let migrated = legacy.flatMap { MediaSelectionModel(rawValue: $0.rawValue) }
        runner.equal(
            "legacy metadata mounts a usable restored item",
            migrated?.item(uri: legacyURI, kind: .artist, metadataItem: nil),
            CatalogItem(
                id: migratedLegacyItem.id,
                uri: migratedLegacyItem.uri,
                title: migratedLegacyItem.title,
                subtitle: "Legacy subtitle",
                artworkURL: URL(string: "https://example.invalid/legacy.jpg"),
                kind: .artist
            )
        )

        let trackURI = "spotify:track:private-track-id"
        runner.equal(
            "track selection routes playback",
            model.select(item(uri: trackURI, title: "Track", kind: .track)),
            .play(trackURI)
        )
        runner.equal("track selection preserves navigation", model.selection, .playlist(uri))
        runner.equal(
            "track selection preserves remembered fallback",
            model.item(uri: uri, kind: .playlist, metadataItem: nil),
            remembered
        )

        let unknownURI = "spotify:episode:private-unknown-id"
        runner.equal(
            "unknown selection routes playback",
            model.select(item(uri: unknownURI, title: "Unknown", kind: .unknown)),
            .play(unknownURI)
        )
        runner.equal("unknown selection preserves navigation", model.selection, .playlist(uri))
        runner.equal(
            "unknown selection preserves remembered fallback",
            model.item(uri: uri, kind: .playlist, metadataItem: nil),
            remembered
        )
        runner.equal("diagnostics retain only the media kind", model.diagnosticLabel, "media:playlist")
        runner.check("diagnostics omit the selected URI", !model.diagnosticLabel.contains("private-id"))
    }
}

private func item(uri: String, title: String, kind: CatalogItem.Kind) -> CatalogItem {
    CatalogItem(
        id: SpotifyURI.id(from: uri) ?? uri,
        uri: uri,
        title: title,
        subtitle: "Synthetic subtitle",
        artworkURL: URL(string: "https://example.invalid/artwork.jpg"),
        kind: kind
    )
}
