import AuralDomain
import Foundation

func runPlaylistEditabilityChecks(_ check: CheckRunner) {
    func track(id: String, uri: String) -> CatalogTrack {
        CatalogTrack(
            id: id,
            uri: uri,
            title: id,
            artist: "",
            album: "",
            duration: 1,
            artworkURL: nil,
            addedAt: nil
        )
    }

    func playlist(uri: String, title: String, ownerURI: String?) -> CatalogItem {
        CatalogItem(
            id: uri,
            uri: uri,
            title: title,
            subtitle: "Owner",
            artworkURL: nil,
            kind: .playlist,
            ownerURI: ownerURI
        )
    }

    check.suite("Playlist ownership and editable-target filtering") {
        check.equal(
            "profile URI prefers the explicit user URI",
            PlaylistEditability.userURI(uri: "spotify:user:Ada", username: "ignored"),
            "spotify:user:ada"
        )
        check.equal(
            "username synthesizes a user URI",
            PlaylistEditability.userURI(uri: nil, username: "Ada"),
            "spotify:user:ada"
        )
        check.nil_(
            "a track URI is not a user identity",
            PlaylistEditability.userURI(uri: "spotify:track:abc", username: nil)
        )
        check.check(
            "matching owner and profile justify a write",
            PlaylistEditability.canJustifyEdit(
                playlistOwnerURI: "spotify:user:me",
                profileURI: "spotify:user:me"
            )
        )
        check.check(
            "someone else’s playlist is not advertised as editable",
            !PlaylistEditability.canJustifyEdit(
                playlistOwnerURI: "spotify:user:them",
                profileURI: "spotify:user:me"
            )
        )
        check.check(
            "missing owner metadata is not treated as editable",
            !PlaylistEditability.canJustifyEdit(playlistOwnerURI: nil, profileURI: "spotify:user:me")
        )
        check.check(
            "missing profile metadata is not treated as editable",
            !PlaylistEditability.canJustifyEdit(playlistOwnerURI: "spotify:user:me", profileURI: nil)
        )

        let items = [
            playlist(uri: "spotify:playlist:mine", title: "Mine", ownerURI: "spotify:user:me"),
            playlist(uri: "spotify:playlist:theirs", title: "Theirs", ownerURI: "spotify:user:them"),
            CatalogItem(
                id: "spotify:album:one",
                uri: "spotify:album:one",
                title: "Album",
                subtitle: "",
                artworkURL: nil,
                kind: .album,
                ownerURI: "spotify:user:me"
            ),
            playlist(uri: "spotify:playlist:unknown", title: "Unknown", ownerURI: nil),
        ]
        check.equal(
            "editable targets are owned library playlists only",
            PlaylistEditability.editablePlaylists(items, profileURI: "spotify:user:me").map(\.uri),
            ["spotify:playlist:mine"]
        )
        check.equal(
            "no profile means no writable targets",
            PlaylistEditability.editablePlaylists(items, profileURI: nil).map(\.uri),
            []
        )
    }

    check.suite("Playlist mutation selection, batch add, and occurrence removal") {
        let duplicateURI = "spotify:track:dup"
        let otherURI = "spotify:track:other"
        let rows = [
            track(id: "uid-a", uri: duplicateURI),
            track(id: "uid-b", uri: duplicateURI),
            track(id: "uid-c", uri: otherURI),
            track(id: duplicateURI, uri: duplicateURI),
        ]
        let selected = PlaylistMutationSelection.orderedTracks(
            selectedIDs: ["uid-b", "uid-a", "uid-b", duplicateURI],
            in: rows
        )
        check.equal(
            "selection follows playlist order and drops repeated IDs",
            selected.map(\.id),
            ["uid-a", "uid-b", duplicateURI]
        )
        check.equal(
            "batch add keeps duplicate URIs from distinct occurrences",
            PlaylistMutationSelection.addURIs(from: Array(selected.prefix(2))),
            [duplicateURI, duplicateURI]
        )
        check.equal(
            "removal uses Pathfinder UIDs, never the shared track URI",
            PlaylistMutationSelection.occurrenceIDsForRemoval(from: Array(selected.prefix(2))),
            ["uid-a", "uid-b"]
        )
        check.equal(
            "a URI-as-id row is not a removable occurrence",
            PlaylistMutationSelection.occurrenceIDsForRemoval(from: [rows[3]]),
            []
        )
        check.check(
            "add requires an editable target and at least one URI",
            PlaylistMutationSelection.canAdd(isTargetEditable: true, uris: [duplicateURI])
        )
        check.check(
            "add is refused for a read-only target",
            !PlaylistMutationSelection.canAdd(isTargetEditable: false, uris: [duplicateURI])
        )
        check.check(
            "remove requires an editable playlist and occurrence UIDs",
            PlaylistMutationSelection.canRemove(isPlaylistEditable: true, occurrenceIDs: ["uid-a"])
        )
        check.check(
            "read-only playlists cannot route destructive removal",
            !PlaylistMutationSelection.canRemove(isPlaylistEditable: false, occurrenceIDs: ["uid-a"])
        )
    }

    check.suite("Playlist keyboard command routing") {
        check.equal(
            "Delete on an editable selection removes occurrences",
            PlaylistMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                isPlaylistEditable: true,
                selectedOccurrenceCount: 2
            ),
            .removeOccurrences
        )
        check.equal(
            "Backspace uses the same native delete command",
            PlaylistMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                isPlaylistEditable: true,
                selectedOccurrenceCount: 1
            ),
            .removeOccurrences
        )
        check.nil_(
            "Delete does nothing in a read-only playlist",
            PlaylistMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                isPlaylistEditable: false,
                selectedOccurrenceCount: 2
            )
        )
        check.nil_(
            "Delete does nothing without a selection",
            PlaylistMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                isPlaylistEditable: true,
                selectedOccurrenceCount: 0
            )
        )
        check.nil_(
            "unrelated keys are not playlist removal",
            PlaylistMutationSelection.keyboardCommand(
                deleteOrBackspace: false,
                isPlaylistEditable: true,
                selectedOccurrenceCount: 2
            )
        )
    }

    check.suite("Playlist drag-to-playlist prototype decision") {
        check.check(
            "native drag onto playlist rows is not shipped",
            !PlaylistTrackDragDecision.shipsNativeDragAndDrop
        )
    }
}
