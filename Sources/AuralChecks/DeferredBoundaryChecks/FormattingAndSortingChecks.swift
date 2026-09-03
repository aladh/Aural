//
//  FormattingAndSortingChecks.swift
//  Aural
//

import AuralDomain
import Foundation
@testable import AuralCore

@MainActor
func runFormattingChecks(_ check: CheckRunner) {
    check.suite("Formatting") {
        check.equal("zero duration", formatDuration(0), "0:00")
        check.equal("sub-minute duration", formatDuration(59), "0:59")
        check.equal("crossing the minute", formatDuration(61), "1:01")
        // Long tracks are not wrapped into hours.
        check.equal("hour-plus duration", formatDuration(3_661), "61:01")
        check.equal("catalog durations round to nearest second", formatCatalogDuration(3.5), "0:04")
        check.equal("catalog durations clamp invalid values", formatCatalogDuration(-0.5), "0:00")
        check.equal(
            "catalog durations reject finite values outside Int range",
            formatCatalogDuration(.greatestFiniteMagnitude),
            "0:00"
        )
        check.equal("catalog duration seconds use the same rounded value", roundedCatalogDurationSeconds(61.6), 62)
        check.equal(
            "player durations reject finite values outside Int range",
            formatDuration(.greatestFiniteMagnitude),
            "0:00"
        )
        check.equal("playlist duration uses Spotify-style units", formatPlaylistDuration(2_564), "42 min 44 sec")
        check.equal("playlist duration omits a zero seconds component", formatPlaylistDuration(60), "1 min")
        check.equal("playlist duration clamps invalid values", formatPlaylistDuration(-5), "0 sec")
        check.equal("playlist duration uses hours without trailing minutes", formatPlaylistDuration(3_600), "1 hr")
        check.equal("playlist duration uses hours and minutes", formatPlaylistDuration(3_661), "1 hr 1 min")
        check.equal(
            "playlist durations reject finite values outside Int range",
            formatPlaylistDuration(.greatestFiniteMagnitude),
            "0 sec"
        )
        check.equal("missing date renders an em dash", formatDateAdded(nil), "—")
        check.equal(
            "playlist descriptions discard Spotify markup",
            PlaylistDescription.plainText(
                from:
                    #"A collection by <a href="https://open.spotify.com/artist/1">Bonobo</a> &amp; friends.<br>New music."#
            ),
            "A collection by Bonobo & friends.\nNew music."
        )
        check.nil_(
            "Spotify's epoch sentinel maps to a missing date",
            CatalogMapping.spotifyDate(from: "1970-01-01T00:00:00Z")
        )
        check.check(
            "a real Spotify timestamp still parses",
            CatalogMapping.spotifyDate(from: "2026-08-20T12:34:56Z") != nil
        )

        // Clock skew must not render negative durations.
        check.equal("negative duration clamps to zero", formatDuration(-5), "0:00")
    }

    func track(uri: String, duration: TimeInterval = 1) -> CatalogTrack {
        CatalogTrack(
            id: uri,
            uri: uri,
            title: uri,
            artist: "",
            album: "",
            duration: duration,
            artworkURL: nil,
            addedAt: nil
        )
    }

    func sortValues(
        popularity: Int? = nil,
        bpm: Int? = nil,
        key: String? = nil
    ) -> TrackTableSortValues {
        TrackTableSortValues(popularity: popularity, bpm: bpm, key: key)
    }

    func sortedURIs(
        _ tracks: [CatalogTrack],
        using comparator: KeyPathComparator<TrackTableRow>,
        sortValues: [String: TrackTableSortValues] = [:],
    ) -> [String] {
        let collection = CatalogTrackCollection(tracks: tracks)
        var cache = TrackTableDisplayCache(collection)
        _ = cache.update(
            collection,
            sortValues: sortValues,
            sortValuesRevision: 1,
            sortOrder: [comparator]
        )
        return cache.rows.map(\.track.uri)
    }

    check.suite("Track table sorting") {
        let short = track(uri: "short")
        let long = track(uri: "long", duration: 240)
        let missing = track(uri: "missing")
        let values = [
            "short": sortValues(popularity: 10, bpm: 90, key: "2A"),
            "long": sortValues(popularity: 80, bpm: 130, key: "10A"),
        ]

        check.equal(
            "popularity sorts ascending from displayed enrichment",
            sortedURIs(
                [long, short],
                using: KeyPathComparator(\TrackTableRow.popularitySortValue),
                sortValues: values
            ),
            ["short", "long"]
        )
        check.equal(
            "BPM reverses while missing enrichment stays last",
            sortedURIs(
                [missing, short, long],
                using: KeyPathComparator(\TrackTableRow.bpmSortValue, order: .reverse),
                sortValues: values
            ),
            ["long", "short", "missing"]
        )
        check.equal(
            "Camelot keys use numeric ordering",
            sortedURIs(
                [long, short],
                using: KeyPathComparator(\TrackTableRow.keySortValue),
                sortValues: values
            ),
            ["short", "long"]
        )
        check.equal(
            "time sorts by numeric duration",
            sortedURIs([long, short], using: KeyPathComparator(\TrackTableRow.duration)),
            ["short", "long"]
        )

        let equalAttributes = [
            "short": sortValues(popularity: 50),
            "long": sortValues(popularity: 50),
        ]
        check.equal(
            "missing values sort deterministically and equal values keep source order",
            sortedURIs(
                [missing, long, short],
                using: KeyPathComparator(\TrackTableRow.popularitySortValue),
                sortValues: equalAttributes
            ),
            ["long", "short", "missing"]
        )
    }
}
