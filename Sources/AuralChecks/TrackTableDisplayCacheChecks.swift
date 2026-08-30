import AuralDomain
import Foundation

func runTrackTableDisplayCacheChecks(_ check: CheckRunner) {
    func track(
        id: String,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        addedAt: Date? = nil
    ) -> CatalogTrack {
        CatalogTrack(
            id: id,
            uri: "spotify:track:\(id)",
            title: title,
            artist: artist,
            album: album,
            duration: 1,
            artworkURL: nil,
            addedAt: addedAt
        )
    }

    check.suite("Catalog track collection revision") {
        var collection = CatalogTrackCollection()
        collection.replace([track(id: "a", title: "A"), track(id: "b", title: "B")])
        check.equal("first assignment bumps the revision", collection.revision, 1)
        check.equal("assignment publishes the new rows", collection.tracks.map(\.id), ["a", "b"])

        let equalReplacement = collection.tracks
        collection.replace(equalReplacement)
        check.equal("equal content still bumps so owners cannot skip a replacement", collection.revision, 2)
    }

    check.suite("Track table display cache") {
        let alpha = track(id: "alpha", title: "Alpha", artist: "B", album: "Z")
        let beta = track(id: "beta", title: "Beta", artist: "A", album: "Y")
        let gamma = track(id: "gamma", title: "Gamma", artist: "A", album: "X")
        let source = [gamma, alpha, beta]

        var cache = TrackTableDisplayCache(tracks: source, revision: 1)
        check.equal("empty sort keeps source order", cache.rows.map(\.id), ["gamma", "alpha", "beta"])

        let unrelated = [gamma, track(id: "middle", title: "Replaced"), beta]
        let hit = cache.update(tracks: unrelated, revision: 1, sortOrder: [])
        check.check("same revision and sort is a cache hit", !hit)
        check.equal(
            "unrelated invalidation does not adopt a same-count middle replacement",
            cache.rows.map(\.id),
            ["gamma", "alpha", "beta"]
        )

        let titleAscending: [KeyPathComparator<CatalogTrack>] = [KeyPathComparator(\.title)]
        check.check(
            "sort-field change recomputes",
            cache.update(tracks: source, revision: 1, sortOrder: titleAscending)
        )
        check.equal("title ascending uses the native comparator", cache.rows.map(\.id), ["alpha", "beta", "gamma"])

        let titleDescending: [KeyPathComparator<CatalogTrack>] = [
            KeyPathComparator(\.title, order: .reverse),
        ]
        check.check(
            "descending recomputes",
            cache.update(tracks: source, revision: 1, sortOrder: titleDescending)
        )
        check.equal("title descending reverses the column", cache.rows.map(\.id), ["gamma", "beta", "alpha"])

        let artistThenReverseTitle: [KeyPathComparator<CatalogTrack>] = [
            KeyPathComparator(\.artist),
            KeyPathComparator(\.title, order: .reverse),
        ]
        check.check(
            "multi-comparator recomputes",
            cache.update(tracks: source, revision: 1, sortOrder: artistThenReverseTitle)
        )
        check.equal(
            "artist then reverse title keeps comparator order",
            cache.rows.map(\.id),
            ["gamma", "beta", "alpha"]
        )

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let dated = [
            track(id: "undated", title: "Undated", addedAt: nil),
            track(id: "old", title: "Old", addedAt: older),
            track(id: "new", title: "New", addedAt: newer),
        ]
        var dateCache = TrackTableDisplayCache(tracks: dated, revision: 4)
        check.check(
            "date-added sort recomputes",
            dateCache.update(
                tracks: dated,
                revision: 4,
                sortOrder: [KeyPathComparator(\CatalogTrack.dateAddedSortValue)]
            )
        )
        check.equal(
            "nil dates sort as distantPast for the table column",
            dateCache.rows.map(\.id),
            ["undated", "old", "new"]
        )

        let first = track(id: "uid-a", title: "Zebra")
        let second = CatalogTrack(
            id: "uid-b",
            uri: first.uri,
            title: "Alpha",
            artist: first.artist,
            album: first.album,
            duration: first.duration,
            artworkURL: nil,
            addedAt: nil
        )
        let duplicates = [first, second]
        var duplicateCache = TrackTableDisplayCache(tracks: duplicates, revision: 7)
        _ = duplicateCache.update(tracks: duplicates, revision: 7, sortOrder: titleAscending)
        check.equal(
            "duplicate occurrences keep distinct identities after sort",
            duplicateCache.rows.map(\.id),
            ["uid-b", "uid-a"]
        )

        let originalMiddle = [alpha, beta, gamma]
        var replacementCache = TrackTableDisplayCache(tracks: originalMiddle, revision: 8)
        let replacedMiddle = [alpha, track(id: "beta-2", title: "Omega"), gamma]
        check.check(
            "same-count middle replacement recomputes when the revision bumps",
            replacementCache.update(tracks: replacedMiddle, revision: 9, sortOrder: titleAscending)
        )
        check.equal(
            "middle replacement participates in the new sort",
            replacementCache.rows.map(\.id),
            ["alpha", "gamma", "beta-2"]
        )

        let selection: Set<String> = ["alpha", "gone", "gamma"]
        check.equal(
            "selection pruning drops identities that left the authoritative collection",
            TrackTableDisplayCache.prunedSelection(selection, from: replacedMiddle),
            ["alpha", "gamma"]
        )
        check.equal(
            "empty selection stays empty",
            TrackTableDisplayCache.prunedSelection([], from: replacedMiddle),
            []
        )
    }
}
