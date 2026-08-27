import Foundation

/// Ownership comparison for playlist writes. Aural only advertises add/remove when the
/// signed-in profile URI matches the playlist owner; collaborative or stale permission
/// changes stay a typed Spotify rejection rather than a guessed capability.
public enum PlaylistEditability: Sendable {
    /// Canonical `spotify:user:` URI, or `nil` when the input cannot identify a user.
    public static func userURI(uri: String?, username: String?) -> String? {
        if let uri, let normalized = normalizeUserURI(uri) {
            return normalized
        }
        return username.flatMap { normalizeUserURI("spotify:user:\($0)") }
    }

    public static func normalizeUserURI(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let id = SpotifyURI.id(from: trimmed, kind: "user") {
            return "spotify:user:\(id)"
        }
        if !trimmed.contains(":") {
            return "spotify:user:\(trimmed)"
        }
        return nil
    }

    public static func canJustifyEdit(playlistOwnerURI: String?, profileURI: String?) -> Bool {
        guard let owner = playlistOwnerURI.flatMap(normalizeUserURI),
              let profile = profileURI.flatMap(normalizeUserURI)
        else {
            return false
        }
        return owner == profile
    }

    public static func editablePlaylists(_ items: [CatalogItem], profileURI: String?) -> [CatalogItem] {
        items.filter { item in
            item.kind == .playlist
                && canJustifyEdit(playlistOwnerURI: item.ownerURI, profileURI: profileURI)
        }
    }
}

/// Occurrence-safe selection for playlist mutations. Track URIs may repeat; `CatalogTrack.id`
/// is the Pathfinder occurrence uid in a playlist and must not be collapsed to a URI set.
public enum PlaylistMutationSelection: Sendable {
    public enum KeyboardCommand: Equatable, Sendable {
        case removeOccurrences
    }

    /// Selected rows in `tracks` order. A `Set` of IDs cannot emit the same occurrence twice.
    public static func orderedTracks(
        selectedIDs: Set<String>,
        in tracks: [CatalogTrack]
    ) -> [CatalogTrack] {
        tracks.filter { selectedIDs.contains($0.id) }
    }

    public static func addURIs(from tracks: [CatalogTrack]) -> [String] {
        tracks.map(\.uri).filter { !$0.isEmpty }
    }

    /// Pathfinder occurrence uids only. An id that is just the track URI is not a removable
    /// occurrence, because remove-by-URI would delete every duplicate copy.
    public static func occurrenceIDsForRemoval(from tracks: [CatalogTrack]) -> [String] {
        tracks.compactMap { track in
            let id = track.id
            guard !id.isEmpty, id != track.uri else { return nil }
            return id
        }
    }

    public static func canAdd(isTargetEditable: Bool, uris: [String]) -> Bool {
        isTargetEditable && !uris.isEmpty
    }

    public static func canRemove(isPlaylistEditable: Bool, occurrenceIDs: [String]) -> Bool {
        isPlaylistEditable && !occurrenceIDs.isEmpty
    }

    public static func keyboardCommand(
        deleteOrBackspace: Bool,
        isPlaylistEditable: Bool,
        selectedOccurrenceCount: Int
    ) -> KeyboardCommand? {
        guard deleteOrBackspace, isPlaylistEditable, selectedOccurrenceCount > 0 else {
            return nil
        }
        return .removeOccurrences
    }
}

/// Recorded result of the native drag-to-playlist prototype for issue #14.
///
/// SwiftUI `Table` transfer representations serialize the dragged row, not the
/// occurrence-aware multi-selection. Disabled drop targeting for non-editable
/// library rows cannot be proven without private hit-testing or pixel coordinates.
/// The context-menu Add to Playlist path and Delete/Backspace removal are the
/// keyboard-accessible equivalents, so drag UI is not shipped.
public enum PlaylistTrackDragDecision: Sendable {
    public static let shipsNativeDragAndDrop = false
}
