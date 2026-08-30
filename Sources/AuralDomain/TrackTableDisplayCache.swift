//
//  TrackTableDisplayCache.swift
//  Aural
//

import Foundation

/// Authoritative catalog rows plus the revision that identifies that assignment.
///
/// `id` is stable for one owner. `revision` is unique only within that owner, so
/// `TrackTable` caches display order on `id` and `revision` plus SwiftUI `sortOrder`.
/// Equatable still compares the rows, so do not use this value as an `onChange` trigger.
public struct CatalogTrackCollection: Equatable, Sendable {
    public let id: UUID
    public private(set) var tracks: [CatalogTrack]
    public private(set) var revision: UInt64

    public init(id: UUID = UUID(), tracks: [CatalogTrack] = [], revision: UInt64 = 0) {
        self.id = id
        self.tracks = tracks
        self.revision = revision
    }

    public mutating func replace(_ tracks: [CatalogTrack]) {
        self.tracks = tracks
        revision &+= 1
    }
}

/// Cached projection of catalog rows for a native `Table` sort order.
///
/// Recompute when the owner identity, revision, or SwiftUI comparators change.
public struct TrackTableDisplayCache: Equatable, Sendable {
    public private(set) var rows: [CatalogTrack]
    private var sourceID: UUID
    private var revision: UInt64
    private var sortOrder: [KeyPathComparator<CatalogTrack>]

    public init(
        _ collection: CatalogTrackCollection = CatalogTrackCollection(),
        sortOrder: [KeyPathComparator<CatalogTrack>] = []
    ) {
        sourceID = collection.id
        revision = collection.revision
        self.sortOrder = sortOrder
        rows = Self.projected(tracks: collection.tracks, sortOrder: sortOrder)
    }

    /// Returns whether `rows` were rebuilt from `collection` and `sortOrder`.
    @discardableResult
    public mutating func update(
        _ collection: CatalogTrackCollection,
        sortOrder: [KeyPathComparator<CatalogTrack>]
    ) -> Bool {
        guard sourceID != collection.id || revision != collection.revision || self.sortOrder != sortOrder else {
            return false
        }
        sourceID = collection.id
        revision = collection.revision
        self.sortOrder = sortOrder
        rows = Self.projected(tracks: collection.tracks, sortOrder: sortOrder)
        return true
    }

    public static func prunedSelection(
        _ selection: Set<CatalogTrack.ID>,
        from tracks: [CatalogTrack]
    ) -> Set<CatalogTrack.ID> {
        selection.intersection(Set(tracks.map(\.id)))
    }

    private static func projected(
        tracks: [CatalogTrack],
        sortOrder: [KeyPathComparator<CatalogTrack>]
    ) -> [CatalogTrack] {
        sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder)
    }
}
