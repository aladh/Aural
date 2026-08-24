//
//  TrackSorting.swift
//  Aural
//

import AuralDomain

typealias PlaylistDateSort = AuralDomain.PlaylistDateSort

func sortedByDateAdded(
    _ tracks: [CatalogTrack],
    newestFirst: Bool,
) -> [CatalogTrack] {
    AuralDomain.sortedByDateAdded(tracks, newestFirst: newestFirst)
}
