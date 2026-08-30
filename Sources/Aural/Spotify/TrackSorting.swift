//
//  TrackSorting.swift
//  Aural
//

import AuralDomain
import Foundation

struct TrackTableRow: Identifiable, Equatable {
    let track: CatalogTrack
    let popularitySortValue: Int
    let bpmSortValue: Int
    let keySortValue: TrackKeySortValue
    let sourceIndex: Int

    var id: CatalogTrack.ID { track.id }
    var title: String { track.title }
    var artist: String { track.artist }
    var album: String { track.album }
    var dateAddedSortValue: Date { track.addedAt ?? .distantPast }
    var duration: TimeInterval { track.duration }

    init(track: CatalogTrack, attributes: TrackAttributes?, sourceIndex: Int) {
        self.track = track
        popularitySortValue = attributes?.popularity ?? -1
        bpmSortValue = attributes?.bpm ?? -1
        keySortValue = TrackKeySortValue(attributes?.key ?? "")
        self.sourceIndex = sourceIndex
    }
}

struct TrackKeySortValue: Comparable, Equatable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value.compare(
            rhs.value,
            options: [.caseInsensitive, .numeric],
            locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedAscending
    }
}

func trackTableRows(
    _ tracks: [CatalogTrack],
    attributes: [String: TrackAttributes]
) -> [TrackTableRow] {
    tracks.enumerated().map { index, track in
        TrackTableRow(track: track, attributes: attributes[track.uri], sourceIndex: index)
    }
}

func sortedTrackTableRows(
    _ rows: [TrackTableRow],
    using comparators: [KeyPathComparator<TrackTableRow>]
) -> [TrackTableRow] {
    guard !comparators.isEmpty else { return rows }
    // KeyPathComparator sorting does not promise stability. Source order is the final descriptor,
    // preserving duplicate occurrences and equal or missing values deterministically.
    return rows.sorted(using: comparators + [KeyPathComparator(\.sourceIndex)])
}
