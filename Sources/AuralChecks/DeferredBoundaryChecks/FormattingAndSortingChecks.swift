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
