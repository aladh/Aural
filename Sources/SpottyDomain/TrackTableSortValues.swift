//
//  TrackTableSortValues.swift
//  Spotty
//

import Foundation

public struct TrackTableSortValues: Equatable, Sendable {
    public let popularity: Int?
    public let bpm: Int?
    public let key: String?

    public init(popularity: Int?, bpm: Int?, key: String?) {
        self.popularity = popularity
        self.bpm = bpm
        self.key = key
    }
}

public struct TrackTableRow: Identifiable, Equatable, Sendable {
    public let track: CatalogTrack
    public let popularitySortValue: Int
    public let bpmSortValue: Int
    public let keySortValue: TrackKeySortValue
    public let sourceIndex: Int
    let hasPopularity: Bool
    let hasBPM: Bool
    let hasKey: Bool

    public var id: CatalogTrack.ID { track.id }
    public var title: String { track.title }
    public var artist: String { track.artist }
    public var album: String { track.album }
    public var dateAddedSortValue: Date { track.addedAt ?? .distantPast }
    public var duration: TimeInterval { track.duration }

    init(track: CatalogTrack, sortValues: TrackTableSortValues?, sourceIndex: Int) {
        self.track = track
        popularitySortValue = sortValues?.popularity ?? -1
        bpmSortValue = sortValues?.bpm ?? -1
        keySortValue = TrackKeySortValue(sortValues?.key ?? "")
        self.sourceIndex = sourceIndex
        hasPopularity = sortValues?.popularity != nil
        hasBPM = sortValues?.bpm != nil
        hasKey = sortValues?.key != nil
    }
}

public struct TrackKeySortValue: Comparable, Equatable, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value.compare(
            rhs.value,
            options: [.caseInsensitive, .numeric],
            locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedAscending
    }
}

public extension Array where Element == KeyPathComparator<TrackTableRow> {
    var usesTrackAttributes: Bool {
        contains { $0.isPopularity || $0.isBPM || $0.isKey }
    }
}

extension KeyPathComparator where Compared == TrackTableRow {
    var isPopularity: Bool {
        self == KeyPathComparator(\TrackTableRow.popularitySortValue, order: order)
    }

    var isBPM: Bool {
        self == KeyPathComparator(\TrackTableRow.bpmSortValue, order: order)
    }

    var isKey: Bool {
        self == KeyPathComparator(\TrackTableRow.keySortValue, order: order)
    }

    var isDateAdded: Bool {
        self == KeyPathComparator(\TrackTableRow.dateAddedSortValue, order: order)
    }
}
