import AuralDomain
import Foundation

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

        let tie = [track(uri: "second", addedAt: older), track(uri: "first", addedAt: older)]
        check.equal(
            "equal dates keep playlist order",
            uris(sortedByDateAdded(tie, newestFirst: true)),
            ["second", "first"]
        )

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
