//
//  TrackTableDisplayCache.swift
//  Aural
//

import Foundation

/// Authoritative catalog rows plus the revision that identifies that assignment.
///
/// `TrackTable` caches display order on `revision` plus SwiftUI `sortOrder`. Equatable
/// still compares the rows, so do not use this value as an `onChange` trigger for that cache.
public struct CatalogTrackCollection: Equatable, Sendable {
    public private(set) var tracks: [CatalogTrack]
    public private(set) var revision: UInt64

    public init(tracks: [CatalogTrack] = [], revision: UInt64 = 0) {
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
/// Recompute only when the owner revision or SwiftUI comparators change. Unrelated body
/// evaluation must call `update` with the same inputs and keep the previous rows.
public struct TrackTableDisplayCache: Equatable, Sendable {
    public private(set) var rows: [CatalogTrack]
    private var revision: UInt64
    private var sortOrder: [KeyPathComparator<CatalogTrack>]

    public init(
        tracks: [CatalogTrack] = [],
        revision: UInt64 = 0,
        sortOrder: [KeyPathComparator<CatalogTrack>] = []
    ) {
        self.revision = revision
        self.sortOrder = sortOrder
        rows = Self.projected(tracks: tracks, sortOrder: sortOrder)
    }

    /// Returns whether `rows` were rebuilt from `tracks` and `sortOrder`.
    @discardableResult
    public mutating func update(
        tracks: [CatalogTrack],
        revision: UInt64,
        sortOrder: [KeyPathComparator<CatalogTrack>]
    ) -> Bool {
        guard self.revision != revision || self.sortOrder != sortOrder else {
            return false
        }
        self.revision = revision
        self.sortOrder = sortOrder
        rows = Self.projected(tracks: tracks, sortOrder: sortOrder)
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
