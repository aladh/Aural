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
        check.equal("a fresh owner starts at revision zero", collection.revision, 0)

        collection.replace([track(id: "a", title: "A"), track(id: "b", title: "B")])
        check.equal("first replace bumps the revision", collection.revision, 1)
        check.equal("replace keeps the owner identity", collection.id, ownerID)
        check.equal("replace publishes the new rows", collection.tracks.map(\.id), ["a", "b"])

        let equalReplacement = collection.tracks
        collection.replace(equalReplacement)
        check.equal("equal content still bumps so owners cannot skip a replacement", collection.revision, 2)
        check.equal("later replace still keeps the owner identity", collection.id, ownerID)

        let seeded = CatalogTrackCollection(tracks: [track(id: "seed", title: "Seed")])
        check.equal("seeded construction still starts at revision zero", seeded.revision, 0)
        check.check("seeded construction still creates a new owner", seeded.id != collection.id)
    }

    check.suite("Track table display cache") {
        let alpha = track(id: "alpha", title: "Alpha", artist: "B", album: "Z")
        let beta = track(id: "beta", title: "Beta", artist: "A", album: "Y")
        let gamma = track(id: "gamma", title: "Gamma", artist: "A", album: "X")
        let source = [gamma, alpha, beta]

        var collection = CatalogTrackCollection()
        collection.replace(source)
        var cache = TrackTableDisplayCache(collection)
        check.equal("empty sort keeps source order", cache.rows.map(\.id), ["gamma", "alpha", "beta"])

        let snapshot = collection
        collection.replace([gamma, track(id: "middle", title: "Replaced"), beta])
        check.check("a copy of the previous generation is a cache hit", !cache.update(snapshot, sortOrder: []))
        check.equal(
            "unrelated invalidation does not adopt a later same-count replacement",
            cache.rows.map(\.id),
            ["gamma", "alpha", "beta"]
        )
        check.check(
            "copy plus replace recomputes when the revision advances",
            cache.update(collection, sortOrder: [])
        )
        check.equal(
            "rows follow the replaced generation",
            cache.rows.map(\.id),
            ["gamma", "middle", "beta"]
        )

        collection.replace(source)
        _ = cache.update(collection, sortOrder: [])
        let titleAscending: [KeyPathComparator<CatalogTrack>] = [KeyPathComparator(\.title)]
        check.check("sort-field change recomputes", cache.update(collection, sortOrder: titleAscending))
        check.equal("title ascending uses the native comparator", cache.rows.map(\.id), ["alpha", "beta", "gamma"])

        let titleDescending: [KeyPathComparator<CatalogTrack>] = [
            KeyPathComparator(\.title, order: .reverse),
        ]
        check.check("descending recomputes", cache.update(collection, sortOrder: titleDescending))
        check.equal("title descending reverses the column", cache.rows.map(\.id), ["gamma", "beta", "alpha"])

        let artistThenReverseTitle: [KeyPathComparator<CatalogTrack>] = [
            KeyPathComparator(\.artist),
            KeyPathComparator(\.title, order: .reverse),
        ]
        check.check("multi-comparator recomputes", cache.update(collection, sortOrder: artistThenReverseTitle))
        check.equal(
            "artist then reverse title keeps comparator order",
            cache.rows.map(\.id),
            ["gamma", "beta", "alpha"]
        )

        var other = CatalogTrackCollection()
        other.replace([beta])
        var peer = CatalogTrackCollection()
        peer.replace([alpha])
        check.equal("independently created owners can share a numeric revision", other.revision, peer.revision)
        check.check("independently created owners have distinct identities", other.id != peer.id)
        check.check(
            "a different collection at the same revision recomputes",
            cache.update(other, sortOrder: [])
        )
        check.equal("rows follow the new collection", cache.rows.map(\.id), ["beta"])

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        var dated = CatalogTrackCollection()
        dated.replace([
            track(id: "undated", title: "Undated", addedAt: nil),
            track(id: "old", title: "Old", addedAt: older),
            track(id: "new", title: "New", addedAt: newer),
        ])
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
        var duplicates = CatalogTrackCollection()
        duplicates.replace([first, second])
        var duplicateCache = TrackTableDisplayCache(duplicates)
        _ = duplicateCache.update(duplicates, sortOrder: titleAscending)
        check.equal(
            "duplicate occurrences keep distinct identities after sort",
            duplicateCache.rows.map(\.id),
            ["uid-b", "uid-a"]
        )

        var replacement = CatalogTrackCollection()
        replacement.replace([alpha, beta, gamma])
        var replacementCache = TrackTableDisplayCache(replacement)
        replacement.replace([alpha, track(id: "beta-2", title: "Omega"), gamma])
        check.check(
            "same-count middle replacement recomputes when the revision bumps",
            replacementCache.update(replacement, sortOrder: titleAscending)
        )
        check.equal(
            "middle replacement participates in the new sort",
            replacementCache.rows.map(\.id),
            ["alpha", "gamma", "beta-2"]
        )

        let selection: Set<String> = ["alpha", "gone", "gamma"]
        check.equal(
            "selection pruning drops identities that left the authoritative collection",
            TrackTableDisplayCache.prunedSelection(selection, from: replacement.tracks),
            ["alpha", "gamma"]
        )
        check.equal(
            "empty selection stays empty",
            TrackTableDisplayCache.prunedSelection([], from: replacement.tracks),
            []
        )
    }
}
