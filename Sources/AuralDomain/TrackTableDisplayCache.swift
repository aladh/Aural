//
//  TrackTableDisplayCache.swift
//  Aural
//

import Foundation

/// Owner-bumped identity of an authoritative `[CatalogTrack]` assignment.
///
/// Catalog stores pass value arrays into `TrackTable`. Playback and metadata observation can
/// re-evaluate that table without assigning a new collection, and same-count middle-element
/// replacement is a real playlist and search update. A `UInt64` revision is the cheapest sound
/// cache key: it does not scan the array, hash it, or fingerprint count/first/last/buffer identity.
public func replaceCatalogTracks(
    _ tracks: inout [CatalogTrack],
    revision: inout UInt64,
    with newTracks: [CatalogTrack]
) {
    tracks = newTracks
    revision &+= 1
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
