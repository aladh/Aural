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
                from: #"A collection by <a href="https://open.spotify.com/artist/1">Bonobo</a> &amp; friends.<br>New music."#
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
}

@MainActor
func runPlaylistSortingChecks(_ check: CheckRunner) {
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)

    func track(uri: String, addedAt: Date?) -> CatalogTrack {
        CatalogTrack(
            id: uri,
            uri: uri,
            title: uri,
            artist: "",
            album: "",
            duration: 1,
            artworkURL: nil,
            addedAt: addedAt
        )
    }

    func uris(_ tracks: [CatalogTrack]) -> [String] {
        tracks.map(\.uri)
    }

    check.suite("Playlist date sorting") {
        check.equal("first date sort click chooses newest", PlaylistDateSort.playlistOrder.toggledDateOrder, .newestFirst)
        check.equal("newest flips to oldest", PlaylistDateSort.newestFirst.toggledDateOrder, .oldestFirst)
        check.equal("oldest flips back to newest", PlaylistDateSort.oldestFirst.toggledDateOrder, .newestFirst)

        let datedPair = [track(uri: "older", addedAt: older), track(uri: "newer", addedAt: newer)]
        check.equal(
            "newest first puts later dates on top",
            uris(sortedByDateAdded(datedPair, newestFirst: true)),
            ["newer", "older"]
        )

        let reversedPair = [track(uri: "newer", addedAt: newer), track(uri: "older", addedAt: older)]
        check.equal(
            "oldest first reverses the direction",
            uris(sortedByDateAdded(reversedPair, newestFirst: false)),
            ["older", "newer"]
        )

        let undated = track(uri: "undated", addedAt: nil)
        let dated = track(uri: "dated", addedAt: older)
        check.equal(
            "undated rows sink in newest-first order",
            uris(sortedByDateAdded([undated, dated], newestFirst: true)),
            ["dated", "undated"]
        )
        check.equal(
            "undated rows sink in oldest-first order too",
            uris(sortedByDateAdded([undated, dated], newestFirst: false)),
            ["dated", "undated"]
        )

        // Ties must not reorder rows the listener curated.
        let tie = [
            track(uri: "second", addedAt: older),
            track(uri: "first", addedAt: older),
        ]
        check.equal(
            "equal dates keep playlist order",
            uris(sortedByDateAdded(tie, newestFirst: true)),
            ["second", "first"]
        )

        // With no dates at all every comparison falls to playlist order.
        let undatedOnly = [
            track(uri: "c", addedAt: nil),
            track(uri: "a", addedAt: nil),
            track(uri: "b", addedAt: nil),
        ]
        check.equal(
            "all-undated lists keep playlist order",
            uris(sortedByDateAdded(undatedOnly, newestFirst: true)),
            ["c", "a", "b"]
        )
        check.equal(
            "all-undated lists keep playlist order oldest-first too",
            uris(sortedByDateAdded(undatedOnly, newestFirst: false)),
            ["c", "a", "b"]
        )

        // Dated and undated rows interleaved: dated rows surface, undated rows sink
        // in their original relative order.
        let interleaved = [
            track(uri: "u1", addedAt: nil),
            track(uri: "old", addedAt: older),
            track(uri: "u2", addedAt: nil),
            track(uri: "new", addedAt: newer),
        ]
        check.equal(
            "undated rows sink together below dated ones",
            uris(sortedByDateAdded(interleaved, newestFirst: true)),
            ["new", "old", "u1", "u2"]
        )
    }
}
