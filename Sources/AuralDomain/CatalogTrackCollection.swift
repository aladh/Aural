//
//  CatalogTrackCollection.swift
//  Aural
//

import Foundation

/// Authoritative catalog rows plus the revision that identifies that assignment.
///
/// `id` is created with the collection and never changes. `revision` starts at 0 and
/// advances only through `replace(_:)`. `TrackTable` caches display order on those two
/// values plus SwiftUI `sortOrder`. Equatable still compares the rows, so do not use
/// this value as an `onChange` trigger for that cache.
public struct CatalogTrackCollection: Equatable, Sendable {
    public let id: UUID
    public private(set) var tracks: [CatalogTrack]
    public private(set) var revision: UInt64

    public init(tracks: [CatalogTrack] = []) {
        id = UUID()
        self.tracks = tracks
        revision = 0
    }

    public mutating func replace(_ tracks: [CatalogTrack]) {
        self.tracks = tracks
        revision &+= 1
    }
}
