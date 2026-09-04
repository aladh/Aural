//
//  PlaylistMutating.swift
//  Spotty
//
//  Focused playlist writes at the catalog boundary. Not part of CatalogProviding.
//

import Foundation

nonisolated protocol PlaylistMutating: Sendable {
    func addToPlaylist(playlistId: String, trackUris: [String]) async throws
    func removeFromPlaylist(playlistId: String, uids: [String]) async throws
}

extension PartnerAPI: PlaylistMutating {
    func addToPlaylist(playlistId: String, trackUris: [String]) async throws {
        try await addToPlaylist(playlistId: playlistId, trackUris: trackUris, position: .bottom)
    }
}

nonisolated struct UnavailablePlaylistMutations: PlaylistMutating {
    func addToPlaylist(playlistId _: String, trackUris: [String]) async throws {
        throw CatalogProviderCapabilityError.unsupported
    }

    func removeFromPlaylist(playlistId _: String, uids: [String]) async throws {
        throw CatalogProviderCapabilityError.unsupported
    }
}
