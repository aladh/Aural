//
//  CatalogTrackCollection.swift
//  Spotty
//

import Foundation

/// Authoritative catalog rows plus one opaque version per assignment.
///
/// `init` and `replace(_:)` each mint a new `version`. Copies share a version until
/// one of them replaces. `TrackTable` caches display order on `version` plus SwiftUI
/// `sortOrder`, not on row equality.
public struct CatalogTrackCollection: Sendable {
    public private(set) var tracks: [CatalogTrack]
    public private(set) var version: UUID

    public init(tracks: [CatalogTrack] = []) {
        self.tracks = tracks
        version = UUID()
    }

    public mutating func replace(_ tracks: [CatalogTrack]) {
        self.tracks = tracks
        version = UUID()
    }
}
