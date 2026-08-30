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
        let ownerID = collection.id
        collection.replace([track(id: "a", title: "A"), track(id: "b", title: "B")])
        check.equal("first assignment bumps the revision", collection.revision, 1)
        check.equal("replace keeps the owner identity", collection.id, ownerID)
        check.equal("assignment publishes the new rows", collection.tracks.map(\.id), ["a", "b"])

        let equalReplacement = collection.tracks
        collection.replace(equalReplacement)
        check.equal("equal content still bumps so owners cannot skip a replacement", collection.revision, 2)
        check.equal("later replace still keeps the owner identity", collection.id, ownerID)
    }

    check.suite("Track table display cache") {
        let alpha = track(id: "alpha", title: "Alpha", artist: "B", album: "Z")
        let beta = track(id: "beta", title: "Beta", artist: "A", album: "Y")
        let gamma = track(id: "gamma", title: "Gamma", artist: "A", album: "X")
        let source = [gamma, alpha, beta]
        let owner = UUID()
        let original = CatalogTrackCollection(id: owner, tracks: source, revision: 1)

        var cache = TrackTableDisplayCache(original)
        check.equal("empty sort keeps source order", cache.rows.map(\.id), ["gamma", "alpha", "beta"])

        let spoofed = CatalogTrackCollection(
            id: owner,
            tracks: [gamma, track(id: "middle", title: "Replaced"), beta],
            revision: 1
        )
        check.check("same owner revision and sort is a cache hit", !cache.update(spoofed, sortOrder: []))
        check.equal(
            "unrelated invalidation does not adopt a same-count middle replacement",
            cache.rows.map(\.id),
            ["gamma", "alpha", "beta"]
        )

        let titleAscending: [KeyPathComparator<CatalogTrack>] = [KeyPathComparator(\.title)]
        check.check("sort-field change recomputes", cache.update(original, sortOrder: titleAscending))
        check.equal("title ascending uses the native comparator", cache.rows.map(\.id), ["alpha", "beta", "gamma"])

        let titleDescending: [KeyPathComparator<CatalogTrack>] = [
            KeyPathComparator(\.title, order: .reverse),
        ]
        check.check("descending recomputes", cache.update(original, sortOrder: titleDescending))
        check.equal("title descending reverses the column", cache.rows.map(\.id), ["gamma", "beta", "alpha"])

        let artistThenReverseTitle: [KeyPathComparator<CatalogTrack>] = [
            KeyPathComparator(\.artist),
            KeyPathComparator(\.title, order: .reverse),
        ]
        check.check("multi-comparator recomputes", cache.update(original, sortOrder: artistThenReverseTitle))
        check.equal(
            "artist then reverse title keeps comparator order",
            cache.rows.map(\.id),
            ["gamma", "beta", "alpha"]
        )

        let foreign = CatalogTrackCollection(id: UUID(), tracks: [beta], revision: original.revision)
        check.equal("distinct owners can share a numeric revision", foreign.revision, original.revision)
        check.check(
            "a different collection at the same revision recomputes",
            cache.update(foreign, sortOrder: [])
        )
        check.equal("rows follow the new collection", cache.rows.map(\.id), ["beta"])

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let dated = CatalogTrackCollection(
            tracks: [
                track(id: "undated", title: "Undated", addedAt: nil),
                track(id: "old", title: "Old", addedAt: older),
                track(id: "new", title: "New", addedAt: newer),
            ],
            revision: 4
        )
        var dateCache = TrackTableDisplayCache(dated)
        check.check(
            "date-added sort recomputes",
            dateCache.update(dated, sortOrder: [KeyPathComparator(\CatalogTrack.dateAddedSortValue)])
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
        let duplicates = CatalogTrackCollection(tracks: [first, second], revision: 7)
        var duplicateCache = TrackTableDisplayCache(duplicates)
        _ = duplicateCache.update(duplicates, sortOrder: titleAscending)
        check.equal(
            "duplicate occurrences keep distinct identities after sort",
            duplicateCache.rows.map(\.id),
            ["uid-b", "uid-a"]
        )

        let originalMiddle = CatalogTrackCollection(id: owner, tracks: [alpha, beta, gamma], revision: 8)
        let replacedMiddle = CatalogTrackCollection(
            id: owner,
            tracks: [alpha, track(id: "beta-2", title: "Omega"), gamma],
            revision: 9
        )
        var replacementCache = TrackTableDisplayCache(originalMiddle)
        check.check(
            "same-count middle replacement recomputes when the revision bumps",
            replacementCache.update(replacedMiddle, sortOrder: titleAscending)
        )
        check.equal(
            "middle replacement participates in the new sort",
            replacementCache.rows.map(\.id),
            ["alpha", "gamma", "beta-2"]
        )

        let selection: Set<String> = ["alpha", "gone", "gamma"]
        check.equal(
            "selection pruning drops identities that left the authoritative collection",
            TrackTableDisplayCache.prunedSelection(selection, from: replacedMiddle.tracks),
            ["alpha", "gamma"]
        )
        check.equal(
            "empty selection stays empty",
            TrackTableDisplayCache.prunedSelection([], from: replacedMiddle.tracks),
            []
        )
    }
}
