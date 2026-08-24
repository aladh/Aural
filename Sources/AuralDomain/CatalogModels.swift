//
//  CatalogModels.swift
//  Aural
//

import Foundation

/// One playable row in a track list.
public struct CatalogTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let uri: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let artworkURL: URL?
    public let addedAt: Date?

    public init(
        id: String,
        uri: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        artworkURL: URL?,
        addedAt: Date?
    ) {
        self.id = id
        self.uri = uri
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.addedAt = addedAt
    }
}

/// One card in the home shelves or a library grid.
public struct CatalogItem: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case album = "Album"
        case artist = "Artist"
        case playlist = "Playlist"
        case track = "Track"
        case unknown = "Spotify"
    }

    public let id: String
    public let uri: String
    public let title: String
    public let subtitle: String
    public let artworkURL: URL?
    public let kind: Kind

    public init(id: String, uri: String, title: String, subtitle: String, artworkURL: URL?, kind: Kind) {
        self.id = id
        self.uri = uri
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.kind = kind
    }
}

/// One shelf on the home page.
public struct CatalogSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [CatalogItem]

    public init(id: String, title: String, items: [CatalogItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}
