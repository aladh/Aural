//
//  FormattingAndSortingChecks.swift
//  Aural
//

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

    func attributes(
        popularity: Int? = nil,
        bpm: Int? = nil,
        key: String? = nil
    ) -> TrackAttributes {
        TrackAttributes(popularity: popularity, bpm: bpm, key: key)
    }

    func sortedURIs(
        _ tracks: [CatalogTrack],
        using comparator: KeyPathComparator<TrackTableRow>,
        attributes: [String: TrackAttributes] = [:],
    ) -> [String] {
        sortedTrackTableRows(
            trackTableRows(tracks, attributes: attributes),
            using: [comparator]
        ).map(\.track.uri)
    }

    check.suite("Track table sorting") {
        let short = track(uri: "short")
        let long = track(uri: "long", duration: 240)
        let missing = track(uri: "missing")
        let values = [
            "short": attributes(popularity: 10, bpm: 90, key: "2A"),
            "long": attributes(popularity: 80, bpm: 130, key: "10A"),
        ]

        check.equal(
            "popularity sorts ascending from displayed enrichment",
            sortedURIs(
                [long, short],
                using: KeyPathComparator(\.popularitySortValue),
                attributes: values
            ),
            ["short", "long"]
        )
        check.equal(
            "BPM reverses while missing enrichment stays last",
            sortedURIs(
                [missing, short, long],
                using: KeyPathComparator(\.bpmSortValue, order: .reverse),
                attributes: values
            ),
            ["long", "short", "missing"]
        )
        check.equal(
            "Camelot keys use numeric ordering",
            sortedURIs(
                [long, short],
                using: KeyPathComparator(\.keySortValue),
                attributes: values
            ),
            ["short", "long"]
        )
        check.equal(
            "time sorts by numeric duration",
            sortedURIs([long, short], using: KeyPathComparator(\.duration)),
            ["short", "long"]
        )

        let equalAttributes = [
            "short": attributes(popularity: 50),
            "long": attributes(popularity: 50),
        ]
        check.equal(
            "missing values sort deterministically and equal values keep source order",
            sortedURIs(
                [missing, long, short],
                using: KeyPathComparator(\.popularitySortValue),
                attributes: equalAttributes
            ),
            ["missing", "long", "short"]
        )
    }
}
