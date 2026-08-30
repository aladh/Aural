//
//  TrackTableDisplayCache.swift
//  Aural
//

import Foundation

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
