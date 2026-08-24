//
//  TrackSorting.swift
//  Aural
//

import Foundation

/// How a playlist's rows are ordered in the detail view.
public enum PlaylistDateSort {
    case playlistOrder
    case newestFirst
    case oldestFirst

    public var title: String {
        switch self {
        case .playlistOrder: "Playlist order"
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        }
    }

    public var symbolName: String {
        switch self {
        case .playlistOrder: "arrow.up.arrow.down"
        case .newestFirst: "chevron.down"
        case .oldestFirst: "chevron.up"
        }
    }

    /// The header is a sort control, not a mode picker: the first click chooses newest-first,
    /// and every later click reverses the date direction.
    public var toggledDateOrder: PlaylistDateSort {
        switch self {
        case .playlistOrder, .oldestFirst: .newestFirst
        case .newestFirst: .oldestFirst
        }
    }
}

/// Stable date-added ordering: dated rows sort by their date, undated rows
/// always sink below dated ones, and playlist order breaks every tie.
///
/// Pure so the controller can keep a sorted copy that is recomputed only when
/// the playlist or the sort changes — never inside a view's body evaluation,
/// where re-sorting thousands of rows per frame is wasted work.
public func sortedByDateAdded(
    _ tracks: [CatalogTrack],
    newestFirst: Bool,
) -> [CatalogTrack] {
    tracks.enumerated().sorted { left, right in
        switch (left.element.addedAt, right.element.addedAt) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return newestFirst ? leftDate > rightDate : leftDate < rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return left.offset < right.offset
        }
    }.map(\.element)
}
